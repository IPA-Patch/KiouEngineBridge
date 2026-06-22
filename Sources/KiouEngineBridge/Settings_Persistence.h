#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>

// ===========================================================================
// Settings_Persistence.h — KiouEngineBridge user-configurable settings.
//
// Thin NSUserDefaults accessor layer, modelled on KiouForge's Persistence.m.
// All keys are prefixed with "kiou_bridge." to avoid conflicts.
// Getters return a sane default when the key is absent so the tweak behaves
// reasonably on first launch without any user interaction.
//
// Consumers read settings at call-site time (stateless pull model — no
// observers). The UI layer (Settings_UI.m) writes through these setters.
// ===========================================================================

// ---------------------------------------------------------------------------
// Auto-rematch
// ---------------------------------------------------------------------------

// Whether to automatically start the next match after the current one ends.
// Default: true (preserves the existing always-on behaviour).
bool    KEBAutoRematchEnabled(void);
void    KEBSetAutoRematchEnabled(bool enabled);

// Seconds to wait before dismissing the result overlay (step 1 of rematch).
// The actual next-match kick fires at rematchStep1Sec + rematchStep2Sec.
// Default: 3.5s  Range: 0–30s
float   KEBRematchStep1Sec(void);
void    KEBSetRematchStep1Sec(float sec);

// Additional seconds after step 1 before calling StartCpuFreeMatchAsync /
// StartRankMatchingAsync (step 2 of rematch).
// Default: 2.0s  Range: 0–30s
float   KEBRematchStep2Sec(void);
void    KEBSetRematchStep2Sec(float sec);

// ---------------------------------------------------------------------------
// Resign
// ---------------------------------------------------------------------------

// Whether %TORYO skips the "投了しますか？" confirmation dialog.
// true  → SurrenderAsync (immediate, no dialog)   ← default
// false → RequestSurrender (shows confirmation dialog)
bool    KEBResignSkipDialog(void);
void    KEBSetResignSkipDialog(bool skip);

// ---------------------------------------------------------------------------
// Matching filter
// ---------------------------------------------------------------------------

// Which seat the client is willing to accept on a MatchFound reply.
// Any other seat is rejected by sending ConnectionFailed; the matching loop
// then requeues automatically.
//
// NOTE: Restricting the accepted seat is for debugging / testing only —
// unsportsmanlike for production use.
typedef NS_ENUM(int32_t, KEBAcceptedSeat) {
    KEBAcceptedSeatBoth  = 0,  // accept any seat — no filter
    KEBAcceptedSeatBlack = 1,  // accept only first-player (sente) matches
    KEBAcceptedSeatWhite = 2,  // accept only second-player (gote) matches
};

KEBAcceptedSeat KEBAcceptedSeatGet(void);
void            KEBAcceptedSeatSet(KEBAcceptedSeat seat);

// When non-zero, the client sends LeaveQueue+JoinQueue whenever the server
// reports CurrentRateRange > this value, keeping the search range tight.
// 0 = disabled (let the server expand freely).
// Default: 0  Range: 0–2000  Step: 50
int32_t KEBFixedRateRange(void);
void    KEBSetFixedRateRange(int32_t range);

// ---------------------------------------------------------------------------
// Accounts
//
// Each KIOU account is identified by a single UUID — the value the game
// passes as both DeviceId and DistinctId to LoginAsync, and that
// TDAnalytics.SetDistinctId restores on launch. Persisting that UUID +
// the server-supplied UserName is enough to switch back to the account
// at any time on the same device (the server reissues AccessToken /
// SessionId per login).
//
// Storage layout (NSUserDefaults under "kiou_bridge.accounts"):
//   NSArray<NSDictionary> — each entry has:
//     uuid:     NSString   (distinctId, primary key)
//     userName: NSString
//     savedAt:  NSNumber   (UNIX seconds, last refresh)
//
// "kiou_bridge.active_account" stores the UUID of whichever account most
// recently passed through LoginReply.
// ---------------------------------------------------------------------------

// Notification posted whenever the saved-account list, the active account,
// or a pending override changes. Observers (Settings UI) reload from
// KEBListAccounts / KEBActiveAccountOpenId on receipt. Posted on whichever
// thread the change happened on — observers should dispatch the reload to
// the main queue themselves.
extern NSString * const KEBAccountStateChangedNotification;

// Save or refresh an account. The primary key is `userId` (server-issued
// ULID, also delivered as JWT.sub on the access token). Other fields are
// best-effort metadata for display:
//   - `uuid`       = LoginReply.deviceId (used as the LoginArgs.deviceId
//                    substitution target when switching accounts)
//   - `openId`     = displayable XXXX-YYYY-ZZZZ-WWWW id
//   - `distinctId` = analytics distinctId sent on Register
//   - `userName`   = display name
// Nil values are stored as empty strings. Existing entries keyed by the
// same `userId` are updated in place; new ones are appended.
void KEBSaveAccount(NSString *uuid,
                    NSString *userName,
                    NSString *openId,
                    NSString *userId,
                    NSString *distinctId);

// Return the saved accounts in insertion order. Each element is a
// dictionary with keys @"uuid", @"userName", @"openId", @"userId",
// @"distinctId", @"savedAt", and optionally @"ranks".
NSArray<NSDictionary *> *KEBListAccounts(void);

// Delete an account by userId. No-op if not found.
void     KEBDeleteAccount(NSString *userId);

// Merge profile data (openId, ranks) into the saved entry for userId.
// `ranks` is an NSArray of NSDictionary, each with keys:
//   matchType (NSNumber), ruleType (NSNumber), rank (NSNumber),
//   rankLabel (NSString), rating (NSNumber).
// No-op if userId is not found in the saved list.
void KEBUpdateAccountProfile(NSString *userId,
                             NSString *openId,
                             NSArray<NSDictionary *> *ranks);

// Most recently observed active account userId (set whenever a LoginReply
// arrives). Returns nil if no qualifying login has been observed yet.
NSString *KEBActiveAccountUserId(void);
void      KEBSetActiveAccountUserId(NSString *userId);

// When YES, the next AccountExists check at boot returns false unconditionally,
// forcing KIOU into the RegisterUserSequenceAsync (name-entry UI) path. The
// flag is cleared automatically when the next LoginReply is observed, so
// "tap reset → relaunch → enter name → register" lights up exactly one
// register flow then reverts to normal login behaviour.
bool KEBForceRegisterOnNextLaunch(void);
void KEBSetForceRegisterOnNextLaunch(bool enabled);

// Pending (deviceId, distinctId) override to apply on the next
// LoginArgs.Create / RegisterUserArgs.Create call:
//   - `pending_device_id` rewrites the LoginArgs.Create deviceId arg so the
//     server returns the chosen account.
//   - `pending_distinct_id` rewrites the LoginArgs.Create distinctId AND
//     the RegisterUserArgs.Create distinctId, so the server pairs this
//     login/register with a specific "terminal" identifier instead of the
//     TDAnalytics Keychain one.
// Together they let us simulate "a different terminal logging in with a
// previously-registered account" or "a new terminal registering a new
// account". Both fields are cleared once the next LoginReply lands.
NSString *KEBPendingDeviceId(void);
void      KEBSetPendingDeviceId(NSString *uuid);
NSString *KEBPendingDistinctId(void);
void      KEBSetPendingDistinctId(NSString *uuid);

// ---------------------------------------------------------------------------
// CSA server
// ---------------------------------------------------------------------------

// TCP port the CSA server listens on. Applied at next app launch — changing
// this while the server is already running has no effect until restart.
// Default: 4081  Range: 1024–65535
uint16_t KEBCsaPort(void);
void     KEBSetCsaPort(uint16_t port);

