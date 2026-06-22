#import "Internal.h"
#import "Settings_Persistence.h"
#import <dlfcn.h>

// ===========================================================================
// Hook_AccountObserve — account identity investigation hooks.
//
// Purpose: log the DeviceId / DistinctId values that flow through the login
// path so we can confirm what needs to be saved / restored to support
// account switching. This is a read-only observation layer — no values are
// modified. Remove or disable once the data flow is confirmed.
//
// Hook sites:
//
//   ILoginArgs.Create (static)          RVA: 0x5B9899C
//     Logs the (deviceId, distinctId) pair sent to LoginAsync.
//
//   AuthServiceExtensions.<RunLoginSequenceAsync>d__1.MoveNext
//                                       RVA: 0x5812534
//     Logs the (accessToken, sessionId, deviceId, userName) returned by
//     the server.
//
//   SystemInfo.get_deviceUniqueIdentifier  RVA: 0x6BD8E80
//     Logs Unity's hardware device ID the first time it is read.
//
//   TDAnalytics.GetDistinctId           RVA: 0x63D735C
//     Logs the DistinctId that ThinkingAnalytics currently holds.
//
//   TDAnalytics.SetDistinctId           RVA: 0x63D7078
//     Logs whenever the DistinctId is changed.
//
//   TDAnalytics.GetDeviceId             RVA: 0x63DFDAC
//     Logs the device ID that ThinkingAnalytics reports.
//
// Field offsets (LoginReply concrete class, dump.cs line 513506):
//   accessToken_  string  0x18
//   sessionId_    string  0x20
//   deviceId_     string  0x28
//   userName_     string  0x30
//
// State machine offsets (RunLoginSequenceAsync d__1, dump.cs line 805035):
//   <>1__state    int32   0x00  (-2 = completed)
//   result is the UniTask<ILoginReply> return value — read via the builder
//   field, but easier to hook the caller that extracts the reply. We instead
//   hook MoveNext and look for state == -2 to capture the result field.
//   The reply pointer sits at offset 0x38 inside the state machine struct
//   (after the builder at 0x08, service at 0x20, ct at 0x28, sessionData
//   at 0x30). Exact offset needs on-device confirmation — we log all
//   candidate pointers when state == -2 so we can identify the right one.
// ===========================================================================

// ---------------------------------------------------------------------------
// RVAs (KIOU 1.0.1 build 11)
// ---------------------------------------------------------------------------
#define RVA_LOGIN_ARGS_CREATE              0x5B9899C
#define RVA_RUN_LOGIN_SEQ_MOVENEXT         0x5812534
#define RVA_SYSTEMINFO_DEVICE_UNIQUE_ID    0x6BD8E80
#define RVA_TD_GET_DISTINCT_ID             0x63D735C
#define RVA_TD_SET_DISTINCT_ID             0x63D7078
#define RVA_TD_GET_DEVICE_ID               0x63DFDAC
// GameService.<GetSelfUserProfileAsync>d__36.MoveNext — completes with the
// SelfUserProfileStatus (UserName, OpenUserId, RankList, BattleRecordList).
#define RVA_GET_SELF_PROFILE_MOVENEXT      0x5BB4774
// TitleMenuPopupPresenter.RunResetUserDataSequenceAsync — fires when the
// user taps "アカウント初期化" from the title-menu popup. After this runs the
// ThinkingAnalytics-persisted UUID is (likely) cleared, so the next login
// generates a fresh account on the server.
#define RVA_RUN_RESET_USER_DATA_SEQ        0x5DC6908
// TitleMenuPopupPresenter.RunDeleteAccountSequenceAsync — full account
// removal. Observed too so we can distinguish from reset.
#define RVA_RUN_DELETE_ACCOUNT_SEQ         0x5DC69B8
// UserSaveDataExtensions.AccountExists — the boot-time login/register
// branch decision. true → RunLoginSequenceAsync, false → RunRegisterUserSequenceAsync.
#define RVA_ACCOUNT_EXISTS                 0x591E860
// IRegisterUserArgs.Create(string userName, string distinctId) — emitted
// when the register flow ships the user's chosen name to the server. We
// intercept it so the post-reset register uses the same pending UUID as
// LoginArgs.Create, keeping the account's distinctId and the gRPC login
// distinctId aligned.
#define RVA_REGISTER_USER_ARGS_CREATE      0x5B98A2C
// AuthService.<RegisterUserAsync>d__4.MoveNext — completion gives us the
// IRegisterUserReply that the server returns from RegisterUserAsync.
// Captured so we can record (UserId, DeviceId, OpenUserId,
// NameValidationResult) the moment the server confirms registration.
#define RVA_AUTHSVC_REGISTER_MOVENEXT      0x5B95EA8
// AuthService.<LoginAsync>d__3.MoveNext — completion gives us the
// ILoginReply that the server returns from LoginAsync. We already observe
// LoginReply via the outer RunLoginSequenceAsync state machine, but
// hooking here lets us see the inner reply even when the outer sequence
// fails (e.g. when LoginAsync returns -40004).
#define RVA_AUTHSVC_LOGIN_MOVENEXT         0x5B957AC

// UserSaveData field offsets (dump.cs line 1593531)
#define OFF_USER_SAVE_DATA_USER_NAME  0x10
#define OFF_USER_SAVE_DATA_OPEN_ID    0x18
#define OFF_USER_SAVE_DATA_USER_ID    0x20
#define OFF_USER_SAVE_DATA_DEVICE_ID  0x28

// ---------------------------------------------------------------------------
// LoginReply field offsets
// ---------------------------------------------------------------------------
#define OFF_LOGIN_REPLY_ACCESS_TOKEN  0x18
#define OFF_LOGIN_REPLY_SESSION_ID    0x20
#define OFF_LOGIN_REPLY_DEVICE_ID     0x28
#define OFF_LOGIN_REPLY_USER_NAME     0x30

// ---------------------------------------------------------------------------
// GetSelfUserProfileReply / SelfUserProfileStatus field offsets
// ---------------------------------------------------------------------------
#define OFF_GET_SELF_PROFILE_REPLY_PROFILE  0x18  // -> SelfUserProfileStatus*
#define OFF_SELF_PROFILE_USER_NAME          0x18  // string
#define OFF_SELF_PROFILE_OPEN_USER_ID       0x20  // string
#define OFF_SELF_PROFILE_RANK_LIST          0x28  // RepeatedField<ProfileRankStatus>
#define OFF_SELF_PROFILE_BATTLE_RECORD_LIST 0x48  // RepeatedField<ProfileBattleRecordStatus>

// RepeatedField<T> il2cpp layout: object header (0x10) + array(ptr@0x10) + count(i32@0x18)
#define OFF_REPEATED_ARRAY 0x10
#define OFF_REPEATED_COUNT 0x18

// ProfileRankStatus field offsets (dump.cs line 565239)
#define OFF_RANK_STATUS_MATCH_TYPE        0x18  // int32
#define OFF_RANK_STATUS_RANK_RULE_TYPE    0x1C  // int32
#define OFF_RANK_STATUS_CPU_RULE_TYPE     0x20  // int32
#define OFF_RANK_STATUS_RANK              0x24  // int32 (ShogiPlayerRankType)
#define OFF_RANK_STATUS_RATING            0x28  // int32

// ---------------------------------------------------------------------------
// RunLoginSequenceAsync d__1 state machine field offsets
//
// Confirmed offset: 0x50 holds the ILoginReply*. The other candidates
// (0x38/0x40/0x48) are logged at scan time but always come back as nil or
// non-LoginReply pointers — kept in the scan loop so we'd notice if a
// future game build shifts the layout.
// ---------------------------------------------------------------------------
#define OFF_SM_LOGIN_STATE        0x00
#define OFF_SM_LOGIN_RESULT_A     0x38
#define OFF_SM_LOGIN_RESULT_B     0x40
#define OFF_SM_LOGIN_RESULT_C     0x48
#define OFF_SM_LOGIN_RESULT_D     0x50  // ← confirmed on KIOU 1.0.1 build 11

// ---------------------------------------------------------------------------
// Reset substitution state — see HookRunResetUserDataSeq for the lifecycle.
// Declared early so HookLoginArgsCreate / HookTDSetDistinctId (both above
// the installer) can reference them.
// ---------------------------------------------------------------------------
// (g_resetSubstActive / g_pendingFreshUuid removed — substitution is now
//  driven by KEBPendingDistinctId which persists across launches.)

// Latest openId / userId observed via AccountExists, consumed by the
// LoginReply observer. See the longer comment lower in the file.
static NSString *volatile g_latestObservedOpenId = nil;
static NSString *volatile g_latestObservedUserId = nil;

// il2cpp_string_new resolved via dlsym(RTLD_DEFAULT) at install time.
typedef void *(*Il2CppStringNew_t)(const char *utf8);
static Il2CppStringNew_t g_il2cpp_string_new __attribute__((unused)) = NULL;

// ---------------------------------------------------------------------------
// il2cpp string helper — reads the UTF-8 content of an il2cpp string object.
// il2cpp string layout: vtable(8) + klass(8) + length(4) + chars(2*len)
// NSString convenience wrapper so we can use it in IPALog directly.
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// JWT helpers — KIOU's AccessToken is an HS256 JWT whose payload carries the
// authoritative server-side userId in the `sub` claim. We use this instead
// of g_latestObservedUserId because the latter is populated from
// AccountExists, which goes stale after a Reset → Register cycle.
// ---------------------------------------------------------------------------
static NSString *extractJWTSub(NSString *jwt) {
    if (jwt.length == 0) return nil;
    NSArray<NSString *> *parts = [jwt componentsSeparatedByString:@"."];
    if (parts.count < 2) return nil;
    NSString *payload = parts[1];
    // base64url → base64
    payload = [payload stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    payload = [payload stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (payload.length % 4) payload = [payload stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:payload options:0];
    if (!data) return nil;
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    id sub = ((NSDictionary *)obj)[@"sub"];
    return [sub isKindOfClass:[NSString class]] ? (NSString *)sub : nil;
}

static NSString *readIl2CppString(void *strObj) {
    if (!strObj) return nil;
    @try {
        int32_t len = readI32(strObj, 0x10);
        if (len <= 0 || len > 4096) return nil;
        // chars are UTF-16LE starting at offset 0x14
        const uint16_t *chars = (const uint16_t *)((uint8_t *)strObj + 0x14);
        return [NSString stringWithCharacters:chars length:(NSUInteger)len];
    } @catch (...) { return nil; }
}

// ---------------------------------------------------------------------------
// Hook: ILoginArgs.Create(string deviceId, string distinctId)
//   x0 = il2cpp string* deviceId
//   x1 = il2cpp string* distinctId
//   returns ILoginArgs*
// ---------------------------------------------------------------------------
typedef void *(*LoginArgsCreate_t)(void *deviceId, void *distinctId);
static LoginArgsCreate_t orig_LoginArgsCreate __attribute__((unused)) = NULL;

// ---------------------------------------------------------------------------
// Hook: IRegisterUserArgs.Create(string userName, string distinctId)
//
// KIOU calls this when the post-reset register flow ships the chosen name
// to the server. When pending_distinct_id is armed, we substitute the
// distinctId argument with the pending value — so the server allocates a
// brand-new account under that UUID instead of overwriting the existing
// one. The post-register LoginAsync (also intercepted) then uses the same
// UUID, so the freshly-registered account can sign in.
// ---------------------------------------------------------------------------
typedef void *(*RegisterUserArgsCreate_t)(void *userName, void *distinctId);
static RegisterUserArgsCreate_t orig_RegisterUserArgsCreate
    __attribute__((unused)) = NULL;

// Shared substitution helpers. Both the JB hook and the chinlan entry hook
// run the same swap-or-pass-through logic; only the orig dispatch differs.

static void *registerUserArgsSwapDistinctId(void *userName, void *distinctId) {
    NSString *origUserName   = readIl2CppString(userName);
    NSString *origDistinctId = readIl2CppString(distinctId);

    NSString *pendingDistinct = KEBPendingDistinctId();
    if (pendingDistinct.length > 0 && g_il2cpp_string_new) {
        void *newStr = g_il2cpp_string_new(pendingDistinct.UTF8String);
        if (newStr) {
            IPALog([NSString stringWithFormat:
                      @"[ACCOUNT] RegisterUserArgs.Create distinctId substituted "
                      @"%@ → %@ (userName=%@)",
                      origDistinctId ?: @"(nil)", pendingDistinct,
                      origUserName ?: @"(nil)"]);
            return newStr;
        }
    }
    IPALog([NSString stringWithFormat:
              @"[ACCOUNT] RegisterUserArgs.Create userName=%@ distinctId=%@",
              origUserName ?: @"(nil)", origDistinctId ?: @"(nil)"]);
    return distinctId;
}

static void *loginArgsSwapDeviceId(void *deviceId, void *distinctId) {
    NSString *origDev  = readIl2CppString(deviceId);
    NSString *origDist = readIl2CppString(distinctId);

    NSString *pendingDevice = KEBPendingDeviceId();
    if (pendingDevice.length > 0 && g_il2cpp_string_new) {
        void *newStr = g_il2cpp_string_new(pendingDevice.UTF8String);
        if (newStr) {
            IPALog([NSString stringWithFormat:
                      @"[ACCOUNT] LoginArgs.Create deviceId substituted %@ → %@ "
                      @"(distinctId untouched=%@)",
                      origDev ?: @"(nil)", pendingDevice,
                      origDist ?: @"(nil)"]);
            return newStr;
        }
    }
    IPALog([NSString stringWithFormat:
              @"[ACCOUNT] LoginArgs.Create deviceId=%@ distinctId=%@",
              origDev ?: @"(nil)", origDist ?: @"(nil)"]);
    return deviceId;
}

#if !KIOU_CHINLAN
// JB MSHookFunction targets. On chinlan these are unused (the entry hooks
// below cover that flavor), so the whole pair is compiled out to silence
// -Werror=unused-variable on KIOU_CALL_ORIG_RET's varargs-dropping macro.
void *HookRegisterUserArgsCreate(void *userName, void *distinctId) {
    void *useDistinctId = registerUserArgsSwapDistinctId(userName, distinctId);
    return KIOU_CALL_ORIG_RET(void *, orig_RegisterUserArgsCreate,
                               userName, useDistinctId);
}

void *HookLoginArgsCreate(void *deviceId, void *distinctId) {
    void *useDeviceId = loginArgsSwapDeviceId(deviceId, distinctId);
    return KIOU_CALL_ORIG_RET(void *, orig_LoginArgsCreate,
                               useDeviceId, distinctId);
}
#endif

// Chinlan entry-cave hooks. The cave gives us pristine x0..x7 and RETs to
// the caller after our hook returns; we substitute the args ourselves and
// invoke orig via the per-site bypass entry, which runs orig's body and
// produces the real ILoginArgs* / IRegisterUserArgs* in x0.
#if KIOU_CHINLAN
void *HookLoginArgsCreateEntry(void *deviceId, void *distinctId) {
    void *useDeviceId = loginArgsSwapDeviceId(deviceId, distinctId);
    LoginArgsCreate_t bypass =
        (LoginArgsCreate_t)g_inject_entry[KIOU_BR_HOOK_LOGIN_ARGS_CREATE];
    if (!bypass) {
        IPALog(@"[ACCOUNT] LoginArgs.Create chinlan bypass not published — "
                 @"returning NULL; the caller will likely abort the login");
        return NULL;
    }
    @try {
        return bypass(useDeviceId, distinctId);
    } @catch (NSException *e) {
        IPALog([NSString stringWithFormat:
                  @"[ACCOUNT] LoginArgs.Create chinlan bypass threw: %@", e]);
        return NULL;
    }
}

void *HookRegisterUserArgsCreateEntry(void *userName, void *distinctId) {
    void *useDistinctId = registerUserArgsSwapDistinctId(userName, distinctId);
    RegisterUserArgsCreate_t bypass = (RegisterUserArgsCreate_t)
        g_inject_entry[KIOU_BR_HOOK_REGISTER_USER_ARGS_CREATE];
    if (!bypass) {
        IPALog(@"[ACCOUNT] RegisterUserArgs.Create chinlan bypass not "
                 @"published — returning NULL");
        return NULL;
    }
    @try {
        return bypass(userName, useDistinctId);
    } @catch (NSException *e) {
        IPALog([NSString stringWithFormat:
                  @"[ACCOUNT] RegisterUserArgs.Create chinlan bypass "
                  @"threw: %@", e]);
        return NULL;
    }
}
#endif

// ---------------------------------------------------------------------------
// Hook: RunLoginSequenceAsync d__1.MoveNext
//   self = boxed IAsyncStateMachine*
//   When state == -2 (completed), scan candidate offsets for the reply ptr.
// ---------------------------------------------------------------------------
typedef void (*MoveNextVoid_t)(void *self);
static MoveNextVoid_t orig_RunLoginSeqMoveNext __attribute__((unused)) = NULL;

// Shared body for both the JB MSHook trampoline and the chinlan entry
// cave. Caller is responsible for invoking orig first; this just scans the
// completed state machine and persists the LoginReply that lives inside it.
static void observeRunLoginSeqCompletion(void *self) {
    if (!self) return;
    int32_t smState = readI32(self, OFF_SM_LOGIN_STATE);
    if (smState != -2) return;

    // Scan candidate offsets for a pointer that looks like a LoginReply.
    uintptr_t candidates[] = {
        OFF_SM_LOGIN_RESULT_A,
        OFF_SM_LOGIN_RESULT_B,
        OFF_SM_LOGIN_RESULT_C,
        OFF_SM_LOGIN_RESULT_D,
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        void *candidate = readPtr(self, candidates[i]);
        if (!candidate) continue;
        NSString *accessToken = readIl2CppString(readPtr(candidate, OFF_LOGIN_REPLY_ACCESS_TOKEN));
        NSString *sessionId   = readIl2CppString(readPtr(candidate, OFF_LOGIN_REPLY_SESSION_ID));
        NSString *deviceId    = readIl2CppString(readPtr(candidate, OFF_LOGIN_REPLY_DEVICE_ID));
        NSString *userName    = readIl2CppString(readPtr(candidate, OFF_LOGIN_REPLY_USER_NAME));
        if (!userName && !deviceId) continue;
        IPALog([NSString stringWithFormat:
                  @"[ACCOUNT] LoginReply @offset=0x%lx: "
                  @"userName=%@ deviceId=%@ sessionId=%@ accessToken=%@",
                  (unsigned long)candidates[i],
                  userName ?: @"(nil)", deviceId ?: @"(nil)",
                  sessionId ?: @"(nil)",
                  accessToken ?: @"(nil)"]);

        // Persist this account so the UI can list & switch back to it later.
        // userId is the primary key — pulled from JWT.sub (authoritative)
        // with g_latestObservedUserId as fallback. openId/AccountExists state
        // can be stale across a Reset → Register cycle, so we don't trust
        // those for keying.
        NSString *userId = extractJWTSub(accessToken);
        if (userId.length == 0) userId = g_latestObservedUserId;
        if (userId.length > 0 && deviceId.length > 0) {
            // Do NOT pass openId here. g_latestObservedOpenId is whichever
            // openId AccountExists most recently saw, which during an
            // account-switch login is the *previous* account's openId — using
            // it would clobber the just-logged-in account's correct openId
            // with the wrong value. AccountExists observer already persisted
            // the right openId per-deviceId; KEBSaveAccount's merge keeps an
            // empty new value from overwriting the stored one.
            KEBSaveAccount(deviceId, userName, @"", userId, deviceId);
            KEBSetActiveAccountUserId(userId);
        }

        // Clear the pending switch slot — it's been consumed by this login.
        KEBSetPendingDeviceId(nil);
        KEBSetPendingDistinctId(nil);
        // Force-Register is also consumed at this point. We waited until a
        // LoginReply lands so that the multiple AccountExists calls during
        // boot all see the flag as true and consistently route into Register.
        KEBSetForceRegisterOnNextLaunch(false);
        // NOTE: we previously fired GetSelfUserProfileAsync here to grab
        // rating/rank immediately after login. That raced KIOU's own boot
        // sequence (SyncItemList → SyncGiftList → ExecuteLoginBonus …) and
        // crashed the app reliably. Removed — we now rely on KIOU itself
        // calling GetSelfUserProfile once the home page finishes loading
        // (HookGetSelfProfileMoveNext still captures the result then).
        return;
    }
}

void HookRunLoginSeqMoveNext(void *self) {
    KIOU_CALL_ORIG_VOID(orig_RunLoginSeqMoveNext, self);
    observeRunLoginSeqCompletion(self);
}

#if KIOU_CHINLAN
// Chinlan entry-cave hook. The cave hands us pristine x0 (= self) and
// RETs after we return; orig isn't run for us. We invoke it via the
// per-site bypass entry so the state machine actually advances to
// state == -2, then observe the now-populated reply field.
void HookRunLoginSeqMoveNextEntry(void *self) {
    MoveNextVoid_t bypass = (MoveNextVoid_t)
        g_inject_entry[KIOU_BR_HOOK_RUN_LOGIN_SEQ_MOVENEXT];
    if (bypass) {
        @try { bypass(self); }
        @catch (NSException *e) {
            IPALog([NSString stringWithFormat:
                      @"[ACCOUNT] RunLoginSeq.MoveNext chinlan bypass "
                      @"threw: %@", e]);
            return;
        }
    } else {
        IPALog(@"[ACCOUNT] RunLoginSeq.MoveNext chinlan bypass not "
                 @"published — skipping observation");
        return;
    }
    observeRunLoginSeqCompletion(self);
}
#endif

// ---------------------------------------------------------------------------
// Hook: SystemInfo.get_deviceUniqueIdentifier() -> il2cpp string*
// (verbose — every call is logged so the call site frequency is visible.)
// ---------------------------------------------------------------------------
typedef void *(*GetDeviceUniqueId_t)(void);
static GetDeviceUniqueId_t orig_GetDeviceUniqueId __attribute__((unused)) = NULL;

void *HookGetDeviceUniqueId(void) {
    void *result = KIOU_CALL_ORIG_RET(void *, orig_GetDeviceUniqueId);
    NSString *s = readIl2CppString(result);
    IPALog([NSString stringWithFormat:@"[ACCOUNT] SystemInfo.deviceUniqueIdentifier=%@",
              s ?: @"(nil)"]);
    return result;
}

// ---------------------------------------------------------------------------
// Hook: TDAnalytics.GetDistinctId(string appId) -> string  (verbose)
// ---------------------------------------------------------------------------
typedef void *(*TDGetDistinctId_t)(void *appId);
static TDGetDistinctId_t orig_TDGetDistinctId __attribute__((unused)) = NULL;

void *HookTDGetDistinctId(void *appId) {
    void *result = KIOU_CALL_ORIG_RET(void *, orig_TDGetDistinctId, appId);
    NSString *appIdStr = readIl2CppString(appId);
    NSString *s = readIl2CppString(result);
    IPALog([NSString stringWithFormat:
              @"[ACCOUNT] TDAnalytics.GetDistinctId(appId=%@) → %@",
              appIdStr ?: @"(nil)", s ?: @"(nil)"]);
    return result;
}

// ---------------------------------------------------------------------------
// Hook: TDAnalytics.SetDistinctId(string distinctId, string appId)
// ---------------------------------------------------------------------------
typedef void (*TDSetDistinctId_t)(void *distinctId, void *appId);
static TDSetDistinctId_t orig_TDSetDistinctId __attribute__((unused)) = NULL;

// Cache the appId il2cpp string (always "") seen by SetDistinctId — reused
// by KEBSwitchAccount as the second argument. Declared early so the hook
// body can populate it.
static void *volatile g_cachedAppIdString __attribute__((unused)) = NULL;

// g_latestObservedOpenId / g_latestObservedUserId declared at file top.

// Reset substitution state.
//
// When the user taps "アカウント初期化", HookRunResetUserDataSeq generates a
// fresh UUID and stashes it in g_pendingFreshUuid. Subsequent
// SetDistinctId + LoginArgs.Create calls inside the reset sequence get
// their UUID arguments rewritten to this value, so the post-reset login
// registers as a brand-new account on the server. The flag is cleared
// once LoginArgs.Create has consumed the fresh UUID.
//
// We use BOTH SetDistinctId substitution AND LoginArgs.Create substitution
// because TDAnalytics.GetDistinctId appears to re-read the persisted value
// regardless of the in-memory SetDistinctId — so the LoginArgs path needs
// a separate intervention.
// g_resetSubstActive / g_pendingFreshUuid / g_il2cpp_string_new declared at
// file top — see the early "Reset substitution state" block.

void HookTDSetDistinctId(void *distinctId, void *appId) {
    // Stash appId early — used both by KEBSwitchAccount and the substitution
    // path below.
    if (appId && !g_cachedAppIdString) g_cachedAppIdString = appId;
    NSString *appIdStr = readIl2CppString(appId);
    NSString *callerDistinctId = readIl2CppString(distinctId);
    IPALog([NSString stringWithFormat:
              @"[ACCOUNT] TDAnalytics.SetDistinctId(distinctId=%@ appId=%@) called",
              callerDistinctId ?: @"(nil)", appIdStr ?: @"(nil)"]);

    // We deliberately DON'T intercept SetDistinctId anymore. The
    // distinctId is the per-terminal identifier (TDAnalytics Keychain
    // UUID) and rewriting it broke the server's terminal/account pairing.
    // pending_distinct_id is now applied to LoginArgs.Create's deviceId
    // argument only.

    KIOU_CALL_ORIG_VOID(orig_TDSetDistinctId, distinctId, appId);
    NSString *s = readIl2CppString(distinctId);
    IPALog([NSString stringWithFormat:@"[ACCOUNT] TDAnalytics.SetDistinctId=%@",
              s ?: @"(nil)"]);
    // Reset the cache flag so the next GetDistinctId call gets logged too.
}

// ---------------------------------------------------------------------------
// Hook: TDAnalytics.GetDeviceId() -> string  (verbose)
// ---------------------------------------------------------------------------
typedef void *(*TDGetDeviceId_t)(void);
static TDGetDeviceId_t orig_TDGetDeviceId __attribute__((unused)) = NULL;

void *HookTDGetDeviceId(void) {
    void *result = KIOU_CALL_ORIG_RET(void *, orig_TDGetDeviceId);
    NSString *s = readIl2CppString(result);
    IPALog([NSString stringWithFormat:@"[ACCOUNT] TDAnalytics.GetDeviceId() → %@",
              s ?: @"(nil)"]);
    return result;
}

// ---------------------------------------------------------------------------
// Hook: GameService.<GetSelfUserProfileAsync>d__36.MoveNext
//   Captures the SelfUserProfileStatus (UserName, OpenUserId, rank list)
//   whenever GetSelfUserProfileAsync completes — invoked by KIOU itself
//   when the user opens the home/profile page.
// ---------------------------------------------------------------------------
static MoveNextVoid_t orig_GetSelfProfileMoveNext __attribute__((unused)) = NULL;



static const char *rankLabel(int32_t rank) {
    // dump.cs line 511935+ — ShogiPlayerRankType: 10Kyu=2 ... 9Dan
    if (rank < 2) return "?";
    static const char *labels[] = {
        "10Kyu","9Kyu","8Kyu","7Kyu","6Kyu","5Kyu","4Kyu","3Kyu","2Kyu","1Kyu",
        "1Dan","2Dan","3Dan","4Dan","5Dan","6Dan","7Dan","8Dan","9Dan",
    };
    int idx = rank - 2;
    if (idx < 0 || idx >= (int)(sizeof(labels)/sizeof(labels[0]))) return "?";
    return labels[idx];
}

// Shared body for both the JB trampoline and the chinlan entry hook.
// Caller is responsible for advancing orig first.
static void observeGetSelfProfileCompletion(void *self) {
    if (!self) return;
    int32_t smState = readI32(self, 0x00);
    if (smState != -2) return;

    // Scan candidate offsets where the IGetSelfUserProfileReply* could live.
    for (uintptr_t off = 0x30; off <= 0x60; off += 0x08) {
        void *reply = readPtr(self, off);
        if (!reply) continue;
        void *profile = readPtr(reply, OFF_GET_SELF_PROFILE_REPLY_PROFILE);
        if (!profile) continue;
        NSString *userName   = readIl2CppString(readPtr(profile, OFF_SELF_PROFILE_USER_NAME));
        NSString *openUserId = readIl2CppString(readPtr(profile, OFF_SELF_PROFILE_OPEN_USER_ID));
        if (userName.length == 0 && openUserId.length == 0) continue;

        IPALog([NSString stringWithFormat:
                  @"[ACCOUNT] SelfProfile @smOff=0x%lx userName=%@ openUserId=%@",
                  (unsigned long)off, userName ?: @"(nil)", openUserId ?: @"(nil)"]);

        // Walk RankList and build a serialisable array for persistence.
        // rankList_ is a reference type field — dereference the slot first
        // to get the RepeatedField object, then read its array/count fields.
        NSMutableArray<NSDictionary *> *rankDicts = [NSMutableArray array];
        void *rankListObj = readPtr(profile, OFF_SELF_PROFILE_RANK_LIST);
        void *array = readPtr(rankListObj, OFF_REPEATED_ARRAY);
        int32_t count = readI32(rankListObj, OFF_REPEATED_COUNT);
        if (array && count > 0 && count < 32) {
            for (int32_t i = 0; i < count; i++) {
                void *entry = *(void **)((uint8_t *)array + 0x20 + i * 8);
                if (!entry) continue;
                int32_t matchType = readI32(entry, OFF_RANK_STATUS_MATCH_TYPE);
                int32_t ruleType  = readI32(entry, OFF_RANK_STATUS_RANK_RULE_TYPE);
                int32_t rank      = readI32(entry, OFF_RANK_STATUS_RANK);
                int32_t rating    = readI32(entry, OFF_RANK_STATUS_RATING);
                IPALog([NSString stringWithFormat:
                          @"[ACCOUNT]   rank[%d] matchType=%d ruleType=%d "
                          @"rank=%d(%s) rating=%d",
                          (int)i, (int)matchType, (int)ruleType,
                          (int)rank, rankLabel(rank), (int)rating]);
                [rankDicts addObject:@{
                    @"matchType": @(matchType),
                    @"ruleType":  @(ruleType),
                    @"rank":      @(rank),
                    @"rankLabel": @(rankLabel(rank)),
                    @"rating":    @(rating),
                }];
            }
        } else {
            IPALog([NSString stringWithFormat:
                      @"[ACCOUNT]   rankList count=%d array=%p (skip)",
                      (int)count, array]);
        }

        // Persist profile into the account entry keyed by the active userId.
        NSString *activeUserId = KEBActiveAccountUserId();
        if (activeUserId.length > 0) {
            KEBUpdateAccountProfile(activeUserId, openUserId, rankDicts);
        }

        return;
    }
}

void HookGetSelfProfileMoveNext(void *self) {
    KIOU_CALL_ORIG_VOID(orig_GetSelfProfileMoveNext, self);
    observeGetSelfProfileCompletion(self);
}

#if KIOU_CHINLAN
// Chinlan entry-cave hook. Same shape as the RunLoginSeq entry hook:
// the cave hands us pristine x0 and RETs after we return, so we have to
// run orig ourselves via the per-site bypass entry before reading the
// state machine fields the observation body needs.
void HookGetSelfProfileMoveNextEntry(void *self) {
    MoveNextVoid_t bypass = (MoveNextVoid_t)
        g_inject_entry[KIOU_BR_HOOK_GET_SELF_PROFILE_MOVENEXT];
    if (bypass) {
        @try { bypass(self); }
        @catch (NSException *e) {
            IPALog([NSString stringWithFormat:
                      @"[ACCOUNT] GetSelfProfile.MoveNext chinlan bypass "
                      @"threw: %@", e]);
            return;
        }
    } else {
        IPALog(@"[ACCOUNT] GetSelfProfile.MoveNext chinlan bypass not "
                 @"published — skipping observation");
        return;
    }
    observeGetSelfProfileCompletion(self);
}
#endif

// ---------------------------------------------------------------------------
// Hook: TitleMenuPopupPresenter.RunResetUserDataSequenceAsync
//   Observation only — we log entry and exit so we can correlate which
//   TDAnalytics.SetDistinctId / LoginArgs.Create calls happen as a
//   consequence of the user tapping "アカウント初期化". The currently-active
//   UUID (if any) is stashed onto the persisted account list before the
//   sequence runs so the user can switch back later.
//
// Signature: static UniTask RunResetUserDataSequenceAsync(CancellationToken ct)
//   — no self pointer, single arg.
// ---------------------------------------------------------------------------
typedef UniTaskRet (*RunResetSeq_t)(void *ct);
static RunResetSeq_t orig_RunResetSeq        __attribute__((unused)) = NULL;
static RunResetSeq_t orig_RunDeleteAccountSeq __attribute__((unused)) = NULL;

// ---------------------------------------------------------------------------
// Hook: AuthService.<LoginAsync>d__3.MoveNext — observes the raw LoginReply
//   the server returns from AuthService.LoginAsync, including failure
//   cases (e.g. -40004) that never make it to the outer
//   RunLoginSequenceAsync observer.
// ---------------------------------------------------------------------------
static MoveNextVoid_t orig_AuthSvcLoginMoveNext __attribute__((unused)) = NULL;

void HookAuthSvcLoginMoveNext(void *self) {
    KIOU_CALL_ORIG_VOID(orig_AuthSvcLoginMoveNext, self);
    if (!self) return;
    int32_t smState = readI32(self, 0x00);
    if (smState != -2) return;
    // d__3 layout (dump.cs line 580479):
    //   0x00 state, 0x08 builder, 0x20 this, 0x28 ct, 0x30 args, 0x38 awaiter
    // The reply lands at +0x50 (past the embedded UniTask<T>.Awaiter struct).
    // DON'T scan 0x38..0x48 — those bytes are the awaiter struct interior, and
    // dereferencing them as pointers can fault on garbage addresses.
    void *reply = readPtr(self, 0x50);
    if (!reply) {
        IPALog(@"[ACCOUNT] AuthSvc.LoginAsync completed but reply@0x50 is NULL (likely failure)");
        return;
    }
    NSString *accessToken = readIl2CppString(readPtr(reply, 0x18));
    if (![accessToken hasPrefix:@"eyJ"]) {
        IPALog([NSString stringWithFormat:
                  @"[ACCOUNT] AuthSvc.LoginAsync reply@0x50 not a LoginReply "
                  @"(accessToken=%@)", accessToken ?: @"(nil)"]);
        return;
    }
    NSString *sessionId = readIl2CppString(readPtr(reply, 0x20));
    NSString *deviceId  = readIl2CppString(readPtr(reply, 0x28));
    NSString *userName  = readIl2CppString(readPtr(reply, 0x30));
    IPALog([NSString stringWithFormat:
              @"[ACCOUNT] AuthSvc.LoginAsync reply "
              @"accessToken=%@ sessionId=%@ deviceId=%@ userName=%@",
              accessToken,
              sessionId ?: @"(empty)",
              deviceId  ?: @"(empty)",
              userName  ?: @"(empty)"]);
}

// ---------------------------------------------------------------------------
// Hook: AuthService.<RegisterUserAsync>d__4.MoveNext — observes the raw
//   IRegisterUserReply the server returns from RegisterUserAsync. Lets us
//   confirm exactly which DeviceId the server assigned to the freshly
//   registered account, plus the OpenUserId / UserId.
// ---------------------------------------------------------------------------
static MoveNextVoid_t orig_AuthSvcRegisterMoveNext __attribute__((unused)) = NULL;

void HookAuthSvcRegisterMoveNext(void *self) {
    KIOU_CALL_ORIG_VOID(orig_AuthSvcRegisterMoveNext, self);
    if (!self) return;
    int32_t smState = readI32(self, 0x00);
    if (smState != -2) return;
    // d__4 layout (dump.cs line 580501): mirrors d__3 — reply lands at +0x50.
    // RegisterUserReply layout (dump.cs line 513813):
    //   userId_              string  0x18
    //   deviceId_            string  0x20
    //   openUserId_          string  0x28
    //   nameValidationResult int32   0x30
    void *reply = readPtr(self, 0x50);
    if (!reply) {
        IPALog(@"[ACCOUNT] AuthSvc.RegisterUserAsync completed but reply@0x50 is NULL");
        return;
    }
    NSString *openUserId = readIl2CppString(readPtr(reply, 0x28));
    // openUserId is "XXXX-YYYY-ZZZZ-WWWW" — 19 chars split into 4 segments by '-'.
    if (openUserId.length < 10 ||
        [[openUserId componentsSeparatedByString:@"-"] count] != 4) {
        IPALog([NSString stringWithFormat:
                  @"[ACCOUNT] AuthSvc.RegisterUserAsync reply@0x50 openUserId "
                  @"shape mismatch (got=%@)", openUserId ?: @"(nil)"]);
        return;
    }
    NSString *userId   = readIl2CppString(readPtr(reply, 0x18));
    NSString *deviceId = readIl2CppString(readPtr(reply, 0x20));
    int32_t nameValidation = readI32(reply, 0x30);
    IPALog([NSString stringWithFormat:
              @"[ACCOUNT] AuthSvc.RegisterUserAsync reply "
              @"userId=%@ deviceId=%@ openUserId=%@ nameValidation=%d",
              userId     ?: @"(empty)",
              deviceId   ?: @"(empty)",
              openUserId,
              (int)nameValidation]);
}

UniTaskRet HookRunResetUserDataSeq(void *ct) {
    NSString *activeUserId = KEBActiveAccountUserId();

    // Generate a fresh distinctId for the upcoming Register flow. Without
    // this, the post-Reset Register would re-use the TDAnalytics keychain
    // distinctId — and the server would overwrite whichever account was
    // already bound to that distinctId. By arming a new UUID,
    // HookRegisterUserArgsCreate swaps it into RegisterUserArgs.distinctId,
    // so the server allocates a brand-new account paired with this UUID
    // (which becomes the new account's deviceId for future switches).
    NSString *freshUuid = [[NSUUID UUID] UUIDString].lowercaseString;
    KEBSetPendingDistinctId(freshUuid);
    // Arm pending_device_id too so the post-Register auto-Login's
    // LoginArgs.deviceId is swapped to the same UUID. Without this KIOU
    // would auto-Login with the original TDAnalytics distinctId, which
    // points to a different (or no) server account.
    KEBSetPendingDeviceId(freshUuid);

    IPALog([NSString stringWithFormat:
              @"[ACCOUNT] RunResetUserDataSequenceAsync entered (active=%@), "
              @"armed fresh_uuid=%@ for next Register + auto-Login",
              activeUserId ?: @"(none)", freshUuid]);
    return KIOU_CALL_ORIG_RET(UniTaskRet, orig_RunResetSeq, ct);
}

UniTaskRet HookRunDeleteAccountSeq(void *ct) {
    NSString *activeUserId = KEBActiveAccountUserId();
    IPALog([NSString stringWithFormat:
              @"[ACCOUNT] RunDeleteAccountSequenceAsync entered "
              @"(active=%@)", activeUserId ?: @"(none)"]);
    return KIOU_CALL_ORIG_RET(UniTaskRet, orig_RunDeleteAccountSeq, ct);
}

// ---------------------------------------------------------------------------
// Hook: UserSaveDataExtensions.AccountExists(UserSaveData data) -> bool
//
// Returns true iff the boot sequence should call RunLoginSequenceAsync;
// false routes the title scene into RunRegisterUserSequenceAsync (the
// name-entry UI). We log the original return value AND the relevant
// UserSaveData fields so we can see what KIOU's own judgement was, then
// override the result to false to force the register flow.
// ---------------------------------------------------------------------------
typedef bool (*AccountExists_t)(void *data);
static AccountExists_t orig_AccountExists __attribute__((unused)) = NULL;

// Read UserSaveData and persist the resulting account row. Shared between the
// JB hook (HookAccountExists) and the chinlan cave observer
// (HookAccountExistsObserve). Idempotent — KEBSaveAccount merges by userId.
//
// Captures the openId / userId fan-out into g_latestObservedOpenId /
// g_latestObservedUserId so the post-Login LoginReply observer can correlate
// them with the JWT.sub when it later populates accessToken metadata.
static void observeAccountExistsData(void *data) {
    if (!data) return;
    NSString *userName = readIl2CppString(readPtr(data, OFF_USER_SAVE_DATA_USER_NAME));
    NSString *openId   = readIl2CppString(readPtr(data, OFF_USER_SAVE_DATA_OPEN_ID));
    NSString *userId   = readIl2CppString(readPtr(data, OFF_USER_SAVE_DATA_USER_ID));
    NSString *deviceId = readIl2CppString(readPtr(data, OFF_USER_SAVE_DATA_DEVICE_ID));

    if (openId.length > 0) g_latestObservedOpenId = openId;
    if (userId.length > 0) g_latestObservedUserId = userId;

    // Persist the currently-active account into accounts.json the moment
    // KIOU consults AccountExists. Without this, a fresh tweak install on a
    // device that's already logged in would not record that account until
    // the user happens to trigger a fresh Login — and on chinlan, where the
    // LoginReply hook can't run at all, that account would never appear.
    if (userId.length > 0 && deviceId.length > 0) {
        KEBSaveAccount(deviceId, userName, openId, userId, deviceId);
        // Don't overwrite the active selection if it's already set — the
        // user may have switched manually since the last boot.
        if (KEBActiveAccountUserId().length == 0) {
            KEBSetActiveAccountUserId(userId);
        }
    }
}

// Shared body for the JB hook and the chinlan entry hook.
// Force-Register flag: when set (via Settings UI), return false so KIOU
// routes the title scene into RunRegisterUserSequenceAsync. Combined
// with the pending_distinct_id armed by the same toggle, the user can
// create a new account WITHOUT going through RunResetUserDataSequenceAsync
// — which appears to trigger server-side rebinding that orphans the
// previous account.
//
// The flag is NOT cleared here. KIOU calls AccountExists multiple times
// during boot — clearing on first read would let the second call drop
// back to Login flow. The flag is consumed in HookRunLoginSeqMoveNext
// once the post-Register auto-Login has succeeded.
static bool accountExistsBody(void *data, bool origResult, const char *flavor) {
    NSString *userName = nil, *openId = nil, *userId = nil, *deviceId = nil;
    if (data) {
        userName = readIl2CppString(readPtr(data, OFF_USER_SAVE_DATA_USER_NAME));
        openId   = readIl2CppString(readPtr(data, OFF_USER_SAVE_DATA_OPEN_ID));
        userId   = readIl2CppString(readPtr(data, OFF_USER_SAVE_DATA_USER_ID));
        deviceId = readIl2CppString(readPtr(data, OFF_USER_SAVE_DATA_DEVICE_ID));
    }
    observeAccountExistsData(data);

    bool forceRegister = KEBForceRegisterOnNextLaunch();
    bool result = forceRegister ? false : origResult;

    IPALog([NSString stringWithFormat:
              @"[ACCOUNT] AccountExists (%s) orig=%s force=%s returned=%s "
              @"userName=%@ openId=%@ userId=%@ deviceId=%@",
              flavor,
              origResult ? "true" : "false",
              forceRegister ? "true" : "false",
              result ? "true" : "false",
              userName ?: @"(empty)", openId ?: @"(empty)",
              userId ?: @"(empty)", deviceId ?: @"(empty)"]);
    return result;
}

bool HookAccountExists(void *data) {
    bool origResult = false;
    @try {
        origResult = KIOU_CALL_ORIG_RET(bool, orig_AccountExists, data);
    } @catch (NSException *e) {
        IPALog([NSString stringWithFormat:@"[ACCOUNT] AccountExists orig threw: %@", e]);
    }
    return accountExistsBody(data, origResult, "jb");
}

// Chinlan entry-cave hook. The cave does NOT run orig; we have to invoke it
// ourselves through the per-site bypass entry (cave_va + 0x4C, published into
// g_inject_entry by KEBBridgeChinlanPublish) and feed its return into the
// shared body. Returning a bool here propagates to the caller because the
// entry cave's tail is RET — the cave never overwrites x0.
#if KIOU_CHINLAN
bool HookAccountExistsEntry(void *data) {
    bool origResult = false;
    AccountExists_t bypass =
        (AccountExists_t)g_inject_entry[KIOU_BR_HOOK_ACCOUNT_EXISTS];
    if (bypass) {
        @try {
            origResult = bypass(data);
        } @catch (NSException *e) {
            IPALog([NSString stringWithFormat:
                      @"[ACCOUNT] AccountExists chinlan bypass threw: %@", e]);
        }
    } else {
        IPALog(@"[ACCOUNT] AccountExists chinlan bypass entry not published — "
                 @"returning false; KIOU will route into the Register flow");
    }
    return accountExistsBody(data, origResult, "chinlan");
}
#endif

// ---------------------------------------------------------------------------
// Account switching — calls TDAnalytics.SetDistinctId with a fresh il2cpp
// string so the next login uses the supplied UUID.
//
// We don't construct an il2cpp string from C — instead we reuse one already
// observed flowing through the hooks. In practice: stash the most recent
// `appId` arg we saw on TDAnalytics.SetDistinctId / GetDistinctId (which is
// always the empty string in this game), then use SystemInfo's deviceId
// path's il2cpp string allocator. Easier: pass NSString through il2cpp's
// "managed string from UTF-16" path using the cached SetDistinctId entry
// point — but the simplest reliable shortcut is to keep a copy of the last
// il2cpp string we saw and overwrite its char buffer in place. That's too
// risky.
//
// The robust path: call mono_string_new / il2cpp_string_new. The symbol
// `il2cpp_string_new` is exported by UnityFramework.
// ---------------------------------------------------------------------------
// Cached SetDistinctId entry pointer (orig trampoline on JB / direct RVA on
// chinlan) — used by KEBSwitchAccount.
static TDSetDistinctId_t g_setDistinctIdEntry __attribute__((unused)) = NULL;

void KEBSwitchAccount(NSString *uuid) {
    // If a fresh UUID is currently armed for a Register flow (set by
    // HookRunResetUserDataSeq), refuse to override it. Otherwise Switch
    // tapped between Reset and the Register UI would clear the fresh UUID,
    // and the subsequent Register would re-use the original TDAnalytics
    // distinctId — which rebinds the server's mapping and clobbers
    // whichever account is currently keyed by it.
    NSString *armedDistinct = KEBPendingDistinctId();
    if (armedDistinct.length > 0) {
        IPALog([NSString stringWithFormat:
                  @"[ACCOUNT] KEBSwitchAccount refused: a fresh UUID %@ is "
                  @"already armed for a Register flow. Complete or cancel "
                  @"that Register first.", armedDistinct]);
        return;
    }
    // Arm the deviceId substitution. Next LoginArgs.Create call sees this
    // value in pending_device_id and swaps the deviceId arg accordingly.
    // distinctId is intentionally untouched — the server keys LoginAsync by
    // the deviceId arg, and overriding distinctId historically caused
    // -40004 (TDAnalytics keychain path vs LoginArgs path mismatch).
    KEBSetPendingDeviceId(uuid);
    IPALog([NSString stringWithFormat:
              @"[ACCOUNT] KEBSwitchAccount: pending_device_id=%@ "
              @"(relaunch app to log in as that account)", uuid ?: @"(nil)"]);
}

// ---------------------------------------------------------------------------
// Installer
// ---------------------------------------------------------------------------
#if !KIOU_CHINLAN
void InstallAccountObserveHook(uintptr_t unityBase) {

    // Resolve il2cpp_string_new from UnityFramework so HookLoginArgsCreate
    // can build managed strings for deviceId substitution.
    if (!g_il2cpp_string_new) {
        g_il2cpp_string_new = (Il2CppStringNew_t)dlsym(RTLD_DEFAULT,
                                                       "il2cpp_string_new");
        IPALog([NSString stringWithFormat:
                  @"[ACCOUNT] il2cpp_string_new=%p", g_il2cpp_string_new]);
    }

    struct { const char *tag; uintptr_t rva; void *hook; void **origSlot; } entries[] = {
        { "ILoginArgs.Create",
          RVA_LOGIN_ARGS_CREATE,
          (void *)HookLoginArgsCreate,
          (void **)&orig_LoginArgsCreate },
        { "RunLoginSequenceAsync.MoveNext",
          RVA_RUN_LOGIN_SEQ_MOVENEXT,
          (void *)HookRunLoginSeqMoveNext,
          (void **)&orig_RunLoginSeqMoveNext },
        { "SystemInfo.deviceUniqueIdentifier",
          RVA_SYSTEMINFO_DEVICE_UNIQUE_ID,
          (void *)HookGetDeviceUniqueId,
          (void **)&orig_GetDeviceUniqueId },
        { "TDAnalytics.GetDistinctId",
          RVA_TD_GET_DISTINCT_ID,
          (void *)HookTDGetDistinctId,
          (void **)&orig_TDGetDistinctId },
        { "TDAnalytics.SetDistinctId",
          RVA_TD_SET_DISTINCT_ID,
          (void *)HookTDSetDistinctId,
          (void **)&orig_TDSetDistinctId },
        { "TDAnalytics.GetDeviceId",
          RVA_TD_GET_DEVICE_ID,
          (void *)HookTDGetDeviceId,
          (void **)&orig_TDGetDeviceId },
        { "GetSelfUserProfileAsync.MoveNext",
          RVA_GET_SELF_PROFILE_MOVENEXT,
          (void *)HookGetSelfProfileMoveNext,
          (void **)&orig_GetSelfProfileMoveNext },
        { "RunResetUserDataSequenceAsync",
          RVA_RUN_RESET_USER_DATA_SEQ,
          (void *)HookRunResetUserDataSeq,
          (void **)&orig_RunResetSeq },
        { "RunDeleteAccountSequenceAsync",
          RVA_RUN_DELETE_ACCOUNT_SEQ,
          (void *)HookRunDeleteAccountSeq,
          (void **)&orig_RunDeleteAccountSeq },
        { "UserSaveDataExtensions.AccountExists",
          RVA_ACCOUNT_EXISTS,
          (void *)HookAccountExists,
          (void **)&orig_AccountExists },
        { "IRegisterUserArgs.Create",
          RVA_REGISTER_USER_ARGS_CREATE,
          (void *)HookRegisterUserArgsCreate,
          (void **)&orig_RegisterUserArgsCreate },
        { "AuthService.LoginAsync.MoveNext",
          RVA_AUTHSVC_LOGIN_MOVENEXT,
          (void *)HookAuthSvcLoginMoveNext,
          (void **)&orig_AuthSvcLoginMoveNext },
        { "AuthService.RegisterUserAsync.MoveNext",
          RVA_AUTHSVC_REGISTER_MOVENEXT,
          (void *)HookAuthSvcRegisterMoveNext,
          (void **)&orig_AuthSvcRegisterMoveNext },
    };

    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        uintptr_t addr = unityBase + entries[i].rva;
        MSHookFunction((void *)addr, entries[i].hook, entries[i].origSlot);
        IPALog([NSString stringWithFormat:
                  @"[ACCOUNT] hooked %s @0x%lx (base+0x%lx)",
                  entries[i].tag,
                  (unsigned long)addr,
                  (unsigned long)entries[i].rva]);
    }
    IPALog(@"[ACCOUNT] observation hooks installed");
}
#else
void InstallAccountObserveHook(uintptr_t unityBase) {
    (void)unityBase;
    // On chinlan, the cave at the AccountExists site routes through the
    // dispatcher to HookAccountExistsObserve. The other account-related
    // hooks (LoginReply / Register reply / TDAnalytics / etc.) are inherently
    // post-orig observations that the static cave model can't express, so
    // they stay JB-only. We still resolve il2cpp_string_new here in case a
    // future cave-side hook needs to allocate a managed string.
    if (!g_il2cpp_string_new) {
        g_il2cpp_string_new = (Il2CppStringNew_t)dlsym(RTLD_DEFAULT,
                                                       "il2cpp_string_new");
        IPALog([NSString stringWithFormat:
                  @"[ACCOUNT] chinlan: il2cpp_string_new=%p", g_il2cpp_string_new]);
    }
    IPALog(@"[ACCOUNT] chinlan: AccountExists observer wired via cave; "
             @"LoginReply / Register / TDAnalytics hooks are JB-only");
}
#endif // !KIOU_CHINLAN
