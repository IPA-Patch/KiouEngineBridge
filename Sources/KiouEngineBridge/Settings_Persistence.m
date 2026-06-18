#import "Settings_Persistence.h"
#import "logging.h"

// ===========================================================================
// Settings_Persistence.m — NSUserDefaults backing for KiouEngineBridge
// settings.
//
// Key naming: "kiou_bridge.<name>" (flat namespace under the kiou_bridge.
// prefix). Writes do NOT call -synchronize: the method has been deprecated
// for years and is not guaranteed to flush to disk, and the system performs
// its own flush at app-quit / background-transition which is more than
// enough for tweak-side preferences.
// ===========================================================================

// ---------------------------------------------------------------------------
// Key constants
// ---------------------------------------------------------------------------
static NSString * const kKeyAutoRematch       = @"kiou_bridge.auto_rematch";
static NSString * const kKeyRematchStep1      = @"kiou_bridge.rematch_step1_sec";
static NSString * const kKeyRematchStep2      = @"kiou_bridge.rematch_step2_sec";
static NSString * const kKeyCsaPort           = @"kiou_bridge.csa_port";

// ---------------------------------------------------------------------------
// Auto-rematch
// ---------------------------------------------------------------------------

bool KEBAutoRematchEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyAutoRematch];
    return v ? [v boolValue] : true;
}

void KEBSetAutoRematchEnabled(bool enabled) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:enabled forKey:kKeyAutoRematch];
    IPALog([NSString stringWithFormat:@"[SETTINGS] auto_rematch=%s",
              enabled ? "true" : "false"]);
}

float KEBRematchStep1Sec(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyRematchStep1];
    if (!v) return 3.5f;
    float val = [v floatValue];
    return (val < 0.0f) ? 0.0f : (val > 30.0f) ? 30.0f : val;
}

void KEBSetRematchStep1Sec(float sec) {
    float clamped = (sec < 0.0f) ? 0.0f : (sec > 30.0f) ? 30.0f : sec;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setFloat:clamped forKey:kKeyRematchStep1];
    IPALog([NSString stringWithFormat:@"[SETTINGS] rematch_step1=%.1fs", clamped]);
}

float KEBRematchStep2Sec(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyRematchStep2];
    if (!v) return 2.0f;
    float val = [v floatValue];
    return (val < 0.0f) ? 0.0f : (val > 30.0f) ? 30.0f : val;
}

void KEBSetRematchStep2Sec(float sec) {
    float clamped = (sec < 0.0f) ? 0.0f : (sec > 30.0f) ? 30.0f : sec;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setFloat:clamped forKey:kKeyRematchStep2];
    IPALog([NSString stringWithFormat:@"[SETTINGS] rematch_step2=%.1fs", clamped]);
}

// ---------------------------------------------------------------------------
// Resign
// ---------------------------------------------------------------------------

static NSString * const kKeyResignSkipDialog = @"kiou_bridge.resign_skip_dialog";

bool KEBResignSkipDialog(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyResignSkipDialog];
    return v ? [v boolValue] : true;
}

void KEBSetResignSkipDialog(bool skip) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:skip forKey:kKeyResignSkipDialog];
    IPALog([NSString stringWithFormat:@"[SETTINGS] resign_skip_dialog=%s",
              skip ? "true" : "false"]);
}

// ---------------------------------------------------------------------------
// CSA server port
// ---------------------------------------------------------------------------

uint16_t KEBCsaPort(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyCsaPort];
    if (!v) return 4081;
    int32_t val = [v intValue];
    if (val < 1024 || val > 65535) return 4081;
    return (uint16_t)val;
}

void KEBSetCsaPort(uint16_t port) {
    uint16_t clamped = (port < 1024) ? 1024 : port;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:clamped forKey:kKeyCsaPort];
    IPALog([NSString stringWithFormat:@"[SETTINGS] csa_port=%u "
              @"(effective on next launch)", (unsigned)clamped]);
}

