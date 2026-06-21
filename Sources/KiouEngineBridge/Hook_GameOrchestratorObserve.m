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

// BackToTitleSequence.RunAsync(CancellationToken) — STATIC method.
// dump.cs:1479425. Unlike GameOrchestrator.NavigateToTitleSceneAsync(),
// this does not require an active GameOrchestrator instance — it works from
// title/home screens where no match has started yet. Pass NULL ct (= default
// CancellationToken).
#define RVA_BACK_TO_TITLE_RUN_ASYNC 0x5CF712C

// BackToTitleSequence.<RunAsync>d__0.MoveNext — observe state transitions to
// figure out which side-effect runs the actual scene transition (so we can
// skip the confirm dialog by invoking that step directly).
#define RVA_BACK_TO_TITLE_MOVENEXT  0x5CF71D8

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

typedef UniTaskRet (*BackToTitleRunAsync_t)(void *ct);

// Trampoline pointer set by InstallBackToTitleSuppressHook — points to the
// real BackToTitleSequence.RunAsync bypassing the suppress hook. Declared
// extern here so KEBNavigateToTitleScene can use it for intentional
// back-to-title calls (account switch, etc.) without hitting the suppress.
// On the JB build InstallBackToTitleSuppressHook must be called before any
// call to KEBNavigateToTitleScene for this to be non-NULL.
extern BackToTitleRunAsync_t orig_BackToTitleRunAsync;

// Public entry point — drive BackToTitleSequence.RunAsync. Works from any
// scene (title / home / match) because the sequence itself is static; no
// GameOrchestrator instance required.
//
// Uses orig_BackToTitleRunAsync (the trampoline set by
// InstallBackToTitleSuppressHook) so that intentional calls bypass the
// suppress hook and reach the real RunAsync. Falls back to the raw RVA on
// chinlan (where no suppress hook is installed) and on JB before the
// suppress hook has fired (which shouldn't happen in practice).
void KEBNavigateToTitleScene(void) {
    // Prefer the trampoline set by InstallBackToTitleSuppressHook (bypasses
    // the suppress hook if installed). Fall back to resolving the RVA directly
    // when the suppress hook is not installed (e.g. while it's disabled).
    BackToTitleRunAsync_t fn = orig_BackToTitleRunAsync;
    if (!fn && g_unityBase) {
        fn = (BackToTitleRunAsync_t)(g_unityBase + RVA_BACK_TO_TITLE_RUN_ASYNC);
    }
    if (!fn) {
        IPALog(@"[ACCOUNT] KEBNavigateToTitleScene: unityBase not yet set");
        return;
    }
    @try {
        // CancellationToken is a 1-word value type whose internal source
        // pointer being null means "no cancellation". Passing NULL as the
        // first integer arg encodes default(CancellationToken).
        (void)fn(NULL);
        IPALog(@"[ACCOUNT] BackToTitleSequence.RunAsync invoked");
    } @catch (NSException *e) {
        IPALog([NSString stringWithFormat:
                  @"[ACCOUNT] BackToTitleSequence.RunAsync threw: %@", e]);
    }
}

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
    if (n <= 3 || (n % 30) == 0) {
        IPALog([NSString stringWithFormat:
                  @"[GAMEORCH] ActivateAsync call#%u self=%p setup=%p",
                  n, self, setup]);
    }
    if (orig_GameOrch_ActivateAsync) {
        return orig_GameOrch_ActivateAsync(self, setup, assetLoader, ct);
    }
    return (UniTaskRet){ NULL, NULL };
}

// ---------------------------------------------------------------------------
// Observation hook for BackToTitleSequence.<RunAsync>d__0.MoveNext.
// Logs every state transition so we can map out:
//   state 0  → "should we go?" confirm dialog awaited
//   state 1  → after dialog (post-bool-result branch)
//   state -2 → completed
// Reading awaiter<bool> at +0x20 lets us also see what the user picked.
// ---------------------------------------------------------------------------
typedef void (*MoveNextVoid_t)(void *self);
static MoveNextVoid_t orig_BackToTitleMoveNext = NULL;

void HookBackToTitleMoveNext(void *self) {
    int32_t before = self ? readI32(self, 0x00) : -999;
    // Awaiter<bool>.task.result lives at +0x20 inside the state machine.
    // Read it as both i8 and i32 so we can tell what the awaiter resolved to.
    uint8_t boolByte = self ? readU8(self, 0x20) : 0xFF;
    IPALog([NSString stringWithFormat:
              @"[BACK2TITLE] MoveNext IN  state=%d boolByte=0x%02x self=%p",
              (int)before, boolByte, self]);
    if (orig_BackToTitleMoveNext) orig_BackToTitleMoveNext(self);
    int32_t after = self ? readI32(self, 0x00) : -999;
    if (after != before) {
        IPALog([NSString stringWithFormat:
                  @"[BACK2TITLE] MoveNext OUT state=%d (was %d)",
                  (int)after, (int)before]);
    }
}

// ---------------------------------------------------------------------------
// Installer. Called once from Tweak.m::installUnityHooks().
// ---------------------------------------------------------------------------
#if !KIOU_CHINLAN
void InstallGameOrchestratorObserveHook(uintptr_t unityBase) {
    uintptr_t addr = unityBase + RVA_GAMEORCH_ACTIVATE;
    MSHookFunction((void *)addr, (void *)HookGameOrchActivateAsync,
                   (void **)&orig_GameOrch_ActivateAsync);

    uintptr_t mvAddr = unityBase + RVA_BACK_TO_TITLE_MOVENEXT;
    MSHookFunction((void *)mvAddr, (void *)HookBackToTitleMoveNext,
                   (void **)&orig_BackToTitleMoveNext);
    IPALog([NSString stringWithFormat:
              @"[BACK2TITLE] hooked d__0.MoveNext @0x%lx", (unsigned long)mvAddr]);
    IPALog([NSString stringWithFormat:
              @"[GAMEORCH] hooked GameOrchestrator.ActivateAsync @0x%lx "
              @"(base+0x%lx)",
              (unsigned long)addr, (unsigned long)RVA_GAMEORCH_ACTIVATE]);
}
#endif  // !KIOU_CHINLAN
// On the chinlan build, the static cave routes GameOrchestrator.ActivateAsync
// through the SLOT-published dispatcher (see recipes/kiouenginebridge.py
// CAVE_PATCHES entry KIOU_BR_HOOK_GAMEORCH_ACTIVATE). The dispatcher will
// invoke HookGameOrchActivateAsync once Phase E wires it up.
