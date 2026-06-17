#import "Internal.h"

// ===========================================================================
// Hook_AfkSuppress — silence the "tap the screen within 15s" warning popup.
//
// What this kills:
//   KIOU's GameOrchestrator runs an AFK watchdog. AfkSettings exposes two
//   knobs:
//     DefaultWarningSeconds       = 60   (sec of inactivity → warning popup)
//     DefaultForceSurrenderSeconds = 15  (sec from warning → auto-resign)
//
//   Methods on GameOrchestrator (KIOU 1.0.1 build 11):
//     IsAfkEnabled                      RVA 0x59455D4
//     IsAfkTimeCountable                RVA 0x594BBF0
//     UpdateAfk(float dt)               RVA 0x5945480
//     ShowAfkWarningAndWaitForTapAsync  RVA 0x594BC9C
//     ForceSurrenderByAfkAsync          RVA 0x594BD58
//
//   The cleanest no-op is to pin IsAfkEnabled to false. UpdateAfk reads
//   this every frame and bails before touching _afkElapsedSeconds, so:
//     - the warning popup never spawns
//     - the auto-resign timer never starts
//     - no other AFK state is mutated
//
//   Side note: when the user explicitly DOES tap, that path still runs
//   normally — we only short-circuit the watchdog. Real player input
//   doesn't go through IsAfkEnabled.
//
// Why this lives in its own file:
//   Hook_MatchModeObserve is about IMatchMode lifecycle; Hook_OnlineObserve
//   is about server snapshots. The AFK watchdog is a presentation-layer
//   concern (GameOrchestrator is a MonoBehaviour, not a match mode), and
//   it's a single-method hook, so a one-file module keeps the rest of the
//   tweak's surface clean.
// ===========================================================================

#define RVA_GAMEORCH_IS_AFK_ENABLED  0x59455D4

typedef bool (*IsAfkEnabled_t)(void *self);
static IsAfkEnabled_t orig_IsAfkEnabled = NULL;

// Counter so we can confirm in the log that the hook is alive without
// spamming every frame. The first three calls are logged, then every
// 600th (= ~ once every 10 seconds at 60 fps).
static uint32_t g_afkCheckCount = 0;

static bool HookIsAfkEnabled(void *self) {
    uint32_t n = ++g_afkCheckCount;
    if (n <= 3 || (n % 600) == 0) {
        IPALog([NSString stringWithFormat:
                  @"[AFK] IsAfkEnabled call#%u self=%p -> returning false "
                  @"(watchdog suppressed)", n, self]);
    }
    // Don't even consult the original — we don't care what KIOU would have
    // decided. We just want the timer to stay at zero forever.
    (void)orig_IsAfkEnabled;
    (void)self;
    return false;
}

#if !KIOU_BINPATCH
void InstallAfkSuppressHook(uintptr_t unityBase) {
    uintptr_t addr = unityBase + RVA_GAMEORCH_IS_AFK_ENABLED;
    MSHookFunction((void *)addr,
                   (void *)HookIsAfkEnabled,
                   (void **)&orig_IsAfkEnabled);
    IPALog([NSString stringWithFormat:
              @"[AFK] hooked GameOrchestrator.IsAfkEnabled @0x%lx "
              @"(base+0x%x) — AFK watchdog now permanently disabled",
              (unsigned long)addr,
              (unsigned)RVA_GAMEORCH_IS_AFK_ENABLED]);
}
#endif  // !KIOU_BINPATCH
// On the binpatch build, IsAfkEnabled is replaced wholesale by a
// `MOVZ W0, #0; RET` inline patch in recipes/kiouenginebridge.py (PATCHES),
// so InstallAfkSuppressHook is intentionally omitted here.
