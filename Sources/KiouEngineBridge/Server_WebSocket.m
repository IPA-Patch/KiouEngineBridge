#import "Internal.h"

#import <CommonCrypto/CommonDigest.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>

// ===========================================================================
// Server_WebSocket — minimal RFC 6455 server, one client at a time.
//
// Lives entirely inside the tweak process. Listens on 0.0.0.0:<port> and lets
// a single host (the TypeScript bridge running on a Mac / Linux box on the
// same LAN) connect. Every observed move / snapshot is shipped as one JSON
// object inside a single text frame. No fragmentation, no compression.
//
// What it implements:
//   - Listen socket via GCD dispatch source (DISPATCH_SOURCE_TYPE_READ on
//     a non-blocking accepting socket).
//   - One concurrent client. A second incoming connection is accepted only
//     to immediately close it with HTTP 409 so the network stack stops
//     half-opening the TCP handshake.
//   - HTTP/1.1 Upgrade handshake on the only accepted connection. Verifies
//     Sec-WebSocket-Key, replies with the SHA-1+base64 accept token.
//   - Text frames out (opcode 0x1, FIN=1, mask=0). Two-byte and eight-byte
//     extended payload-length forms are both supported.
//   - Inbound Ping (0x9) → Pong (0xA), inbound Close (0x8) → tear down. Any
//     other inbound opcode is logged and dropped.
//   - A serial GCD queue funnels every KEBWsServerPush() through one
//     producer-consumer slot. If the queue length crosses a soft cap we
//     drop the oldest pending frame and log a [WS] warning. This keeps
//     a stalled host from back-pressuring the Unity main thread.
//
// What it deliberately doesn't do:
//   - TLS. The tweak runs on a LAN; the upstream host is trusted. No certs
//     to ship, no entitlement to coax.
//   - Per-message-deflate. tsshogi-friendly text frames are tiny.
//   - Multi-client fan-out. One bridge, one debugger — keep it boring.
//   - Backpressure / flow control beyond the drop policy above.
//
// All log lines tagged [WS] land in the shared kiouenginebridge.log via
// file_log() so a quiet socket is still debuggable from outside.
// ===========================================================================

// ---------------------------------------------------------------------------
// Tunables. Cap is deliberately low — the realistic event rate is ~2 / sec.
// ---------------------------------------------------------------------------
#define WS_QUEUE_DROP_THRESHOLD     128
#define WS_HANDSHAKE_MAX_BYTES      8192
#define WS_RECV_CHUNK               2048
#define WS_GUID                     "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// ---------------------------------------------------------------------------
// Singleton-ish state. The whole module assumes at most one server per
// process, which matches the way Tweak.m calls KEBWsServerStart() once.
// ---------------------------------------------------------------------------
static dispatch_queue_t g_acceptQueue = NULL;   // serial, handshake + writes
static dispatch_queue_t g_recvQueue   = NULL;   // serial, blocking client reads
static dispatch_source_t g_listenSrc  = NULL;   // listen-fd readable source
static int g_listenFd = -1;
static int g_clientFd = -1;                     // -1 = no client
static BOOL g_clientHandshakeDone = NO;
static NSUInteger g_pendingSends = 0;           // best-effort backlog gauge

// Inbound text-frame callback. Inject_Move.m self-registers via
// KEBWsServerSetTextHandler() at constructor time. Reads happen on
// g_recvQueue; the setter just stores the function pointer (8-byte aligned
// pointer writes are atomic on arm64 so we don't bother with a barrier).
static kiou_ws_text_handler_t g_textHandler = NULL;

// ---------------------------------------------------------------------------
// Helpers — socket plumbing
// ---------------------------------------------------------------------------
static void ws_set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

// Enable SO_KEEPALIVE with aggressive timers so a silently-dead peer
// (= bridge SIGKILL'd, network cable yanked) is detected within ~15s
// rather than the Darwin default of ~2 hours. Without this the recv
// loop can sit blocked on a peer that's been gone forever, with
// g_clientFd still held, which means the next bridge connect attempt
// gets refused with the "Already serving someone" 409 below.
//
// TCP_KEEPALIVE  is Darwin's name for the idle-time-before-probe knob.
// TCP_KEEPINTVL  is the interval between probes once started.
// TCP_KEEPCNT    is how many lost probes count as "peer is dead".
// 5s idle + 3s × 3 probes = peer death detected ~15s after a dirty drop.
//
// All four setsockopt calls are best-effort — if the kernel refuses one
// the worst case is we fall back to the OS default, which is "slow but
// works".
static void ws_set_keepalive(int fd) {
    int on = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof(on));
    int idle = 5;          // seconds of idle before the first probe
    int intvl = 3;         // seconds between subsequent probes
    int count = 3;         // probes lost before declaring the peer dead
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle,  sizeof(idle));
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT,   &count, sizeof(count));
}

static BOOL ws_send_all(int fd, const uint8_t *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, buf + off, len - off, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) return NO;
        off += (size_t)n;
    }
    return YES;
}

// Blocking read of exactly `len` bytes. Returns NO on EOF / error.
static BOOL ws_recv_all(int fd, uint8_t *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = recv(fd, buf + off, len - off, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) return NO;
        off += (size_t)n;
    }
    return YES;
}

static void ws_close_client(void) {
    bool wasUp = (g_clientFd >= 0);
    if (g_clientFd >= 0) {
        close(g_clientFd);
        g_clientFd = -1;
    }
    g_clientHandshakeDone = NO;
    g_pendingSends = 0;
    if (wasUp) {
        // Phase 2: let the USI engine driver reset its state machine. Safe
        // to call even if no engine module is wired (the symbol is always
        // linked, since the same translation unit defines an empty stub
        // when Usi_Engine.m is absent — not the case in this build).
        UsiEngineOnWsClientDisconnected();
    }
}

// ---------------------------------------------------------------------------
// Handshake — parse "Sec-WebSocket-Key: <key>" out of the request and reply
// with the matching accept token. Permissive about headers we don't care
// about; we only need the key.
// ---------------------------------------------------------------------------
static NSString *ws_compute_accept(NSString *key) {
    NSString *combo = [key stringByAppendingString:@WS_GUID];
    const char *cstr = combo.UTF8String;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cstr, (CC_LONG)strlen(cstr), digest);
    NSData *data = [NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
    return [data base64EncodedStringWithOptions:0];
}

static NSString *ws_extract_key(NSString *request) {
    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    for (NSString *line in lines) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[line substringToIndex:colon.location]
                          stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
        if ([name caseInsensitiveCompare:@"Sec-WebSocket-Key"] != NSOrderedSame) continue;
        NSString *value = [[line substringFromIndex:colon.location + 1]
                           stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
        return value;
    }
    return nil;
}

// Slurp the HTTP request up to and including the blank line. Cap at
// WS_HANDSHAKE_MAX_BYTES so a confused / hostile peer can't keep us reading.
static NSString *ws_read_handshake(int fd) {
    NSMutableData *acc = [NSMutableData data];
    uint8_t chunk[WS_RECV_CHUNK];
    while (acc.length < WS_HANDSHAKE_MAX_BYTES) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return nil;
        }
        if (n == 0) return nil;
        [acc appendBytes:chunk length:(NSUInteger)n];
        if ([acc rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                     options:0
                       range:NSMakeRange(0, acc.length)].location != NSNotFound) {
            break;
        }
    }
    return [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding];
}

static BOOL ws_perform_handshake(int fd) {
    NSString *request = ws_read_handshake(fd);
    if (!request) {
        file_log(@"[WS] handshake: client closed before request");
        return NO;
    }
    NSString *key = ws_extract_key(request);
    if (!key) {
        file_log(@"[WS] handshake: missing Sec-WebSocket-Key");
        const char *bad = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
        ws_send_all(fd, (const uint8_t *)bad, strlen(bad));
        return NO;
    }
    NSString *accept = ws_compute_accept(key);
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 101 Switching Protocols\r\n"
        @"Upgrade: websocket\r\n"
        @"Connection: Upgrade\r\n"
        @"Sec-WebSocket-Accept: %@\r\n"
        @"\r\n", accept];
    const char *bytes = response.UTF8String;
    return ws_send_all(fd, (const uint8_t *)bytes, strlen(bytes));
}

// ---------------------------------------------------------------------------
// Frame emit — unmasked, opcode 0x1, FIN=1.
// ---------------------------------------------------------------------------
static BOOL ws_send_text(int fd, NSString *text) {
    NSData *payload = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger len = payload.length;

    uint8_t header[10];
    size_t headerLen = 0;
    header[0] = 0x81;  // FIN=1, opcode=text
    if (len < 126) {
        header[1] = (uint8_t)len;
        headerLen = 2;
    } else if (len < 65536) {
        header[1] = 126;
        header[2] = (uint8_t)((len >> 8) & 0xFF);
        header[3] = (uint8_t)(len & 0xFF);
        headerLen = 4;
    } else {
        header[1] = 127;
        uint64_t l64 = (uint64_t)len;
        for (int i = 0; i < 8; i++) {
            header[2 + i] = (uint8_t)((l64 >> (8 * (7 - i))) & 0xFF);
        }
        headerLen = 10;
    }
    if (!ws_send_all(fd, header, headerLen)) {
        file_log([NSString stringWithFormat:
                  @"[WS-DBG] ws_send_text header send FAILED len=%lu errno=%d",
                  (unsigned long)len, errno]);
        return NO;
    }
    BOOL ok = ws_send_all(fd, payload.bytes, len);
    if (!ok) {
        file_log([NSString stringWithFormat:
                  @"[WS-DBG] ws_send_text body send FAILED len=%lu errno=%d",
                  (unsigned long)len, errno]);
    }
    return ok;
}

static BOOL ws_send_pong(int fd, const uint8_t *payload, size_t len) {
    uint8_t header[4];
    size_t headerLen;
    header[0] = 0x8A;  // FIN=1, opcode=pong
    if (len < 126) {
        header[1] = (uint8_t)len;
        headerLen = 2;
    } else {
        // Pings shouldn't carry > 125 bytes per spec, but be defensive.
        header[1] = 126;
        header[2] = (uint8_t)((len >> 8) & 0xFF);
        header[3] = (uint8_t)(len & 0xFF);
        headerLen = 4;
    }
    if (!ws_send_all(fd, header, headerLen)) return NO;
    if (len == 0) return YES;
    return ws_send_all(fd, payload, len);
}

// ---------------------------------------------------------------------------
// Inbound frame loop — runs on g_recvQueue while a client is attached.
// We expect Ping / Close / occasional small text frames from the host. The
// only mandatory work is responding to Ping and reacting to Close.
// ---------------------------------------------------------------------------
static void ws_client_recv_loop(int fd) {
    while (1) {
        uint8_t hdr[2];
        if (!ws_recv_all(fd, hdr, 2)) {
            file_log(@"[WS-DBG] recv hdr failed (EOF or error)");
            break;
        }
        BOOL fin    = (hdr[0] & 0x80) != 0;
        uint8_t op  = hdr[0] & 0x0F;
        BOOL masked = (hdr[1] & 0x80) != 0;
        uint64_t plen = hdr[1] & 0x7F;
        (void)fin;
        file_log([NSString stringWithFormat:
                  @"[WS-DBG] frame op=0x%x fin=%d masked=%d plen=%llu",
                  op, (int)fin, (int)masked, plen]);

        if (plen == 126) {
            uint8_t ex[2];
            if (!ws_recv_all(fd, ex, 2)) break;
            plen = ((uint64_t)ex[0] << 8) | ex[1];
        } else if (plen == 127) {
            uint8_t ex[8];
            if (!ws_recv_all(fd, ex, 8)) break;
            plen = 0;
            for (int i = 0; i < 8; i++) plen = (plen << 8) | ex[i];
        }

        uint8_t mask[4] = {0};
        if (masked) {
            if (!ws_recv_all(fd, mask, 4)) break;
        }

        // Cap inbound payloads — we never need more than control-frame sized
        // input. A megabyte ceiling kills runaway peers without making us
        // worry about heap blowup.
        if (plen > (1 << 20)) {
            file_log([NSString stringWithFormat:
                      @"[WS] oversize inbound frame plen=%llu, closing",
                      plen]);
            break;
        }

        uint8_t *body = NULL;
        if (plen > 0) {
            body = (uint8_t *)malloc((size_t)plen);
            if (!body) break;
            if (!ws_recv_all(fd, body, (size_t)plen)) { free(body); break; }
            if (masked) {
                for (uint64_t i = 0; i < plen; i++) body[i] ^= mask[i & 3];
            }
        }

        if (op == 0x8) {                                 // close
            file_log(@"[WS-DBG] received CLOSE from client, exiting loop");
            if (body) free(body);
            break;
        } else if (op == 0x9) {                          // ping
            // Marshal the pong onto the accept queue — same queue that
            // ws_send_text uses — so we don't interleave a pong frame
            // halfway through an outbound text frame. Without this both
            // ws_send_text (from KEBWsServerPush -> accept queue) and
            // ws_send_pong (from this recv queue) could be writing the same
            // fd concurrently, fragmenting frames and tripping client-side
            // protocol parsers (= Python websockets sees a corrupt frame
            // after its 20s keepalive ping and closes the connection).
            file_log(@"[WS-DBG] ping received, scheduling pong");
            NSData *pingPayload = (plen > 0 && body)
                ? [NSData dataWithBytes:body length:(NSUInteger)plen]
                : nil;
            int captured_fd = fd;
            dispatch_async(g_acceptQueue, ^{
                if (g_clientFd != captured_fd) return;
                ws_send_pong(captured_fd,
                             pingPayload.bytes,
                             (size_t)pingPayload.length);
            });
        } else if (op == 0x1) {                          // text
            // The bridge sends raw USI lines here ("bestmove 7g7f",
            // "bestmove resign"). Hand them to whichever handler the
            // injection module installed; if nobody's listening, drop
            // silently so a stray frame is a no-op rather than an error.
            if (g_textHandler && body && plen > 0) {
                g_textHandler((const char *)body, (size_t)plen);
            }
        } else if (op == 0x2 || op == 0xA) {
            // binary / pong — informational; the bridge never sends these.
        } else {
            file_log([NSString stringWithFormat:
                      @"[WS] dropping inbound opcode 0x%x", op]);
        }
        if (body) free(body);
    }

    file_log(@"[WS] client recv loop exited");
    dispatch_async(g_acceptQueue, ^{
        ws_close_client();
    });
}

// ---------------------------------------------------------------------------
// Listen-source handler — accept one connection, run the handshake on the
// accept queue, then hand the fd off to the recv queue's blocking loop.
// ---------------------------------------------------------------------------
static void ws_handle_accept(void) {
    struct sockaddr_in peer;
    socklen_t peerLen = sizeof(peer);
    int fd = accept(g_listenFd, (struct sockaddr *)&peer, &peerLen);
    if (fd < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            file_log([NSString stringWithFormat:@"[WS] accept errno=%d", errno]);
        }
        return;
    }

    char ip[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));

    // New-client-wins policy. The previous "1 client only, second one
    // gets 409" rule made bridge restarts painful: a Ctrl-C'd bridge can
    // leave the TCP session in TIME_WAIT on its side, the kernel here
    // hasn't yet noticed EOF, the recv loop is still parked on a dead
    // fd, and the freshly-spawned bridge eats a 409. Since the bridge
    // is the only legitimate WS client (control of the engine —
    // observers are out of scope on this socket), an incoming connect
    // is unambiguous evidence that the previous holder is gone. Close
    // the old fd from the accept queue (same queue ws_close_client
    // runs on — no cross-queue race), then carry on accepting the new
    // peer.
    if (g_clientFd >= 0) {
        file_log([NSString stringWithFormat:
                  @"[WS] preempt: closing prior client fd=%d to make room "
                  @"for %s:%u",
                  g_clientFd, ip, (unsigned)ntohs(peer.sin_port)]);
        ws_close_client();
    }

    file_log([NSString stringWithFormat:@"[WS] accepted from %s:%u fd=%d",
              ip, (unsigned)ntohs(peer.sin_port), fd]);

    // accept() inherits the non-blocking flag from the listen socket on Darwin,
    // which breaks our blocking ws_recv_all loop (it returns immediately with
    // EAGAIN and we mistake that for EOF). Force the client fd back to
    // blocking I/O — the recv loop lives on its own dispatch queue, so
    // blocking there is fine.
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);

    // SO_KEEPALIVE + tight intervals: dead peers detected in ~15s
    // instead of the Darwin default 2-hour idle. Keeps the recv loop
    // from blocking forever on a bridge that vanished without sending
    // a Close frame.
    ws_set_keepalive(fd);

    if (!ws_perform_handshake(fd)) {
        close(fd);
        return;
    }
    g_clientFd = fd;
    g_clientHandshakeDone = YES;
    file_log(@"[WS] handshake OK");
    // Phase 2: hand off to the USI engine driver. It owns the post-handshake
    // protocol (sending `usi`, awaiting `usiok`, etc.). Server_WebSocket is
    // back to being a plain transport.
    UsiEngineOnWsClientConnected();

    // Drain inbound on a separate queue so the accept queue is never blocked
    // by a slow / silent peer.
    dispatch_async(g_recvQueue, ^{
        ws_client_recv_loop(fd);
    });
}

// ---------------------------------------------------------------------------
// Public API.
// ---------------------------------------------------------------------------
void KEBWsServerStart(uint16_t port) {
    if (g_listenFd >= 0) {
        file_log(@"[WS] server already running");
        return;
    }

    g_acceptQueue = dispatch_queue_create("io.kiou.usi.ws.accept",
                                          DISPATCH_QUEUE_SERIAL);
    g_recvQueue   = dispatch_queue_create("io.kiou.usi.ws.recv",
                                          DISPATCH_QUEUE_SERIAL);

    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
        file_log([NSString stringWithFormat:@"[WS] socket errno=%d", errno]);
        return;
    }

    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        file_log([NSString stringWithFormat:@"[WS] bind errno=%d port=%u",
                  errno, (unsigned)port]);
        close(s);
        return;
    }
    if (listen(s, 4) < 0) {
        file_log([NSString stringWithFormat:@"[WS] listen errno=%d", errno]);
        close(s);
        return;
    }
    ws_set_nonblock(s);
    g_listenFd = s;

    g_listenSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                         (uintptr_t)s, 0, g_acceptQueue);
    dispatch_source_set_event_handler(g_listenSrc, ^{
        ws_handle_accept();
    });
    dispatch_resume(g_listenSrc);

    file_log([NSString stringWithFormat:@"[WS] listening on 0.0.0.0:%u",
              (unsigned)port]);
}

void KEBWsServerSetTextHandler(kiou_ws_text_handler_t fn) {
    // Pointer write — atomic on arm64. No barrier needed; the worst-case
    // race is a single recv-loop iteration reading the previous handler,
    // which is fine because handlers are always installed before the bridge
    // can finish its TCP handshake.
    g_textHandler = fn;
}

void KEBWsServerPush(NSString *json) {
    if (!json) return;
    if (!g_acceptQueue) return;  // server never started

    // Cheap shortcut: no client means nothing to do. We still allow the log
    // sinks to record everything; the WS path is purely additive.
    if (g_clientFd < 0 || !g_clientHandshakeDone) return;

    if (g_pendingSends >= WS_QUEUE_DROP_THRESHOLD) {
        // Back-pressure: don't pile up. file_log only every now and then or
        // a stuck host floods the disk.
        if ((g_pendingSends % 32) == 0) {
            file_log([NSString stringWithFormat:
                      @"[WS] drop: backlog=%lu",
                      (unsigned long)g_pendingSends]);
        }
        return;
    }

    g_pendingSends++;
    NSString *copy = [json copy];
    dispatch_async(g_acceptQueue, ^{
        int fd = g_clientFd;
        if (fd < 0) {
            g_pendingSends--;
            return;
        }
        BOOL ok = ws_send_text(fd, copy);
        g_pendingSends--;
        if (!ok) {
            file_log(@"[WS] send failed, dropping client");
            ws_close_client();
        }
    });
}
