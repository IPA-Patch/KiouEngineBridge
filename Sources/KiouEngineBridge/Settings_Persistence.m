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
// Matching filter
// ---------------------------------------------------------------------------

static NSString * const kKeyAcceptedSeat   = @"kiou_bridge.accepted_seat";
static NSString * const kKeyFixedRateRange = @"kiou_bridge.fixed_rate_range";

KEBAcceptedSeat KEBAcceptedSeatGet(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyAcceptedSeat];
    if (!v) return KEBAcceptedSeatBoth;
    int32_t raw = [v intValue];
    if (raw == KEBAcceptedSeatBlack) return KEBAcceptedSeatBlack;
    if (raw == KEBAcceptedSeatWhite) return KEBAcceptedSeatWhite;
    return KEBAcceptedSeatBoth;
}

void KEBAcceptedSeatSet(KEBAcceptedSeat seat) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:(NSInteger)seat forKey:kKeyAcceptedSeat];
    const char *label = (seat == KEBAcceptedSeatBlack) ? "Black"
                      : (seat == KEBAcceptedSeatWhite) ? "White"
                      : "Both";
    IPALog([NSString stringWithFormat:@"[SETTINGS] accepted_seat=%s", label]);
}

int32_t KEBFixedRateRange(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyFixedRateRange];
    if (!v) return 0;
    int32_t val = [v intValue];
    if (val < 0) return 0;
    if (val > 2000) return 2000;
    return val;
}

void KEBSetFixedRateRange(int32_t range) {
    int32_t clamped = (range < 0) ? 0 : (range > 2000) ? 2000 : range;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:clamped forKey:kKeyFixedRateRange];
    IPALog([NSString stringWithFormat:@"[SETTINGS] fixed_rate_range=%d%@",
              clamped, clamped == 0 ? @" (disabled)" : @""]);
}

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

NSString * const KEBAccountStateChangedNotification =
    @"KEBAccountStateChangedNotification";

static inline void kebPostAccountStateChanged(void) {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:KEBAccountStateChangedNotification object:nil];
}

static NSString * const kKeyAccounts          = @"kiou_bridge.accounts";
// Stores the userId of the active account. Schema version bumped — the legacy
// "kiou_bridge.active_account" key (openId-keyed) is left orphan; values get
// rewritten on the next successful Login.
static NSString * const kKeyActiveAccountUuid = @"kiou_bridge.active_account_user_id";

static NSString * const kAccountFieldUuid       = @"uuid";
static NSString * const kAccountFieldUserName   = @"userName";
static NSString * const kAccountFieldOpenId     = @"openId";
static NSString * const kAccountFieldUserId     = @"userId";
static NSString * const kAccountFieldDistinctId = @"distinctId";
static NSString * const kAccountFieldSavedAt    = @"savedAt";

NSArray<NSDictionary *> *KEBListAccounts(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *raw = [d arrayForKey:kKeyAccounts];
    if (![raw isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:raw.count];
    for (id entry in raw) {
        if ([entry isKindOfClass:[NSDictionary class]]) [result addObject:entry];
    }
    return result;
}

void KEBSaveAccount(NSString *uuid,
                    NSString *userName,
                    NSString *openId,
                    NSString *userId,
                    NSString *distinctId) {
    // Primary key is userId (the server-issued ULID, == JWT.sub). openId can
    // be stale via AccountExists' cache, so we deliberately don't key on it.
    if (userId.length == 0) {
        IPALog([NSString stringWithFormat:
                  @"[SETTINGS] account save skipped: missing userId "
                  @"(uuid=%@ userName=%@ openId=%@)",
                  uuid ?: @"", userName ?: @"", openId ?: @""]);
        return;
    }
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *existing = KEBListAccounts();
    NSMutableArray<NSDictionary *> *next = [NSMutableArray arrayWithCapacity:existing.count + 1];
    BOOL replaced = NO;
    NSDictionary *fresh = @{
        kAccountFieldUuid:       uuid       ?: @"",
        kAccountFieldUserName:   userName   ?: @"",
        kAccountFieldOpenId:     openId     ?: @"",
        kAccountFieldUserId:     userId,
        kAccountFieldDistinctId: distinctId ?: @"",
        kAccountFieldSavedAt:    @((NSInteger)[[NSDate date] timeIntervalSince1970]),
    };
    for (NSDictionary *e in existing) {
        NSString *eUserId = e[kAccountFieldUserId];
        if ([eUserId isKindOfClass:[NSString class]] && [eUserId isEqualToString:userId]) {
            NSMutableDictionary *merged = [fresh mutableCopy];
            if (uuid.length       == 0) merged[kAccountFieldUuid]       = e[kAccountFieldUuid]       ?: @"";
            if (userName.length   == 0) merged[kAccountFieldUserName]   = e[kAccountFieldUserName]   ?: @"";
            if (openId.length     == 0) merged[kAccountFieldOpenId]     = e[kAccountFieldOpenId]     ?: @"";
            if (distinctId.length == 0) merged[kAccountFieldDistinctId] = e[kAccountFieldDistinctId] ?: @"";
            [next addObject:merged];
            replaced = YES;
        } else {
            [next addObject:e];
        }
    }
    if (!replaced) [next addObject:fresh];
    [d setObject:next forKey:kKeyAccounts];
    IPALog([NSString stringWithFormat:
              @"[SETTINGS] account saved userId=%@ userName=%@ uuid=%@ "
              @"openId=%@ distinctId=%@ total=%lu",
              userId, userName ?: @"", uuid ?: @"",
              openId ?: @"", distinctId ?: @"",
              (unsigned long)next.count]);
    kebPostAccountStateChanged();
}

void KEBUpdateAccountProfile(NSString *userId,
                             NSString *openId,
                             NSArray<NSDictionary *> *ranks) {
    if (userId.length == 0) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *existing = KEBListAccounts();
    BOOL found = NO;
    NSMutableArray<NSDictionary *> *next = [NSMutableArray arrayWithCapacity:existing.count];
    for (NSDictionary *e in existing) {
        NSString *eUserId = e[kAccountFieldUserId];
        if ([eUserId isKindOfClass:[NSString class]] && [eUserId isEqualToString:userId]) {
            NSMutableDictionary *merged = [e mutableCopy];
            if (openId.length > 0) merged[kAccountFieldOpenId] = openId;
            if (ranks.count > 0)   merged[@"ranks"] = ranks;
            [next addObject:merged];
            found = YES;
        } else {
            [next addObject:e];
        }
    }
    if (!found) return;
    [d setObject:next forKey:kKeyAccounts];
    IPALog([NSString stringWithFormat:
              @"[SETTINGS] profile updated userId=%@ openId=%@ ranks=%lu",
              userId, openId ?: @"", (unsigned long)ranks.count]);
    kebPostAccountStateChanged();
}

void KEBDeleteAccount(NSString *userId) {
    if (userId.length == 0) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *existing = KEBListAccounts();
    NSMutableArray<NSDictionary *> *next = [NSMutableArray arrayWithCapacity:existing.count];
    for (NSDictionary *e in existing) {
        NSString *eUserId = e[kAccountFieldUserId];
        if ([eUserId isKindOfClass:[NSString class]] && [eUserId isEqualToString:userId]) continue;
        [next addObject:e];
    }
    [d setObject:next forKey:kKeyAccounts];
    IPALog([NSString stringWithFormat:
              @"[SETTINGS] account deleted userId=%@ remaining=%lu",
              userId, (unsigned long)next.count]);
    kebPostAccountStateChanged();
}

NSString *KEBActiveAccountUserId(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyActiveAccountUuid];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

void KEBSetActiveAccountUserId(NSString *userId) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (userId.length == 0) {
        [d removeObjectForKey:kKeyActiveAccountUuid];
    } else {
        [d setObject:userId forKey:kKeyActiveAccountUuid];
    }
    IPALog([NSString stringWithFormat:@"[SETTINGS] active_account_user_id=%@",
              userId.length > 0 ? userId : @"(none)"]);
    kebPostAccountStateChanged();
}

static NSString * const kKeyForceRegisterOnNextLaunch = @"kiou_bridge.force_register_on_next_launch";

bool KEBForceRegisterOnNextLaunch(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyForceRegisterOnNextLaunch];
    return v ? [v boolValue] : false;
}

void KEBSetForceRegisterOnNextLaunch(bool enabled) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (enabled) {
        [d setBool:YES forKey:kKeyForceRegisterOnNextLaunch];
    } else {
        [d removeObjectForKey:kKeyForceRegisterOnNextLaunch];
    }
    IPALog([NSString stringWithFormat:@"[SETTINGS] force_register_on_next_launch=%s",
              enabled ? "true" : "false"]);
}

static NSString * const kKeyPendingDistinctId = @"kiou_bridge.pending_distinct_id";
static NSString * const kKeyPendingDeviceId   = @"kiou_bridge.pending_device_id";

NSString *KEBPendingDistinctId(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyPendingDistinctId];
    return [v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0 ? v : nil;
}

void KEBSetPendingDistinctId(NSString *uuid) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (uuid.length == 0) {
        [d removeObjectForKey:kKeyPendingDistinctId];
        IPALog(@"[SETTINGS] pending_distinct_id cleared");
    } else {
        [d setObject:uuid forKey:kKeyPendingDistinctId];
        IPALog([NSString stringWithFormat:@"[SETTINGS] pending_distinct_id=%@", uuid]);
    }
    kebPostAccountStateChanged();
}

NSString *KEBPendingDeviceId(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kKeyPendingDeviceId];
    return [v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0 ? v : nil;
}

void KEBSetPendingDeviceId(NSString *uuid) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (uuid.length == 0) {
        [d removeObjectForKey:kKeyPendingDeviceId];
        IPALog(@"[SETTINGS] pending_device_id cleared");
    } else {
        [d setObject:uuid forKey:kKeyPendingDeviceId];
        IPALog([NSString stringWithFormat:@"[SETTINGS] pending_device_id=%@", uuid]);
    }
    kebPostAccountStateChanged();
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

