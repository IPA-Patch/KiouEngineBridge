#import "Internal.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import <unistd.h>

// ===========================================================================
// Server_CSA — minimal CSA server protocol transport, one client at a time.
//
// Replaces Server_WebSocket.m as part of the CSA migration
// (docs/plans/kiou_engine_bridge_csa_migration.md). The shape is the same as
// the deprecated WebSocket server (single client, GCD accept/recv queue
// split, SO_KEEPALIVE for fast dead-peer detection) but the wire format is
// dramatically simpler — CSA is a raw line-oriented TCP protocol with no
// framing, no upgrade handshake, no masking, no compression.
//
// What it implements:
//   - Listen on 0.0.0.0:<port> via GCD dispatch source.
//   - One concurrent client. A second incoming connection preempts the
//     stale one — same new-client-wins policy as the WS server.
//   - LF-terminated UTF-8 lines in both directions. Lines may also be
//     CRLF-terminated on the inbound side; we tolerate either.
//   - A serial GCD queue funnels every KEBCsaServerPush() through one
//     producer-consumer slot. If the queue length crosses a soft cap we
//     drop the new line and log a [CSA] warning.
//
// What it deliberately doesn't do:
//   - TLS. CSA's TCP transport is unencrypted by design.
//   - LOGIN authentication. The CSA engine driver (Csa_Engine.m) accepts
//     any LOGIN line and replies with `LOGIN:<name> OK`; this server only
//     handles the transport.
//   - Multi-client fan-out.
//
// All log lines are tagged [CSA] in the shared kiouenginebridge.log.
// ===========================================================================

// ---------------------------------------------------------------------------
// Tunables.
// ---------------------------------------------------------------------------
#define CSA_QUEUE_DROP_THRESHOLD    128
#define CSA_RECV_CHUNK              4096
#define CSA_LINE_MAX                65536  // hard cap on a single line

// ---------------------------------------------------------------------------
// Module state. Assumes one server per process (one KEBCsaServerStart call).
// ---------------------------------------------------------------------------
static dispatch_queue_t g_acceptQueue = NULL;
static dispatch_queue_t g_recvQueue   = NULL;
static dispatch_source_t g_listenSrc  = NULL;
static int g_listenFd = -1;
static _Atomic int g_clientFd = -1;
static _Atomic uint32_t g_pendingSends = 0;

static kiou_csa_line_handler_t g_lineHandler = NULL;

// ---------------------------------------------------------------------------
// Socket plumbing — mirrors Server_WebSocket.m's helpers with the WS-side
// nomenclature swapped to CSA. The semantics are identical: we want
// non-blocking accepts, tight keepalive intervals, and blocking I/O on the
// client fd so the recv-queue loop has a clean stream.
// ---------------------------------------------------------------------------
static void csa_set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void csa_set_keepalive(int fd) {
    int on = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof(on));
    int idle = 5, intvl = 3, count = 3;
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle,  sizeof(idle));
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT,   &count, sizeof(count));
}

static BOOL csa_send_all(int fd, const uint8_t *buf, size_t len) {
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

static void csa_close_client(void) {
    int fd = atomic_exchange(&g_clientFd, -1);
    bool wasUp = (fd >= 0);
    if (fd >= 0) {
        close(fd);
    }
    atomic_store(&g_pendingSends, 0);
    if (wasUp) {
        // Let the CSA engine driver reset its state machine. Symbol always
        // resolves because Csa_Stubs.m provides a no-op until Task 4 lands
        // the real driver.
        CsaEngineOnTcpClientDisconnected();
    }
}

// ---------------------------------------------------------------------------
// Inbound line loop — read bytes off the wire, slice on LF, dispatch one
// trimmed line at a time. CRLF is normalized to LF before dispatch so the
// handler can treat its input as POSIX text.
// ---------------------------------------------------------------------------
static void csa_client_recv_loop(int fd) {
    NSMutableData *acc = [NSMutableData dataWithCapacity:CSA_RECV_CHUNK];
    uint8_t chunk[CSA_RECV_CHUNK];

    while (1) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            IPALog([NSString stringWithFormat:
                      @"[CSA] recv errno=%d, exiting loop", errno]);
            break;
        }
        if (n == 0) {
            IPALog(@"[CSA] peer closed connection");
            break;
        }

        [acc appendBytes:chunk length:(NSUInteger)n];
        if (acc.length > CSA_LINE_MAX) {
            IPALog([NSString stringWithFormat:
                      @"[CSA] line buffer overflowed %d bytes, closing",
                      CSA_LINE_MAX]);
            break;
        }

        // Drain every complete line currently in the buffer. A CSA line is
        // terminated by LF; CR is tolerated by stripping it from the end of
        // the slice before dispatching.
        while (1) {
            const uint8_t *bytes = (const uint8_t *)acc.bytes;
            NSUInteger len = acc.length;
            NSUInteger nl = NSNotFound;
            for (NSUInteger i = 0; i < len; i++) {
                if (bytes[i] == '\n') { nl = i; break; }
            }
            if (nl == NSNotFound) break;

            NSUInteger lineLen = nl;
            if (lineLen > 0 && bytes[lineLen - 1] == '\r') lineLen--;
            NSString *line = (lineLen == 0)
                ? @""
                : [[NSString alloc] initWithBytes:bytes
                                            length:lineLen
                                          encoding:NSUTF8StringEncoding];
            // Drop the line + its terminator from the buffer.
            [acc replaceBytesInRange:NSMakeRange(0, nl + 1)
                           withBytes:NULL
                              length:0];
            if (line == nil) {
                IPALog(@"[CSA] dropped non-UTF8 line");
                continue;
            }
            IPALog([NSString stringWithFormat:@"[CSA<] %@", line]);
            if (g_lineHandler) g_lineHandler(line);
        }
    }

    IPALog(@"[CSA] client recv loop exited");
    dispatch_async(g_acceptQueue, ^{
        csa_close_client();
    });
}

// ---------------------------------------------------------------------------
// accept(): new-client-wins, then hand the fd off to the recv queue.
// ---------------------------------------------------------------------------
static void csa_handle_accept(void) {
    struct sockaddr_in peer;
    socklen_t peerLen = sizeof(peer);
    int fd = accept(g_listenFd, (struct sockaddr *)&peer, &peerLen);
    if (fd < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            IPALog([NSString stringWithFormat:
                      @"[CSA] accept errno=%d", errno]);
        }
        return;
    }

    char ip[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));

    // New-client-wins. A stale recv loop parked on a dead fd would
    // otherwise reject the new peer; CSA engines tend to reconnect after
    // crashes, and we want the most recent connect to be authoritative.
    if (atomic_load(&g_clientFd) >= 0) {
        IPALog([NSString stringWithFormat:
                  @"[CSA] preempt: closing prior client fd=%d to make room "
                  @"for %s:%u",
                  g_clientFd, ip, (unsigned)ntohs(peer.sin_port)]);
        csa_close_client();
    }

    IPALog([NSString stringWithFormat:@"[CSA] accepted from %s:%u fd=%d",
              ip, (unsigned)ntohs(peer.sin_port), fd]);

    // Darwin propagates O_NONBLOCK from the listen socket to the accept
    // fd; flip it back so the recv loop can block on its own queue.
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);

    csa_set_keepalive(fd);
    atomic_store(&g_clientFd, fd);
    CsaEngineOnTcpClientConnected();

    dispatch_async(g_recvQueue, ^{
        csa_client_recv_loop(fd);
    });
}

// ---------------------------------------------------------------------------
// Public API.
// ---------------------------------------------------------------------------
void KEBCsaServerStart(uint16_t port) {
    if (g_listenFd >= 0) {
        IPALog(@"[CSA] server already running");
        return;
    }

    g_acceptQueue = dispatch_queue_create("io.kiou.csa.tcp.accept",
                                          DISPATCH_QUEUE_SERIAL);
    g_recvQueue   = dispatch_queue_create("io.kiou.csa.tcp.recv",
                                          DISPATCH_QUEUE_SERIAL);

    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
        IPALog([NSString stringWithFormat:@"[CSA] socket errno=%d", errno]);
        return;
    }

    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        IPALog([NSString stringWithFormat:@"[CSA] bind errno=%d port=%u",
                  errno, (unsigned)port]);
        close(s);
        return;
    }
    if (listen(s, 4) < 0) {
        IPALog([NSString stringWithFormat:@"[CSA] listen errno=%d", errno]);
        close(s);
        return;
    }
    csa_set_nonblock(s);
    g_listenFd = s;

    g_listenSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                         (uintptr_t)s, 0, g_acceptQueue);
    dispatch_source_set_event_handler(g_listenSrc, ^{
        csa_handle_accept();
    });
    dispatch_resume(g_listenSrc);

    IPALog([NSString stringWithFormat:@"[CSA] listening on 0.0.0.0:%u",
              (unsigned)port]);
}

void KEBCsaServerSetLineHandler(kiou_csa_line_handler_t fn) {
    // Pointer write is atomic on arm64; the worst-case race is a single
    // recv-loop iteration reading the previous handler. Csa_Engine.m
    // installs its handler at constructor time before any client can
    // connect, so the race is theoretical.
    g_lineHandler = fn;
}

void KEBCsaServerPush(NSString *line) {
    if (!line) return;
    if (!g_acceptQueue) return;   // server never started
    if (atomic_load(&g_clientFd) < 0) return;   // no client attached

    uint32_t pending = atomic_load(&g_pendingSends);
    if (pending >= CSA_QUEUE_DROP_THRESHOLD) {
        if ((pending % 32) == 0) {
            IPALog([NSString stringWithFormat:
                      @"[CSA] drop: backlog=%u", pending]);
        }
        return;
    }

    atomic_fetch_add(&g_pendingSends, 1);
    NSString *withNewline = [line hasSuffix:@"\n"]
        ? [line copy]
        : [line stringByAppendingString:@"\n"];

    dispatch_async(g_acceptQueue, ^{
        int fd = atomic_load(&g_clientFd);
        if (fd < 0) {
            atomic_fetch_sub(&g_pendingSends, 1);
            return;
        }
        NSData *data = [withNewline dataUsingEncoding:NSUTF8StringEncoding];
        BOOL ok = csa_send_all(fd, data.bytes, data.length);
        atomic_fetch_sub(&g_pendingSends, 1);
        if (!ok) {
            IPALog(@"[CSA] send failed, dropping client");
            csa_close_client();
        }
    });
}

void KEBCsaServerClose(void) {
    if (!g_acceptQueue) return;
    dispatch_async(g_acceptQueue, ^{
        if (atomic_load(&g_clientFd) >= 0) {
            IPALog(@"[CSA] KEBCsaServerClose: tearing down client");
            csa_close_client();
        }
    });
}
