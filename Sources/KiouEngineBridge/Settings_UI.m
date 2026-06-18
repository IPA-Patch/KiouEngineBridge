#import "Internal.h"
#import "Settings_Persistence.h"
#import <UIKit/UIKit.h>

// ===========================================================================
// Settings_UI.m — KiouEngineBridge in-process settings panel.
//
// Architecture mirrors KiouForge/Hook_SettingsUI.m:
//   Layer 1: NSUserDefaults getters/setters  →  Settings_Persistence.m
//   Layer 2: UITableViewController           →  KEBSettingsViewController
//   Layer 3: presenter bridge                →  KEBPresentSettings()
//   Layer 4: gesture entry point             →  KEBSettingsInstall()
//
// Section layout:
//   0  KEB_SECTION_MATCH   — auto-rematch, auto-start (drill-down), timings
//   1  KEB_SECTION_SERVER  — CSA port
//   2  KEB_SECTION_DISPLAY — eval overlay toggle
//   3  KEB_SECTION_ABOUT   — version / build info
// ===========================================================================

#define KEB_SECTION_MATCH   0
#define KEB_SECTION_DELAY   1
#define KEB_SECTION_SERVER  2
#define KEB_SECTION_ABOUT   3
#define KEB_SECTION_COUNT   4

#define KEB_ROW_AUTO_REMATCH 0
#define KEB_MATCH_ROW_COUNT  1

#define KEB_ROW_REMATCH_STEP1 0
#define KEB_ROW_REMATCH_STEP2 1
#define KEB_DELAY_ROW_COUNT   2

#define KEB_ROW_CSA_PORT      0
#define KEB_SERVER_ROW_COUNT  1

#define KEB_ROW_ABOUT_REPO    0
#define KEB_ROW_ABOUT_AUTHOR  1
#define KEB_ABOUT_ROW_COUNT   2

static NSString *const kAboutRepoURL   = @"https://github.com/IPA-Patch/KiouEngineBridge";
static NSString *const kAboutAuthorURL = @"https://x.com/tkgling";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static UIWindow *kebKeyWindow(void) {
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in scene.windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

static UIViewController *kebTopmostViewController(void) {
    UIViewController *vc = kebKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// ---------------------------------------------------------------------------
// KEBSettingsViewController
// ---------------------------------------------------------------------------

@interface KEBSettingsViewController : UITableViewController
@property (nonatomic, strong) UILabel *step1ValueLabel;
@property (nonatomic, strong) UILabel *step2ValueLabel;
@property (nonatomic, strong) UILabel *portValueLabel;
@end

@implementation KEBSettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.title = @"KiouEngineBridge";
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
    return KEB_SECTION_COUNT;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case KEB_SECTION_MATCH:  return KEB_MATCH_ROW_COUNT;
        case KEB_SECTION_DELAY:  return KEB_DELAY_ROW_COUNT;
        case KEB_SECTION_SERVER: return KEB_SERVER_ROW_COUNT;
        case KEB_SECTION_ABOUT:  return KEB_ABOUT_ROW_COUNT;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case KEB_SECTION_MATCH:  return @"Match";
        case KEB_SECTION_DELAY:  return @"Delay";
        case KEB_SECTION_SERVER: return @"CSA Server";
        case KEB_SECTION_ABOUT:  return @"About";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == KEB_SECTION_SERVER) {
        return @"Port change takes effect after restarting the app.";
    }
    if (section == KEB_SECTION_ABOUT) {
        return [NSString stringWithFormat:@"%s (%s)",
                KIOU_ENGINE_BRIDGE_VERSION, KIOU_ENGINE_BRIDGE_COMMIT];
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch (ip.section) {

        // -- Match ---------------------------------------------------------
        case KEB_SECTION_MATCH: {
            if (ip.row == KEB_ROW_AUTO_REMATCH) {
                return [self toggleCellWithTitle:@"Auto Rematch"
                                            key:@"auto_rematch"
                                          value:KEBAutoRematchEnabled()
                                         action:@selector(autoRematchChanged:)];
            }
            break;
        }

        // -- Delay ---------------------------------------------------------
        case KEB_SECTION_DELAY: {
            if (ip.row == KEB_ROW_REMATCH_STEP1) {
                UITableViewCell *cell =
                    [self stepperCellWithReuseId:@"step1"
                                          title:@"Close Result"
                                          value:KEBRematchStep1Sec()
                                           unit:@"s"
                                            min:0.0 max:30.0 step:0.5
                                         action:@selector(step1Changed:)];
                self.step1ValueLabel = cell.detailTextLabel;
                return cell;
            }
            if (ip.row == KEB_ROW_REMATCH_STEP2) {
                UITableViewCell *cell =
                    [self stepperCellWithReuseId:@"step2"
                                          title:@"Next Match"
                                          value:KEBRematchStep2Sec()
                                           unit:@"s"
                                            min:0.0 max:30.0 step:0.5
                                         action:@selector(step2Changed:)];
                self.step2ValueLabel = cell.detailTextLabel;
                return cell;
            }
            break;
        }

        // -- CSA Server ----------------------------------------------------
        case KEB_SECTION_SERVER: {
            if (ip.row == KEB_ROW_CSA_PORT) {
                UITableViewCell *cell =
                    [self stepperCellWithReuseId:@"port"
                                          title:@"Port"
                                          value:(double)KEBCsaPort()
                                           unit:nil
                                            min:1024.0 max:65535.0 step:1.0
                                         action:@selector(csaPortChanged:)];
                self.portValueLabel = cell.detailTextLabel;
                return cell;
            }
            break;
        }

        // -- About ---------------------------------------------------------
        case KEB_SECTION_ABOUT: {
            static NSString *kId = @"about";
            UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:kId];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                              reuseIdentifier:kId];
                cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            }
            if (ip.row == KEB_ROW_ABOUT_REPO) {
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
    if (ip.section == KEB_SECTION_ABOUT) return ip;
    return nil;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == KEB_SECTION_ABOUT) {
        NSString *str = (ip.row == KEB_ROW_ABOUT_REPO) ? kAboutRepoURL : kAboutAuthorURL;
        NSURL *url = [NSURL URLWithString:str];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
}

// ---------------------------------------------------------------------------
// Cell builders — mirrors KiouForge's UITableViewCellStyleValue1 pattern.
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

- (UITableViewCell *)stepperCellWithReuseId:(NSString *)reuseId
                                      title:(NSString *)title
                                      value:(double)value
                                       unit:(NSString *)unit
                                        min:(double)min
                                        max:(double)max
                                       step:(double)step
                                     action:(SEL)action {
    UITableViewCell *cell =
        [self.tableView dequeueReusableCellWithIdentifier:reuseId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:reuseId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        UIStepper *s = [[UIStepper alloc] init];
        s.continuous   = NO;
        s.minimumValue = min;
        s.maximumValue = max;
        s.stepValue    = step;
        [s addTarget:self action:action forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = s;
    }
    cell.textLabel.text = title;
    ((UIStepper *)cell.accessoryView).value = value;
    cell.detailTextLabel.text = [self formatValue:value step:step unit:unit];
    return cell;
}

- (NSString *)formatValue:(double)value step:(double)step unit:(NSString *)unit {
    NSString *num = (step >= 1.0)
        ? [NSString stringWithFormat:@"%.0f", value]
        : [NSString stringWithFormat:@"%.1f", value];
    return unit ? [NSString stringWithFormat:@"%@ %@", num, unit] : num;
}

// ---------------------------------------------------------------------------
// Toggle actions
// ---------------------------------------------------------------------------

- (void)autoRematchChanged:(UISwitch *)sw {
    KEBSetAutoRematchEnabled(sw.on);
}

// ---------------------------------------------------------------------------
// Stepper actions
// ---------------------------------------------------------------------------

- (void)step1Changed:(UIStepper *)stepper {
    KEBSetRematchStep1Sec((float)stepper.value);
    self.step1ValueLabel.text = [self formatValue:stepper.value step:0.5 unit:@"s"];
}

- (void)step2Changed:(UIStepper *)stepper {
    KEBSetRematchStep2Sec((float)stepper.value);
    self.step2ValueLabel.text = [self formatValue:stepper.value step:0.5 unit:@"s"];
}

- (void)csaPortChanged:(UIStepper *)stepper {
    KEBSetCsaPort((uint16_t)stepper.value);
    self.portValueLabel.text = [self formatValue:stepper.value step:1.0 unit:nil];
}

@end

// ---------------------------------------------------------------------------
// KEBPresentSettings — presenter bridge, mirrors KFPresentSettings().
// ---------------------------------------------------------------------------

void KEBPresentSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = kebTopmostViewController();
        if (!top) {
            IPALog(@"[SETTINGS] no topmost vc — cannot present");
            return;
        }
        if ([top isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)top;
            if ([nav.viewControllers.firstObject isKindOfClass:
                 [KEBSettingsViewController class]]) {
                IPALog(@"[SETTINGS] already presented — skipping");
                return;
            }
        }
        KEBSettingsViewController *settings =
            [[KEBSettingsViewController alloc] init];
        UINavigationController *nav =
            [[UINavigationController alloc] initWithRootViewController:settings];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [top presentViewController:nav animated:YES completion:^{
            IPALog(@"[SETTINGS] modal presented");
        }];
    });
}

// ---------------------------------------------------------------------------
// KEBGestureHandler — target for the UIScreenEdgePanGestureRecognizer.
// ---------------------------------------------------------------------------

@interface KEBGestureHandler : NSObject
@end

@implementation KEBGestureHandler

- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    IPALog(@"[SETTINGS] right-edge swipe detected — presenting settings");
    KEBPresentSettings();
}

@end

// ---------------------------------------------------------------------------
// KEBSettingsInstall — public entry point called from Tweak.m.
// Mirrors KiouForge's KFGestureInstall().
// ---------------------------------------------------------------------------

void KEBSettingsInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = kebKeyWindow();
        if (!win) {
            IPALog(@"[SETTINGS] key window not ready — will retry in 1s");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                KEBSettingsInstall();
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

        static KEBGestureHandler *sHandler = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sHandler = [[KEBGestureHandler alloc] init]; });

        UIScreenEdgePanGestureRecognizer *gr =
            [[UIScreenEdgePanGestureRecognizer alloc]
                initWithTarget:sHandler
                        action:@selector(handleEdgePan:)];
        gr.edges = UIRectEdgeRight;
        [win addGestureRecognizer:gr];
        IPALog(@"[SETTINGS] right-edge gesture installed on key window");
    });
}
