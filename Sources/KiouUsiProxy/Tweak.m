#import "Internal.h"
#import <mach-o/dyld.h>
#import <string.h>

// ===========================================================================
// KiouUsiProxy — entry point.
//
// Stub for now: locate UnityFramework, log its base address, but do not
// install any hooks yet. The Frida-driven exploration phase has to land
// concrete RVAs for the BoardPresenter / MoveCommit code paths first; once
// those are confirmed, this file will gain install_*() calls in the same
// shape as KiouEditor/Tweak.m.
//
// Goal at this revision: ship a dylib that loads cleanly into KIOU,
// initializes the shared logging sink at /var/tmp/kiou_usi_proxy.log, and
// verifies it can coexist in-process with KiouEditor.
// ===========================================================================

static BOOL g_unityHooked = NO;

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

    file_log([NSString stringWithFormat:
              @"UnityFramework base=0x%lx (%s)",
              (unsigned long)unityBase, unityName ? unityName : "?"]);

    // No installers yet — Frida exploration is pending. The stub still
    // marks itself done so the retry loop stops once Unity is visible.

    g_unityHooked = YES;
    file_log(@"=== KiouUsiProxy: Unity located, no hooks installed yet ===");
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
    logging_init("com.neconome.shogi.kiouusiproxy", "/var/tmp/kiou_usi_proxy.log");
    file_log(@"=== KiouUsiProxy loaded ===");
    file_log([NSString stringWithFormat:@"build commit=%s", KIOU_USI_PROXY_COMMIT]);

    // UnityFramework is almost certainly not mapped yet at constructor time.
    installUnityHooks();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        retryInstallHooks();
    });

    file_log(@"=== KiouUsiProxy constructor done ===");
}
