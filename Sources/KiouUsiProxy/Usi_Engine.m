#import "Internal.h"

#import <mach/mach_time.h>
#import <stdatomic.h>

// ===========================================================================
// Usi_Engine — KiouUsiProxy as a USI client driving an external engine.
//
// Phase 2 architecture:
//   tweak (us)            = USI client / USI User. We own the position
//                           (= KIOU's internal state) and ask an external
//                           engine to think for us.
//   YaneuraOu (or any USI engine) = USI engine. Connects to our ws server,
//                           receives `usi` / `isready` / `usinewgame` /
//                           `position sfen ...` / `go ...`, replies with
//                           `bestmove <usi>`.
//
// Flow (one half-move):
//
//   KIOU's opponent makes a move
//      ↓ Hook_LowLevelObserve::hook_AdapterTryMakeMoveOut fires
//      ↓ usi_engine_on_move_observed(usi, sfen_after, side_to_move)
//      ↓ side_to_move == g_<mode>LocalPlayer  ?
//      yes →  usi_engine_send_line("position sfen <sfen_after>")
//             usi_engine_send_line("go movetime 1000")
//             state = THINKING
//      no  →  (do nothing, wait for the next move)
//
//   YaneuraOu thinks, sends "bestmove 7g7f"
//      ↓ usi_engine_handle_inbound_line("bestmove 7g7f")
//      ↓ state = INJECTING
//      ↓ inject_apply("7g7f") — uses the Phase 1 OPM + Adapter pipeline
//      ↓ state = READY (the inject itself fires hook_AdapterTryMakeMoveOut
//                       again, which sees side_to_move != localPlayer and
//                       skips, so we don't loop on our own injection)
//
// What this file does NOT do:
//   * Generate moves. The whole point is to delegate to a real engine.
//   * Touch il2cpp directly. inject_apply does that on the main thread.
//   * Block the recv queue while waiting for bestmove. state is atomic and
//     observation hooks fire on Unity threads, completely independent of
//     the ws recv path.
// ===========================================================================

// ---------------------------------------------------------------------------
// Tunables. Movetime is for the engine's `go movetime <ms>`; bumping it
// trades latency for stronger play. 1000ms is a good "feel" default —
// KIOU's own CPU pauses are 0.5–2 seconds so nothing looks out of place.
// ---------------------------------------------------------------------------
#define USI_ENGINE_DEFAULT_MOVETIME_MS  1000

// ---------------------------------------------------------------------------
// State. All access goes through stdatomic so the recv queue (where USI
// lines come in) and the Unity main thread (where hook callbacks fire)
// don't trip over each other. The state machine is small enough that a
// single _Atomic int suffices.
// ---------------------------------------------------------------------------
static _Atomic int g_usiState = USI_STATE_BOOT;

// Last `info string` (just the value, not the whole line) — useful when
// debugging engine behavior. Single-writer single-reader so a plain
// pointer is fine.
static NSString *g_lastInfoString = nil;

// Seat assignment for the live match. -1 = no fixed seat (LocalPvP /
// RecordReplay) or no live match.
static _Atomic int g_localPlayerSide = -1;

// "We expect an inject to fire this exact usi" — set when we send
// `position`+`go`, used to suppress the post-inject reentry into the
// hook callback (the inject itself causes hook_AdapterTryMakeMoveOut to
// run again, but we don't want THAT to trigger another `position`+`go`).
static NSString *g_expectedNextUsi = nil;

// ---------------------------------------------------------------------------
// Outbound — funnel all USI lines through one helper so the log shows
// exactly what the engine sees.
// ---------------------------------------------------------------------------
void usi_engine_send_line(NSString *line) {
    if (line.length == 0) return;
    NSString *withNewline = [line hasSuffix:@"\n"]
        ? line
        : [line stringByAppendingString:@"\n"];
    file_log([NSString stringWithFormat:@"[USI>] %@",
              [line stringByReplacingOccurrencesOfString:@"\n"
                                              withString:@"\\n"]]);
    kiou_ws_server_push(withNewline);
}

// ---------------------------------------------------------------------------
// State helpers.
// ---------------------------------------------------------------------------
static const char *usi_state_name(int s) {
    switch (s) {
        case USI_STATE_BOOT:      return "BOOT";
        case USI_STATE_HANDSHAKE: return "HANDSHAKE";
        case USI_STATE_READY:     return "READY";
        case USI_STATE_THINKING:  return "THINKING";
        case USI_STATE_INJECTING: return "INJECTING";
        default:                  return "?";
    }
}

static void usi_set_state(int newState) {
    int old = atomic_exchange(&g_usiState, newState);
    if (old != newState) {
        file_log([NSString stringWithFormat:@"[USI] state %s -> %s",
                  usi_state_name(old), usi_state_name(newState)]);
    }
}

// ---------------------------------------------------------------------------
// Match lifecycle. Called from Hook_MatchModeObserve.m.
// ---------------------------------------------------------------------------
void usi_engine_on_match_start(int32_t local_player) {
    atomic_store(&g_localPlayerSide, local_player);
    file_log([NSString stringWithFormat:
              @"[USI] match_start local_player=%d state=%s",
              (int)local_player,
              usi_state_name(atomic_load(&g_usiState))]);

    // If we're already past handshake when a match begins, send
    // `usinewgame` to reset the engine's per-game state. The handshake
    // path also sends `usinewgame` once at readyok time; this is
    // harmless to repeat — USI engines reset cleanly on it.
    int s = atomic_load(&g_usiState);
    if (s == USI_STATE_READY || s == USI_STATE_THINKING) {
        usi_engine_send_line(@"usinewgame");
    }

    // First-move kick: if we're the side to move at match start (e.g.
    // playing Black with no resume state), the observation hook won't
    // fire until after the first move. Read the current side from the
    // game adapter and, if it matches us, send position+go now.
    //
    // We do this on a short delay so the local engine has time to settle
    // into its starting Position. inject's resolver already handles the
    // "no GameCtrl, use Standard opening" case, so the SFEN is reachable
    // even at t=0.
    if (local_player == 0 || local_player == 1) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // Reuse the observation callback's logic by faking a "the
            // opponent just moved" event with the current SFEN and
            // side_to_move read from GameController.
            // We can't easily synthesize the usi argument (there's no
            // observed move) so we pass nil — usi_engine_on_move_observed
            // tolerates that and only uses it for logging.
            //
            // NOTE: This path may race with the first real ADAPTER2
            // observation. That's fine: the state check in the callback
            // ensures only one position+go goes out per turn.
            extern void *volatile g_gameCtrlCache;
            (void)g_gameCtrlCache;  // suppress unused warning
            // We don't have a direct helper to read sfen+side here that
            // lives outside Inject_Move.m, so the simpler path is to let
            // the first ADAPTER2 hit do the work. The kickstart is only
            // necessary when we're moving FIRST and there's been no
            // earlier move at all; in CPUStreamMode that's rare because
            // resume + opening normally come with at least one observed
            // move before our turn. Leave this stub in place for a
            // future patch that reads the SFEN directly.
            file_log(@"[USI] match_start kickstart deferred until first "
                      "ADAPTER2 observation");
        });
    }
}

void usi_engine_on_match_end(void) {
    atomic_store(&g_localPlayerSide, -1);
    file_log(@"[USI] match_end — resetting state");
    // Drop back to READY (not BOOT) — the engine is still connected and
    // through its handshake; we just want a fresh game next time.
    int s = atomic_load(&g_usiState);
    if (s != USI_STATE_BOOT && s != USI_STATE_HANDSHAKE) {
        usi_set_state(USI_STATE_READY);
    }
    g_expectedNextUsi = nil;
}

// ---------------------------------------------------------------------------
// Outbound: build `position sfen ...` + `go movetime ...` and send.
// ---------------------------------------------------------------------------
static void usi_engine_request_thinking(NSString *sfen) {
    if (sfen.length == 0) {
        file_log(@"[USI] request_thinking skipped: empty sfen");
        return;
    }
    usi_engine_send_line([NSString stringWithFormat:@"position sfen %@",
                          sfen]);
    usi_engine_send_line([NSString stringWithFormat:@"go movetime %d",
                          USI_ENGINE_DEFAULT_MOVETIME_MS]);
    usi_set_state(USI_STATE_THINKING);
}

// ---------------------------------------------------------------------------
// Observation callback: every time the game's adapter applies a move, we
// look at whose turn is next. If it's ours, ask the engine to think.
// ---------------------------------------------------------------------------
void usi_engine_on_move_observed(NSString *usi,
                                 NSString *sfen_after,
                                 int32_t side_to_move) {
    int s = atomic_load(&g_usiState);
    int seat = atomic_load(&g_localPlayerSide);

    file_log([NSString stringWithFormat:
              @"[USI] observed usi=%@ side_to_move=%d local=%d state=%s "
              @"expected=%@",
              usi ?: @"<nil>",
              (int)side_to_move, (int)seat,
              usi_state_name(s),
              g_expectedNextUsi ?: @"<nil>"]);

    // Any observation while we're in INJECTING means the inject's flow has
    // played out (either KIOU applied our move and the opponent already
    // replied, or the user nudged the board themselves). Either way, the
    // bestmove cycle is over — snap back to READY so the next request
    // isn't skipped. We do this regardless of whose turn is next.
    //
    // The original "wait for ADAPTER2 to echo our own move via
    // g_expectedNextUsi" design didn't pan out because the inject path
    // calls orig_AdapterTryMakeMoveOut directly, which bypasses our hook
    // trampoline, so the echo never fires.
    if (s == USI_STATE_INJECTING) {
        g_expectedNextUsi = nil;
        usi_set_state(USI_STATE_READY);
        s = USI_STATE_READY;
    }

    if (seat != 0 && seat != 1) return;          // no fixed seat
    if (side_to_move != seat) return;            // opponent's turn next

    if (s != USI_STATE_READY) {
        // Already thinking or in an odd state — don't pile on a second
        // `go` before bestmove comes back.
        file_log([NSString stringWithFormat:
                  @"[USI] skip request: state=%s",
                  usi_state_name(s)]);
        return;
    }

    if (sfen_after.length == 0) {
        file_log(@"[USI] skip request: empty sfen_after");
        return;
    }
    usi_engine_request_thinking(sfen_after);
}

// ---------------------------------------------------------------------------
// Inbound handling — split USI lines, dispatch on the first token.
// ---------------------------------------------------------------------------
static NSString *usi_first_token(NSString *line) {
    NSRange r = [line rangeOfCharacterFromSet:
                 [NSCharacterSet whitespaceCharacterSet]];
    if (r.location == NSNotFound) return line;
    return [line substringToIndex:r.location];
}

static NSString *usi_rest_after(NSString *line, NSString *token) {
    if (line.length <= token.length) return @"";
    NSString *tail = [line substringFromIndex:token.length];
    return [tail stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
}

// Per-line dispatcher. Returns nothing — replies are sent via
// usi_engine_send_line.
static void usi_engine_handle_line(NSString *line) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;
    file_log([NSString stringWithFormat:@"[USI<] %@", trimmed]);

    NSString *cmd = usi_first_token(trimmed);

    if ([cmd isEqualToString:@"id"]) {
        // engine identification; just log
        return;
    }
    if ([cmd isEqualToString:@"option"]) {
        // engine option; just log
        return;
    }
    if ([cmd isEqualToString:@"usiok"]) {
        // engine done announcing itself — request readiness
        usi_engine_send_line(@"isready");
        return;
    }
    if ([cmd isEqualToString:@"readyok"]) {
        usi_engine_send_line(@"usinewgame");
        usi_set_state(USI_STATE_READY);
        return;
    }
    if ([cmd isEqualToString:@"info"]) {
        // info pv ... / info string ... — keep last info string handy
        NSString *rest = usi_rest_after(trimmed, @"info");
        if ([rest hasPrefix:@"string "]) {
            g_lastInfoString = [rest substringFromIndex:7];
        }
        return;
    }
    if ([cmd isEqualToString:@"bestmove"]) {
        NSString *rest = usi_rest_after(trimmed, @"bestmove");
        NSString *mv = usi_first_token(rest);
        if (mv.length == 0) {
            file_log(@"[USI] bestmove with no arg, ignoring");
            return;
        }
        if ([mv isEqualToString:@"resign"] ||
            [mv isEqualToString:@"(none)"] ||
            [mv isEqualToString:@"win"]) {
            file_log([NSString stringWithFormat:
                      @"[USI] engine returned %@, no injection", mv]);
            usi_set_state(USI_STATE_READY);
            return;
        }
        usi_set_state(USI_STATE_INJECTING);
        g_expectedNextUsi = mv;
        NSString *sfen = nil;
        NSString *err = nil;
        uint32_t raw = 0;
        bool ok = inject_apply(mv, &sfen, &raw, &err);
        file_log([NSString stringWithFormat:
                  @"[USI] inject_apply usi=%@ ok=%d raw=0x%x err=%@ sfen=%@",
                  mv, (int)ok, (unsigned)raw, err ?: @"", sfen ?: @""]);
        // Originally we wanted to wait for the post-inject ADAPTER2 echo to
        // tick state back to READY, but the inject path calls
        // orig_AdapterTryMakeMoveOut directly (= no hook re-entry), so the
        // echo never fires. Instead we leave state at INJECTING and let
        // usi_engine_on_move_observed flip it to READY the moment KIOU's
        // opponent moves and it becomes our turn again. That observation is
        // the natural cue that this turn is over.
        // On a failed inject there's no waiting to do, so reset directly.
        if (!ok) {
            g_expectedNextUsi = nil;
            usi_set_state(USI_STATE_READY);
        }
        return;
    }
    // Anything else (e.g. an echo from a misbehaving engine): drop quietly.
    file_log([NSString stringWithFormat:@"[USI] ignored inbound: %@",
              trimmed]);
}

// Recv handler — called from Server_WebSocket.m. The buffer may contain
// multiple newline-terminated USI lines; split and dispatch each one.
static void usi_engine_text_handler(const char *data, size_t len) {
    if (!data || len == 0) return;
    NSData *raw = [NSData dataWithBytes:data length:len];
    NSString *whole = [[NSString alloc] initWithData:raw
                                            encoding:NSUTF8StringEncoding];
    if (!whole) return;
    // Split on \r\n / \n / \r so we tolerate any line ending the engine
    // happens to use.
    NSCharacterSet *nl = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];
    NSArray<NSString *> *lines = [whole componentsSeparatedByCharactersInSet:nl];
    for (NSString *line in lines) {
        if (line.length == 0) continue;
        usi_engine_handle_line(line);
    }
}

// ---------------------------------------------------------------------------
// WS lifecycle hooks. Server_WebSocket.m calls these from the accept queue
// the moment a peer finishes the WebSocket upgrade (connected) or the
// recv loop exits for any reason (disconnected).
// ---------------------------------------------------------------------------
void usi_engine_on_ws_client_connected(void) {
    file_log(@"[USI] ws client connected; starting USI handshake");
    usi_set_state(USI_STATE_HANDSHAKE);
    g_expectedNextUsi = nil;
    usi_engine_send_line(@"usi");
}

void usi_engine_on_ws_client_disconnected(void) {
    file_log(@"[USI] ws client disconnected");
    usi_set_state(USI_STATE_BOOT);
    g_expectedNextUsi = nil;
}

// ---------------------------------------------------------------------------
// Installer. Called once from Tweak.m's installUnityHooks() after the
// observation hooks are in place.
// ---------------------------------------------------------------------------
void usi_engine_install(void) {
    kiou_ws_server_set_text_handler(usi_engine_text_handler);
    file_log(@"[USI] engine installed (text handler registered)");
}
