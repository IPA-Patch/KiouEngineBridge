#import "Internal.h"

#import <mach/mach_time.h>
#import <stdatomic.h>

// ===========================================================================
// Usi_Engine — KiouEngineBridge as a USI client driving an external engine.
//
// Phase 2 architecture:
//   tweak (us)            = pure translator between Kiou Engine (the in-app
//                           il2cpp CPU) and the external USI engine. We own
//                           the position view (= KIOU's internal state) and
//                           hand it off as a USI `position` line. We do NOT
//                           configure the engine and we do NOT drive its
//                           thinking — that's the bridge's job.
//   bridge (TypeScript)   = sits between us and the USI engine. Owns all
//                           engine setup (`setoption ...`) and thinking
//                           cadence (`go ...`). Forwards our handshake +
//                           `position` lines into the engine, and forwards
//                           the engine's `bestmove` back to us.
//   USI engine            = whatever the bridge spawns (YaneuraOu w/ Suisho5
//                           NNUE, etc). We never speak to it directly.
//
// Flow (one half-move):
//
//   KIOU's opponent makes a move
//      ↓ Hook_LowLevelObserve::hook_AdapterTryMakeMoveOut fires
//      ↓ usi_engine_on_move_observed(usi, sfen_after, side_to_move)
//      ↓ side_to_move == g_<mode>LocalPlayer  ?
//      yes →  usi_engine_send_line("position sfen <sfen_after>")
//             state = THINKING
//             (bridge sees the position line and triggers the engine to
//              think with its own `go` cadence)
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
// Tweak is just a translator between Kiou Engine (in-app il2cpp CPU) and
// the external USI engine. Thinking parameters live in two places:
//   - YaneuraOu side : bridge sends `setoption ...` before usiok
//   - Kiou Engine    : decided inside the app, not our concern
// We send `position sfen ...` on the tweak side; the bridge observes that
// line and injects whatever `go ...` it wants into the engine. Thus tweak
// itself never emits a `go` line.
// ---------------------------------------------------------------------------

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

// Forward decl — defined further down once usi_engine_request_thinking
// is in scope. Both match_start and the readyok handler call this.
static void usi_engine_try_kick_on_main(NSString *tag);

// ---------------------------------------------------------------------------
// Match lifecycle. Called from Hook_MatchModeObserve.m.
// ---------------------------------------------------------------------------
void usi_engine_on_match_start(int32_t local_player) {
    atomic_store(&g_localPlayerSide, local_player);
    file_log([NSString stringWithFormat:
              @"[USI] match_start local_player=%d state=%s",
              (int)local_player,
              usi_state_name(atomic_load(&g_usiState))]);

    // NOTE: we do NOT send `usinewgame` here. The readyok handler already
    // sent one when the bridge connected, and the engine sits in "ready
    // for a new game" until the first `position` arrives. Sending a second
    // `usinewgame` confused the trace (two back-to-back ones in the log)
    // and bought us nothing — USI engines don't need re-priming per match.

    // First-move kick: if we're the side to move at match start (e.g.
    // playing sente against the in-app CPU), no observation will fire
    // until after our move. Read the current SFEN and, if it's our turn,
    // ship it to the bridge so YaneuraOu can answer.
    //
    // 0.5s delay lets KIOU's mode code finish wiring the GameController
    // and authoritative SFEN — at t=0 inject_currentSfen() often returns
    // empty because nothing has populated GameCtrl yet.
    if (local_player == 0 || local_player == 1) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            usi_engine_try_kick_on_main(@"match_start");
        });
    }
}

void usi_engine_on_match_end(usi_match_result_t result) {
    // Tell the bridge the match is over BEFORE we touch our own state.
    // The USI spec says the user (us) sends `gameover {win|lose|draw}` to
    // the engine when the match ends; the bridge in turn forwards it to
    // YaneuraOu so it can run its end-of-game bookkeeping (clear its
    // think state, free its position, etc) before the next `position` +
    // `go` arrives. We omit the gameover line for USI_RESULT_UNKNOWN
    // (open-seat modes where we can't tell the outcome) — sending a
    // wrong win/lose to the engine is worse than sending nothing.
    NSString *resultWord = nil;
    switch (result) {
        case USI_RESULT_WIN:  resultWord = @"win";  break;
        case USI_RESULT_LOSE: resultWord = @"lose"; break;
        case USI_RESULT_DRAW: resultWord = @"draw"; break;
        case USI_RESULT_UNKNOWN:
        default:
            break;
    }
    if (resultWord) {
        usi_engine_send_line([NSString stringWithFormat:@"gameover %@",
                              resultWord]);
    } else {
        file_log(@"[USI] match_end: result unknown, suppressing gameover");
    }

    atomic_store(&g_localPlayerSide, -1);
    file_log([NSString stringWithFormat:
              @"[USI] match_end result=%@ — resetting state",
              resultWord ?: @"<unknown>"]);
    // Drop back to READY (not BOOT) — the engine is still connected and
    // through its handshake; we just want a fresh game next time.
    int s = atomic_load(&g_usiState);
    if (s != USI_STATE_BOOT && s != USI_STATE_HANDSHAKE) {
        usi_set_state(USI_STATE_READY);
    }
    g_expectedNextUsi = nil;
}

// ---------------------------------------------------------------------------
// Outbound: send `position sfen ...` only. The bridge observes the
// position line on the WS, then writes its own `go` to the engine's
// stdin (the engine is on the bridge side, not the tweak side, so
// nothing crosses the WS for go). Thinking limits live entirely in the
// engine via `setoption ...` configured by the bridge at startup
// (DepthLimit, etc). Once the line goes out we flip to THINKING and
// wait for `bestmove` to come back over the WS.
// ---------------------------------------------------------------------------
static void usi_engine_request_thinking(NSString *sfen) {
    if (sfen.length == 0) {
        file_log(@"[USI] request_thinking skipped: empty sfen");
        return;
    }
    usi_engine_send_line([NSString stringWithFormat:@"position sfen %@",
                          sfen]);
    usi_set_state(USI_STATE_THINKING);
}

// Try to kick a position+think for the current board, given that we may
// already know the seat and have a usable SFEN reachable from the il2cpp
// helpers. Used both right after `readyok` (in case the bridge connected
// mid-game) and right after match_start (in case we're sente and the
// opponent will never trigger an ADAPTER2 observation for us). Must run
// on the main thread — inject_currentSfen() touches il2cpp accessors.
//
// `tag` is just for the file log so it's obvious which path called us.
static void usi_engine_try_kick_on_main(NSString *tag) {
    int seat = atomic_load(&g_localPlayerSide);
    if (seat != 0 && seat != 1) {
        file_log([NSString stringWithFormat:
                  @"[USI] kick(%@): no fixed seat yet, "
                  @"waiting for first observation", tag]);
        return;
    }
    NSString *sfen = inject_currentSfen();
    if (sfen.length == 0) {
        file_log([NSString stringWithFormat:
                  @"[USI] kick(%@): no SFEN available yet", tag]);
        return;
    }
    // Inspect the side-to-move character at sfen[1] (after the board).
    int32_t sideToMove = -1;
    NSArray<NSString *> *parts = [sfen componentsSeparatedByString:@" "];
    if (parts.count >= 2) {
        NSString *s = parts[1];
        if      ([s isEqualToString:@"b"]) sideToMove = 0;
        else if ([s isEqualToString:@"w"]) sideToMove = 1;
    }
    if (sideToMove != seat) {
        file_log([NSString stringWithFormat:
                  @"[USI] kick(%@): not our turn (side=%d seat=%d)",
                  tag, (int)sideToMove, (int)seat]);
        return;
    }
    if (atomic_load(&g_usiState) != USI_STATE_READY) {
        file_log([NSString stringWithFormat:
                  @"[USI] kick(%@): state not READY (%s), skipping",
                  tag, usi_state_name(atomic_load(&g_usiState))]);
        return;
    }
    file_log([NSString stringWithFormat:
              @"[USI] kick(%@): starting thinking with current board", tag]);
    usi_engine_request_thinking(sfen);
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
        // If the bridge connected mid-game (user already in a CPU match
        // before launching us), no observation will fire until the next
        // move plays. Kick a position right now if we already know the
        // seat and it's our turn.
        dispatch_async(dispatch_get_main_queue(), ^{
            usi_engine_try_kick_on_main(@"post-readyok");
        });
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
