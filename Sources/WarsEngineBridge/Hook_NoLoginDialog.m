#import "Internal.h"

// ===========================================================================
// Hook_NoLoginDialog — bypass the "Login or Registration" startup wall.
//
// What this kills:
//   ShogiWars opens a WebView-backed "Login or Registration" prompt the
//   moment the title scene boots when the device has no saved credentials.
//   The dialog stalls the entire UI behind a modal — the CSA client can't
//   even connect to the live board because GameController never reaches
//   OnGameStart.
//
//   Four hooks combine to suppress the prompt and convince downstream
//   ShogiWars code that the player is authenticated:
//
//     1. Global.IsLogin                    RVA 0x1528C64   → return true
//     2. OpeningController.ShowDialog      RVA 0x1556238   → no-op
//     3. WebViewController.ShowSetupNotLogin RVA 0x15CCE6C → no-op
//     4. WebViewController.ShowLogin       RVA 0x15CA13C   → no-op
//
//   `Global.IsLogin()` is the central authentication predicate used across
//   the app to gate menu items, server requests, and the title-scene popup
//   pipeline (`OpeningController.ShowDialog` reads it before deciding which
//   sub-dialog to fire). Forcing it to true short-circuits the gate at the
//   source.
//
//   The two `WebViewController.Show*` entry points are belt-and-suspenders
//   for paths that bypass `IsLogin` and call the WebView directly (e.g. via
//   a JS bridge invocation from the title scene HTML). Both are public
//   static voids — no-ops are safe.
//
//   `OpeningController.ShowDialog` is kept neutralised so the per-scene
//   bootstrap pipeline (banner / quiz / pass status) doesn't accidentally
//   reach a sub-popup we haven't accounted for.
//
// Why a single-file module:
//   Mirrors KEB's Hook_AfkSuppress.m — small set of single-purpose hooks
//   with no shared state, no other tweak module needs to see them.
// ===========================================================================

// ---------------------------------------------------------------------------
// RVAs (ShogiWars 11.0.1).
// ---------------------------------------------------------------------------
#define RVA_GLOBAL_IS_LOGIN               0x1528C64
#define RVA_OPENING_SHOW_DIALOG           0x1556238
#define RVA_OPENING_IS_SHOW_TUTORIAL      0x15566F8
#define RVA_OPENING_OPEN_TUTORIAL         0x1556830
#define RVA_WEBVIEW_SHOW_SETUP_NOT_LOGIN  0x15CCE6C
#define RVA_WEBVIEW_SHOW_LOGIN            0x15CA13C

// ---------------------------------------------------------------------------
// Signatures.
// ---------------------------------------------------------------------------
typedef bool (*GlobalIsLogin_t)(void);
typedef void (*OpeningShowDialog_t)(void *self);
typedef bool (*OpeningIsShowTutorial_t)(void *self);
typedef void (*OpeningOpenTutorial_t)(void *self);
typedef void (*WebViewShowVoid_t)(void);

static GlobalIsLogin_t          orig_GlobalIsLogin            = NULL;
static OpeningShowDialog_t      orig_OpeningShowDialog        = NULL;
static OpeningIsShowTutorial_t  orig_OpeningIsShowTutorial    = NULL;
static OpeningOpenTutorial_t    orig_OpeningOpenTutorial      = NULL;
static WebViewShowVoid_t        orig_WebViewShowSetupNotLogin = NULL;
static WebViewShowVoid_t        orig_WebViewShowLogin         = NULL;

// Log-rate counters — first few calls and every Nth after that.
static uint32_t g_isLoginCount            = 0;
static uint32_t g_openingShowDialogCount  = 0;
static uint32_t g_isShowTutorialCount     = 0;
static uint32_t g_openTutorialCount       = 0;
static uint32_t g_showSetupNotLoginCount  = 0;
static uint32_t g_showLoginCount          = 0;

static inline BOOL shouldLogFreq(uint32_t n) {
    return n <= 3 || (n % 60) == 0;
}

// ---------------------------------------------------------------------------
// Hook bodies.
// ---------------------------------------------------------------------------

static bool HookGlobalIsLogin(void) {
    uint32_t n = ++g_isLoginCount;
    if (shouldLogFreq(n)) {
        IPALog([NSString stringWithFormat:
                  @"[NO-LOGIN] Global.IsLogin call#%u -> returning true "
                  @"(forced auth)", n]);
    }
    (void)orig_GlobalIsLogin;
    return true;
}

static void HookOpeningShowDialog(void *self) {
    uint32_t n = ++g_openingShowDialogCount;
    IPALog([NSString stringWithFormat:
              @"[NO-LOGIN] OpeningController.ShowDialog call#%u self=%p — "
              @"suppressed", n, self]);
    (void)orig_OpeningShowDialog;
    (void)self;
}

static bool HookOpeningIsShowTutorial(void *self) {
    uint32_t n = ++g_isShowTutorialCount;
    IPALog([NSString stringWithFormat:
              @"[NO-LOGIN] OpeningController.IsShowTutorial call#%u "
              @"self=%p -> returning false", n, self]);
    (void)orig_OpeningIsShowTutorial;
    (void)self;
    return false;
}

static void HookOpeningOpenTutorial(void *self) {
    uint32_t n = ++g_openTutorialCount;
    IPALog([NSString stringWithFormat:
              @"[NO-LOGIN] OpeningController.OpenTutorial call#%u self=%p — "
              @"suppressed", n, self]);
    (void)orig_OpeningOpenTutorial;
    (void)self;
}

static void HookWebViewShowSetupNotLogin(void) {
    uint32_t n = ++g_showSetupNotLoginCount;
    IPALog([NSString stringWithFormat:
              @"[NO-LOGIN] WebViewController.ShowSetupNotLogin call#%u — "
              @"suppressed", n]);
    (void)orig_WebViewShowSetupNotLogin;
}

static void HookWebViewShowLogin(void) {
    uint32_t n = ++g_showLoginCount;
    IPALog([NSString stringWithFormat:
              @"[NO-LOGIN] WebViewController.ShowLogin call#%u — suppressed",
              n]);
    (void)orig_WebViewShowLogin;
}

// ---------------------------------------------------------------------------
// Installer.
// ---------------------------------------------------------------------------
#if !WARS_CHINLAN
void InstallNoLoginDialogHook(uintptr_t unityBase) {
    struct {
        const char *tag;
        uintptr_t   rva;
        void       *hook;
        void      **origSlot;
    } entries[] = {
        { "Global.IsLogin",
          RVA_GLOBAL_IS_LOGIN,               (void *)HookGlobalIsLogin,
          (void **)&orig_GlobalIsLogin },
        { "OpeningController.ShowDialog",
          RVA_OPENING_SHOW_DIALOG,           (void *)HookOpeningShowDialog,
          (void **)&orig_OpeningShowDialog },
        { "OpeningController.IsShowTutorial",
          RVA_OPENING_IS_SHOW_TUTORIAL,      (void *)HookOpeningIsShowTutorial,
          (void **)&orig_OpeningIsShowTutorial },
        { "OpeningController.OpenTutorial",
          RVA_OPENING_OPEN_TUTORIAL,         (void *)HookOpeningOpenTutorial,
          (void **)&orig_OpeningOpenTutorial },
        { "WebViewController.ShowSetupNotLogin",
          RVA_WEBVIEW_SHOW_SETUP_NOT_LOGIN,  (void *)HookWebViewShowSetupNotLogin,
          (void **)&orig_WebViewShowSetupNotLogin },
        { "WebViewController.ShowLogin",
          RVA_WEBVIEW_SHOW_LOGIN,            (void *)HookWebViewShowLogin,
          (void **)&orig_WebViewShowLogin },
    };
    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        uintptr_t addr = unityBase + entries[i].rva;
        MSHookFunction((void *)addr, entries[i].hook, entries[i].origSlot);
        IPALog([NSString stringWithFormat:
                  @"[NO-LOGIN] hooked %s @0x%lx (base+0x%lx)",
                  entries[i].tag,
                  (unsigned long)addr,
                  (unsigned long)entries[i].rva]);
    }
    IPALog(@"[NO-LOGIN] all login-prompt suppression hooks installed");
}
#else
void InstallNoLoginDialogHook(uintptr_t unityBase) {
    (void)unityBase;
    IPALog(@"[NO-LOGIN] chinlan: handled by inline patch in recipe");
}
#endif
