#import "Internal.h"
#import "Settings/Persistence.h"
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

#define KEB_SECTION_ACCOUNT  0
#define KEB_SECTION_MATCH    1
#define KEB_SECTION_ACCEPT   2
#define KEB_SECTION_MATCHING 3
#define KEB_SECTION_DELAY    4
#define KEB_SECTION_SERVER   5
#define KEB_SECTION_ABOUT    6
#define KEB_SECTION_COUNT    7

#define KEB_ROW_ACCOUNT_ACTIVE         0
#define KEB_ROW_ACCOUNT_FORCE_REGISTER 1
#define KEB_ACCOUNT_ROW_COUNT          2

#define KEB_ROW_ACCEPT_BLACK  0
#define KEB_ROW_ACCEPT_WHITE  1
#define KEB_ROW_ACCEPT_BOTH   2
#define KEB_ACCEPT_ROW_COUNT  3

#define KEB_ROW_AUTO_REMATCH       0
#define KEB_ROW_RESIGN_SKIP_DIALOG 1
#define KEB_MATCH_ROW_COUNT        2

#define KEB_ROW_FIXED_RATE_RANGE   0
#define KEB_MATCHING_ROW_COUNT     1

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

static UIViewController *kebTopmostViewController(void) {
    UIViewController *vc = kebKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// ---------------------------------------------------------------------------
// KEBAccountsViewController — drilled-down list with select / edit / delete.
//
// Shows every saved account. Tapping a row switches the active account
// (calls KEBSwitchAccount which writes to TDAnalytics.SetDistinctId, and
// updates KEBSetActiveAccountUuid). The Edit button enables row reorder
// and swipe-to-delete. Deletions cascade to the persisted list; the
// currently-active row is rendered with a checkmark.
// ---------------------------------------------------------------------------
@interface KEBAccountsViewController : UITableViewController
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *accounts;
@end

@implementation KEBAccountsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.title = @"Accounts";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIBarButtonItem *share =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                      target:self
                                                      action:@selector(exportAccounts:)];
    self.navigationItem.rightBarButtonItems = @[self.editButtonItem, share];
    self.accounts = [NSMutableArray arrayWithArray:KEBListAccounts()];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(onAccountStateChanged:)
               name:KEBAccountStateChangedNotification
             object:nil];
}

- (void)exportAccounts:(UIBarButtonItem *)sender {
    NSArray *accs = KEBListAccounts();
    NSError *err = nil;
    NSData *data = [NSJSONSerialization
                       dataWithJSONObject:accs
                                  options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                    error:&err];
    if (data.length == 0) {
        UIAlertController *err_alert = [UIAlertController
            alertControllerWithTitle:@"Export failed"
                              message:err.localizedDescription ?: @"(unknown)"
                       preferredStyle:UIAlertControllerStyleAlert];
        [err_alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
        [self presentViewController:err_alert animated:YES completion:nil];
        return;
    }
    NSURL *tmpURL = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"accounts.json"]];
    [data writeToURL:tmpURL atomically:YES];
    UIActivityViewController *vc =
        [[UIActivityViewController alloc] initWithActivityItems:@[tmpURL]
                                          applicationActivities:nil];
    vc.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.accounts = [NSMutableArray arrayWithArray:KEBListAccounts()];
    [self logAccounts:@"viewWillAppear"];
    [self.tableView reloadData];
}

- (void)logAccounts:(NSString *)tag {
    IPALog([NSString stringWithFormat:
              @"[SETTINGS] accounts (%@) count=%lu active_user_id=%@",
              tag, (unsigned long)self.accounts.count,
              KEBActiveAccountUserId() ?: @"(none)"]);
    for (NSUInteger i = 0; i < self.accounts.count; i++) {
        NSDictionary *acc = self.accounts[i];
        IPALog([NSString stringWithFormat:
                  @"  [%lu] userId=%@ userName=%@ uuid=%@ openId=%@ distinctId=%@",
                  (unsigned long)i,
                  acc[@"userId"]     ?: @"(empty)",
                  acc[@"userName"]   ?: @"(empty)",
                  acc[@"uuid"]       ?: @"(empty)",
                  acc[@"openId"]     ?: @"(empty)",
                  acc[@"distinctId"] ?: @"(empty)"]);
    }
}

- (void)onAccountStateChanged:(NSNotification *)note {
    // Posted from whichever thread changed persistence (hooks often run
    // off the main thread). Bounce to the main queue before touching UI.
    dispatch_async(dispatch_get_main_queue(), ^{
        self.accounts = [NSMutableArray arrayWithArray:KEBListAccounts()];
        [self.tableView reloadData];
    });
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return self.accounts.count;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (self.accounts.count == 0) {
        return @"No accounts saved yet. Log in once and KiouEngineBridge will remember the identity.";
    }
    return @"Tap to switch. App relaunch required.";
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *kId = @"account_row";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:kId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:kId];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.showsReorderControl = YES;
    }
    NSDictionary *acc = self.accounts[ip.row];
    NSString *userName = acc[@"userName"];
    NSString *openId = acc[@"openId"];
    NSString *userId = acc[@"userId"];
    cell.textLabel.text = userName.length > 0 ? userName : @"(no name)";
    cell.detailTextLabel.text = openId.length > 0 ? openId : @"(no open id)";
    NSString *activeUserId = KEBActiveAccountUserId();
    cell.accessoryType = ([userId isKindOfClass:[NSString class]] &&
                          [userId isEqualToString:activeUserId])
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.tableView.isEditing) return;  // ignore taps while editing
    if (ip.row >= (NSInteger)self.accounts.count) return;
    NSDictionary *acc = self.accounts[ip.row];
    NSString *userId   = acc[@"userId"];
    NSString *uuid     = acc[@"uuid"];
    NSString *userName = acc[@"userName"];
    if (![userId isKindOfClass:[NSString class]] || userId.length == 0) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"%@に切り替え",
                                   userName.length > 0 ? userName : @"このアカウント"]
                          message:nil
                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"切り替え"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
        if (uuid.length > 0) KEBSwitchAccount(uuid);
        KEBSetActiveAccountUserId(userId);
        // Close the settings modal then let KIOU navigate itself back to the
        // title scene — that re-runs AccountExists → LoginAsync with the
        // pending_device_id substitution in effect, no app relaunch needed.
        UIViewController *modalRoot = self.navigationController ?: self;
        UIViewController *presenter = modalRoot.presentingViewController;
        [presenter dismissViewControllerAnimated:YES completion:^{
            KEBNavigateToTitleScene();
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Editing — delete + reorder.
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return YES;
}

- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip {
    return YES;
}

- (void)tableView:(UITableView *)tv
    commitEditingStyle:(UITableViewCellEditingStyle)style
     forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    if (ip.row >= (NSInteger)self.accounts.count) return;
    NSString *userId = self.accounts[ip.row][@"userId"];
    [self.accounts removeObjectAtIndex:ip.row];
    if ([userId isKindOfClass:[NSString class]]) KEBDeleteAccount(userId);
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)tableView:(UITableView *)tv
    moveRowAtIndexPath:(NSIndexPath *)src
           toIndexPath:(NSIndexPath *)dst {
    if (src.row >= (NSInteger)self.accounts.count) return;
    NSDictionary *moved = self.accounts[src.row];
    [self.accounts removeObjectAtIndex:src.row];
    [self.accounts insertObject:moved atIndex:dst.row];
    // Persist the new order — overwrite the raw array under the same key.
    [[NSUserDefaults standardUserDefaults] setObject:self.accounts
                                              forKey:@"kiou_bridge.accounts"];
}

@end

// ---------------------------------------------------------------------------
// KEBSettingsViewController
// ---------------------------------------------------------------------------

@interface KEBSettingsViewController : UITableViewController
@property (nonatomic, strong) UILabel *step1ValueLabel;
@property (nonatomic, strong) UILabel *step2ValueLabel;
@property (nonatomic, strong) UILabel *portValueLabel;
@property (nonatomic, strong) UILabel *rateRangeValueLabel;
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
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(onAccountStateChanged:)
               name:KEBAccountStateChangedNotification
             object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)onAccountStateChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Only refresh the Account section — leaving other sections alone
        // avoids resetting scroll state or any in-flight cell editing.
        if (self.isViewLoaded && self.view.window) {
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:KEB_SECTION_ACCOUNT]
                          withRowAnimation:UITableViewRowAnimationNone];
        }
    });
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
        case KEB_SECTION_ACCOUNT:  return KEB_ACCOUNT_ROW_COUNT;
        case KEB_SECTION_MATCH:    return KEB_MATCH_ROW_COUNT;
        case KEB_SECTION_ACCEPT:   return KEB_ACCEPT_ROW_COUNT;
        case KEB_SECTION_MATCHING: return KEB_MATCHING_ROW_COUNT;
        case KEB_SECTION_DELAY:    return KEB_DELAY_ROW_COUNT;
        case KEB_SECTION_SERVER:   return KEB_SERVER_ROW_COUNT;
        case KEB_SECTION_ABOUT:    return KEB_ABOUT_ROW_COUNT;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case KEB_SECTION_ACCOUNT:  return @"Account";
        case KEB_SECTION_MATCH:    return @"Match";
        case KEB_SECTION_ACCEPT:   return @"Accept Seat";
        case KEB_SECTION_MATCHING: return @"Matching Filter";
        case KEB_SECTION_DELAY:    return @"Delay";
        case KEB_SECTION_SERVER:   return @"CSA Server";
        case KEB_SECTION_ABOUT:    return @"About";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == KEB_SECTION_ACCOUNT) {
        return @"New Register: routes the next launch into the name-entry "
               @"flow without going through KIOU's Reset button (which may "
               @"trigger server-side rebinding).";
    }
    if (section == KEB_SECTION_ACCEPT) {
        return @"Reject MatchFound replies whose seat doesn't match. Rejected matches requeue automatically.";
    }
    if (section == KEB_SECTION_MATCHING) {
        return @"Fixed Rate Range: requeues when the server's rate range exceeds this value. 0 = disabled.";
    }
    if (section == KEB_SECTION_SERVER) {
        return @"Port change takes effect after restarting the app.";
    }
    if (section == KEB_SECTION_ABOUT) {
        return [NSString stringWithFormat:@"%s (%s)",
                BUILD_VERSION, BUILD_COMMIT];
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch (ip.section) {

        // -- Account -------------------------------------------------------
        case KEB_SECTION_ACCOUNT: {
            if (ip.row == KEB_ROW_ACCOUNT_ACTIVE) {
                static NSString *kId = @"account_active";
                UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:kId];
                if (!cell) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                  reuseIdentifier:kId];
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
                }
                cell.textLabel.text = @"Active";
                NSString *activeUserId = KEBActiveAccountUserId();
                NSString *activeName = nil;
                for (NSDictionary *acc in KEBListAccounts()) {
                    NSString *u = acc[@"userId"];
                    if ([u isKindOfClass:[NSString class]] && [u isEqualToString:activeUserId]) {
                        NSString *n = acc[@"userName"];
                        if ([n isKindOfClass:[NSString class]]) activeName = n;
                        break;
                    }
                }
                cell.detailTextLabel.text = activeName.length > 0 ? activeName : @"(not logged in)";
                return cell;
            }
            if (ip.row == KEB_ROW_ACCOUNT_FORCE_REGISTER) {
                return [self toggleCellWithTitle:@"New Register"
                                            key:@"force_register"
                                          value:KEBForceRegisterOnNextLaunch()
                                         action:@selector(forceRegisterChanged:)];
            }
            break;
        }

        // -- Match ---------------------------------------------------------
        case KEB_SECTION_MATCH: {
            if (ip.row == KEB_ROW_AUTO_REMATCH) {
                return [self toggleCellWithTitle:@"Auto Rematch"
                                            key:@"auto_rematch"
                                          value:KEBAutoRematchEnabled()
                                         action:@selector(autoRematchChanged:)];
            }
            if (ip.row == KEB_ROW_RESIGN_SKIP_DIALOG) {
                return [self toggleCellWithTitle:@"Skip Resign Dialog"
                                            key:@"resign_skip_dialog"
                                          value:KEBResignSkipDialog()
                                         action:@selector(resignSkipDialogChanged:)];
            }
            break;
        }

        // -- Accept Seat ---------------------------------------------------
        case KEB_SECTION_ACCEPT: {
            static NSString *kId = @"accept_row";
            UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:kId];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                              reuseIdentifier:kId];
            }
            KEBAcceptedSeat current = KEBAcceptedSeatGet();
            int32_t rowSeat = (ip.row == KEB_ROW_ACCEPT_BLACK) ? KEBAcceptedSeatBlack
                            : (ip.row == KEB_ROW_ACCEPT_WHITE) ? KEBAcceptedSeatWhite
                            : KEBAcceptedSeatBoth;
            cell.textLabel.text = (rowSeat == KEBAcceptedSeatBlack) ? @"Black"
                                : (rowSeat == KEBAcceptedSeatWhite) ? @"White"
                                : @"Both";
            cell.accessoryType = (current == rowSeat)
                ? UITableViewCellAccessoryCheckmark
                : UITableViewCellAccessoryNone;
            return cell;
        }

        // -- Matching Filter -----------------------------------------------
        case KEB_SECTION_MATCHING: {
            if (ip.row == KEB_ROW_FIXED_RATE_RANGE) {
                UITableViewCell *cell =
                    [self stepperCellWithReuseId:@"rate_range"
                                          title:@"Fixed Rate Range"
                                          value:(double)KEBFixedRateRange()
                                           unit:nil
                                            min:0.0 max:2000.0 step:50.0
                                         action:@selector(fixedRateRangeChanged:)];
                self.rateRangeValueLabel = cell.detailTextLabel;
                return cell;
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
    if (ip.section == KEB_SECTION_ABOUT)  return ip;
    if (ip.section == KEB_SECTION_ACCEPT) return ip;
    // Only the Active row in Account drills down — the Force Register row
    // is a toggle and shouldn't push a view controller.
    if (ip.section == KEB_SECTION_ACCOUNT &&
        ip.row == KEB_ROW_ACCOUNT_ACTIVE) return ip;
    return nil;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == KEB_SECTION_ABOUT) {
        NSString *str = (ip.row == KEB_ROW_ABOUT_REPO) ? kAboutRepoURL : kAboutAuthorURL;
        NSURL *url = [NSURL URLWithString:str];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        return;
    }
    if (ip.section == KEB_SECTION_ACCOUNT &&
        ip.row == KEB_ROW_ACCOUNT_ACTIVE) {
        KEBAccountsViewController *vc = [[KEBAccountsViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (ip.section == KEB_SECTION_ACCEPT) {
        KEBAcceptedSeat picked = (ip.row == KEB_ROW_ACCEPT_BLACK) ? KEBAcceptedSeatBlack
                               : (ip.row == KEB_ROW_ACCEPT_WHITE) ? KEBAcceptedSeatWhite
                               : KEBAcceptedSeatBoth;
        KEBAcceptedSeatSet(picked);
        // Reload only the Accept section so the checkmark moves.
        [tv reloadSections:[NSIndexSet indexSetWithIndex:KEB_SECTION_ACCEPT]
          withRowAnimation:UITableViewRowAnimationNone];
        return;
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

- (void)resignSkipDialogChanged:(UISwitch *)sw {
    KEBSetResignSkipDialog(sw.on);
}

- (void)forceRegisterChanged:(UISwitch *)sw {
    KEBSetForceRegisterOnNextLaunch(sw.on);
    if (sw.on) {
        // Arm a fresh distinctId so the upcoming Register hits the server
        // with a previously-unused UUID instead of re-binding the current
        // TDAnalytics distinctId. pending_device_id matches so the auto-Login
        // right after Register lands on the new account.
        NSString *fresh = [[NSUUID UUID] UUIDString].lowercaseString;
        KEBSetPendingDistinctId(fresh);
        KEBSetPendingDeviceId(fresh);
    } else {
        KEBSetPendingDistinctId(nil);
        KEBSetPendingDeviceId(nil);
    }
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

- (void)fixedRateRangeChanged:(UIStepper *)stepper {
    KEBSetFixedRateRange((int32_t)stepper.value);
    self.rateRangeValueLabel.text = [self formatValue:stepper.value step:50.0 unit:nil];
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
