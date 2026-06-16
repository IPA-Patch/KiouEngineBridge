#import "Internal.h"

// ===========================================================================
// Inject_Resign — bridge CSA's %TORYO / %KACHI submissions back to KIOU.
//
// CSA fires %TORYO when the connected engine resigns — meaning the local
// KIOU side wins the match. KIOU's own surrender entry point is
// GameOrchestrator.RequestSurrender (RVA 0x594A91C, void method, no args)
// which kicks off the same end-of-match flow the in-game "投了" button
// triggers.
//
// Because the CSA engine is "the other player" we can't selectively resign
// the engine's seat — RequestSurrender always surrenders the LOCAL player.
// That's fine for the most common case (CPU vs engine), but in OnlinePvP
// with the user as black and an engine ghosting on the server side it
// would surrender the wrong seat. Until the CSA path is exercised against
// every match mode we accept that limitation; CSA's engine resignation in
// VsAI maps cleanly to "the user wins by the engine's resignation," which
// is what RequestSurrender produces if the user is the loser (it then ends
// up with the right outcome from CSA's perspective because we swap WIN /
// LOSE before sending the result block).
//
// Nyugyoku declaration (%KACHI) has no first-class KIOU API in dump.cs
// today; we log the request and let the CSA session terminate normally
// without driving KIOU. Task 7's follow-up will revisit this once the
// declaration surface is reverse-engineered.
// ===========================================================================

#define RVA_GAME_ORCHESTRATOR_REQUEST_SURRENDER  0x594A91C

typedef void (*GameOrchestratorRequestSurrender_t)(void *self);
static GameOrchestratorRequestSurrender_t g_RequestSurrender = NULL;

static void resolve_request_surrender(void) {
    if (g_RequestSurrender) return;
    if (g_unityBase == 0) return;
    g_RequestSurrender = (GameOrchestratorRequestSurrender_t)
        (void *)(g_unityBase + RVA_GAME_ORCHESTRATOR_REQUEST_SURRENDER);
}

void InjectResign(int32_t playerSide) {
    resolve_request_surrender();
    void *orch = g_gameOrchestratorCache;
    if (!orch || !g_RequestSurrender) {
        file_log([NSString stringWithFormat:
                  @"[RESIGN] cannot resign player=%d: orch=%p fn=%p",
                  (int)playerSide, orch, g_RequestSurrender]);
        return;
    }
    file_log([NSString stringWithFormat:
              @"[RESIGN] invoking GameOrchestrator.RequestSurrender "
              @"(player=%d, orch=%p)",
              (int)playerSide, orch]);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            g_RequestSurrender(orch);
        } @catch (NSException *e) {
            file_log([NSString stringWithFormat:
                      @"[RESIGN] threw: %@", e]);
        }
    });
}

void InjectNyugyokuDeclaration(int32_t playerSide) {
    file_log([NSString stringWithFormat:
              @"[RESIGN] %%KACHI for player=%d — no KIOU API surfaced yet, "
              @"only the CSA session learns of the declaration",
              (int)playerSide]);
}
