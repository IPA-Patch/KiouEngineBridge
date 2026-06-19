#import "Internal.h"

#import <stdatomic.h>

// ===========================================================================
// Csa_Engine — CSA server-side state machine for WarsEngineBridge.
//
// WEB acts as the CSA server; the connecting TCP peer is a CSA engine.
// ShogiWars owns board state and clocks via its own TCP server protocol.
//
// State machine:
//
//   BOOT        ── no TCP client
//      ↓  TCP accept
//   LOGIN       ── awaiting LOGIN from engine
//      ↓  "LOGIN <name> <pass>"   →  "LOGIN:<name> OK"
//   PLAYING     ── per-move exchange
//      ↓  inbound "<sign><from><to><PIECE>"  →  inject via GameController.Move
//      ↓  inbound "%TORYO"                   →  ShowResignAlertDialog
//      ↓  OnMatchEnd                         →  "#REASON\n#WIN/LOSE/DRAW"
//   GAME_OVER   ── waiting for next LOGIN or LOGOUT
//
// Key difference from KEB: ShogiWars's moves arrive in CSA text form
// ("+7776FU") already, so there is no KIOU Move bits parsing needed.
// We pass the CSA string directly to inject_apply which calls
// GameController.Move(csa, timeLeft, quiet).
// ===========================================================================

typedef enum {
    CSA_STATE_BOOT      = 0,
    CSA_STATE_LOGIN     = 1,
    CSA_STATE_PLAYING   = 2,
    CSA_STATE_GAME_OVER = 3,
} csa_state_t;

static _Atomic int    g_csaState       = CSA_STATE_BOOT;
static _Atomic int    g_csaIsBlack     = -1;  // -1=unknown, 0=gote, 1=sente
static NSString *volatile g_csaLastGameSummary = nil;
static NSString *volatile g_csaLastGameID      = nil;

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------
static const char *csa_state_name(int s) {
    switch (s) {
        case CSA_STATE_BOOT:      return "BOOT";
        case CSA_STATE_LOGIN:     return "LOGIN";
        case CSA_STATE_PLAYING:   return "PLAYING";
        case CSA_STATE_GAME_OVER: return "GAME_OVER";
        default:                  return "?";
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
// Outbound funnel.
// ---------------------------------------------------------------------------
static void CsaEngineSendLine(NSString *line) {
    if (!line.length) return;
    IPALog([NSString stringWithFormat:@"[CSA>] %@", line]);
    WEBCsaServerPush(line);
}

static void CsaEngineSendBlock(NSString *block) {
    if (!block.length) return;
    for (NSString *line in [block componentsSeparatedByString:@"\n"]) {
        if (line.length) CsaEngineSendLine(line);
    }
}

// ---------------------------------------------------------------------------
// Game_Summary delivery.
// ---------------------------------------------------------------------------
static void csa_send_game_summary(bool isBlack) {
    NSString *gameId  = nil;
    NSString *summary = CsaBuildGameSummary(isBlack, &gameId);
    if (!summary.length) {
        IPALog(@"[CSA-ENG] CsaBuildGameSummary returned empty — deferring");
        return;
    }
    g_csaLastGameSummary = summary;
    g_csaLastGameID      = gameId ?: @"GAME";
    CsaEngineSendBlock(summary);
    // Send START immediately — ShogiWars's server starts ticking the clock
    // the moment GAME_START arrives; we can't pause it waiting for AGREE.
    CsaEngineSendLine([NSString stringWithFormat:@"START:%@",
                       g_csaLastGameID]);
    csa_set_state(CSA_STATE_PLAYING);
}

// ---------------------------------------------------------------------------
// Inbound line handlers.
// ---------------------------------------------------------------------------
static void csa_handle_login(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *name = (parts.count >= 2) ? parts[1] : @"engine";
    CsaEngineSendLine([NSString stringWithFormat:@"LOGIN:%@ OK", name]);

    int isBlack = atomic_load(&g_csaIsBlack);
    if (isBlack == 0 || isBlack == 1) {
        // Match in progress (either currently PLAYING, just GAME_OVER, or a
        // reconnect after the previous client dropped while PLAYING). Send
        // Game_Summary regardless of current state — for PLAYING this is a
        // re-emit so a reconnecting engine learns the live board; for
        // LOGIN/GAME_OVER it's the first emit.
        bool isBlackBool = (isBlack == 1);
        dispatch_async(dispatch_get_main_queue(), ^{
            csa_send_game_summary(isBlackBool);
        });
    } else {
        csa_set_state(CSA_STATE_LOGIN);
    }
}

static void csa_handle_agree(NSString *line) {
    (void)line;
    int s = atomic_load(&g_csaState);
    if (s == CSA_STATE_PLAYING) {
        IPALog(@"[CSA-ENG] AGREE in PLAYING — already started, dropping");
        return;
    }
    IPALog([NSString stringWithFormat:@"[CSA-ENG] AGREE in state %s — ignoring",
              csa_state_name(s)]);
}

static void csa_handle_reject(NSString *line) {
    (void)line;
    NSString *gid = g_csaLastGameID ?: @"GAME";
    CsaEngineSendLine([NSString stringWithFormat:@"REJECT:%@ by engine", gid]);
    csa_set_state(CSA_STATE_LOGIN);
}

static void csa_handle_logout(void) {
    CsaEngineSendLine(@"LOGOUT:completed");
    WEBCsaServerClose();
    csa_set_state(CSA_STATE_BOOT);
}

// %%TIME — reply with remaining time block.
static void csa_handle_time_query(void) {
    int s = atomic_load(&g_csaState);
    if (s != CSA_STATE_PLAYING) {
        IPALog(@"[CSA-ENG] %%TIME outside PLAYING — ignoring");
        return;
    }
    float sr = g_csaLastSenteRemainSec;
    float gr = g_csaLastGoteRemainSec;
    NSMutableString *block = [NSMutableString string];
    [block appendString:@"BEGIN Time\n"];
    if (!isnan(sr) && sr >= 0)
        [block appendFormat:@"Remaining_Time_Ms+:%lld\n", (long long)(sr * 1000.0f)];
    if (!isnan(gr) && gr >= 0)
        [block appendFormat:@"Remaining_Time_Ms-:%lld\n", (long long)(gr * 1000.0f)];
    [block appendString:@"END Time"];
    CsaEngineSendBlock(block);
}

// %TORYO / %KACHI / %CHUDAN.
static void csa_handle_special(NSString *line) {
    int s = atomic_load(&g_csaState);
    if (s != CSA_STATE_PLAYING) {
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] special %@ in state %s — ignoring",
                  line, csa_state_name(s)]);
        return;
    }

    if ([line isEqualToString:@"%TORYO"]) {
        InjectResign();
        CsaEngineSendLine(@"#RESIGN");
        CsaEngineSendLine(@"#LOSE");
        csa_set_state(CSA_STATE_GAME_OVER);
        return;
    }
    if ([line isEqualToString:@"%KACHI"]) {
        CsaEngineSendLine(@"#JISHOGI");
        CsaEngineSendLine(@"#WIN");
        csa_set_state(CSA_STATE_GAME_OVER);
        return;
    }
    if ([line isEqualToString:@"%CHUDAN"]) {
        CsaEngineSendLine(@"#CHUDAN");
        csa_set_state(CSA_STATE_GAME_OVER);
        return;
    }
    IPALog([NSString stringWithFormat:@"[CSA-ENG] unknown special: %@", line]);
}

// Engine move: "+7776FU" or "-3334FU" etc.
// ShogiWars uses CSA format natively — pass directly to inject_apply.
static void csa_handle_move_from_engine(NSString *line) {
    int s = atomic_load(&g_csaState);
    if (s != CSA_STATE_PLAYING) {
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] move in state %s — ignoring: %@",
                  csa_state_name(s), line]);
        return;
    }

    // Strip optional ",T<n>" suffix — GameController.Move doesn't take it.
    NSString *csa = line;
    NSRange tRange = [line rangeOfString:@",T"];
    if (tRange.location != NSNotFound) {
        csa = [line substringToIndex:tRange.location];
    }

    // Hop to the Unity main thread.
    NSString *csaCap = [csa copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        int now = atomic_load(&g_csaState);
        if (now != CSA_STATE_PLAYING) {
            IPALog([NSString stringWithFormat:
                      @"[CSA-ENG] move dropped (state changed to %s): %@",
                      csa_state_name(now), csaCap]);
            return;
        }
        BOOL ok = inject_apply(csaCap);
        IPALog([NSString stringWithFormat:
                  @"[CSA-ENG] inject_apply csa=%@ ok=%d", csaCap, (int)ok]);
        if (!ok) {
            CsaEngineSendLine(@"#ILLEGAL_MOVE");
        }
    });
}

static void csa_handle_line(NSString *line) {
    NSString *t = [line stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return;  // CSA liveness ping

    if ([t hasPrefix:@"LOGIN "] || [t isEqualToString:@"LOGIN"]) {
        csa_handle_login(t); return;
    }
    if ([t isEqualToString:@"LOGOUT"]) {
        csa_handle_logout(); return;
    }
    if ([t hasPrefix:@"AGREE"]) {
        csa_handle_agree(t); return;
    }
    if ([t hasPrefix:@"REJECT"]) {
        csa_handle_reject(t); return;
    }
    if ([t isEqualToString:@"%%TIME"]) {
        csa_handle_time_query(); return;
    }
    if ([t hasPrefix:@"%%"]) {
        IPALog([NSString stringWithFormat:@"[CSA-ENG] unknown extension: %@", t]);
        return;
    }
    if ([t hasPrefix:@"%"]) {
        csa_handle_special(t); return;
    }
    if ([t hasPrefix:@"+"] || [t hasPrefix:@"-"]) {
        csa_handle_move_from_engine(t); return;
    }
    IPALog([NSString stringWithFormat:
              @"[CSA-ENG] ignoring unrecognised line: %@", t]);
}

// ---------------------------------------------------------------------------
// Match lifecycle (called from Hook_GameController.m).
// ---------------------------------------------------------------------------
void CsaEngineOnMatchStart(bool isBlack, void *gameStartJson) {
    (void)gameStartJson;  // already stashed by CsaSetGameStart
    int isBlackInt = isBlack ? 1 : 0;
    atomic_store(&g_csaIsBlack, isBlackInt);
    g_csaLastSenteRemainSec = NAN;
    g_csaLastGoteRemainSec  = NAN;

    int s = atomic_load(&g_csaState);
    IPALog([NSString stringWithFormat:
              @"[CSA-ENG] match_start isBlack=%d state=%s",
              isBlackInt, csa_state_name(s)]);

    if (s == CSA_STATE_LOGIN || s == CSA_STATE_GAME_OVER) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            int now = atomic_load(&g_csaState);
            if (now == CSA_STATE_LOGIN || now == CSA_STATE_GAME_OVER) {
                csa_send_game_summary(isBlack);
            }
        });
    }
}

void CsaEngineOnMoveObserved(NSString *csa, float timeLeft, bool isBlackMove) {
    int s = atomic_load(&g_csaState);
    if (s != CSA_STATE_PLAYING) return;

    // Update remaining time cache.
    if (timeLeft > 0.0f) {
        if (isBlackMove) g_csaLastSenteRemainSec = timeLeft;
        else             g_csaLastGoteRemainSec  = timeLeft;
    }

    // Emit CSA move notification. timeLeft == 0 means we don't know — omit T.
    NSString *line;
    if (timeLeft > 0.0f) {
        line = [NSString stringWithFormat:@"%@,T%d",
                csa, (int32_t)timeLeft];
    } else {
        line = csa;
    }
    CsaEngineSendLine(line);
}

void CsaEngineOnMatchEnd(web_match_result_t result, NSString *reason) {
    int s = atomic_load(&g_csaState);
    IPALog([NSString stringWithFormat:
              @"[CSA-ENG] match_end result=%d reason=%@ state=%s",
              (int)result, reason ?: @"", csa_state_name(s)]);

    if (s != CSA_STATE_GAME_OVER) {
        NSString *resultLines = CsaBuildMatchResult(result, reason ?: @"");
        if (resultLines.length > 0) CsaEngineSendBlock(resultLines);
    }

    atomic_store(&g_csaIsBlack, -1);
    CsaSetGameStart(NULL);
    csa_set_state(CSA_STATE_GAME_OVER);
}

// ---------------------------------------------------------------------------
// TCP transport callbacks.
// ---------------------------------------------------------------------------
void CsaEngineOnTcpClientConnected(void) {
    IPALog(@"[CSA-ENG] tcp client connected");
    csa_set_state(CSA_STATE_LOGIN);

    // Auto-login convenience: if a ShogiWars match is already in progress,
    // ship `LOGIN:auto OK` + Game_Summary + START immediately so a plain
    // `nc` operator can start sending moves without typing `LOGIN test
    // pass` first. A real CSA engine that sends its own LOGIN later will
    // be handled by csa_handle_login — sending Game_Summary twice is
    // harmless (clients treat the latest as authoritative).
    int isBlack = atomic_load(&g_csaIsBlack);
    if (isBlack == 0 || isBlack == 1) {
        bool isBlackBool = (isBlack == 1);
        CsaEngineSendLine(@"LOGIN:auto OK");
        dispatch_async(dispatch_get_main_queue(), ^{
            csa_send_game_summary(isBlackBool);
        });
    }
}

void CsaEngineOnTcpClientDisconnected(void) {
    int s = atomic_load(&g_csaState);
    IPALog([NSString stringWithFormat:
              @"[CSA-ENG] tcp client disconnected (state=%s)",
              csa_state_name(s)]);

    // Keep PLAYING / GAME_OVER state intact so a reconnect can resume the
    // same match. csa_handle_login on the next connection re-sends
    // Game_Summary + START based on the live ShogiWars match. Only fall
    // back to BOOT when there's no live match in flight (LOGIN /
    // AGREE_WAIT).
    if (s == CSA_STATE_PLAYING || s == CSA_STATE_GAME_OVER) {
        IPALog(@"[CSA-ENG] preserving match state for reconnect");
        return;
    }
    csa_set_state(CSA_STATE_BOOT);
}

// ---------------------------------------------------------------------------
// Installer.
// ---------------------------------------------------------------------------
static void csa_engine_line_handler(NSString *line) {
    @autoreleasepool { csa_handle_line(line); }
}

void CsaEngineInstall(void) {
    WEBCsaServerSetLineHandler(csa_engine_line_handler);
    IPALog(@"[CSA-ENG] installed (line handler registered)");
}
