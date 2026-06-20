#import "Internal.h"
#import "Settings_Persistence.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>

// Flag set by Hook_GameController when ShowResignAlertDialog is entered.
// The swizzle below checks this on the next presentation and auto-runs the
// OK action when skip_resign_dialog is on. Cleared after consumed.
_Atomic bool g_webNextAlertIsResign = false;

// ===========================================================================
// Hook_AlertObserve.m — observe every UIAlertController presented by the app.
//
// We can't easily predict which il2cpp method funnels into the "Continue?"
// dialog because ShogiWars uses many dialog wrappers (ShowAlertDialog,
// ShowSelectDialog, ShowSubmitDialog, OpenDialog, etc.). Hooking at the
// UIKit layer guarantees we see every alert that actually reaches the user.
//
// Strategy: swizzle UIViewController -presentViewController:animated:
// completion:. When the presented VC is a UIAlertController, log title /
// message / all action titles. The original implementation is always
// invoked so behaviour is unchanged.
// ===========================================================================

static IMP g_originalPresentIMP = NULL;

// EndingEvent.RevengeStartProcess (RVA 0x158135C) is the il2cpp method that
// triggers the "Continue?" rematch dialog after match end. The next method
// in the class is RevengeVisibleProcess at 0x15815F0, so any frame whose
// UnityFramework offset falls in [0x158135C, 0x15815F0) is inside it.
#define WEB_REVENGE_START_RVA_LO 0x158135C
#define WEB_REVENGE_START_RVA_HI 0x15815F0

// Returns true if any frame in the current stack is inside the
// RevengeStartProcess range above. Sufficient to identify the "Continue?"
// dialog without depending on its localized title or message.
static BOOL stackIsRevengeFlow(NSArray<NSString *> *symbols) {
    for (NSString *frame in symbols) {
        // Frame format example:
        //   "2   UnityFramework   0x000... UnityFramework + 22327708"
        NSRange r = [frame rangeOfString:@"UnityFramework + "];
        if (r.location == NSNotFound) continue;
        NSString *tail = [frame substringFromIndex:r.location + r.length];
        long long offset = [tail longLongValue];
        if (offset >= WEB_REVENGE_START_RVA_LO &&
            offset <  WEB_REVENGE_START_RVA_HI) {
            return YES;
        }
    }
    return NO;
}

static void web_present_swizzled(id self, SEL _cmd,
                                  UIViewController *vc,
                                  BOOL animated,
                                  void (^completion)(void)) {
    BOOL suppress = NO;
    BOOL autoConfirmResign = NO;
    UIAlertAction *resignOKAction = nil;
    @try {
        if ([vc isKindOfClass:[UIAlertController class]]) {
            UIAlertController *alert = (UIAlertController *)vc;
            NSMutableArray<NSString *> *actionTitles =
                [NSMutableArray arrayWithCapacity:alert.actions.count];
            for (UIAlertAction *a in alert.actions) {
                [actionTitles addObject:a.title ?: @"(nil)"];
            }

            // Resign flow: ShowResignAlertDialog sets g_webNextAlertIsResign
            // just before presenting. Consume it here.
            bool resignFlag = atomic_exchange(&g_webNextAlertIsResign, false);
            BOOL skipResign = WEBSkipResignDialog();

            // Revenge flow: detected by stack signature (RevengeStartProcess).
            NSArray<NSString *> *symbols = [NSThread callStackSymbols];
            BOOL inRevengeFlow = stackIsRevengeFlow(symbols);
            BOOL skipRevenge = WEBSkipRevengeDialog();

            if (resignFlag && skipResign) {
                // Find the non-cancel action — that's "OK"/"Confirm".
                for (UIAlertAction *a in alert.actions) {
                    if (a.style != UIAlertActionStyleCancel) {
                        resignOKAction = a;
                        break;
                    }
                }
                if (resignOKAction) {
                    autoConfirmResign = YES;
                    suppress = YES;
                }
            } else if (inRevengeFlow && skipRevenge) {
                suppress = YES;
            }

            IPALog([NSString stringWithFormat:
                      @"[ALERT] title=\"%@\" msg=\"%@\" style=%ld actions=[%@] "
                      @"resign=%d revenge=%d suppress=%d autoConfirm=%d",
                      alert.title ?: @"(nil)",
                      alert.message ?: @"(nil)",
                      (long)alert.preferredStyle,
                      [actionTitles componentsJoinedByString:@", "],
                      (int)resignFlag, (int)inRevengeFlow,
                      (int)suppress, (int)autoConfirmResign]);
        }
    } @catch (NSException *e) {
        IPALog([NSString stringWithFormat:@"[ALERT] swizzle threw: %@", e]);
    }

    if (suppress) {
        if (autoConfirmResign && resignOKAction) {
            // Pull the private handler block and invoke it directly.
            @try {
                id handler = [resignOKAction valueForKey:@"handler"];
                if (handler) {
                    void (^block)(UIAlertAction *) = handler;
                    block(resignOKAction);
                    IPALog(@"[ALERT] resign OK handler invoked");
                } else {
                    IPALog(@"[ALERT] resign OK action has no handler");
                }
            } @catch (NSException *e) {
                IPALog([NSString stringWithFormat:
                          @"[ALERT] resign handler invoke threw: %@", e]);
            }
        }
        if (completion) completion();
        return;
    }

    ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))g_originalPresentIMP)
        (self, _cmd, vc, animated, completion);
}

void InstallAlertObserveHook(void) {
    Class cls = [UIViewController class];
    SEL sel = @selector(presentViewController:animated:completion:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        IPALog(@"[ALERT] swizzle target method not found");
        return;
    }
    g_originalPresentIMP = method_setImplementation(m, (IMP)web_present_swizzled);
    IPALog(@"[ALERT] swizzled UIViewController -presentViewController:animated:completion:");
}
