#import "Settings_Persistence.h"
#import "logging.h"

// ===========================================================================
// Settings_Persistence.m — NSUserDefaults backing for WarsEngineBridge.
//
// Key naming: "wars_bridge.<name>". Writes do not call -synchronize (the
// system flushes on app-quit / background).
// ===========================================================================

static NSString * const kKeyAutoRematch       = @"wars_bridge.auto_rematch";
static NSString * const kKeySkipRevengeDialog = @"wars_bridge.skip_revenge_dialog";
static NSString * const kKeySkipResignDialog  = @"wars_bridge.skip_resign_dialog";

// ---------------------------------------------------------------------------
// Auto-rematch
// ---------------------------------------------------------------------------

bool WEBAutoRematchEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyAutoRematch];
    return v ? [v boolValue] : false;
}

void WEBSetAutoRematchEnabled(bool enabled) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:enabled forKey:kKeyAutoRematch];
    IPALog([NSString stringWithFormat:@"[SETTINGS] auto_rematch=%s",
              enabled ? "true" : "false"]);
}

// ---------------------------------------------------------------------------
// Skip "play again?" dialog
// ---------------------------------------------------------------------------

bool WEBSkipRevengeDialog(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeySkipRevengeDialog];
    return v ? [v boolValue] : true;
}

void WEBSetSkipRevengeDialog(bool skip) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:skip forKey:kKeySkipRevengeDialog];
    IPALog([NSString stringWithFormat:@"[SETTINGS] skip_revenge_dialog=%s",
              skip ? "true" : "false"]);
}

bool WEBSkipResignDialog(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeySkipResignDialog];
    return v ? [v boolValue] : false;
}

void WEBSetSkipResignDialog(bool skip) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:skip forKey:kKeySkipResignDialog];
    IPALog([NSString stringWithFormat:@"[SETTINGS] skip_resign_dialog=%s",
              skip ? "true" : "false"]);
}
