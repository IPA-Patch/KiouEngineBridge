#import "Internal.h"

// ===========================================================================
// Inject_Resign — bridge CSA's %TORYO / %KACHI submissions back to KIOU.
//
// CSA fires %TORYO when the connected engine resigns.
//
// We call MatchController.SurrenderAsync(PlayerSide) (RVA 0x59DDD94) which
// is the same internal path the game takes after the user taps "OK" on the
// resign confirmation dialog. It bypasses the dialog entirely and records
// the result as ShogiMatchResultReasonType.Resign (= 2) — correct and
// unrelated to AFK.
//
//   RequestSurrender (RVA 0x594A91C)
//     → shows "投了しますか？" dialog, then waits for human tap → NOT usable
//
//   ForceSurrenderByAfkAsync (RVA 0x594BD58)
//     → executes immediately but records the reason as AFK → wrong reason
//
//   MatchController.SurrenderAsync(PlayerSide) (RVA 0x59DDD94)  ← we use this
//     → executes immediately with Resign reason → correct
//
// MatchController is obtained from g_gameOrchestratorCache at field offset
// 0xF0 (_matchController, as documented in dump.cs). The pointer is read
// inside the dispatch_async block so it is always fresh.
//
// SurrenderAsync is a UniTask-returning async method. We call it
// fire-and-forget (UniTask discarded); KIOU drives the match-end sequence.
//
// PlayerSide enum (dump.cs TypeDefIndex 19506): Black = 0, White = 1.
//
// Seat note: %TORYO means the CSA engine (= local KIOU player) resigns.
// We pass the supplied playerSide directly. OnlinePvP ghosting is out of
// scope; CSA vs-CPU maps cleanly.
//
// Nyugyoku declaration (%KACHI) has no first-class KIOU API in dump.cs
// today; we log the request and let the CSA session terminate normally
// without driving KIOU. Task 7's follow-up will revisit this once the
// declaration surface is reverse-engineered.
// ===========================================================================

// GameOrchestrator._matchController field offset (dump.cs line 1211401)
#define GAMEORCH_MATCHCONTROLLER_OFFSET  0xF0

// MatchController.SurrenderAsync(PlayerSide player) -> UniTask
// dump.cs line 1418887, RVA 0x59DDD94
#define RVA_MATCHCTRL_SURRENDER_ASYNC  0x59DDD94

// PlayerSide enum values (dump.cs TypeDefIndex 19506)
#define PLAYER_SIDE_BLACK  0
#define PLAYER_SIDE_WHITE  1

// SurrenderAsync(PlayerSide) — PlayerSide is an int-backed enum, passed as
// a plain int32 in the second argument register (x1 on arm64).
typedef UniTaskRet (*MatchControllerSurrenderAsync_t)(void *self, int32_t player);
static MatchControllerSurrenderAsync_t g_SurrenderAsync = NULL;

static void resolve_surrender_async(void) {
    if (g_SurrenderAsync) return;
    if (g_unityBase == 0) return;
    g_SurrenderAsync = (MatchControllerSurrenderAsync_t)
        (void *)(g_unityBase + RVA_MATCHCTRL_SURRENDER_ASYNC);
}

void InjectResign(int32_t playerSide) {
    resolve_surrender_async();
    if (!g_SurrenderAsync) {
        IPALog([NSString stringWithFormat:
                  @"[RESIGN] cannot resign player=%d: fn not resolved "
                  @"(unityBase=0x%lx)",
                  (int)playerSide, (unsigned long)g_unityBase]);
        return;
    }
    IPALog([NSString stringWithFormat:
              @"[RESIGN] queueing MatchController.SurrenderAsync(player=%d)",
              (int)playerSide]);
    dispatch_async(dispatch_get_main_queue(), ^{
        // Read MatchController fresh — orch pointer may change between matches.
        void *orch = g_gameOrchestratorCache;
        if (!orch) {
            IPALog(@"[RESIGN] orch nil on main thread — resign dropped");
            return;
        }
        void *matchCtrl = *(void **)((uint8_t *)orch + GAMEORCH_MATCHCONTROLLER_OFFSET);
        if (!matchCtrl) {
            IPALog(@"[RESIGN] _matchController nil — resign dropped");
            return;
        }
        IPALog([NSString stringWithFormat:
                  @"[RESIGN] invoking MatchController.SurrenderAsync "
                  @"(player=%d, matchCtrl=%p)",
                  (int)playerSide, matchCtrl]);
        @try {
            // UniTask は fire-and-forget で捨てる。
            (void)g_SurrenderAsync(matchCtrl, playerSide);
        } @catch (NSException *e) {
            IPALog([NSString stringWithFormat:
                      @"[RESIGN] threw: %@", e]);
        }
    });
}

void InjectNyugyokuDeclaration(int32_t playerSide) {
    IPALog([NSString stringWithFormat:
              @"[RESIGN] %%KACHI for player=%d — no KIOU API surfaced yet, "
              @"only the CSA session learns of the declaration",
              (int)playerSide]);
}
