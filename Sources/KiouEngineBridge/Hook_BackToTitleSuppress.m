#import "Internal.h"

// ===========================================================================
// Hook_BackToTitleSuppress — suppress the midnight date-change back-to-title
// forced transition.
//
// What this kills:
//   At 04:00 JST (daily reset), KIOU calls
//   BackToTitleSequence.RunAsync(CancellationToken) which shows a dialog
//   then navigates back to the title scene, interrupting any ongoing session.
//
//   We hook RunAsync and return immediately with a completed UniTask so the
//   caller's await resolves instantly with no side effects — the game never
//   shows the dialog or performs the scene transition.
//
// Note: KEBNavigateToTitleScene() uses g_BackToTitleRunAsync (resolved lazily
//   in Hook_GameOrchestratorObserve.m) which writes through to the same RVA.
//   To preserve that intentional call path after MSHookFunction installs a
//   trampoline here, KEBNavigateToTitleScene keeps calling orig_ (the
//   trampoline) and therefore still works correctly.
//
// Why this lives in its own file:
//   The daily-reset suppression is a presentation-layer bypass (no match-mode
//   awareness needed); isolating it keeps Hook_GameOrchestratorObserve.m
//   focused on instance caching and avoids tangling two distinct concerns.
// ===========================================================================

// BackToTitleSequence.RunAsync(CancellationToken) — static method.
// dump.cs:1479425  RVA: 0x5CF712C
// Signature (AAPCS64): void *ct → x0; returns UniTaskRet in {x0, x1}.
#define RVA_BACK_TO_TITLE_RUN_ASYNC  0x5CF712C

typedef UniTaskRet (*BackToTitleRunAsync_t)(void *ct);
// Exported so KEBNavigateToTitleScene (Hook_GameOrchestratorObserve.m) can
// bypass the suppress hook and call the real RunAsync directly when making an
// intentional back-to-title (e.g. account switch).
BackToTitleRunAsync_t orig_BackToTitleRunAsync = NULL;

static uint32_t g_suppressCount = 0;

static UniTaskRet HookBackToTitleRunAsync(void *ct) {
    uint32_t n = ++g_suppressCount;
    IPALog([NSString stringWithFormat:
              @"[BACK2TITLE] RunAsync suppressed (call#%u ct=%p) — "
              @"daily-reset back-to-title blocked", n, ct]);
    // Return a zero-valued UniTask struct.  The awaiter in the caller
    // (BackToTitleSequence.<RunAsync>d__0.MoveNext, state 0) reads
    // the result as UniTask.CompletedTask — it transitions to state -2
    // (completed) immediately without showing the confirm dialog or
    // navigating to the title scene.
    (void)orig_BackToTitleRunAsync;
    return (UniTaskRet){ NULL, NULL };
}

#if !KIOU_CHINLAN
void InstallBackToTitleSuppressHook(uintptr_t unityBase) {
    uintptr_t addr = unityBase + RVA_BACK_TO_TITLE_RUN_ASYNC;
    MSHookFunction((void *)addr,
                   (void *)HookBackToTitleRunAsync,
                   (void **)&orig_BackToTitleRunAsync);
    IPALog([NSString stringWithFormat:
              @"[BACK2TITLE] hooked BackToTitleSequence.RunAsync @0x%lx "
              @"(base+0x%x) — daily-reset forced back-to-title now suppressed",
              (unsigned long)addr,
              (unsigned)RVA_BACK_TO_TITLE_RUN_ASYNC]);
}
#endif  // !KIOU_CHINLAN
