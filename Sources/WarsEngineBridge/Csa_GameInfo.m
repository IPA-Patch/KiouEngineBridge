#import "Internal.h"
#import "Csa_Convert.h"

#import <math.h>
#import <stdatomic.h>

// ===========================================================================
// Csa_GameInfo — ShogiWars GameStartJson -> CSA Game_Summary + result block.
//
// ShogiWars provides match metadata through GameStartJson (populated by
// the server's GAME_START JSON). This file reads those fields and builds
// the CSA `BEGIN Game_Summary … END Game_Summary` block.
//
// The il2cpp string and field offsets mirror Hook_GameController.m's
// defines. All reads run on the Unity main thread (the dispatch block in
// CsaEngineOnMatchStart guarantees this).
// ===========================================================================

// ---------------------------------------------------------------------------
// Offsets — must stay in sync with Hook_GameController.m.
// ---------------------------------------------------------------------------
#define OFF_GSJ_NAME             0x10
#define OFF_GSJ_GTYPE            0x18
#define OFF_GSJ_OPPONENT_TYPE    0x24
#define OFF_GSJ_INIT_POS         0x30
#define OFF_GSJ_SENTE            0x38
#define OFF_GSJ_GOTE             0x40
#define OFF_GSJ_SENTE_TIME_LIMIT 0x48
#define OFF_GSJ_GOTE_TIME_LIMIT  0x4C
#define OFF_GSJ_SENTE_BYOYOMI    0x50
#define OFF_GSJ_GOTE_BYOYOMI     0x54

#define OFF_GPJ_NAME             0x18
#define OFF_GPJ_POINTS           0x20
#define OFF_GPJ_GAME_RECORD      0x28
#define OFF_GRJ_DAN              0x14
#define OFF_GPJ_FAVSENPOU        0x38

#define IL2CPP_STRING_LENGTH_OFF 0x10
#define IL2CPP_STRING_DATA_OFF   0x14

// ---------------------------------------------------------------------------
// State.
// ---------------------------------------------------------------------------
static void *volatile g_csaGameStartJson = NULL;

// Set to true once at least one move has been observed in the current match.
// When true, CsaBuildGameSummary uses WarsLiveSfen() for the live position
// instead of init_pos. Reset to false on match end (CsaSetGameStart(nil)).
static _Atomic bool g_csaHasMoves = false;

// Remaining time cache (seconds), updated by CsaEngineOnMoveObserved.
// NaN = no move observed yet.
_Atomic float g_csaLastSenteRemainSec = NAN;
_Atomic float g_csaLastGoteRemainSec  = NAN;

// ---------------------------------------------------------------------------
// il2cpp string helper (duplicated from Hook_GameController.m to keep this
// file self-contained).
// ---------------------------------------------------------------------------
static NSString *il2cppStr(void *str) {
    if (!str) return @"";
    int32_t len = readI32(str, IL2CPP_STRING_LENGTH_OFF);
    if (len <= 0 || len > 4096) return @"";
    const unichar *chars = (const unichar *)((const uint8_t *)str
                                              + IL2CPP_STRING_DATA_OFF);
    return [NSString stringWithCharacters:chars length:(NSUInteger)len];
}

// ---------------------------------------------------------------------------
// ISO 8601 helpers.
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

static NSString *csa_compactTimestamp(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyyMMdd'T'HHmmss";
        fmt.timeZone   = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return [fmt stringFromDate:[NSDate date]];
}

// ---------------------------------------------------------------------------
// opponent_type -> mode string.
// GameModeSetting.OpponentType enum from dump.cs: 0=CPU, 1=Online, ...
// ---------------------------------------------------------------------------
static NSString *csa_modeName(int32_t opponentType) {
    switch (opponentType) {
        case 0:  return @"Practice";
        case 1:  return @"Online";
        default: return [NSString stringWithFormat:@"Unknown(%d)", (int)opponentType];
    }
}

// ---------------------------------------------------------------------------
// Public: stash GameStartJson pointer captured by Hook_GameController.m.
// ---------------------------------------------------------------------------
void CsaSetGameStart(void *gameStartJson) {
    g_csaGameStartJson = gameStartJson;
    if (!gameStartJson) {
        // Match teardown — reset time and move-history caches.
        g_csaLastSenteRemainSec = NAN;
        g_csaLastGoteRemainSec  = NAN;
        atomic_store(&g_csaHasMoves, false);
    }
}

void CsaSetMoveObserved(void) {
    bool prev = atomic_exchange(&g_csaHasMoves, true);
    if (!prev) {
        IPALog(@"[CSA-GAME] first move observed: live SFEN on next reconnect");
    }
}

// ---------------------------------------------------------------------------
// Game_Summary builder.
// ---------------------------------------------------------------------------
NSString *CsaBuildGameSummary(bool isBlack, NSString **outGameId) {
    void *gsj = g_csaGameStartJson;
    if (!gsj) return nil;

    void *sentePj  = readPtr(gsj, OFF_GSJ_SENTE);
    void *gotePj   = readPtr(gsj, OFF_GSJ_GOTE);
    int32_t oType  = readI32(gsj, OFF_GSJ_OPPONENT_TYPE);

    NSString *senteName = il2cppStr(readPtr(sentePj, OFF_GPJ_NAME));
    NSString *goteName  = il2cppStr(readPtr(gotePj,  OFF_GPJ_NAME));

    int32_t sentePoints  = sentePj ? readI32(sentePj, OFF_GPJ_POINTS) : 0;
    int32_t gotePoints   = gotePj  ? readI32(gotePj,  OFF_GPJ_POINTS) : 0;
    int32_t senteDan     = 0, goteDan = 0;
    if (sentePj) {
        void *gr = readPtr(sentePj, OFF_GPJ_GAME_RECORD);
        if (gr) senteDan = readI32(gr, OFF_GRJ_DAN);
    }
    if (gotePj) {
        void *gr = readPtr(gotePj, OFF_GPJ_GAME_RECORD);
        if (gr) goteDan = readI32(gr, OFF_GRJ_DAN);
    }
    NSString *senteFav = il2cppStr(readPtr(sentePj, OFF_GPJ_FAVSENPOU));
    NSString *goteFav  = il2cppStr(readPtr(gotePj,  OFF_GPJ_FAVSENPOU));

    int32_t senteTimeLimit = readI32(gsj, OFF_GSJ_SENTE_TIME_LIMIT);
    int32_t goteTimeLimit  = readI32(gsj, OFF_GSJ_GOTE_TIME_LIMIT);
    int32_t senteByoyomi   = readI32(gsj, OFF_GSJ_SENTE_BYOYOMI);
    int32_t goteByoyomi    = readI32(gsj, OFF_GSJ_GOTE_BYOYOMI);

    // Position block for BEGIN Position...END Position.
    // hasMoves=true: mid-game reconnect — use live CSA block from WarsLiveSfen().
    // hasMoves=false: match start — convert init_pos SFEN via CsaPositionFromSfen().
    bool hasMoves = atomic_load(&g_csaHasMoves);
    IPALog([NSString stringWithFormat:
              @"[CSA-GAME] BuildGameSummary: hasMoves=%d", (int)hasMoves]);

    // liveCsaBlock: non-nil when WarsLiveSfen() succeeds (already in CSA format).
    // initPosSfen: SFEN string from GameStartJson for the starting position.
    NSString *liveCsaBlock = nil;
    NSString *initPosSfen  = il2cppStr(readPtr(gsj, OFF_GSJ_INIT_POS));

    if (hasMoves) {
        IPALog(@"[CSA-GAME] hasMoves=true: calling WarsLiveSfen()");
        liveCsaBlock = WarsLiveSfen();
        if (liveCsaBlock.length == 0) {
            IPALog(@"[CSA-GAME] WarsLiveSfen() nil/empty, falling back to init_pos");
            liveCsaBlock = nil;
        }
    }

    // To_Move: derive from live block tail line or init_pos SFEN side token.
    NSString *toMove = @"+";
    if (liveCsaBlock.length > 0) {
        // Last non-empty line of the CSA block is "+" or "-".
        NSArray<NSString *> *blkLines = [liveCsaBlock componentsSeparatedByString:@"\n"];
        for (NSInteger i = (NSInteger)blkLines.count - 1; i >= 0; i--) {
            NSString *ln = [blkLines[i] stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
            if ([ln isEqualToString:@"+"] || [ln isEqualToString:@"-"]) {
                toMove = ln;
                break;
            }
        }
    } else if (initPosSfen.length > 0) {
        NSArray<NSString *> *parts = [initPosSfen componentsSeparatedByString:@" "];
        if (parts.count >= 2 && [parts[1] isEqualToString:@"w"]) toMove = @"-";
    }
    IPALog([NSString stringWithFormat:@"[CSA-GAME] toMove=%@", toMove]);

    NSString *mode   = csa_modeName(oType);
    NSString *gameId = [NSString stringWithFormat:@"%@-%@",
                        csa_compactTimestamp(), mode];
    if (outGameId) *outGameId = gameId;

    // Your_Turn reflects which side the local player (= the CSA engine) holds.
    NSString *yourTurn = isBlack ? @"+" : @"-";

    // Engine's time control — use the side that matches isBlack.
    int32_t engineTimeLimit = isBlack ? senteTimeLimit : goteTimeLimit;
    int32_t engineByoyomi   = isBlack ? senteByoyomi   : goteByoyomi;

    // Remaining time from the move-observation cache, or fall back to total.
    float senteRemain = g_csaLastSenteRemainSec;
    float goteRemain  = g_csaLastGoteRemainSec;
    int32_t senteRemainSec = isnan(senteRemain) ? senteTimeLimit
                           : (int32_t)senteRemain;
    int32_t goteRemainSec  = isnan(goteRemain)  ? goteTimeLimit
                           : (int32_t)goteRemain;

    NSMutableString *out = [NSMutableString stringWithCapacity:1024];
    [out appendString:@"BEGIN Game_Summary\n"];
    [out appendString:@"Protocol_Version:1.2\n"];
    [out appendString:@"Protocol_Mode:Server\n"];
    [out appendString:@"Format:Shogi 1.0\n"];
    [out appendString:@"Declaration:Jishogi 1.1\n"];
    [out appendFormat:@"Game_ID:%@\n", gameId];
    if (senteName.length > 0) [out appendFormat:@"Name+:%@\n", senteName];
    if (goteName.length  > 0) [out appendFormat:@"Name-:%@\n", goteName];
    [out appendFormat:@"Your_Turn:%@\n", yourTurn];
    [out appendFormat:@"To_Move:%@\n",   toMove];

    [out appendString:@"BEGIN Time\n"];
    [out appendString:@"Time_Unit:1sec\n"];
    if (engineTimeLimit > 0)
        [out appendFormat:@"Total_Time:%d\n", engineTimeLimit];
    if (engineByoyomi > 0)
        [out appendFormat:@"Byoyomi:%d\n", engineByoyomi];
    if (senteRemainSec > 0)
        [out appendFormat:@"Remaining_Time+:%d\n", senteRemainSec];
    if (goteRemainSec > 0)
        [out appendFormat:@"Remaining_Time-:%d\n", goteRemainSec];
    [out appendString:@"END Time\n"];

    [out appendString:@"BEGIN Position\n"];
    if (liveCsaBlock.length > 0) {
        // WarsLiveSfen() returns a ready-to-use CSA block (P1..P9, P+, P-, +/-).
        [out appendString:liveCsaBlock];
        if (![liveCsaBlock hasSuffix:@"\n"]) [out appendString:@"\n"];
    } else {
        // Fall back to starting position from GameStartJson.
        NSString *csaPos = CsaPositionFromSfen(initPosSfen);
        if (csaPos.length > 0) {
            [out appendString:csaPos];
            [out appendString:@"\n"];
        }
    }
    [out appendString:@"END Position\n"];

    // WARS_* extensions.
    [out appendFormat:@"WARS_Mode:%@\n", mode];
    if (senteDan > 0) [out appendFormat:@"WARS_Dan+:%d\n", senteDan];
    if (goteDan  > 0) [out appendFormat:@"WARS_Dan-:%d\n", goteDan];
    if (sentePoints > 0) [out appendFormat:@"WARS_Points+:%d\n", sentePoints];
    if (gotePoints  > 0) [out appendFormat:@"WARS_Points-:%d\n", gotePoints];
    if (senteFav.length > 0) [out appendFormat:@"WARS_Favsenpou+:%@\n", senteFav];
    if (goteFav.length  > 0) [out appendFormat:@"WARS_Favsenpou-:%@\n", goteFav];
    [out appendFormat:@"WARS_StartedAt:%@\n", csa_iso8601_now() ?: @""];

    [out appendString:@"END Game_Summary"];
    return out;
}

// ---------------------------------------------------------------------------
// Result block builder.
//
// ShogiWars surfaces a full Reason enum (TORYO / CHECKMATE / TIMEOUT /
// DISCONNECT / SENNICHI / OUTE_SENNICHI / ENTERINGKING / PLY_LIMIT /
// MAINTENANCE), so we can map to the precise CSA reason marker rather than
// always falling back to #RESIGN.
// ---------------------------------------------------------------------------
NSString *CsaBuildMatchResult(web_match_result_t result, NSString *reason) {
    NSString *reasonMarker = @"#RESIGN";  // conservative default

    if ([reason isEqualToString:@"CHECKMATE"]) {
        reasonMarker = @"#TSUMI";
    } else if ([reason isEqualToString:@"TIMEOUT"]) {
        reasonMarker = @"#TIME_UP";
    } else if ([reason isEqualToString:@"SENNICHI"]) {
        reasonMarker = @"#SENNICHITE";
    } else if ([reason isEqualToString:@"OUTE_SENNICHI"]) {
        reasonMarker = @"#OUTE_SENNICHITE";
    } else if ([reason isEqualToString:@"ENTERINGKING"]) {
        reasonMarker = @"#JISHOGI";
    } else if ([reason isEqualToString:@"PLY_LIMIT"]) {
        reasonMarker = @"#MAX_MOVES";
    } else if ([reason isEqualToString:@"MAINTENANCE"]) {
        // MAINTENANCE ends the match without a win/lose — just emit #CHUDAN.
        return @"#CHUDAN";
    }

    switch (result) {
        case WEB_RESULT_WIN:
            return [NSString stringWithFormat:@"%@\n#WIN", reasonMarker];
        case WEB_RESULT_LOSE:
            return [NSString stringWithFormat:@"%@\n#LOSE", reasonMarker];
        case WEB_RESULT_DRAW:
            // Sennichite, oute-sennichite, ply-limit all come back as DRAW.
            return [NSString stringWithFormat:@"%@\n#DRAW", reasonMarker];
        case WEB_RESULT_UNKNOWN:
        default:
            return nil;
    }
}
