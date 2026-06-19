#import "Internal.h"
#import <mach-o/dyld.h>
#import <string.h>

// ===========================================================================
// WarsEngineBridge — entry point.
//
// Locates UnityFramework at load time, installs observation hooks into
// GameController (OnGameStart / OnMovesNormal / OnFinishGame / SendMove), and
// starts the CSA TCP server on port 4081. The CSA state machine in
// Csa_Engine.m then drives the connected engine through Game_Summary /
// per-move exchange / game-over.
//
// ShogiWars hook surface:
//   GameController.OnGameStart(GameStartJson)     — match start, board setup
//   GameController.OnMovesNormal(XmlDocument)     — opponent move received
//   GameController.OnFinishGame(FinishedGameInfo) — match end
//   GameController.SendMove(string, bool)         — local player played a move
//   ShowResignAlertDialog()                       — resign trigger
// ===========================================================================

static BOOL g_unityHooked = NO;

// UnityFramework base captured at install time. Exported via Internal.h so
// injection helpers can resolve RVA-pinned function pointers from dispatch
// blocks that don't carry the installer's unityBase argument on the stack.
uintptr_t g_unityBase = 0;

static void installUnityHooks(void) {
    if (g_unityHooked) return;

    uint32_t imgCount = _dyld_image_count();
    uintptr_t unityBase = 0;
    const char *unityName = NULL;
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "UnityFramework")) {
            unityBase = (uintptr_t)_dyld_get_image_header(i);
            unityName = name;
            break;
        }
    }

    if (unityBase == 0) {
        return;
    }

    g_unityBase = unityBase;

    IPALog([NSString stringWithFormat:
              @"UnityFramework base=0x%lx (%s)",
              (unsigned long)unityBase, unityName ? unityName : "?"]);

#if WARS_CHINLAN
    WEBBridgeChinlanPublish();
    InstallGameControllerHook(unityBase);
    InstallResignHook(unityBase);
    InstallNoLoginDialogHook(unityBase);
    CsaEngineInstall();
#else
    InstallGameControllerHook(unityBase);
    InstallResignHook(unityBase);
    InstallNoLoginDialogHook(unityBase);
    // CSA engine driver. Must come AFTER hook installers so the observation
    // callbacks are wired before the CSA recv queue can dispatch into them.
    CsaEngineInstall();
#endif

    g_unityHooked = YES;
    IPALog(@"=== WarsEngineBridge: all hooks installed ===");
}

static void retryInstallHooks(void) {
    if (!g_unityHooked) installUnityHooks();

    if (!g_unityHooked) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            retryInstallHooks();
        });
    }
}

__attribute__((constructor)) static void init(void) {
    IPALoggingInit("jp.co.heroz.warsenginebridge");
    IPALog(@"=== WarsEngineBridge loaded ===");

#if WARS_CHINLAN
    static const char *const kBuildFlavor = "chinlan";
#elif IPA_JAILED
    static const char *const kBuildFlavor = "jailed";
#else
    static const char *const kBuildFlavor = "jb";
#endif
    IPALog([NSString stringWithFormat:
              @"build commit=%s flavor=%s built=%s %s",
              WARS_ENGINE_BRIDGE_COMMIT, kBuildFlavor,
              __DATE__, __TIME__]);

    // Bind the CSA TCP server as early as possible.
    // Dispatch to the main queue so cfprefs / sandbox are fully initialised.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IPALog(@"[CSA] starting server on port 4081");
        WEBCsaServerStart(4081);
    });

    // UnityFramework is almost certainly not mapped yet at constructor time.
    installUnityHooks();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        retryInstallHooks();
    });

    IPALog(@"=== WarsEngineBridge constructor done ===");
}
