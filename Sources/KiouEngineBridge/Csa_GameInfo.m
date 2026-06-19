#import "Internal.h"
#import "Csa_Convert.h"
#import "Csa_Engine.h"

#import <math.h>
#import <mach/mach_time.h>

// ===========================================================================
// Csa_GameInfo — KIOU MatchConfig / GameStateStore -> CSA `Game_Summary`
// block + `#WIN`/`#LOSE`/`#DRAW` result block.
//
// Reads the same MatchConfig / PlayerInfo / TimeControlConfig fields the
// (now-deprecated) Meta_Emitter.m walked; the offsets and string helpers
// are duplicated here verbatim so this file can own the CSA wire format
// without depending on Meta_Emitter's JSON helpers. Once Task 5 fully
// migrates the Online race-resolution path the legacy meta path is
// retired in a follow-up commit.
//
// All il2cpp reads happen on whichever thread the caller is on; the field
// accesses below only touch raw memory via the inline il2cpp helpers, so
// they're safe to invoke from the OnMatchStart dispatch_async block.
// ===========================================================================

// ---------------------------------------------------------------------------
// State.
//
// MatchConfig pointer captured by Hook_MatchModeObserve.m's Init macro.
// Online player-info pointers captured by Hook_GameStateStoreObserve.m's
// Set*PlayerInfo hooks (matchmaking resolves the opponent identity after
// InitializeAsync runs). All three are cleared on match end.
// ---------------------------------------------------------------------------
static void *volatile g_csaMatchConfig = NULL;
static void *volatile g_csaLatestBlackPlayerInfo = NULL;
static void *volatile g_csaLatestWhitePlayerInfo = NULL;

// ---------------------------------------------------------------------------
// Field offsets — kept in sync with Meta_Emitter.m's META_OFF_* defines.
// ---------------------------------------------------------------------------
#define CSA_OFF_MATCHCONFIG_MODE            0x10  // MatchMode (int32)
#define CSA_OFF_MATCHCONFIG_BLACK_PLAYER    0x18  // PlayerInfo*
#define CSA_OFF_MATCHCONFIG_WHITE_PLAYER    0x20  // PlayerInfo*
#define CSA_OFF_MATCHCONFIG_TIME_CONTROL    0x28  // TimeControlConfig*
#define CSA_OFF_MATCHCONFIG_START_POSITION  0x50  // InitialPositionType (int32)

#define CSA_OFF_PLAYERINFO_USER_ID          0x10  // string
#define CSA_OFF_PLAYERINFO_NAME             0x18  // string
#define CSA_OFF_PLAYERINFO_RANK             0x20  // string
#define CSA_OFF_PLAYERINFO_RATE             0x2C  // int32

#define CSA_OFF_TIMECONTROL_MAIN_SECONDS    0x10  // float
#define CSA_OFF_TIMECONTROL_BYOYOMI         0x14  // float
#define CSA_OFF_TIMECONTROL_INCREMENT       0x18  // float

// ---------------------------------------------------------------------------
// Enum helpers.
// ---------------------------------------------------------------------------
static NSString *csa_matchModeName(int32_t v) {
    switch (v) {
        case 0:  return @"VsAI";
        case 1:  return @"LocalPvP";
        case 2:  return @"OnlinePvP";
        case 3:  return @"RecordReplay";
        case 4:  return @"Spectate";
        default: return [NSString stringWithFormat:@"Unknown(%d)", (int)v];
    }
}

static NSString *csa_initialPositionName(int32_t v) {
    switch (v) {
        case 0:  return @"Standard";
        case 1:  return @"Empty";
        case 2:  return @"HandicapLance";
        case 3:  return @"HandicapRightLance";
        case 4:  return @"HandicapBishop";
        case 5:  return @"HandicapRook";
        case 6:  return @"HandicapRookLance";
        case 7:  return @"Handicap2Pieces";
        case 8:  return @"Handicap4Pieces";
        case 9:  return @"Handicap6Pieces";
        case 10: return @"Handicap8Pieces";
        case 11: return @"Handicap10Pieces";
        case 12: return @"TsumeShogi";
        case 13: return @"TsumeShogi2Kings";
        default: return [NSString stringWithFormat:@"Unknown(%d)", (int)v];
    }
}

// ---------------------------------------------------------------------------
// ISO 8601 helpers + Game_ID derivation.
// ---------------------------------------------------------------------------
static NSString *csa_iso8601_now(void) {
    static NSISO8601DateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSISO8601DateFormatter alloc] init];
        fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [fmt stringFromDate:[NSDate date]];
}

// Compact timestamp suitable for embedding in a Game_ID.
static NSString *csa_compactTimestamp(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyyMMdd'T'HHmmss";
        fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return [fmt stringFromDate:[NSDate date]];
}

// ---------------------------------------------------------------------------
// External entry points used by Hook_MatchModeObserve.m and
// Hook_GameStateStoreObserve.m. These mirror the MetaSetMatchConfig /
// MetaOnPlayerInfoSet API surface but feed Csa_GameInfo's own state cache.
// ---------------------------------------------------------------------------
void CsaSetMatchConfig(void *cfg) {
    g_csaMatchConfig = cfg;
    if (!cfg) {
        // Match teardown: drop the per-match player-info pointers so the
        // next match doesn't inherit a stale opponent identity.
        g_csaLatestBlackPlayerInfo = NULL;
        g_csaLatestWhitePlayerInfo = NULL;
    }
}

void CsaOnPlayerInfoSet(int32_t side, void *playerInfo) {
    if (!playerInfo) return;
    if (side == 0) {
        g_csaLatestBlackPlayerInfo = playerInfo;
    } else if (side == 1) {
        g_csaLatestWhitePlayerInfo = playerInfo;
    }
}

// ---------------------------------------------------------------------------
// PlayerInfo + TimeControl readers — emit zero/empty defaults rather than
// throwing on a null pointer.
// ---------------------------------------------------------------------------
typedef struct {
    NSString *name;
    NSString *rank;
    NSString *userId;
    int32_t rate;
} csa_player_info_t;

static csa_player_info_t csa_readPlayerInfo(void *playerInfo) {
    csa_player_info_t out = {nil, nil, nil, 0};
    if (!playerInfo) return out;
    out.name   = il2cppStringToNSString(readPtr(playerInfo,
                                                CSA_OFF_PLAYERINFO_NAME));
    out.rank   = il2cppStringToNSString(readPtr(playerInfo,
                                                CSA_OFF_PLAYERINFO_RANK));
    out.userId = il2cppStringToNSString(readPtr(playerInfo,
                                                CSA_OFF_PLAYERINFO_USER_ID));
    out.rate   = readI32(playerInfo, CSA_OFF_PLAYERINFO_RATE);
    return out;
}

typedef struct {
    int32_t main_seconds;
    int32_t byoyomi;
    int32_t increment;
} csa_time_control_t;

static csa_time_control_t csa_readTimeControl(void *tcc) {
    csa_time_control_t out = {0, 0, 0};
    if (!tcc) return out;
    float main = 0, byo = 0, inc = 0;
    @try {
        main = *(const float *)((const uint8_t *)tcc +
                                CSA_OFF_TIMECONTROL_MAIN_SECONDS);
        byo  = *(const float *)((const uint8_t *)tcc +
                                CSA_OFF_TIMECONTROL_BYOYOMI);
        inc  = *(const float *)((const uint8_t *)tcc +
                                CSA_OFF_TIMECONTROL_INCREMENT);
    } @catch (NSException *e) {
        return out;
    }
    out.main_seconds = (int32_t)main;
    out.byoyomi      = (int32_t)byo;
    out.increment    = (int32_t)inc;
    atomic_store(&g_csaByoyomiMs, (out.byoyomi >= 0) ? out.byoyomi * 1000 : -1);
    atomic_store(&g_csaTotalTimeMs, (out.main_seconds >= 0) ? (int64_t)out.main_seconds * 1000 : -1);
    return out;
}

// ---------------------------------------------------------------------------
// `Game_Summary` builder. Mode names follow the dump.cs enum (csa_matchModeName);
// every CSA-standard field is required; KIOU_* extensions sit between the
// position block and END Game_Summary so a strict CSA parser ignores them.
// ---------------------------------------------------------------------------
NSString *CsaBuildGameSummary(int32_t local_player,
                              NSString **outGameId,
                              NSString **outStartSfen) {
    void *cfg = g_csaMatchConfig;
    if (!cfg) {
        // No MatchConfig — without it we cannot construct a meaningful
        // Game_Summary. Return nil so Csa_Engine knows to wait for a real
        // OnMatchStart before sending anything.
        return nil;
    }

    int32_t mode     = readI32(cfg, CSA_OFF_MATCHCONFIG_MODE);
    int32_t startPos = readI32(cfg, CSA_OFF_MATCHCONFIG_START_POSITION);
    void *blackPI    = g_csaLatestBlackPlayerInfo
                           ?: readPtr(cfg, CSA_OFF_MATCHCONFIG_BLACK_PLAYER);
    void *whitePI    = g_csaLatestWhitePlayerInfo
                           ?: readPtr(cfg, CSA_OFF_MATCHCONFIG_WHITE_PLAYER);
    void *tcc        = readPtr(cfg, CSA_OFF_MATCHCONFIG_TIME_CONTROL);

    csa_player_info_t blackInfo = csa_readPlayerInfo(blackPI);
    csa_player_info_t whiteInfo = csa_readPlayerInfo(whitePI);
    csa_time_control_t tc       = csa_readTimeControl(tcc);

    NSString *gameId = [NSString stringWithFormat:@"%@-%@",
                       csa_compactTimestamp(),
                       csa_matchModeName(mode)];
    if (outGameId) *outGameId = gameId;

    NSMutableString *out = [NSMutableString stringWithCapacity:1024];
    [out appendString:@"BEGIN Game_Summary\n"];
    [out appendString:@"Protocol_Version:1.2\n"];
    [out appendString:@"Protocol_Mode:Server\n"];
    [out appendString:@"Format:Shogi 1.0\n"];
    [out appendString:@"Declaration:Jishogi 1.1\n"];
    [out appendFormat:@"Game_ID:%@\n", gameId];
    if (blackInfo.name.length > 0) {
        [out appendFormat:@"Name+:%@\n", blackInfo.name];
    }
    if (whiteInfo.name.length > 0) {
        [out appendFormat:@"Name-:%@\n", whiteInfo.name];
    }
    // your_turn / to_move. In open-seat modes local_player == -1; CSA does
    // not have a "no fixed seat" notion, so default to "+" (the engine ends
    // up controlling the black side).
    NSString *yourTurn = (local_player == 1) ? @"-" : @"+";
    [out appendFormat:@"Your_Turn:%@\n", yourTurn];
    // To_Move reflects the actual side-to-move in the current position,
    // which may be white (-) on reconnect to a mid-game position.
    // Derive from SFEN (read later); default to + for now and overwrite.
    NSString *sfenForToMove = SfenFromGameController(g_gameCtrlCache);
    NSString *toMove = @"+";
    if (sfenForToMove.length > 0) {
        NSArray<NSString *> *sfenParts = [sfenForToMove componentsSeparatedByString:@" "];
        if (sfenParts.count >= 2 && [sfenParts[1] isEqualToString:@"w"]) {
            toMove = @"-";
        }
    }
    [out appendFormat:@"To_Move:%@\n", toMove];

    [out appendString:@"BEGIN Time\n"];
    [out appendString:@"Time_Unit:1sec\n"];
    if (tc.main_seconds > 0) {
        [out appendFormat:@"Total_Time:%d\n", tc.main_seconds];
    }
    if (tc.byoyomi > 0) {
        [out appendFormat:@"Byoyomi:%d\n", tc.byoyomi];
    }
    if (tc.increment > 0) {
        [out appendFormat:@"Increment:%d\n", tc.increment];
    }
    // Remaining_Time+/- — the actual remaining clock at the moment the
    // engine reconnects. Populated from g_csaLastBlack/WhiteRemainSec which
    // is updated on every observed move. NaN means no move has been played
    // yet (or KIOU declined to surface a clock for that side), in which case
    // we omit the field so the engine falls back to Total_Time.
    float blackRemain = g_csaLastBlackRemainSec;
    float whiteRemain = g_csaLastWhiteRemainSec;
    // NaN = no clock observed yet for this side.
    //   VsAI non-local side (CPU): no-limit → 86400s.
    //   All other cases: fall back to the initial total time.
    // < 0 = no-limit sentinel (-1.0f from the hook) → 86400s.
    BOOL isVsAI = (mode == 0);
    int32_t blackNanFallback = (isVsAI && local_player != 0) ? 86400 : tc.main_seconds;
    int32_t whiteNanFallback = (isVsAI && local_player != 1) ? 86400 : tc.main_seconds;
    int32_t blackRemainSec = isnan(blackRemain) ? blackNanFallback
        : (blackRemain < 0.0f ? 86400 : (int32_t)blackRemain);
    int32_t whiteRemainSec = isnan(whiteRemain) ? whiteNanFallback
        : (whiteRemain < 0.0f ? 86400 : (int32_t)whiteRemain);
    [out appendFormat:@"Remaining_Time+:%d\n", blackRemainSec];
    [out appendFormat:@"Remaining_Time-:%d\n", whiteRemainSec];
    [out appendString:@"END Time\n"];

    [out appendString:@"BEGIN Position\n"];
    NSString *sfen = SfenFromGameController(g_gameCtrlCache);
    if (sfen.length > 0) {
        if (outStartSfen) *outStartSfen = [sfen copy];
        NSString *csaPos = CsaPositionFromSfen(sfen);
        if (csaPos.length > 0) {
            [out appendString:csaPos];
            [out appendString:@"\n"];
        }
    }
    [out appendString:@"END Position\n"];

    // KIOU_* extensions — non-standard CSA fields preserved for richer KIF
    // metadata. A strict CSA parser is required to ignore unknown keys.
    //
    // KIOU_Sfen: the raw SFEN of the starting position. Redundant with
    // BEGIN Position but lets CSA clients reconstruct the board without
    // parsing the multi-line CSA position format.
    if (sfen.length > 0) {
        [out appendFormat:@"KIOU_Sfen:%@\n", sfen];
    }
    [out appendFormat:@"KIOU_Mode:%@\n", csa_matchModeName(mode)];
    [out appendFormat:@"KIOU_StartPosition:%@\n",
                       csa_initialPositionName(startPos)];
    if (blackInfo.rank.length > 0) {
        [out appendFormat:@"KIOU_Rank+:%@\n", blackInfo.rank];
    }
    if (blackInfo.rate > 0) {
        [out appendFormat:@"KIOU_Rate+:%d\n", blackInfo.rate];
    }
    if (blackInfo.userId.length > 0) {
        [out appendFormat:@"KIOU_UserId+:%@\n", blackInfo.userId];
    }
    if (whiteInfo.rank.length > 0) {
        [out appendFormat:@"KIOU_Rank-:%@\n", whiteInfo.rank];
    }
    if (whiteInfo.rate > 0) {
        [out appendFormat:@"KIOU_Rate-:%d\n", whiteInfo.rate];
    }
    if (whiteInfo.userId.length > 0) {
        [out appendFormat:@"KIOU_UserId-:%@\n", whiteInfo.userId];
    }
    [out appendFormat:@"KIOU_StartedAt:%@\n",
                       csa_iso8601_now() ?: @""];

    [out appendString:@"END Game_Summary"];
    return out;
}

// ---------------------------------------------------------------------------
// Match result builder.
//
// CSA splits the result into a reason marker (`#RESIGN`, `#TIME_UP`,
// `#ILLEGAL_MOVE`, `#SENNICHITE`, `#JISHOGI`, ...) followed by the outcome
// (`#WIN` / `#LOSE` / `#DRAW`). KEB doesn't reliably know the reason — the
// only thing inferMatchResult() can give us is win/lose/draw/unknown — so
// we conservatively emit a generic reason and the outcome. `#WIN` / `#LOSE`
// are written from the local seat's perspective, the same way CSA's spec
// describes the broadcast to each player.
// ---------------------------------------------------------------------------
NSString *CsaBuildMatchResult(usi_match_result_t result) {
    switch (result) {
        case USI_RESULT_WIN:
            return @"#RESIGN\n#WIN";
        case USI_RESULT_LOSE:
            return @"#RESIGN\n#LOSE";
        case USI_RESULT_DRAW:
            return @"#SENNICHITE\n#DRAW";
        case USI_RESULT_UNKNOWN:
        default:
            return nil;
    }
}
