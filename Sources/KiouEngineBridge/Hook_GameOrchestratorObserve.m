#import "Internal.h"

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
static uint32_t g_orchSeen = 0;

UniTaskRet HookGameOrchActivateAsync(void *self, void *setup,
                                       void *assetLoader, void *ct) {
    if (g_gameOrchestratorCache != self) g_gameOrchestratorCache = self;
    uint32_t n = ++g_orchSeen;
    // Match the seen-counter cadence used by the OPM hooks: log the first
    // three, then every 30th. Activation only happens at scene transitions
    // so we'll almost never spam, but the cap is cheap insurance.
    if (n <= 3 || (n % 30) == 0) {
        file_log([NSString stringWithFormat:
                  @"[GAMEORCH] ActivateAsync call#%u self=%p setup=%p",
                  n, self, setup]);
    }
    if (orig_GameOrch_ActivateAsync) {
        return orig_GameOrch_ActivateAsync(self, setup, assetLoader, ct);
    }
    return (UniTaskRet){ NULL, NULL };
}

// ---------------------------------------------------------------------------
// Installer. Called once from Tweak.m::installUnityHooks().
// ---------------------------------------------------------------------------
#if !KIOU_BINPATCH
void InstallGameOrchestratorObserveHook(uintptr_t unityBase) {
    uintptr_t addr = unityBase + RVA_GAMEORCH_ACTIVATE;
    MSHookFunction((void *)addr, (void *)HookGameOrchActivateAsync,
                   (void **)&orig_GameOrch_ActivateAsync);
    file_log([NSString stringWithFormat:
              @"[GAMEORCH] hooked GameOrchestrator.ActivateAsync @0x%lx "
              @"(base+0x%lx)",
              (unsigned long)addr, (unsigned long)RVA_GAMEORCH_ACTIVATE]);
}
#endif  // !KIOU_BINPATCH
// On the binpatch build, the static cave routes GameOrchestrator.ActivateAsync
// through the SLOT-published dispatcher (see recipes/kiouenginebridge.py
// CAVE_PATCHES entry KIOU_BR_HOOK_GAMEORCH_ACTIVATE). The dispatcher will
// invoke HookGameOrchActivateAsync once Phase E wires it up.
