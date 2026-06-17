#import "Internal.h"
#import "Csa_Engine.h"

#import <mach/mach_time.h>
#import <stdatomic.h>

// ===========================================================================
// Csa_Engine — CSA server-side state machine.
//
// Phase summary:
//
//   KEB acts as the CSA server. The connecting TCP peer is the CSA engine.
//   KIOU owns board state and clocks; KEB translates KIOU's per-match
//   events into the CSA protocol (`BEGIN Game_Summary`, `+7776FU,T10`,
//   `#WIN`) and translates the engine's CSA submissions (`+7776FU`,
//   `%TORYO`, `LOGOUT`) back into KIOU actions (Move bits injection,
//   resign API, session teardown).
//
// State machine:
//
//   BOOT          ── tweak loaded, no TCP client.
//      ↓  TCP accept
//   LOGIN         ── client connected, awaiting LOGIN. Any non-LOGIN line
//                    is logged and dropped until LOGIN arrives.
//      ↓  inbound "LOGIN <name> <pass>"  →  send "LOGIN:<name> OK"
//   AGREE_WAIT[*] ── set the moment OnMatchStart fires AND we have already
//                    sent Game_Summary. Stays AGREE_WAIT until AGREE
//                    arrives, then advances to PLAYING.
//      ↓  inbound "AGREE [Game_ID]"      →  send "START:<Game_ID>"
//   PLAYING       ── per-move exchange. inbound `+7776FU` / `-3334FU`
//                    injects into KIOU; inbound `%TORYO` triggers the
//                    KIOU resign API (Task 6 — stubbed for now).
//      ↓  OnMatchEnd
//   GAME_OVER     ── result emitted (`#WIN` / `#LOSE` / `#DRAW`). The
//                    transport stays open; if the engine submits another
//                    LOGIN / AGREE pair a new match can be played without
//                    reconnecting.
//
// [*] AGREE_WAIT is also entered directly from LOGIN if Game_Summary has
// not yet been sent (= no KIOU match in progress at LOGIN time): we sit in
// LOGIN until OnMatchStart fires, then send Game_Summary and roll forward.
// ===========================================================================

// ---------------------------------------------------------------------------
// State, accessed from the recv queue and the Unity main thread; an
// _Atomic int keeps writes coherent without needing a serial gate.
// ---------------------------------------------------------------------------
static _Atomic int g_csaState = CSA_STATE_BOOT;

// Snapshot of the seat the local KIOU player holds. -1 = open-seat mode
// (LocalPvP / RecordReplay) or no live match.
static _Atomic int g_csaLocalPlayer = -1;

// Game_Summary cache. The engine driver isn't the source of truth for any
// of the Game_Summary fields — Csa_GameInfo.m owns the MatchConfig
// reads — but it does remember the most recently-sent payload so we can
// re-emit on reconnect mid-match.
static NSString *volatile g_csaLastGameSummary = nil;
static NSString *volatile g_csaLastGameID = nil;

// Per-move remaining-time cache, used to derive the `,T<n>` suffix on the
// next move notification. Values are post-move remaining seconds (float)
// pulled straight off GameStateStore (+0x80 / +0x90 + 0x20) — see
// Hook_GameStateStoreObserve::HookNotifyPieceMoved for the read site.
//
// NaN means "no value cached yet" (first move of the match, or KIOU
// declined to surface a clock for that side this match).
static float volatile g_csaLastBlackRemainSec = NAN;
static float volatile g_csaLastWhiteRemainSec = NAN;

// Wall-clock fallback. When KIOU's per-side clock is unavailable (VsAI's
// CPU side reports 86400s "no limit," NaN on the very first move, etc.)
// we measure think time the boring way: how long ago did the *opponent*
// finish their move? That delta IS this side's think time.
//
// Indexed by player side (0=Black, 1=White). Mach absolute ticks; zero
// means "no baseline yet — wait for one more move before T<n> can be
// computed via the fallback path."
static uint64_t volatile g_csaLastMoveMachTicks[2] = {0, 0};

static uint32_t csa_machTicksToSec(uint64_t ticks) {
    static mach_timebase_info_data_t s_tb = {0, 0};
    if (s_tb.denom == 0) mach_timebase_info(&s_tb);
    if (s_tb.denom == 0) return 0;
    // ticks * numer / denom -> ns; / 1e9 -> s.
    uint64_t ns = (s_tb.numer == s_tb.denom)
        ? ticks
        : (ticks * s_tb.numer) / s_tb.denom;
    return (uint32_t)(ns / 1000000000ULL);
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------
static const char *csa_state_name(int s) {
    switch (s) {
        case CSA_STATE_BOOT:       return "BOOT";
        case CSA_STATE_LOGIN:      return "LOGIN";
        case CSA_STATE_AGREE_WAIT: return "AGREE_WAIT";
        case CSA_STATE_PLAYING:    return "PLAYING";
        case CSA_STATE_GAME_OVER:  return "GAME_OVER";
        default:                   return "?";
    }
}

static void csa_set_state(int newState) {
    int old = atomic_exchange(&g_csaState, newState);
    if (old != newState) {
        file_log([NSString stringWithFormat:@"[CSA-ENG] state %s -> %s",
                  csa_state_name(old), csa_state_name(newState)]);
    }
}

// ---------------------------------------------------------------------------
// Outbound funnel — every line that goes on the wire passes through
// CsaEngineSendLine, so the log shows the engine's view of the session.
// ---------------------------------------------------------------------------
void CsaEngineSendLine(NSString *line) {
    if (line.length == 0) return;
    file_log([NSString stringWithFormat:@"[CSA>] %@", line]);
    KEBCsaServerPush(line);
}

void CsaEngineSendBlock(NSString *block) {
    if (block.length == 0) return;
    NSArray<NSString *> *lines = [block componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        if (line.length == 0) continue;
        CsaEngineSendLine(line);
    }
}

csa_state_t CsaEngineCurrentState(void) {
    return (csa_state_t)atomic_load(&g_csaState);
}

// ---------------------------------------------------------------------------
// Game_Summary delivery. Csa_GameInfo.m owns the actual block builder;
// this file just pulls the cached payload (or refuses if it hasn't been
// primed by an OnMatchStart yet).
//
// Csa_GameInfo.m is introduced in Task 5; we expose two extern declarations
// here so the linker is happy on the migration build. Until Task 5 lands,
// the Csa_Stubs.m no-op variants resolve these symbols.
// ---------------------------------------------------------------------------
extern NSString *CsaBuildGameSummary(int32_t local_player,
                                     NSString **outGameId);
extern NSString *CsaBuildMatchResult(usi_match_result_t result);

static void csa_send_game_summary(int32_t local_player) {
    NSString *gameId = nil;
    NSString *summary = CsaBuildGameSummary(local_player, &gameId);
    if (summary.length == 0) {
        file_log(@"[CSA-ENG] CsaBuildGameSummary returned empty — "
                 @"deferring Game_Summary");
        return;
    }
    g_csaLastGameSummary = summary;
    g_csaLastGameID = gameId ?: @"GAME";
    CsaEngineSendBlock(summary);
    // KIOU does not wait for the engine's AGREE — its CPU starts thinking
    // (and committing moves) the moment OnMatchStart fires. If we sit in
    // AGREE_WAIT until the engine replies, every move the CPU makes in the
    // gap is dropped by CsaEngineOnMoveObserved's state check. Send START
    // immediately and advance to PLAYING so observed moves flow through.
    // A later inbound AGREE in PLAYING is treated as a no-op (csa_handle_agree
    // logs and drops it when the state is already PLAYING).
    CsaEngineSendLine([NSString stringWithFormat:@"START:%@",
                       g_csaLastGameID]);
    csa_set_state(CSA_STATE_PLAYING);
}

// ---------------------------------------------------------------------------
// Inbound dispatcher. Lines arrive on the CSA recv queue (single-threaded
// per Server_CSA.m's queue setup).
// ---------------------------------------------------------------------------

static void csa_handle_login(NSString *line) {
    // Standard CSA LOGIN: "LOGIN <name> <pass>". Reply with "LOGIN:<name> OK"
    // regardless — KEB does not validate credentials.
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *name = (parts.count >= 2) ? parts[1] : @"engine";
    CsaEngineSendLine([NSString stringWithFormat:@"LOGIN:%@ OK", name]);

    int32_t lp = atomic_load(&g_csaLocalPlayer);
    if (lp == 0 || lp == 1) {
        // We already have a KIOU match in progress — push Game_Summary now.
        csa_send_game_summary(lp);
    } else {
        // No active match yet. Hold in LOGIN; the next OnMatchStart will
        // trigger Game_Summary delivery.
        csa_set_state(CSA_STATE_LOGIN);
    }
}

static void csa_handle_agree(NSString *line) {
    (void)line;  // optional <GameID> suffix is accepted but not validated
    int s = atomic_load(&g_csaState);
    if (s == CSA_STATE_PLAYING) {
        // csa_send_game_summary already shipped START and rolled us into
        // PLAYING because KIOU does not wait for AGREE. A late AGREE from
        // the engine is harmless — log and drop.
        file_log(@"[CSA-ENG] AGREE in PLAYING — already started, dropping");
        return;
    }
    if (s != CSA_STATE_AGREE_WAIT) {
        file_log([NSString stringWithFormat:
                  @"[CSA-ENG] AGREE in state %s — ignoring",
                  csa_state_name(s)]);
        return;
    }
    NSString *gid = g_csaLastGameID ?: @"GAME";
    CsaEngineSendLine([NSString stringWithFormat:@"START:%@", gid]);
    csa_set_state(CSA_STATE_PLAYING);
}

static void csa_handle_reject(NSString *line) {
    (void)line;
    file_log(@"[CSA-ENG] engine REJECTed match — staying connected");
    NSString *gid = g_csaLastGameID ?: @"GAME";
    CsaEngineSendLine([NSString stringWithFormat:@"REJECT:%@ by engine", gid]);
    csa_set_state(CSA_STATE_LOGIN);
}

// Forward decl — implemented later in this file.
static void csa_handle_move_from_engine(NSString *line);
static void csa_handle_special(NSString *line);

static void csa_handle_logout(void) {
    CsaEngineSendLine(@"LOGOUT:completed");
    KEBCsaServerClose();
    csa_set_state(CSA_STATE_BOOT);
}

static void csa_handle_line(NSString *line) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        // CSA uses bare LF (within 30 seconds) as a liveness ping. Nothing
        // to do — TCP keepalive handles dead-peer detection too.
        return;
    }

    if ([trimmed hasPrefix:@"LOGIN "] || [trimmed isEqualToString:@"LOGIN"]) {
        csa_handle_login(trimmed);
        return;
    }
    if ([trimmed isEqualToString:@"LOGOUT"]) {
        csa_handle_logout();
        return;
    }
    if ([trimmed hasPrefix:@"AGREE"]) {
        csa_handle_agree(trimmed);
        return;
    }
    if ([trimmed hasPrefix:@"REJECT"]) {
        csa_handle_reject(trimmed);
        return;
    }
    if ([trimmed hasPrefix:@"%"]) {
        csa_handle_special(trimmed);
        return;
    }
    if ([trimmed hasPrefix:@"+"] || [trimmed hasPrefix:@"-"]) {
        csa_handle_move_from_engine(trimmed);
        return;
    }
    file_log([NSString stringWithFormat:
              @"[CSA-ENG] ignoring unrecognised line: %@", trimmed]);
}

// ---------------------------------------------------------------------------
// %TORYO / %KACHI / %CHUDAN.
// ---------------------------------------------------------------------------

// Forward decl from Inject_Resign.m. Task 6 fills in real implementations;
// until then Csa_Stubs.m supplies no-op variants.
extern void InjectResign(int32_t playerSide);
extern void InjectNyugyokuDeclaration(int32_t playerSide);

static void csa_handle_special(NSString *line) {
    int s = atomic_load(&g_csaState);
    if (s != CSA_STATE_PLAYING) {
        file_log([NSString stringWithFormat:
                  @"[CSA-ENG] special %@ in state %s — ignoring",
                  line, csa_state_name(s)]);
        return;
    }

    int32_t lp = atomic_load(&g_csaLocalPlayer);
    if ([line isEqualToString:@"%TORYO"]) {
        // The CSA engine resigns — meaning the local KIOU side wins.
        // Convert that to a KIOU-side resign call against the engine's
        // seat (= the opposite of the local player).
        int32_t enginePlayer = (lp == 0) ? 1 : (lp == 1) ? 0 : -1;
        InjectResign(enginePlayer);
        CsaEngineSendLine(@"#RESIGN");
        CsaEngineSendLine(@"#WIN");
        csa_set_state(CSA_STATE_GAME_OVER);
        return;
    }
    if ([line isEqualToString:@"%KACHI"]) {
        int32_t enginePlayer = (lp == 0) ? 1 : (lp == 1) ? 0 : -1;
        InjectNyugyokuDeclaration(enginePlayer);
        CsaEngineSendLine(@"#JISHOGI");
        CsaEngineSendLine(@"#WIN");
        csa_set_state(CSA_STATE_GAME_OVER);
        return;
    }
    if ([line isEqualToString:@"%CHUDAN"]) {
        file_log(@"[CSA-ENG] %%CHUDAN received — not surfaced to KIOU");
        CsaEngineSendLine(@"#CHUDAN");
        csa_set_state(CSA_STATE_GAME_OVER);
        return;
    }
    file_log([NSString stringWithFormat:
              @"[CSA-ENG] unknown special: %@", line]);
}

// ---------------------------------------------------------------------------
// Engine move handling. The engine submits its move in CSA form
// (`+7776FU` / `-0055FU` etc); we parse, derive the USI string, and feed
// the existing inject pipeline so KIOU advances exactly as if the user had
// played the move locally.
// ---------------------------------------------------------------------------

// Translate a CSA coordinate ("77") to a USI coordinate ("7g"). Returns nil
// on malformed input.
static NSString *csa_squareToUsi(NSString *csaSq) {
    if (csaSq.length != 2) return nil;
    unichar f = [csaSq characterAtIndex:0];
    unichar r = [csaSq characterAtIndex:1];
    if (f < '1' || f > '9') return nil;
    if (r < '1' || r > '9') return nil;
    char usiFile = (char)f;
    char usiRank = (char)('a' + (r - '1'));
    return [NSString stringWithFormat:@"%c%c", usiFile, usiRank];
}

static NSString *csa_pieceToUsiDropLetter(int32_t pieceType) {
    switch (pieceType) {
        case 1: return @"P";
        case 2: return @"L";
        case 3: return @"N";
        case 4: return @"S";
        case 5: return @"B";
        case 6: return @"R";
        case 7: return @"G";
        default: return nil;
    }
}

static void csa_handle_move_from_engine(NSString *line) {
    int s = atomic_load(&g_csaState);
    if (s != CSA_STATE_PLAYING) {
        file_log([NSString stringWithFormat:
                  @"[CSA-ENG] move in state %s — ignoring: %@",
                  csa_state_name(s), line]);
        return;
    }

    uint32_t move = 0;
    int32_t pieceType = 0;
    int32_t playerSide = -1;
    int32_t timeSpent = -1;
    if (!MoveBitsFromCsaText(line, &move, &pieceType, &playerSide, &timeSpent)) {
        file_log([NSString stringWithFormat:
                  @"[CSA-ENG] malformed move: %@", line]);
        return;
    }

    int32_t lp = atomic_load(&g_csaLocalPlayer);
    // The connected CSA engine stands in for KIOU's local human player —
    // it occupies the same seat (Your_Turn maps directly to lp). On
    // open-seat modes (lp == -1) we accept whatever side the engine
    // claims.
    int32_t enginePlayer = lp;
    if (enginePlayer != -1 && playerSide != enginePlayer) {
        file_log([NSString stringWithFormat:
                  @"[CSA-ENG] move side mismatch: engine=%d got=%d "
                  @"(applying anyway)",
                  enginePlayer, playerSide]);
    }

    // Build USI for the inject pipeline. The "from" / "to" bits already
    // match the PSC Square encoding, so they translate directly.
    uint32_t to       = move & 0x7F;
    uint32_t from     = (move >> 7) & 0x7F;
    uint32_t promote  = (move >> 14) & 1;
    uint32_t drop     = (move >> 15) & 1;

    NSString *toCsa = CsaSquareFromMoveBits(to);
    NSString *toUsi = csa_squareToUsi(toCsa);
    if (!toUsi) {
        file_log([NSString stringWithFormat:
                  @"[CSA-ENG] bad to-square in: %@", line]);
        return;
    }

    NSString *usi;
    if (drop) {
        NSString *letter = csa_pieceToUsiDropLetter(pieceType);
        if (!letter) {
            file_log([NSString stringWithFormat:
                      @"[CSA-ENG] cannot map drop piece %d to USI: %@",
                      pieceType, line]);
            return;
        }
        usi = [NSString stringWithFormat:@"%@*%@", letter, toUsi];
    } else {
        NSString *fromCsa = CsaSquareFromMoveBits(from);
        NSString *fromUsi = csa_squareToUsi(fromCsa);
        if (!fromUsi) {
            file_log([NSString stringWithFormat:
                      @"[CSA-ENG] bad from-square in: %@", line]);
            return;
        }
        usi = promote
            ? [NSString stringWithFormat:@"%@%@+", fromUsi, toUsi]
            : [NSString stringWithFormat:@"%@%@", fromUsi, toUsi];
    }

    NSString *outSfen = nil;
    NSString *outErr = nil;
    uint32_t outRaw = 0;
    bool ok = inject_apply(usi, &outSfen, &outRaw, &outErr);
    file_log([NSString stringWithFormat:
              @"[CSA-ENG] inject_apply usi=%@ ok=%d raw=0x%x err=%@ sfen=%@",
              usi, (int)ok, (unsigned)outRaw, outErr ?: @"", outSfen ?: @""]);
}

// ---------------------------------------------------------------------------
// Match lifecycle.
// ---------------------------------------------------------------------------

void CsaEngineOnMatchStart(int32_t local_player) {
    atomic_store(&g_csaLocalPlayer, local_player);
    // Reset the per-side post-move clock cache so the first move's `,T<n>`
    // delta isn't computed against a stale previous-match value.
    g_csaLastBlackRemainSec = NAN;
    g_csaLastWhiteRemainSec = NAN;
    // Bootstrap the wall-clock baseline so the first move's T<n> falls
    // back to "match-start → first move" wall-time when the live clock is
    // unavailable. We seed the BLACK side because the very first move is
    // always Black's (CSA's spec, and KIOU follows it).
    uint64_t startMach = mach_absolute_time();
    g_csaLastMoveMachTicks[0] = startMach;
    g_csaLastMoveMachTicks[1] = startMach;

    int s = atomic_load(&g_csaState);
    file_log([NSString stringWithFormat:
              @"[CSA-ENG] match_start local_player=%d state=%s",
              (int)local_player, csa_state_name(s)]);

    // If a client is already logged in, push Game_Summary right away.
    if (s == CSA_STATE_LOGIN || s == CSA_STATE_GAME_OVER) {
        csa_send_game_summary(local_player);
    } else if (s == CSA_STATE_BOOT) {
        // No client connected yet — cache state; the LOGIN handler will
        // pick this up when the engine eventually connects.
    } else {
        file_log([NSString stringWithFormat:
                  @"[CSA-ENG] match_start in unexpected state %s, "
                  @"forcing Game_Summary",
                  csa_state_name(s)]);
        csa_send_game_summary(local_player);
    }
}

void CsaEngineOnMatchEnd(usi_match_result_t result) {
    int s = atomic_load(&g_csaState);
    file_log([NSString stringWithFormat:
              @"[CSA-ENG] match_end result=%d state=%s",
              (int)result, csa_state_name(s)]);

    NSString *resultLines = CsaBuildMatchResult(result);
    if (resultLines.length > 0) {
        CsaEngineSendBlock(resultLines);
    }

    atomic_store(&g_csaLocalPlayer, -1);
    csa_set_state(CSA_STATE_GAME_OVER);
}

void CsaEngineOnMoveObserved(uint32_t move,
                             int32_t playerSide,
                             NSString *sfenAfter,
                             float blackTimeRemainSec,
                             float whiteTimeRemainSec) {
    int s = atomic_load(&g_csaState);
    if (s != CSA_STATE_PLAYING && s != CSA_STATE_AGREE_WAIT) {
        // Outside the per-move window — don't surface moves to the engine.
        // They'd confuse the CSA state machine on the engine's side.
        return;
    }

    // Recover the piece type from the post-move SFEN. For drops the to
    // square holds the freshly placed (unpromoted) piece; for normal moves
    // it holds the (possibly-promoted) moving piece.
    uint32_t to = move & 0x7F;
    int32_t pscPieceType = PscPieceTypeAtSquare(sfenAfter, to);
    if (pscPieceType < 0) {
        file_log([NSString stringWithFormat:
                  @"[CSA-ENG] cannot resolve piece type at to=%u "
                  @"(sfen=%@) — emitting raw bits log only",
                  to, sfenAfter ?: @""]);
        return;
    }

    // For normal promoting moves, CsaTextFromMoveBits wants the *unpromoted*
    // piece type and uses the promote bit to compute the destination piece
    // name (FU → TO etc). The post-move SFEN at the `to` square already
    // holds the promoted piece type; downshift before handing over.
    uint32_t promote = (move >> 14) & 1;
    uint32_t drop    = (move >> 15) & 1;
    if (!drop && promote && pscPieceType >= 9 && pscPieceType <= 14) {
        // 9 TO -> 1 FU, 10 NY -> 2 KY, 11 NK -> 3 KE, 12 NG -> 4 GI,
        // 13 UM -> 5 KA, 14 RY -> 6 HI.
        pscPieceType = pscPieceType - 8;
    }

    // Compute T<n> in seconds for this move. Two paths feed it:
    //
    //   (a) KIOU surfaces a live per-side clock (Online + the user's side
    //       in VsAI / Local) — we cache the post-move remaining-time and
    //       subtract the previous cached value on the next move.
    //
    //   (b) KIOU does NOT surface a live clock (VsAI's CPU side reports
    //       86400.0f "no limit," NaN on the first move) — we fall back to
    //       a wall-clock measurement: the time since the *opponent*
    //       finished their move. That delta IS this side's think time,
    //       because by the time NotifyPieceMoved fires for this move,
    //       only this side has been thinking.
    //
    // Path (a) wins when both are available because KIOU's internal clock
    // accounts for the animation / commit latency we don't see from
    // wall-clock alone. Path (b) is bootstrapped from the previous
    // observed move (any side) so the very first move of the match gets
    // T<n> based on the OnMatchStart-to-first-move delta.
    int32_t timeSpent = -1;
    float remain = (playerSide == 0) ? blackTimeRemainSec : whiteTimeRemainSec;
    float volatile *cacheSlot = (playerSide == 0)
        ? &g_csaLastBlackRemainSec
        : &g_csaLastWhiteRemainSec;

    uint64_t nowMach = mach_absolute_time();
    int32_t opponentSide = (playerSide == 0) ? 1 : 0;
    uint64_t opponentLastMach = g_csaLastMoveMachTicks[opponentSide];

    if (remain >= 0.0f) {
        // Path (a): live clock available.
        float last = *cacheSlot;
        if (!isnan(last) && last >= remain) {
            float delta = last - remain;
            timeSpent = (int32_t)delta;  // round down
        }
        *cacheSlot = remain;
    }
    if (timeSpent < 0 && opponentLastMach > 0 && nowMach > opponentLastMach) {
        // Path (b): wall-clock fallback. Used either when KIOU doesn't
        // surface a live clock for this side (VsAI's CPU sentinel), or
        // when path (a) couldn't compute a delta (this side's first move
        // of the match — no previous cached value to subtract from).
        timeSpent = (int32_t)csa_machTicksToSec(nowMach - opponentLastMach);
    }

    // Always update the wall-clock baseline for this side so the *next*
    // side's move (typically the opponent) can compute its think time.
    g_csaLastMoveMachTicks[playerSide] = nowMach;

    NSString *csa = CsaTextFromMoveBits(move, pscPieceType, playerSide,
                                        timeSpent);
    if (!csa) {
        file_log([NSString stringWithFormat:
                  @"[CSA-ENG] CsaTextFromMoveBits returned nil for "
                  @"move=0x%x piece=%d side=%d",
                  (unsigned)move, (int)pscPieceType, (int)playerSide]);
        return;
    }
    CsaEngineSendLine(csa);
}

// ---------------------------------------------------------------------------
// TCP transport callbacks. Server_CSA.m calls these from the accept queue.
// ---------------------------------------------------------------------------

void CsaEngineOnTcpClientConnected(void) {
    file_log(@"[CSA-ENG] tcp client connected");
    csa_set_state(CSA_STATE_LOGIN);
}

void CsaEngineOnTcpClientDisconnected(void) {
    file_log(@"[CSA-ENG] tcp client disconnected");
    csa_set_state(CSA_STATE_BOOT);
}

// ---------------------------------------------------------------------------
// Installer. Run once from Tweak.m after Server_CSA.m has bound the port.
// ---------------------------------------------------------------------------
static void csa_engine_line_handler(NSString *line) {
    @autoreleasepool {
        csa_handle_line(line);
    }
}

void CsaEngineInstall(void) {
    KEBCsaServerSetLineHandler(csa_engine_line_handler);
    file_log(@"[CSA-ENG] installed (line handler registered)");
}
