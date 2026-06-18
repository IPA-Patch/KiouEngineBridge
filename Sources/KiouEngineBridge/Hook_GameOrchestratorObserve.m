#import "Internal.h"
#import "Settings_Persistence.h"

// ===========================================================================
// Hook_GameOrchestratorObserve — capture the live GameOrchestrator instance.
//
// Why this exists:
//   The match-end auto-rematch path needs to call
//     GameOrchestrator.OnEndSequenceCompleted()  (RVA 0x594AE5C)
//   to close the result overlay and trigger the exit flow back to the
//   previous scene. But OnEndSequenceCompleted is a private instance
//   method — we need a live `GameOrchestrator*` self pointer to invoke
//   it. The only public entry point that hands us one is ActivateAsync,
//   which GameScene calls exactly once per match-scene activation.
//
//   We hook ActivateAsync, stash `self` into g_gameOrchestratorCache,
//   then chain straight through to the original. No behavior change.
//
//   GameOrchestrator outlives the match — it's a MonoBehaviour rooted by
//   GameScene, and the in-scene il2cpp object stays alive across an
//   entire match including OnMatchEndAsync. So the cached pointer is
//   safe to use from the dispatch_after blocks in Hook_MatchModeObserve's
//   END_HOOK paths.
//
// What this file deliberately doesn't do:
//   - Reach into GameOrchestrator's fields. The match-end path only
//     needs the receiver — the resolved config (GameSetup → GameParams)
//     is read on demand from the END_HOOK side, not here.
//   - Hook EnterAsync as a backup. ActivateAsync fires first, and if it
//     somehow doesn't, the dispatch_after block notices the NULL cache
//     and just logs + skips the rematch kick rather than crashing.
// ===========================================================================

// ---------------------------------------------------------------------------
// RVA (KIOU 1.0.1 build 11).
//   ActivateAsync(GameSetup setup, IAssetLoader assetLoader, CT ct)
//     -> UniTask
// dump.cs:1211443
// ---------------------------------------------------------------------------
#define RVA_GAMEORCH_ACTIVATE 0x5944E84

// ---------------------------------------------------------------------------
// Cache definition — declaration lives in Internal.h so other modules
// (Hook_MatchModeObserve.m) can read it. `volatile` because writers run on
// whatever thread Unity calls ActivateAsync from (main thread in practice)
// and readers run inside dispatch_after blocks on the main queue —
// pointer reads/writes are atomic on arm64 so no mutex needed.
// ---------------------------------------------------------------------------
void *volatile g_gameOrchestratorCache = NULL;

// ---------------------------------------------------------------------------
// Original (untrampolined) function pointer. UniTask return shape mirrors
// the OPM hooks in Hook_MatchModeObserve.m — must be a {r0, r1} pair so
// the trampoline doesn't corrupt the caller's await frame.
// ---------------------------------------------------------------------------
typedef UniTaskRet (*GameOrch_ActivateAsync_t)(void *self, void *setup,
                                               void *assetLoader, void *ct);
static GameOrch_ActivateAsync_t orig_GameOrch_ActivateAsync = NULL;

// ---------------------------------------------------------------------------
// Hook body. Stash self, log the first call, then chain through. We don't
// gate on g_gameOrchestratorCache being NULL — overwriting it on every
// activation handles the case where the user backs out to title and
// re-enters the match scene (a fresh GameOrchestrator MonoBehaviour is
// created each time, the old one is destroyed; pointer reuse is fine
// either way since Boehm GC is non-moving).
// ---------------------------------------------------------------------------
// RVAs reused from Hook_MatchModeObserve.m's rematch path.
#define RVA_AUTO_CPU_MATCH_START  0x5D02FE8
#define RVA_AUTO_RANK_MATCH_START 0x5D0478C

typedef UniTaskRet (*AutoStart_CpuFreeMatch_t)(int32_t strength,
                                               bool beginnerSupport, void *ct);
typedef UniTaskRet (*AutoStart_RankMatching_t)(int32_t ruleType,
                                               bool beginnerSupport, void *ct);

// CPUStrengthType: Easy=2, Normal=3, Hard=4
static int32_t cpuStrengthForKind(KEBAutoStartKind kind) {
    switch (kind) {
        case KEBAutoStartKind_CpuEasy:   return 2;
        case KEBAutoStartKind_CpuHard:   return 4;
        default:                         return 3; // Normal
    }
}

// RankMatchRuleType: Beginner=2, VIP=3, Fischer=4, Bullet3Min=5
static int32_t rankRuleForKind(KEBAutoStartKind kind) {
    switch (kind) {
        case KEBAutoStartKind_RankBeginner: return 2;
        case KEBAutoStartKind_RankVip:      return 3;
        case KEBAutoStartKind_RankFischer:  return 4;
        default:                            return 5; // Bullet
    }
}

static BOOL g_autoStartFired = NO;
static uint32_t g_orchSeen = 0;

UniTaskRet HookGameOrchActivateAsync(void *self, void *setup,
                                       void *assetLoader, void *ct) {
    if (g_gameOrchestratorCache != self) g_gameOrchestratorCache = self;
    uint32_t n = ++g_orchSeen;
    if (n <= 3 || (n % 30) == 0) {
        IPALog([NSString stringWithFormat:
                  @"[GAMEORCH] ActivateAsync call#%u self=%p setup=%p",
                  n, self, setup]);
    }
    UniTaskRet ret = (UniTaskRet){ NULL, NULL };
    if (orig_GameOrch_ActivateAsync) {
        ret = orig_GameOrch_ActivateAsync(self, setup, assetLoader, ct);
    }

    // Auto-start: fire once on the very first ActivateAsync (= app launch
    // reaching the match scene). Subsequent activations are rematch cycles
    // which already handle their own restart via scheduleAutoRematch().
    if (!g_autoStartFired && KEBAutoStartEnabled()) {
        g_autoStartFired = YES;
        KEBAutoStartKind kind = KEBAutoStartKind_();
        uintptr_t base = g_unityBase;
        IPALog([NSString stringWithFormat:
                  @"[GAMEORCH] auto-start kind=%d — scheduling in 1.0s", (int)kind]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (base == 0) {
                IPALog(@"[GAMEORCH] auto-start: no unityBase — skipped");
                return;
            }
            BOOL isCpu = (kind <= KEBAutoStartKind_CpuHard);
            if (isCpu) {
                int32_t strength = cpuStrengthForKind(kind);
                AutoStart_CpuFreeMatch_t fn = (AutoStart_CpuFreeMatch_t)(void *)
                    (base + RVA_AUTO_CPU_MATCH_START);
                @try {
                    (void)fn(strength, false, NULL);
                    IPALog([NSString stringWithFormat:
                              @"[GAMEORCH] auto-start: StartCpuFreeMatchAsync "
                              @"strength=%d", (int)strength]);
                } @catch (NSException *e) {
                    IPALog([NSString stringWithFormat:
                              @"[GAMEORCH] auto-start (cpu) threw: %@", e]);
                }
            } else {
                int32_t rule = rankRuleForKind(kind);
                AutoStart_RankMatching_t fn = (AutoStart_RankMatching_t)(void *)
                    (base + RVA_AUTO_RANK_MATCH_START);
                @try {
                    (void)fn(rule, false, NULL);
                    IPALog([NSString stringWithFormat:
                              @"[GAMEORCH] auto-start: StartRankMatchingAsync "
                              @"rule=%d", (int)rule]);
                } @catch (NSException *e) {
                    IPALog([NSString stringWithFormat:
                              @"[GAMEORCH] auto-start (rank) threw: %@", e]);
                }
            }
        });
    }
    return ret;
}

// ---------------------------------------------------------------------------
// Installer. Called once from Tweak.m::installUnityHooks().
// ---------------------------------------------------------------------------
#if !KIOU_BINPATCH
void InstallGameOrchestratorObserveHook(uintptr_t unityBase) {
    uintptr_t addr = unityBase + RVA_GAMEORCH_ACTIVATE;
    MSHookFunction((void *)addr, (void *)HookGameOrchActivateAsync,
                   (void **)&orig_GameOrch_ActivateAsync);
    IPALog([NSString stringWithFormat:
              @"[GAMEORCH] hooked GameOrchestrator.ActivateAsync @0x%lx "
              @"(base+0x%lx)",
              (unsigned long)addr, (unsigned long)RVA_GAMEORCH_ACTIVATE]);
}
#endif  // !KIOU_BINPATCH
// On the binpatch build, the static cave routes GameOrchestrator.ActivateAsync
// through the SLOT-published dispatcher (see recipes/kiouenginebridge.py
// CAVE_PATCHES entry KIOU_BR_HOOK_GAMEORCH_ACTIVATE). The dispatcher will
// invoke HookGameOrchActivateAsync once Phase E wires it up.
