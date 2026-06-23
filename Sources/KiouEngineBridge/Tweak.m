#import "Internal.h"
#import "Settings_Persistence.h"
#import <mach-o/dyld.h>
#import <dlfcn.h>
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

static void installUnityHooks(uintptr_t unityBase, const char *unityName);

// dyld add-image callback. Fires for every Mach-O image already loaded at
// registration time, then for every subsequent dlopen. We watch for
// UnityFramework and install our hooks the first time it appears.
static void kebOnImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)slide;
    if (g_unityHooked) return;
    Dl_info info;
    if (dladdr(mh, &info) == 0 || !info.dli_fname) return;
    if (!strstr(info.dli_fname, "UnityFramework")) return;
    installUnityHooks((uintptr_t)mh, info.dli_fname);
}

static void installUnityHooks(uintptr_t unityBase, const char *unityName) {
    if (g_unityHooked) return;
    if (unityBase == 0) return;

    g_unityBase = unityBase;

    IPALog([NSString stringWithFormat:
              @"UnityFramework base=0x%lx (%s)",
              (unsigned long)unityBase, unityName ? unityName : "?"]);

#if KIOU_CHINLAN
    // On the chinlan build, every observation hook is wired by the static
    // cave at app launch (recipes/kiouenginebridge.py); all we need at
    // runtime is to publish the dispatcher pointer into the __DATA,__bss
    // SLOT so the cave's ADRP+LDR resolves to a real function pointer.
    // Inject_Move is still a symbol-only resolver (no MSHookFunction) so it
    // runs in both flavours. USI engine init must come after Inject_Move so
    // inject_apply is wired before the WS handler can reach it.
    KEBBridgeChinlanPublish();
    InstallLowLevelObserveHook(unityBase);  // symbol pointer resolves only
    // No-op on chinlan (see Hook_MatchModeObserve.m's chinlan installer).
    // orig_*OnPlayerMoveAsync is intentionally left NULL so the route picker
    // falls through to KIOU_BR_CHINLAN_ORIG_OR_BYPASS, which returns the
    // per-site cave-bypass entry (cave + KIOU_BR_CAVE_BYPASS_OFFSET). The
    // inject path then calls that bypass entry — calling orig_* directly
    // would re-enter the dispatcher cave because unityBase+RVA is the
    // patched `B <cave>` instruction.
    InstallMatchModeObserveHook(unityBase);
    InstallInjectHook(unityBase);
    // Account observation — on chinlan this only wires the cave-side
    // AccountExists observer + resolves il2cpp_string_new. The Login /
    // Register / TDAnalytics post-orig observers stay JB-only.
    InstallAccountObserveHook(unityBase);
    // Matching filter (Accept Seat / Fixed Rate Range). On chinlan the
    // hook sites are cave-patched in via recipes/kiouenginebridge.py; this
    // installer is what points g_ArgsCreate at the cave-bypass entry so
    // sendAction() can build IShogiMatchStreamArgs without re-entering the
    // entry hook.
    InstallMatchingFilterObserveHook(unityBase);
    // gRPC header helpers — on chinlan this resolves g_HttpHeadersTryAdd /
    // g_HttpHeadersRemove / g_GrpcStringNew so HookHttpMsgInvokerSendAsyncEntry
    // can swap the x-user-id header on account-switch logins.
    InstallGrpcLoggingHook(unityBase);
    // CSA engine driver. Must come AFTER InstallInjectHook so inject_apply
    // is fully wired before the CSA recv queue can dispatch into it.
    CsaEngineInstall();
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
    // TODO: Suppress the daily 04:00 JST date-change back-to-title forced
    // transition. Suppressing BackToTitleSequence.RunAsync directly is too
    // broad — it also kills user-initiated back-to-title. Need to identify
    // the midnight-specific caller RVA from device logs first.
    // InstallBackToTitleSuppressHook(unityBase);
    // Capture the GameOrchestrator instance the moment GameScene calls
    // ActivateAsync. The match-end auto-rematch path needs this `self` to
    // invoke OnEndSequenceCompleted on it.
    InstallGameOrchestratorObserveHook(unityBase);
    // Capture GameStateStore.Set*PlayerInfo so Meta_Emitter can emit
    // match_start with the matchmaking-resolved opponent identity on
    // Online matches (MatchConfig alone holds placeholders there).
    InstallGameStateStoreObserveHook(unityBase);
    // Account identity observation (LoginArgs / LoginReply / RegisterReply /
    // AccountExists / TDAnalytics). Must come before CsaEngineInstall so
    // account state is live before any engine session starts.
    InstallAccountObserveHook(unityBase);
    // Matching filter — Accept Seat (sente / gote only) and Fixed Rate
    // Range cap. Settings UI toggles these off by default; the hooks no-op
    // until the user opts in from the right-edge swipe panel.
    InstallMatchingFilterObserveHook(unityBase);
    // gRPC HTTP/2 transport logging — logs every outbound URL + HTTP status.
    InstallGrpcLoggingHook(unityBase);
    // CSA engine driver. Must come AFTER InstallInjectHook so inject_apply
    // is fully wired before the CSA recv queue can dispatch into it.
    CsaEngineInstall();
#endif

    g_unityHooked = YES;
    IPALog(@"=== KiouEngineBridge: all hooks installed ===");
}


__attribute__((constructor)) static void init(void) {
    IPALoggingInit("com.neconome.shogi.kiouenginebridge");
    IPALog(@"=== KiouEngineBridge loaded ===");

    // Build identity so a stray log file can be matched back to the exact
    // dylib that wrote it. Flavor distinguishes JB (libsubstrate) / jailed
    // (Dobby-static) / chinlan (static cave + SLOT dispatcher).
#if KIOU_CHINLAN
    static const char *const kBuildFlavor = "chinlan";
#elif IPA_JAILED
    static const char *const kBuildFlavor = "jailed";
#else
    static const char *const kBuildFlavor = "jb";
#endif
    IPALog([NSString stringWithFormat:
              @"build commit=%s flavor=%s built=%s %s",
              BUILD_COMMIT, kBuildFlavor,
              __DATE__, __TIME__]);

    // CSA migration Task 3: bind the CSA TCP server as early as possible.
    // Port is read from NSUserDefaults — dispatch to the main queue so
    // cfprefs / sandbox are fully initialised before the first read.
    // The 0.5s head-start is well before any engine could connect anyway.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        uint16_t csaPort = KEBCsaPort();
        IPALog([NSString stringWithFormat:@"[SETTINGS] CSA server port=%u",
                  (unsigned)csaPort]);
        KEBCsaServerStart(csaPort);
    });

    // Settings panel (right-edge swipe). Dispatches to main queue internally
    // and retries until the key window is available — safe to call here.
    KEBSettingsInstall();

    // Wire UnityFramework hooks the moment UnityFramework is mapped.
    // _dyld_register_func_for_add_image fires synchronously for every image
    // already loaded at registration time, then for every subsequent dlopen
    // — so this works whether UnityFramework is mapped when our constructor
    // runs or it gets dlopened later.
    _dyld_register_func_for_add_image(&kebOnImageAdded);

    IPALog(@"=== KiouEngineBridge constructor done ===");
}
