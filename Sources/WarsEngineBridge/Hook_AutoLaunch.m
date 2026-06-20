#import "Internal.h"
#import "Settings_Persistence.h"
#import <stdatomic.h>

// ===========================================================================
// Hook_AutoLaunch — drive the app from the title screen straight into a match.
//
// Two hooks chain the launch flow:
//
//   1. OpeningController.Start (RVA 0x1555600)
//        Title screen finished loading. We auto-fire OnPracticeGame(self)
//        which transitions into the PracticeSetting scene.
//
//   2. PracticeSetting.Awake (RVA 0x1570074)
//        Difficulty-picker scene finished loading. We auto-fire
//        OnClickStart(self) which submits the chosen settings and kicks off
//        the actual PRACTICESHOGI match.
//
// Each step fires once per app launch (gated by an atomic flag) so the user
// can still navigate around once the auto-launch chain has run. The whole
// thing is gated by the Auto Launch toggle in Settings_Persistence; turn it
// off and the title screen behaves normally.
// ===========================================================================

#define RVA_OPENING_START          0x1555600
#define RVA_OPENING_ON_PRACTICE    0x1553B08
#define RVA_PRACTICE_AWAKE         0x1570074
#define RVA_PRACTICE_ON_CLICK_START 0x156FDC0

typedef void (*OpeningStart_t)(void *self);
typedef void (*OpeningOnPractice_t)(void *self);
typedef void (*PracticeAwake_t)(void *self);
typedef void (*PracticeOnClickStart_t)(void *self);

static OpeningStart_t          orig_OpeningStart        = NULL;
static OpeningOnPractice_t     g_OnPracticeGame         = NULL;
static PracticeAwake_t         orig_PracticeAwake       = NULL;
static PracticeOnClickStart_t  g_PracticeOnClickStart   = NULL;

// One-shot gates so each auto-fire only happens once per app launch.
// Both reset implicitly because the tweak dylib is re-injected on install.
static _Atomic bool g_autoLaunchDone        = false;
static _Atomic bool g_autoPracticeStartDone = false;

void HookOpeningStart(void *self) {
    IPALog([NSString stringWithFormat:@"[AUTOLAUNCH] OpeningController.Start self=%p", self]);
    WARS_CALL_ORIG_VOID(orig_OpeningStart, self);

    if (!WEBAutoLaunchEnabled()) return;
    if (atomic_exchange(&g_autoLaunchDone, true)) return;
    if (!g_OnPracticeGame || !self) return;

    void *capturedSelf = self;
    OpeningOnPractice_t fn = g_OnPracticeGame;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            fn(capturedSelf);
            IPALog([NSString stringWithFormat:
                      @"[AUTOLAUNCH] OnPracticeGame called on %p", capturedSelf]);
        } @catch (NSException *e) {
            IPALog([NSString stringWithFormat:
                      @"[AUTOLAUNCH] OnPracticeGame threw: %@", e]);
        }
    });
}

void HookPracticeAwake(void *self) {
    IPALog([NSString stringWithFormat:@"[AUTOLAUNCH] PracticeSetting.Awake self=%p", self]);
    WARS_CALL_ORIG_VOID(orig_PracticeAwake, self);

    // Fire if either auto-launch (first run) or auto-rematch (subsequent
    // entries) wants the next match to start without manual intervention.
    bool wantsStart = WEBAutoLaunchEnabled() || WEBAutoRematchEnabled();
    if (!wantsStart) return;
    // We allow auto-rematch to refire even after the first auto-launch.
    if (WEBAutoLaunchEnabled() && !atomic_load(&g_autoLaunchDone)) {
        // OpeningController.Start hasn't fired yet — bail. The opening flow
        // will reach us through its own dispatch eventually.
    }
    if (atomic_exchange(&g_autoPracticeStartDone, true)) {
        // Only fire once per Awake — reset on each Awake call by clearing
        // after a short delay so a fresh Awake (next match) can fire again.
    }
    if (!g_PracticeOnClickStart || !self) return;

    void *capturedSelf = self;
    PracticeOnClickStart_t fn = g_PracticeOnClickStart;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            fn(capturedSelf);
            IPALog([NSString stringWithFormat:
                      @"[AUTOLAUNCH] PracticeSetting.OnClickStart called on %p",
                      capturedSelf]);
        } @catch (NSException *e) {
            IPALog([NSString stringWithFormat:
                      @"[AUTOLAUNCH] OnClickStart threw: %@", e]);
        }
        // Allow re-fire on the next Awake (e.g. auto-rematch).
        atomic_store(&g_autoPracticeStartDone, false);
    });
}

void InstallAutoLaunchHook(uintptr_t unityBase) {
    g_OnPracticeGame       = (OpeningOnPractice_t)(void *)(unityBase + RVA_OPENING_ON_PRACTICE);
    g_PracticeOnClickStart = (PracticeOnClickStart_t)(void *)(unityBase + RVA_PRACTICE_ON_CLICK_START);
    IPALog([NSString stringWithFormat:
              @"[AUTOLAUNCH] OnPracticeGame=%p OnClickStart=%p",
              g_OnPracticeGame, g_PracticeOnClickStart]);

    struct {
        const char *tag;
        uintptr_t rva;
        void *hook;
        void **origSlot;
    } entries[] = {
        { "OpeningController.Start",
          RVA_OPENING_START, (void *)HookOpeningStart,
          (void **)&orig_OpeningStart },
        { "PracticeSetting.Awake",
          RVA_PRACTICE_AWAKE, (void *)HookPracticeAwake,
          (void **)&orig_PracticeAwake },
    };
    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        uintptr_t addr = unityBase + entries[i].rva;
        MSHookFunction((void *)addr, entries[i].hook, entries[i].origSlot);
        IPALog([NSString stringWithFormat:
                  @"[AUTOLAUNCH] hooked %s @0x%lx (base+0x%lx)",
                  entries[i].tag,
                  (unsigned long)addr,
                  (unsigned long)entries[i].rva]);
    }
}
