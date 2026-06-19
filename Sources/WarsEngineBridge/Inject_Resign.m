#import "Internal.h"

// ===========================================================================
// Inject_Resign — trigger the resign dialog when the engine sends %TORYO.
//
// ShowResignAlertDialog() is a static method on the dialog helper class
// (RVA 0x154B72C). It posts the in-game "are you sure?" resign confirmation
// dialog on the local player's side. Calling it directly is equivalent to the
// user tapping the resign button — the dialog then drives
// GameController.ToryoFinish() on confirmation.
//
// We do NOT call ToryoFinish() directly because that would skip the
// confirmation step and potentially produce an invalid server-side state
// if the game has already ended on the engine side.
// ===========================================================================

// RVA: 0x154B72C  prologue: f657bda9 (STP X22,X21,[SP,#-0x30]!)
#define RVA_SHOW_RESIGN_ALERT_DIALOG 0x154B72C

void InstallResignHook(uintptr_t unityBase) {
    g_ShowResignAlertDialog =
        (ShowResignAlertDialog_t)(void *)(unityBase + RVA_SHOW_RESIGN_ALERT_DIALOG);
    IPALog([NSString stringWithFormat:
              @"[RESIGN] resolved ShowResignAlertDialog @0x%lx (base+0x%x)",
              (unsigned long)(unityBase + RVA_SHOW_RESIGN_ALERT_DIALOG),
              (unsigned)RVA_SHOW_RESIGN_ALERT_DIALOG]);
}

void InjectResign(void) {
    ShowResignAlertDialog_t fn = g_ShowResignAlertDialog;
    if (!fn) {
        IPALog(@"[RESIGN] ShowResignAlertDialog not resolved yet");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            fn();
            IPALog(@"[RESIGN] ShowResignAlertDialog called");
        } @catch (NSException *e) {
            IPALog([NSString stringWithFormat:
                      @"[RESIGN] ShowResignAlertDialog threw: %@", e]);
        }
    });
}
