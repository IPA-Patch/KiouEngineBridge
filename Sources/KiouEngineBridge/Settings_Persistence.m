#import "Settings_Persistence.h"
#import "logging.h"

// ===========================================================================
// Settings_Persistence.m — NSUserDefaults backing for KiouEngineBridge
// settings.
//
// Key naming: "kiou_bridge.<group>.<name>"
// All writes call -synchronize so values survive an immediate app kill.
// ===========================================================================

// ---------------------------------------------------------------------------
// Key constants
// ---------------------------------------------------------------------------
static NSString * const kKeyAutoRematch       = @"kiou_bridge.auto_rematch";
static NSString * const kKeyRematchStep1      = @"kiou_bridge.rematch_step1_sec";
static NSString * const kKeyRematchStep2      = @"kiou_bridge.rematch_step2_sec";
static NSString * const kKeyAutoStartKind     = @"kiou_bridge.auto_start_kind";
static NSString * const kKeyCsaPort           = @"kiou_bridge.csa_port";
static NSString * const kKeyEvalOverlay       = @"kiou_bridge.eval_overlay";

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
    [d synchronize];
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
    [d synchronize];
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
    [d synchronize];
    IPALog([NSString stringWithFormat:@"[SETTINGS] rematch_step2=%.1fs", clamped]);
}

// ---------------------------------------------------------------------------
// Auto-start kind
// ---------------------------------------------------------------------------

KEBAutoStartKind KEBAutoStartKind_(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyAutoStartKind];
    if (!v) return KEBAutoStartKind_None;
    int32_t val = [v intValue];
    if (val < KEBAutoStartKind_None || val > KEBAutoStartKind_RankBullet) {
        return KEBAutoStartKind_None;
    }
    return (KEBAutoStartKind)val;
}

void KEBSetAutoStartKind(KEBAutoStartKind kind) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:(NSInteger)kind forKey:kKeyAutoStartKind];
    [d synchronize];
    IPALog([NSString stringWithFormat:@"[SETTINGS] auto_start_kind=%d", (int)kind]);
}

bool KEBAutoStartEnabled(void) {
    return KEBAutoStartKind_() != KEBAutoStartKind_None;
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
    [d synchronize];
    IPALog([NSString stringWithFormat:@"[SETTINGS] csa_port=%u "
              @"(effective on next launch)", (unsigned)clamped]);
}

// ---------------------------------------------------------------------------
// Eval overlay
// ---------------------------------------------------------------------------

bool KEBEvalOverlayEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyEvalOverlay];
    return v ? [v boolValue] : false;
}

void KEBSetEvalOverlayEnabled(bool enabled) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:enabled forKey:kKeyEvalOverlay];
    [d synchronize];
    IPALog([NSString stringWithFormat:@"[SETTINGS] eval_overlay=%s",
              enabled ? "true" : "false"]);
}
