#import "Internal.h"
#import "Settings_Persistence.h"
#import <UIKit/UIKit.h>

// ===========================================================================
// Settings_UI.m — WarsEngineBridge in-process settings panel.
//
// Mirrors KiouEngineBridge's Settings_UI.m layout but pared down to the
// two toggles WarsEngineBridge exposes today:
//
//   Match
//     Auto Rematch
//     Skip Revenge Dialog
//   About
//     GitHub repo URL
//     Author X URL
//
// Entry point is a right-edge screen swipe (UIScreenEdgePanGestureRecognizer)
// installed by WEBSettingsInstall(), called from Tweak.m once UnityFramework
// has loaded.
// ===========================================================================

#define WEB_SECTION_MATCH 0
#define WEB_SECTION_ABOUT 1
#define WEB_SECTION_COUNT 2

#define WEB_ROW_AUTO_REMATCH     0
#define WEB_ROW_SKIP_DIALOG      1
#define WEB_ROW_SKIP_RESIGN      2
#define WEB_MATCH_ROW_COUNT      3

#define WEB_ROW_ABOUT_REPO   0
#define WEB_ROW_ABOUT_AUTHOR 1
#define WEB_ABOUT_ROW_COUNT  2

static NSString *const kAboutRepoURL   = @"https://github.com/IPA-Patch/WarsEngineBridge";
static NSString *const kAboutAuthorURL = @"https://x.com/tkgling";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static UIWindow *webKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

static UIViewController *webTopmostViewController(void) {
    UIViewController *vc = webKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// ---------------------------------------------------------------------------
// WEBSettingsViewController
// ---------------------------------------------------------------------------

@interface WEBSettingsViewController : UITableViewController
@end

@implementation WEBSettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.title = @"WarsEngineBridge";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(onDone:)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)onDone:(id)sender {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

// ---------------------------------------------------------------------------
// UITableViewDataSource
// ---------------------------------------------------------------------------

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return WEB_SECTION_COUNT;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case WEB_SECTION_MATCH: return WEB_MATCH_ROW_COUNT;
        case WEB_SECTION_ABOUT: return WEB_ABOUT_ROW_COUNT;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case WEB_SECTION_MATCH: return @"Match";
        case WEB_SECTION_ABOUT: return @"About";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == WEB_SECTION_ABOUT) {
        return [NSString stringWithFormat:@"%s (%s)",
                WARS_ENGINE_BRIDGE_VERSION, WARS_ENGINE_BRIDGE_COMMIT];
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch (ip.section) {

        case WEB_SECTION_MATCH: {
            if (ip.row == WEB_ROW_AUTO_REMATCH) {
                return [self toggleCellWithTitle:@"Auto Rematch"
                                            key:@"auto_rematch"
                                          value:WEBAutoRematchEnabled()
                                         action:@selector(autoRematchChanged:)];
            }
            if (ip.row == WEB_ROW_SKIP_DIALOG) {
                return [self toggleCellWithTitle:@"Skip Revenge Dialog"
                                            key:@"skip_revenge_dialog"
                                          value:WEBSkipRevengeDialog()
                                         action:@selector(skipDialogChanged:)];
            }
            if (ip.row == WEB_ROW_SKIP_RESIGN) {
                return [self toggleCellWithTitle:@"Skip Resign Dialog"
                                            key:@"skip_resign_dialog"
                                          value:WEBSkipResignDialog()
                                         action:@selector(skipResignChanged:)];
            }
            break;
        }

        case WEB_SECTION_ABOUT: {
            static NSString *kId = @"about";
            UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:kId];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                              reuseIdentifier:kId];
                cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            }
            if (ip.row == WEB_ROW_ABOUT_REPO) {
                cell.textLabel.text       = @"GitHub";
                cell.detailTextLabel.text = kAboutRepoURL;
            } else {
                cell.textLabel.text       = @"Author (X)";
                cell.detailTextLabel.text = kAboutAuthorURL;
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }

        default: break;
    }
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                  reuseIdentifier:@"empty"];
}

// ---------------------------------------------------------------------------
// UITableViewDelegate
// ---------------------------------------------------------------------------

- (NSIndexPath *)tableView:(UITableView *)tv
  willSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == WEB_SECTION_ABOUT) return ip;
    return nil;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == WEB_SECTION_ABOUT) {
        NSString *str = (ip.row == WEB_ROW_ABOUT_REPO) ? kAboutRepoURL : kAboutAuthorURL;
        NSURL *url = [NSURL URLWithString:str];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
}

// ---------------------------------------------------------------------------
// Cell builder
// ---------------------------------------------------------------------------

- (UITableViewCell *)toggleCellWithTitle:(NSString *)title
                                     key:(NSString *)key
                                   value:(bool)value
                                  action:(SEL)action {
    NSString *reuseId = [@"toggle_" stringByAppendingString:key];
    UITableViewCell *cell =
        [self.tableView dequeueReusableCellWithIdentifier:reuseId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:reuseId];
        UISwitch *sw = [[UISwitch alloc] init];
        [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = title;
    ((UISwitch *)cell.accessoryView).on = value;
    return cell;
}

// ---------------------------------------------------------------------------
// Toggle actions
// ---------------------------------------------------------------------------

- (void)autoRematchChanged:(UISwitch *)sw {
    WEBSetAutoRematchEnabled(sw.on);
}

- (void)skipDialogChanged:(UISwitch *)sw {
    WEBSetSkipRevengeDialog(sw.on);
}

- (void)skipResignChanged:(UISwitch *)sw {
    WEBSetSkipResignDialog(sw.on);
}

@end

// ---------------------------------------------------------------------------
// WEBPresentSettings — presenter bridge.
// ---------------------------------------------------------------------------

void WEBPresentSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = webTopmostViewController();
        if (!top) {
            IPALog(@"[SETTINGS] no topmost vc — cannot present");
            return;
        }
        if ([top isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)top;
            if ([nav.viewControllers.firstObject isKindOfClass:
                 [WEBSettingsViewController class]]) {
                IPALog(@"[SETTINGS] already presented — skipping");
                return;
            }
        }
        WEBSettingsViewController *settings =
            [[WEBSettingsViewController alloc] init];
        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:settings];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [top presentViewController:nav animated:YES completion:^{
            IPALog(@"[SETTINGS] modal presented");
        }];
    });
}

// ---------------------------------------------------------------------------
// Gesture handler + installer
// ---------------------------------------------------------------------------

@interface WEBGestureHandler : NSObject
@end

@implementation WEBGestureHandler
- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    IPALog(@"[SETTINGS] right-edge swipe detected — presenting settings");
    WEBPresentSettings();
}
@end

void WEBSettingsInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = webKeyWindow();
        if (!win) {
            IPALog(@"[SETTINGS] key window not ready — will retry in 1s");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WEBSettingsInstall();
            });
            return;
        }

        for (UIGestureRecognizer *gr in win.gestureRecognizers) {
            if (![gr isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) continue;
            UIScreenEdgePanGestureRecognizer *epgr =
                (UIScreenEdgePanGestureRecognizer *)gr;
            if (epgr.edges == UIRectEdgeRight) {
                IPALog(@"[SETTINGS] gesture already installed — skipping");
                return;
            }
        }

        static WEBGestureHandler *sHandler = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sHandler = [[WEBGestureHandler alloc] init]; });

        UIScreenEdgePanGestureRecognizer *gr =
            [[UIScreenEdgePanGestureRecognizer alloc]
                initWithTarget:sHandler
                        action:@selector(handleEdgePan:)];
        gr.edges = UIRectEdgeRight;
        [win addGestureRecognizer:gr];
        IPALog(@"[SETTINGS] right-edge gesture installed on key window");
    });
}
