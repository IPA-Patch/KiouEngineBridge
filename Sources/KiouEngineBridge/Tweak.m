#import "Internal.h"
#import <mach-o/dyld.h>
#import <string.h>

// ===========================================================================
// KiouEngineBridge — entry point.
//
// Stub for now: locate UnityFramework, log its base address, but do not
// install any hooks yet. The Frida-driven exploration phase has to land
// concrete RVAs for the BoardPresenter / MoveCommit code paths first; once
// those are confirmed, this file will gain install_*() calls in the same
// shape as KiouEditor/Tweak.m.
//
// Goal at this revision: ship a dylib that loads cleanly into KIOU,
// initializes the shared logging sink at NSTemporaryDirectory()/
// kiouenginebridge.log (= <sandbox>/tmp/kiouenginebridge.log under rootless),
// and verifies it can coexist in-process with KiouEditor.
// ===========================================================================

static BOOL g_unityHooked = NO;

// UnityFramework base captured at install time. Exported via Internal.h so
// the match-end auto-rematch path can resolve static il2cpp methods (e.g.
// CpuMatchStarter.StartCpuFreeMatchAsync) inside a dispatch_after block
// that doesn't carry the installer's `unityBase` argument on its stack.
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
        // Not loaded yet - retry will call us again.
        return;
    }

    g_unityBase = unityBase;

    file_log([NSString stringWithFormat:
              @"UnityFramework base=0x%lx (%s)",
              (unsigned long)unityBase, unityName ? unityName : "?"]);

#if KIOU_BINPATCH
    // On the binpatch build, every observation hook is wired by the static
    // cave at app launch (recipes/kiouenginebridge.py); all we need at
    // runtime is to publish the dispatcher pointer into the __DATA,__bss
    // SLOT so the cave's ADRP+LDR resolves to a real function pointer.
    // Inject_Move is still a symbol-only resolver (no MSHookFunction) so it
    // runs in both flavours. USI engine init must come after Inject_Move so
    // inject_apply is wired before the WS handler can reach it.
    KebBridgeBinpatchPublish();
    InstallLowLevelObserveHook(unityBase);  // symbol pointer resolves only
    // No-op on binpatch (see Hook_MatchModeObserve.m's binpatch installer).
    // orig_*OnPlayerMoveAsync is intentionally left NULL so the route picker
    // falls through to KIOU_BR_BINPATCH_ORIG_OR_BYPASS, which returns the
    // per-site cave-bypass entry (cave + KIOU_BR_CAVE_BYPASS_OFFSET). The
    // inject path then calls that bypass entry — calling orig_* directly
    // would re-enter the dispatcher cave because unityBase+RVA is the
    // patched `B <cave>` instruction.
    InstallMatchModeObserveHook(unityBase);
    InstallInjectHook(unityBase);
    UsiEngineInstall();
#else
    InstallOnlineObserveHook(unityBase);
    InstallLowLevelObserveHook(unityBase);
    InstallMatchModeObserveHook(unityBase);
    // Inject_Move needs the observation hooks above already in place so it
    // can lean on their `orig_*` pointers and self caches.
    InstallInjectHook(unityBase);
    // Pin GameOrchestrator.IsAfkEnabled to false so the "tap within 15s"
    // popup never spawns during long engine thinking. Independent of all
    // other hooks; install order doesn't matter for it.
    InstallAfkSuppressHook(unityBase);
    // Capture the GameOrchestrator instance the moment GameScene calls
    // ActivateAsync. The match-end auto-rematch path needs this `self` to
    // invoke OnEndSequenceCompleted on it.
    InstallGameOrchestratorObserveHook(unityBase);
    // Capture GameStateStore.Set*PlayerInfo so Meta_Emitter can emit
    // match_start with the matchmaking-resolved opponent identity on
    // Online matches (MatchConfig alone holds placeholders there).
    InstallGameStateStoreObserveHook(unityBase);
    // Phase 2: USI engine driver. Must come AFTER InstallInjectHook so
    // inject_apply is fully wired before the WS handler can call into it.
    UsiEngineInstall();
#endif

    g_unityHooked = YES;
    file_log(@"=== KiouEngineBridge: all hooks installed ===");
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
    logging_init("com.neconome.shogi.kiouenginebridge");
    file_log(@"=== KiouEngineBridge loaded ===");
    // Build identity so a stray log file can be matched back to the exact
    // dylib that wrote it. Flavor distinguishes JB (libsubstrate) / jailed
    // (Dobby-static) / binpatch (static cave + SLOT dispatcher).
#if KIOU_BINPATCH
    static const char *const kBuildFlavor = "binpatch";
#elif IPA_JAILED
    static const char *const kBuildFlavor = "jailed";
#else
    static const char *const kBuildFlavor = "jb";
#endif
    file_log([NSString stringWithFormat:
              @"build commit=%s flavor=%s built=%s %s",
              KIOU_ENGINE_BRIDGE_COMMIT, kBuildFlavor,
              __DATE__, __TIME__]);

    // Bring the WebSocket sink up as early as possible. It binds 0.0.0.0:9527
    // and just sits there until a host connects — no host attached means
    // every KebWsServerPush() call below is a no-op.
    KebWsServerStart(9527);

    // UnityFramework is almost certainly not mapped yet at constructor time.
    installUnityHooks();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        retryInstallHooks();
    });

    file_log(@"=== KiouEngineBridge constructor done ===");
}
