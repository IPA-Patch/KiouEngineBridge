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
_Atomic float g_csaLastBlackRemainSec = NAN;
_Atomic float g_csaLastWhiteRemainSec = NAN;
_Atomic int32_t g_csaByoyomiMs = -1;

// Previous-move SFEN. Used to detect drops by hand-delta against the
// post-move SFEN (the KIOU Move bits don't encode the dropped piece type
// in any reverse-engineered form yet — Task 7 of the migration plan).
static NSString *volatile g_csaPrevSfen = nil;

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

static void csa_set_state_impl(int newState, const char *caller) {
    int old = atomic_exchange(&g_csaState, newState);
    if (old != newState) {
        IPALog([NSString stringWithFormat:@"[CSA-ENG] state %s -> %s (from %s)",
                  csa_state_name(old), csa_state_name(newState), caller]);
    }
}
#define csa_set_state(s) csa_set_state_impl((s), __FUNCTION__)

// ---------------------------------------------------------------------------
// Outbound funnel — every line that goes on the wire passes through
// CsaEngineSendLine, so the log shows the engine's view of the session.
// ---------------------------------------------------------------------------
void CsaEngineSendLine(NSString *line) {
    if (line.length == 0) return;
    IPALog([NSString stringWithFormat:@"[CSA>] %@", line]);
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
                                     NSString **outGameId,
                                     NSString **outStartSfen);
extern NSString *CsaBuildMatchResult(usi_match_result_t result);

static void csa_send_game_summary(int32_t local_player) {
    NSString *gameId = nil;
    NSString *startSfen = nil;
    NSString *summary = CsaBuildGameSummary(local_player, &gameId, &startSfen);
    if (summary.length == 0) {
        IPALog(@"[CSA-ENG] CsaBuildGameSummary returned empty — "
                 @"deferring Game_Summary");
        return;
    }
    g_csaLastGameSummary = summary;
    g_csaLastGameID = gameId ?: @"GAME";
    // Cache the starting SFEN so the very first engine move can be validated
    // against a real board snapshot (g_csaPrevSfen is nil until the first
    // NotifyPieceMoved fires, which leaves the validator blind for move 1).
    if (startSfen.length > 0) {
        g_csaPrevSfen = startSfen;
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] seeded g_csaPrevSfen from Game_Summary sfen=%@",
                  startSfen]);
    }
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
        // We already have a KIOU match in progress — push Game_Summary
        // from the main queue: SfenFromGameController dereferences
        // il2cpp objects and isn't safe on the CSA recv queue this
        // handler runs on.
        //
        // Accept LOGIN in both LOGIN and PLAYING states: the connect-time
        // auto-renegotiate (CsaEngineOnTcpClientConnected) races this
        // handler on the main queue, so by the time this dispatch lands
        // the state may already be PLAYING. Sending Game_Summary again is
        // harmless — the engine treats it as the authoritative starting
        // position and discards any prior state.
        int32_t lpCap = lp;
        dispatch_async(dispatch_get_main_queue(), ^{
            int now = atomic_load(&g_csaState);
            if (now == CSA_STATE_LOGIN || now == CSA_STATE_PLAYING) {
                // Send Game_Summary regardless of whether we're in LOGIN or
                // PLAYING: the match_start handler races this dispatch on the
                // main queue and may have already advanced state to PLAYING.
                // Resending Game_Summary + START from PLAYING is harmless —
                // the engine treats the last received summary as authoritative
                // and the bridge's parse_game_summary breaks on the first
                // START it sees.
                // Do NOT reset state to LOGIN first — that flip causes the
                // next move observation to be dropped.
                csa_send_game_summary(lpCap);
            } else {
                IPALog([NSString stringWithFormat:
                          @"[CSA-ENG] LOGIN renegotiate skipped: state "
                          @"changed to %s before main-queue dispatch",
                          csa_state_name(now)]);
            }
        });
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
        IPALog(@"[CSA-ENG] AGREE in PLAYING — already started, dropping");
        return;
    }
    if (s != CSA_STATE_AGREE_WAIT) {
        IPALog([NSString stringWithFormat:
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
    IPALog(@"[CSA-ENG] engine REJECTed match — staying connected");
    NSString *gid = g_csaLastGameID ?: @"GAME";
    CsaEngineSendLine([NSString stringWithFormat:@"REJECT:%@ by engine", gid]);
    csa_set_state(CSA_STATE_LOGIN);
}

static NSString *csa_timeBlockString(void) {
    float blackRemainSec = atomic_load(&g_csaLastBlackRemainSec);
    float whiteRemainSec = atomic_load(&g_csaLastWhiteRemainSec);
    int32_t byoyomiMs = atomic_load(&g_csaByoyomiMs);

    if (isnan(blackRemainSec) || isnan(whiteRemainSec)) return nil;

    int64_t blackRemainMs = (int64_t)llroundf(blackRemainSec * 1000.0f);
    int64_t whiteRemainMs = (int64_t)llroundf(whiteRemainSec * 1000.0f);
    if (blackRemainMs < 0 || whiteRemainMs < 0) return nil;

    NSMutableString *out = [NSMutableString stringWithString:@"BEGIN Time\n"];
    [out appendFormat:@"Remaining_Time_Ms+:%lld\n", blackRemainMs];
    [out appendFormat:@"Remaining_Time_Ms-:%lld\n", whiteRemainMs];
    if (byoyomiMs >= 0) {
        [out appendFormat:@"Byoyomi_Ms:%d\n", byoyomiMs];
    }
    [out appendString:@"END Time"];
    return out;
}

static void csa_handle_extension(NSString *line) {
    int s = atomic_load(&g_csaState);
    if (s != CSA_STATE_PLAYING) {
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] extension %@ in state %s — ignoring",
                  line, csa_state_name(s)]);
        return;
    }

    if ([line isEqualToString:@"%%TIME"]) {
        NSString *timeBlock = csa_timeBlockString();
        if (timeBlock.length == 0) {
            IPALog(@"[CSA-ENG] %%TIME requested before both remain clocks were known");
            return;
        }
        CsaEngineSendBlock(timeBlock);
        return;
    }

    IPALog([NSString stringWithFormat:
              @"[CSA-ENG] unknown extension: %@", line]);
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
    if ([trimmed hasPrefix:@"%%"]) {
        csa_handle_extension(trimmed);
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
    IPALog([NSString stringWithFormat:
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
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] special %@ in state %s — ignoring",
                  line, csa_state_name(s)]);
        return;
    }

    int32_t lp = atomic_load(&g_csaLocalPlayer);
    if ([line isEqualToString:@"%TORYO"]) {
        // The CSA engine resigns — the engine IS the local KIOU player,
        // so the local seat surrenders. RequestSurrender always resigns the
        // local player; the outcome from the engine's view is #LOSE.
        InjectResign(lp);
        CsaEngineSendLine(@"#RESIGN");
        CsaEngineSendLine(@"#LOSE");
        csa_set_state(CSA_STATE_GAME_OVER);
        return;
    }
    if ([line isEqualToString:@"%KACHI"]) {
        // The engine declares nyugyoku for the local seat — local wins.
        InjectNyugyokuDeclaration(lp);
        CsaEngineSendLine(@"#JISHOGI");
        CsaEngineSendLine(@"#WIN");
        csa_set_state(CSA_STATE_GAME_OVER);
        return;
    }
    if ([line isEqualToString:@"%CHUDAN"]) {
        IPALog(@"[CSA-ENG] %%CHUDAN received — not surfaced to KIOU");
        CsaEngineSendLine(@"#CHUDAN");
        csa_set_state(CSA_STATE_GAME_OVER);
        return;
    }
    IPALog([NSString stringWithFormat:
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

// Forward decl — body below; hosts the actual validator + inject_apply
// path that the dispatcher hops onto the main queue.
static void csa_apply_engine_move(NSString *line, uint32_t move,
                                  int32_t pieceType, int32_t playerSide);

static void csa_handle_move_from_engine(NSString *line) {
    int s = atomic_load(&g_csaState);
    if (s != CSA_STATE_PLAYING) {
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] move in state %s — ignoring: %@",
                  csa_state_name(s), line]);
        return;
    }

    uint32_t move = 0;
    int32_t pieceType = 0;
    int32_t playerSide = -1;
    int32_t timeSpent = -1;
    if (!MoveBitsFromCsaText(line, &move, &pieceType, &playerSide, &timeSpent)) {
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] malformed move: %@", line]);
        return;
    }
    (void)timeSpent;  // engine-reported think time is logged but unused

    IPALog([NSString stringWithFormat:
              @"[CSA-ENG-DBG] parsed line=\"%@\" move=0x%x piece=%d "
              @"side=%d t=%d — about to dispatch_async(main)",
              line, (unsigned)move, (int)pieceType,
              (int)playerSide, (int)timeSpent]);

    // Hop to the Unity main queue: inject_apply touches il2cpp methods
    // that are only safe from the main thread. The CSA recv queue this
    // handler runs on isn't.
    NSString *lineCap = [line copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG-DBG] main-queue dispatch arrived for: %@",
                  lineCap]);
        csa_apply_engine_move(lineCap, move, pieceType, playerSide);
        IPALog(@"[CSA-ENG-DBG] csa_apply_engine_move returned cleanly");
    });
    IPALog(@"[CSA-ENG-DBG] dispatch_async(main) submitted, returning");
}

static void csa_apply_engine_move(NSString *line, uint32_t move,
                                  int32_t pieceType, int32_t playerSide) {
    IPALog([NSString stringWithFormat:
              @"[CSA-ENG-DBG] csa_apply_engine_move entered line=%@", line]);

    // Re-check the state on the main queue — a LOGOUT / match_end could
    // have landed between the recv-queue dispatch and us getting picked up.
    int s = atomic_load(&g_csaState);
    IPALog([NSString stringWithFormat:
              @"[CSA-ENG-DBG] state on main queue=%s", csa_state_name(s)]);
    if (s != CSA_STATE_PLAYING) {
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] move state changed to %s before main "
                  @"dispatch — dropping: %@",
                  csa_state_name(s), line]);
        return;
    }
    uint32_t drop    = (move >> 15) & 1;
    uint32_t promote = (move >> 14) & 1;
    uint32_t from    = (move >> 7) & 0x7F;
    uint32_t to      = move & 0x7F;
    IPALog([NSString stringWithFormat:
              @"[CSA-ENG-DBG] decoded from=%u to=%u promote=%u drop=%u",
              from, to, promote, drop]);

    int32_t lp = atomic_load(&g_csaLocalPlayer);
    // The connected CSA engine stands in for KIOU's local human player —
    // it occupies the same seat (Your_Turn maps directly to lp). On
    // open-seat modes (lp == -1) we accept whatever side the engine
    // claims.
    int32_t enginePlayer = lp;
    if (enginePlayer != -1 && playerSide != enginePlayer) {
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] move side mismatch: engine=%d got=%d "
                  @"(applying anyway)",
                  enginePlayer, playerSide]);
    }

    // (to/from/promote/drop already extracted above so the validator
    // hook can inspect them before we build the USI string.)

    // MoveBitsFromCsaText flags promote=true whenever the CSA piece
    // mnemonic is a promoted form (TO/NY/NK/NG/UM/RY), but in CSA a
    // promoted name on the move line carries two cases:
    //
    //   (1) the piece was unpromoted on `from` and is promoting on this move
    //   (2) the piece was already promoted on `from` and is just moving
    //
    // We disambiguate by reading the piece sitting on `from` in the
    // pre-move SFEN. If it's already promoted (PieceType 9..14), the
    // move is case (2) and USI must NOT carry a trailing '+'.
    if (promote && !drop) {
        NSString *prev = g_csaPrevSfen;
        if (prev.length > 0) {
            int32_t fromPiece = PscPieceTypeAtSquare(prev, from);
            if (fromPiece >= 9 && fromPiece <= 14) {
                IPALog([NSString stringWithFormat:
                          @"[CSA-ENG] promote bit cleared (from=%u "
                          @"already holds promoted piece %d): %@",
                          from, fromPiece, line]);
                promote = 0;
            }
        }
    }
    IPALog(@"[CSA-ENG-DBG] promote check done — building toUsi");

    NSString *toCsa = CsaSquareFromMoveBits(to);
    NSString *toUsi = csa_squareToUsi(toCsa);
    if (!toUsi) {
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] bad to-square in: %@", line]);
        return;
    }
    IPALog([NSString stringWithFormat:
              @"[CSA-ENG-DBG] toCsa=%@ toUsi=%@", toCsa, toUsi]);

    // Cheap legality pre-checks. The primary goal is to keep blatantly
    // illegal moves (drop on occupied, move from empty, nifu, dead-end
    // drops, etc) from reaching inject_apply.
    //
    // We use the cached g_csaPrevSfen (captured from NotifyPieceMoved)
    // rather than a live read, because the live read needs il2cpp main-
    // thread guarantees that earlier attempts couldn't satisfy without
    // crashing the runtime. KIOU's own validation catches the
    // position-specific rules anyway; the cached SFEN is enough to
    // reject the obvious categories KEB cares about (occupied drops,
    // dead-end drops, nifu, piece-type mismatches).
    NSString *validatorSfen = g_csaPrevSfen;

    IPALog([NSString stringWithFormat:
              @"[CSA-ENG-DBG] validator sfen len=%lu — running validator",
              (unsigned long)validatorSfen.length]);

    if (validatorSfen.length > 0) {
        const char *reason = drop
            ? ValidateCsaDrop(validatorSfen, to, pieceType, playerSide)
            : ValidateCsaMove(validatorSfen, from, to, pieceType,
                              promote ? YES : NO, playerSide);
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG-DBG] validator result reason=%s",
                  reason ?: "OK"]);
        if (reason) {
            IPALog([NSString stringWithFormat:
                      @"[CSA-ENG] rejecting illegal move (reason=%s): %@",
                      reason, line]);
            // CSA spec lets the server emit `#ILLEGAL_MOVE` on the engine's
            // submission but the existing match continues. Send the marker
            // so the engine knows its move was discarded; keep PLAYING so
            // the engine can submit a different move.
            CsaEngineSendLine(@"#ILLEGAL_MOVE");
            return;
        }
    }

    NSString *usi;
    if (drop) {
        NSString *letter = csa_pieceToUsiDropLetter(pieceType);
        if (!letter) {
            IPALog([NSString stringWithFormat:
                      @"[CSA-ENG] cannot map drop piece %d to USI: %@",
                      pieceType, line]);
            return;
        }
        usi = [NSString stringWithFormat:@"%@*%@", letter, toUsi];
    } else {
        NSString *fromCsa = CsaSquareFromMoveBits(from);
        NSString *fromUsi = csa_squareToUsi(fromCsa);
        if (!fromUsi) {
            IPALog([NSString stringWithFormat:
                      @"[CSA-ENG] bad from-square in: %@", line]);
            return;
        }
        usi = promote
            ? [NSString stringWithFormat:@"%@%@+", fromUsi, toUsi]
            : [NSString stringWithFormat:@"%@%@", fromUsi, toUsi];
    }

    IPALog([NSString stringWithFormat:
              @"[CSA-ENG-DBG] built usi=%@ — calling inject_apply", usi]);

    NSString *outSfen = nil;
    NSString *outErr = nil;
    uint32_t outRaw = 0;
    bool ok = inject_apply(usi, &outSfen, &outRaw, &outErr);
    IPALog([NSString stringWithFormat:
              @"[CSA-ENG] inject_apply usi=%@ ok=%d raw=0x%x err=%@ sfen=%@",
              usi, (int)ok, (unsigned)outRaw, outErr ?: @"", outSfen ?: @""]);
    if (!ok) {
        // inject_apply already filtered out the obvious bit-level
        // parse failures (empty_from, dropfmt, etc) — KEB's own
        // validators caught the rest before we got here. Anything
        // that still slipped through and was rejected at the
        // injection layer is, by definition, illegal: tell the
        // engine so it can submit a different move instead of
        // assuming the previous one stuck.
        CsaEngineSendLine(@"#ILLEGAL_MOVE");
    }
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
    atomic_store(&g_csaByoyomiMs, -1);
    // Drop the previous match's SFEN so hand-delta drop detection and
    // pre-move piece lookup don't carry across matches.
    g_csaPrevSfen = nil;
    // Bootstrap the wall-clock baseline so the first move's T<n> falls
    // back to "match-start → first move" wall-time when the live clock is
    // unavailable. We seed the BLACK side because the very first move is
    // always Black's (CSA's spec, and KIOU follows it).
    uint64_t startMach = mach_absolute_time();
    g_csaLastMoveMachTicks[0] = startMach;
    g_csaLastMoveMachTicks[1] = startMach;

    int s = atomic_load(&g_csaState);
    IPALog([NSString stringWithFormat:
              @"[CSA-ENG] match_start local_player=%d state=%s",
              (int)local_player, csa_state_name(s)]);

    // If a client is waiting in LOGIN state, push Game_Summary right away.
    // GAME_OVER: new match started while client is still connected — send
    // a fresh Game_Summary so the engine can restart.
    // BOOT: no client yet — g_csaLocalPlayer is now set; LOGIN handler
    // will send Game_Summary when the engine connects.
    // PLAYING: engine is connected and a previous Game_Summary + START have
    // already been sent. The engine will send LOGIN when it reconnects, and
    // the LOGIN handler sends a fresh Game_Summary at that point. Don't send
    // a second Game_Summary here — that would race with the LOGIN dispatch
    // and cause a PLAYING→LOGIN→PLAYING flip-flop.
    if (s == CSA_STATE_LOGIN || s == CSA_STATE_GAME_OVER) {
        // Defer Game_Summary by ~500ms so scene-create / GameController
        // initialization finishes first. SfenFromGameController inside
        // csa_send_game_summary can otherwise block on il2cpp locks
        // during scene transition, triggering 0x8badf00d watchdog kill.
        int32_t lpCap = local_player;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            int now = atomic_load(&g_csaState);
            if (now == CSA_STATE_LOGIN || now == CSA_STATE_GAME_OVER) {
                csa_send_game_summary(lpCap);
            }
        });
    }
}

void CsaEngineOnMatchEnd(usi_match_result_t result) {
    int s = atomic_load(&g_csaState);
    IPALog([NSString stringWithFormat:
              @"[CSA-ENG] match_end result=%d state=%s",
              (int)result, csa_state_name(s)]);

    // Skip if already in GAME_OVER — %TORYO / %KACHI / %CHUDAN have already
    // sent the result block and advanced the state; re-emitting here would
    // send contradictory or duplicate #WIN/#LOSE lines to the engine.
    if (s != CSA_STATE_GAME_OVER) {
        NSString *resultLines = CsaBuildMatchResult(result);
        if (resultLines.length > 0) {
            CsaEngineSendBlock(resultLines);
        }
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
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] cannot resolve piece type at to=%u "
                  @"(sfen=%@) — emitting raw bits log only",
                  to, sfenAfter ?: @""]);
        // Even when we can't emit, advance the SFEN cache so the next
        // move's validator runs against the freshest board (otherwise the
        // pre-inject checks fire against a stale snapshot and let bad
        // moves through).
        g_csaPrevSfen = [sfenAfter copy];
        return;
    }

    uint32_t promote = (move >> 14) & 1;
    uint32_t dropBit = (move >> 15) & 1;
    BOOL isDrop = dropBit ? YES : NO;

    // KIOU's Move bits don't always set the drop bit reliably (the upper-16
    // encoding for drops is still under RE — Task 7 of the migration plan).
    // Cross-check by comparing the previous SFEN's hand-piece counts: if
    // the player who just moved is missing exactly one piece in hand, the
    // move was a drop and that's the dropped piece type.
    int32_t handDelta = DropPieceTypeFromHandDelta(g_csaPrevSfen, sfenAfter,
                                                   playerSide);
    if (!isDrop && handDelta > 0) {
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] drop inferred from hand delta — piece=%d "
                  @"(move bit said normal move)", handDelta]);
        isDrop = YES;
        pscPieceType = handDelta;
    }

    if (isDrop) {
        // Drops are always unpromoted. Use the hand-delta result when
        // available (more reliable than reading the to-square's piece).
        if (handDelta > 0) pscPieceType = handDelta;
    } else if (promote && pscPieceType >= 9 && pscPieceType <= 14) {
        // For normal promoting moves, CsaTextFromMoveBits wants the
        // *unpromoted* piece type and re-promotes it for display. The
        // post-move SFEN at the `to` square already holds the promoted
        // piece type; downshift before handing over.
        // 9 TO -> 1 FU, 10 NY -> 2 KY, 11 NK -> 3 KE, 12 NG -> 4 GI,
        // 13 UM -> 5 KA, 14 RY -> 6 HI.
        pscPieceType = pscPieceType - 8;
    }

    // Patch the drop bit into the move uint so CsaTextFromMoveBits emits
    // the canonical "+0055FU" form (from = "00") regardless of whether
    // KIOU's original bits had the drop flag set.
    if (isDrop) {
        move = (move | (1u << 15)) & ~(1u << 14);
        // Clear the from field so MoveBitsFromCsaText round-trips cleanly.
        move &= ~(((uint32_t)0x7F) << 7);
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
    _Atomic float *cacheSlot = (playerSide == 0)
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
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] CsaTextFromMoveBits returned nil for "
                  @"move=0x%x piece=%d side=%d drop=%d promote=%d "
                  @"prevSfen=\"%@\" postSfen=\"%@\"",
                  (unsigned)move, (int)pscPieceType, (int)playerSide,
                  (int)isDrop, (int)promote,
                  g_csaPrevSfen ?: @"", sfenAfter ?: @""]);
        // Even on emit failure, advance the SFEN snapshot so the next
        // hand-delta / promote check works against the latest board.
        g_csaPrevSfen = [sfenAfter copy];
        return;
    }
    CsaEngineSendLine(csa);
    // Roll forward the prev-SFEN cache so the *next* move can do
    // hand-delta drop detection and pre-move piece lookup.
    g_csaPrevSfen = [sfenAfter copy];
}

// ---------------------------------------------------------------------------
// TCP transport callbacks. Server_CSA.m calls these from the accept queue.
// ---------------------------------------------------------------------------

void CsaEngineOnTcpClientConnected(void) {
    IPALog(@"[CSA-ENG] tcp client connected");
    csa_set_state(CSA_STATE_LOGIN);
    // If a KIOU match is already in progress (reconnect mid-game, or the
    // engine simply attached after the user already started a CPU match),
    // auto-ship Game_Summary so the engine doesn't need to send LOGIN to
    // discover the current state.
    //
    // CsaEngineOnTcpClientConnected runs on the CSA accept queue (a GCD
    // serial queue inside Server_CSA.m). csa_send_game_summary eventually
    // calls SfenFromGameController, which dereferences il2cpp objects and
    // MUST run on Unity's main thread — touching them off-main crashes the
    // il2cpp runtime instantly (observed on-device as a KIOU restart 16s
    // after `mid-match reconnect — auto-renegotiating`).
    //
    // Hop the renegotiation to the main queue. The state set above is
    // safe to leave on LOGIN; csa_handle_login already gates the explicit-
    // LOGIN path so the engine doesn't get two Game_Summary blocks if it
    // races us to the wire.
    // Do NOT auto-send Game_Summary here. The CSA protocol requires the
    // engine to send LOGIN first; we send Game_Summary in response to that
    // (see csa_handle_login). Dispatching Game_Summary from both here and
    // csa_handle_login races on the main queue and causes the LOGIN handler's
    // dispatch to arrive when the state is already PLAYING (set by the
    // connect-time dispatch), silently dropping the second Game_Summary.
    // Letting LOGIN be the sole trigger eliminates the race entirely.
}

void CsaEngineOnTcpClientDisconnected(void) {
    IPALog(@"[CSA-ENG] tcp client disconnected");
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
    IPALog(@"[CSA-ENG] installed (line handler registered)");
}
