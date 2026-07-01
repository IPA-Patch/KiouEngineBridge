#import "Internal.h"

#if IPA_CHINLAN
// The meta sidecar is dropped on the chinlan flavour
// (docs/plans/kiou_engine_bridge_chinlan.md § 2). Provide no-op stubs so
// the Hook_*.m / Tweak.m call sites can compile without an #if guard at
// every reference.
void MetaSetMatchConfig(void *cfg) { (void)cfg; }
void MetaEmitMatchStart(int32_t local_player) { (void)local_player; }
void MetaEmitMove(NSString *usi, NSString *sfen_after, int32_t side_to_move) {
    (void)usi; (void)sfen_after; (void)side_to_move;
}
void MetaEmitMatchEnd(usi_match_result_t result,
                         NSString *final_sfen,
                         NSString *usi_text) {
    (void)result; (void)final_sfen; (void)usi_text;
}
#else

#import <mach/mach_time.h>

// ===========================================================================
// Meta_Emitter — 1-line JSON metadata stream on top of the WS sink.
//
// Phase 2 ships USI lines and `gameover` over the same WS port the bridge
// already speaks. The bridge needs richer match metadata than USI carries —
// player names, ratings, time control, ply numbers, elapsed thinking, etc.
// USI has no native vocabulary for any of that.
//
// Design:
//   - Every line starts with the literal "meta " followed by a single JSON
//     object terminated by "\n". The bridge's reader looks for that prefix
//     and routes those lines to its KIF assembler rather than the engine.
//   - Three event types:
//        match_start  — once per match, right after OnMatchStart latches
//                       the local-player seat (so we know whose side is which)
//        move         — once per move, fired from Hook_LowLevelObserve's
//                       Adapter.TryMakeMove(out) observation (same site as
//                       UsiEngineOnMoveObserved)
//        match_end    — once per match, from Hook_MatchModeObserve's END_HOOK
//                       (after the inferred win/lose has been computed)
//   - No retries, no buffering across reconnects. If no bridge is attached
//     when emit fires, the line is dropped — same as every other WS push.
//   - All JSON building goes through NSJSONSerialization so escaping is
//     correct without us hand-rolling string encoders.
//
// What this file deliberately doesn't do:
//   - Persist anything. KIF persistence will be a separate module that reads
//     from the same observation hooks. meta lines are pure pass-through.
//   - Read il2cpp object fields beyond what the observation hooks already
//     have on hand. The match_start payload only uses MatchConfig and its
//     immediate sub-objects (PlayerInfo, TimeControl).
//   - Touch ReactiveProperty<T> internals. Live remaining-time is omitted
//     from meta_move for now because the ReactiveProperty layout is
//     load-bearing and unverified from dump.cs alone.
// ===========================================================================

// ---------------------------------------------------------------------------
// State. Caches that survive across hook fires within one match.
// ---------------------------------------------------------------------------

// MatchConfig pointer captured by InitializeAsync — owns the player info,
// time control, and mode. Cleared on OnMatchEndAsync to avoid stale carry-
// over between matches. `volatile` because writers are on Unity threads and
// readers can be on either Unity threads (observation hooks) or the recv
// queue (none right now, but future-proofed).
static void *volatile g_metaMatchConfig = NULL;

// Match-start wall-clock time (UTC ISO 8601). Captured by emit_match_start
// and reused as the "match_started_at" in subsequent meta_move log lines
// (handy for debugging but not part of the wire format).
static NSString *volatile g_metaMatchStartedAtISO = nil;

// Per-match move counter. 1-based; secondary "ply" source for meta_move
// when the SFEN-based primary source can't be read. Reset on each
// meta_match_start.
//
// NOTE: this counter is NOT the authoritative ply number — sfen_after's
// trailing moveNum is. The counter is only here so we still emit
// _something_ in the unlikely case that sfen parsing fails. The two
// disagree across mid-match resumes (bridge reconnect, tweak reload):
// the SFEN keeps the real game's count, the counter restarts at 0.
static int32_t volatile g_metaPlyCounter = 0;

// Per-move stopwatch. mach_absolute_time ticks at the moment the previous
// move landed (or at meta_match_start for the first move). The delta to
// "now" inside emit_move becomes "elapsed_ms". 0 means "first move of the
// match — elapsed_ms will be the time from match_start to first move."
static uint64_t volatile g_metaLastMoveMachTime = 0;

// Latest PlayerInfo pointers captured from
// GameStateStore.SetBlackPlayerInfo / SetWhitePlayerInfo. On Online matches
// the MatchConfig.BlackPlayer / WhitePlayer that InitializeAsync hands us
// hold a placeholder ("プレイヤー") until matchmaking completes — the
// real opponent identity arrives later via these Set*PlayerInfo calls on
// the GameStateStore. We stash the latest pointer in each slot and use it
// in match_start instead of MatchConfig when present.
//
// Volatile because writers are Unity-side hook callbacks and the reader
// runs on whichever queue MetaEmitMatchStart ends up on.
static void *volatile g_metaLatestBlackPlayerInfo = NULL;
static void *volatile g_metaLatestWhitePlayerInfo = NULL;

// match_start gating. OnMatchStart sets g_metaMatchStartPending and a
// local_player snapshot, then we wait for SetBlackPlayerInfo +
// SetWhitePlayerInfo to both arrive. The first such call that finds the
// pair complete emits match_start and clears the pending flag.
//
// CPU matches don't necessarily fire Set*PlayerInfo at all, so the
// OnMatchStart path also schedules a 1.5s fallback timer that fires
// match_start with whatever's available at that point. Whoever wins the
// race wins; the other side notices pending == 0 and bails.
static bool volatile g_metaMatchStartPending = false;
static int32_t volatile g_metaPendingLocalPlayer = -1;

// MatchConfig field offsets — dump.cs:1418061. The Init hook caches a
// pointer to the whole struct; we walk from there at emit time so we read
// the live values, not a snapshot.
#define META_OFF_MATCHCONFIG_MODE                0x10  // MatchMode (int32)
#define META_OFF_MATCHCONFIG_BLACK_PLAYER        0x18  // PlayerInfo*
#define META_OFF_MATCHCONFIG_WHITE_PLAYER        0x20  // PlayerInfo*
#define META_OFF_MATCHCONFIG_TIME_CONTROL        0x28  // TimeControlConfig*
#define META_OFF_MATCHCONFIG_START_POSITION      0x50  // InitialPositionType (int32)

// PlayerInfo field offsets — dump.cs:1419145.
#define META_OFF_PLAYERINFO_USER_ID              0x10  // string
#define META_OFF_PLAYERINFO_NAME                 0x18  // string
#define META_OFF_PLAYERINFO_RANK                 0x20  // string
#define META_OFF_PLAYERINFO_RATE                 0x2C  // int32

// TimeControlSettings layout (struct) — dump.cs:1209078. MatchConfig's
// TimeControl is the related TimeControlConfig class; both expose the same
// three floats (TimeSeconds, Byoyomi, Increment) at the same internal
// offsets. We read them via the dedicated getters when possible, but
// MatchConfig holds it as a pointer-typed field so the offsets here are
// for the class wrapper (16-byte il2cpp object header + fields).
#define META_OFF_TIMECONTROL_MAIN_SECONDS        0x10  // float
#define META_OFF_TIMECONTROL_BYOYOMI             0x14  // float
#define META_OFF_TIMECONTROL_INCREMENT           0x18  // float

// ---------------------------------------------------------------------------
// mach_absolute_time -> milliseconds. Same idea as Inject_Move.m's
// inject_machTicksToUs but at ms granularity; meta_move's "elapsed_ms"
// rarely benefits from sub-ms precision and the JSON is smaller.
// ---------------------------------------------------------------------------
static uint64_t meta_machTicksToMs(uint64_t ticks) {
    static mach_timebase_info_data_t s_tb = {0, 0};
    if (s_tb.denom == 0) mach_timebase_info(&s_tb);
    if (s_tb.denom == 0) return 0;
    // ticks * numer / denom -> ns, then / 1e6 -> ms.
    if (s_tb.numer == s_tb.denom) return ticks / 1000000ULL;
    return (ticks * s_tb.numer) / s_tb.denom / 1000000ULL;
}

// ---------------------------------------------------------------------------
// ISO 8601 UTC timestamp formatter. NSISO8601DateFormatter is iOS 10+, fine
// for KIOU 15+. Singleton so we don't reallocate per call.
// ---------------------------------------------------------------------------
static NSString *meta_iso8601_now(void) {
    static NSISO8601DateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSISO8601DateFormatter alloc] init];
        fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [fmt stringFromDate:[NSDate date]];
}

// ---------------------------------------------------------------------------
// Enum-to-string helpers. We keep the wire format human-readable so the
// bridge doesn't need a copy of every enum to interpret meta lines.
// ---------------------------------------------------------------------------
static NSString *meta_matchModeName(int32_t v) {
    switch (v) {
        case 0:  return @"VsAI";
        case 1:  return @"LocalPvP";
        case 2:  return @"OnlinePvP";
        case 3:  return @"RecordReplay";
        case 4:  return @"Spectate";
        default: return [NSString stringWithFormat:@"Unknown(%d)", (int)v];
    }
}

static NSString *meta_initialPositionName(int32_t v) {
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

static NSString *meta_sideName(int32_t side) {
    switch (side) {
        case 0:  return @"b";
        case 1:  return @"w";
        default: return @"?";
    }
}

static NSString *meta_resultName(usi_match_result_t r) {
    switch (r) {
        case USI_RESULT_WIN:  return @"win";
        case USI_RESULT_LOSE: return @"lose";
        case USI_RESULT_DRAW: return @"draw";
        case USI_RESULT_UNKNOWN:
        default:              return @"unknown";
    }
}

// ---------------------------------------------------------------------------
// PlayerInfo -> NSDictionary. Reads name/rank/rate/user_id straight out of
// the cached pointer; nil entries are dropped from the output (JSON has no
// "missing" distinct from "null", but we emit null for missing fields so
// the bridge sees a stable schema).
// ---------------------------------------------------------------------------
static NSDictionary *meta_playerDict(void *playerInfo) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (!playerInfo) {
        // Even a missing PlayerInfo gets the full skeleton so the bridge's
        // schema is stable.
        d[@"name"]    = [NSNull null];
        d[@"rank"]    = [NSNull null];
        d[@"rate"]    = [NSNull null];
        d[@"user_id"] = [NSNull null];
        return d;
    }
    NSString *name   = il2cppStringToNSString(readPtr(playerInfo, META_OFF_PLAYERINFO_NAME));
    NSString *rank   = il2cppStringToNSString(readPtr(playerInfo, META_OFF_PLAYERINFO_RANK));
    NSString *userId = il2cppStringToNSString(readPtr(playerInfo, META_OFF_PLAYERINFO_USER_ID));
    int32_t rate     = readI32(playerInfo, META_OFF_PLAYERINFO_RATE);
    d[@"name"]    = name   ?: (id)[NSNull null];
    d[@"rank"]    = rank   ?: (id)[NSNull null];
    d[@"rate"]    = (rate > 0) ? @(rate) : (id)[NSNull null];
    d[@"user_id"] = userId ?: (id)[NSNull null];
    return d;
}

// ---------------------------------------------------------------------------
// TimeControl -> NSDictionary. The MatchConfig holds a TimeControlConfig
// class pointer; we read the three floats from it. Missing pointer or
// nonsense values produce nulls rather than zeroes.
// ---------------------------------------------------------------------------
static NSDictionary *meta_timeControlDict(void *tcc) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (!tcc) {
        d[@"main_seconds"]      = [NSNull null];
        d[@"byoyomi_seconds"]   = [NSNull null];
        d[@"increment_seconds"] = [NSNull null];
        return d;
    }
    float main = 0, byo = 0, inc = 0;
    @try {
        main = *(const float *)((const uint8_t *)tcc + META_OFF_TIMECONTROL_MAIN_SECONDS);
        byo  = *(const float *)((const uint8_t *)tcc + META_OFF_TIMECONTROL_BYOYOMI);
        inc  = *(const float *)((const uint8_t *)tcc + META_OFF_TIMECONTROL_INCREMENT);
    } @catch (NSException *e) {
        d[@"main_seconds"]      = [NSNull null];
        d[@"byoyomi_seconds"]   = [NSNull null];
        d[@"increment_seconds"] = [NSNull null];
        return d;
    }
    d[@"main_seconds"]      = @(main);
    d[@"byoyomi_seconds"]   = @(byo);
    d[@"increment_seconds"] = @(inc);
    return d;
}

// ---------------------------------------------------------------------------
// Emit. NSJSONSerialization produces canonical JSON; the body is logged
// via the standard sandbox / TCP log sink with a "[META>]" prefix. The
// old transport that pushed "meta <json>\n" lines to KEBCsaServerPush
// has been removed — meta is now diagnostic-only and never reaches a
// CSA client. Failures (oversize dict, encoding errors, ...) are
// logged but never thrown back; meta is best-effort by design.
// ---------------------------------------------------------------------------
static void meta_emit_dict(NSDictionary *payload) {
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:0
                                                     error:&err];
    if (!json) {
        IPALog([NSString stringWithFormat:
                  @"[META] serialize failed: %@",
                  err.localizedDescription ?: @"?"]);
        return;
    }
    NSString *body = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if (!body) {
        IPALog(@"[META] serialize: utf-8 decode failed");
        return;
    }
    IPALog([NSString stringWithFormat:@"[META>] %@", body]);
}

// ---------------------------------------------------------------------------
// Internal: actually build and ship the match_start dict. Picks the best
// PlayerInfo source for each color — GameStateStore.Set*PlayerInfo if
// captured (Online), otherwise MatchConfig (CPU / LocalPvP).
//
// Callable from the OnMatchStart fallback timer or from a Set*PlayerInfo
// hook once both sides are in. The caller must ensure
// g_metaMatchStartPending is still true at entry; we clear it on emit.
// ---------------------------------------------------------------------------
static void meta_do_emit_match_start(const char *trigger) {
    if (!g_metaMatchStartPending) {
        // Already emitted by a faster path; bail out silently.
        return;
    }
    g_metaMatchStartPending = false;

    int32_t local_player = g_metaPendingLocalPlayer;

    void *cfg = g_metaMatchConfig;
    int32_t mode = cfg ? readI32(cfg, META_OFF_MATCHCONFIG_MODE) : -1;
    int32_t startPos = cfg ? readI32(cfg, META_OFF_MATCHCONFIG_START_POSITION) : -1;
    void *cfgBlackPI = cfg ? readPtr(cfg, META_OFF_MATCHCONFIG_BLACK_PLAYER) : NULL;
    void *cfgWhitePI = cfg ? readPtr(cfg, META_OFF_MATCHCONFIG_WHITE_PLAYER) : NULL;
    void *tcc        = cfg ? readPtr(cfg, META_OFF_MATCHCONFIG_TIME_CONTROL) : NULL;

    // Prefer the store-captured PlayerInfo if available — that's the
    // matchmaking-resolved opponent. Fall back to MatchConfig (which on
    // Online holds the pre-match placeholder).
    void *blackPI = g_metaLatestBlackPlayerInfo ?: cfgBlackPI;
    void *whitePI = g_metaLatestWhitePlayerInfo ?: cfgWhitePI;

    NSString *startedAt = meta_iso8601_now();
    g_metaMatchStartedAtISO = startedAt;
    g_metaPlyCounter = 0;
    g_metaLastMoveMachTime = mach_absolute_time();

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"type"]           = @"match_start";
    d[@"mode"]           = meta_matchModeName(mode);
    d[@"started_at"]     = startedAt ?: (id)[NSNull null];
    d[@"local_player"]   = (local_player == 0 || local_player == 1)
                               ? meta_sideName(local_player)
                               : (id)[NSNull null];
    d[@"start_position"] = meta_initialPositionName(startPos);
    d[@"time_control"]   = meta_timeControlDict(tcc);
    d[@"black"]          = meta_playerDict(blackPI);
    d[@"white"]          = meta_playerDict(whitePI);

    IPALog([NSString stringWithFormat:
              @"[META] match_start emit trigger=%s black_src=%s "
              @"white_src=%s",
              trigger,
              g_metaLatestBlackPlayerInfo ? "store" : "cfg",
              g_metaLatestWhitePlayerInfo ? "store" : "cfg"]);
    meta_emit_dict(d);
}

// ---------------------------------------------------------------------------
// External entry — called from Hook_MatchModeObserve's OnMatchStart hook.
//
// We DON'T emit immediately on Online matches because MatchConfig.Black/
// WhitePlayer still hold "プレイヤー" placeholders at this point — the
// matchmaking-resolved opponent identity arrives later via
// GameStateStore.SetBlackPlayerInfo / SetWhitePlayerInfo. We arm a
// pending flag and a 1.5s fallback timer:
//
//   - Set*PlayerInfo hook fires first → emits with the store-supplied
//     PlayerInfo
//   - Timer fires first → emits with whatever's available (CPU matches
//     where Set*PlayerInfo may never fire fall through to MatchConfig)
//
// Whoever wins clears g_metaMatchStartPending so the loser bails.
// ---------------------------------------------------------------------------
void MetaEmitMatchStart(int32_t local_player) {
    g_metaPendingLocalPlayer = local_player;
    g_metaMatchStartPending = true;
    // Reset the captured PlayerInfo from any previous match before we wait
    // for the new ones. If they were carrying over from match N-1 the
    // emit would race against fresh writes and might show a half-stale
    // pair (one new, one stale).
    g_metaLatestBlackPlayerInfo = NULL;
    g_metaLatestWhitePlayerInfo = NULL;

    IPALog([NSString stringWithFormat:
              @"[META] match_start armed local_player=%d, "
              @"waiting for Set*PlayerInfo (1.5s fallback)",
              (int)local_player]);

    // Fallback timer. Runs on a global queue; the emit itself doesn't
    // touch il2cpp so we don't need the main queue.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                   ^{
        meta_do_emit_match_start("timer");
    });
}

// ---------------------------------------------------------------------------
// PlayerInfo capture from GameStateStore.Set*PlayerInfo hooks. Called from
// Hook_GameStateStoreObserve.m. side: 0=Black, 1=White.
//
// If both sides have now been seen and a match_start is pending, we emit
// immediately. The fallback timer notices the pending flag is clear and
// bails. Late writes after emit are kept in the cache (so a follow-up
// stat surface could re-read them) but don't re-emit.
// ---------------------------------------------------------------------------
void MetaOnPlayerInfoSet(int32_t side, void *playerInfo) {
    if (!playerInfo) return;
    if (side == 0) {
        g_metaLatestBlackPlayerInfo = playerInfo;
    } else if (side == 1) {
        g_metaLatestWhitePlayerInfo = playerInfo;
    } else {
        return;
    }
    IPALog([NSString stringWithFormat:
              @"[META] PlayerInfo captured side=%d pi=%p "
              @"(black=%p white=%p pending=%d)",
              (int)side, playerInfo,
              g_metaLatestBlackPlayerInfo,
              g_metaLatestWhitePlayerInfo,
              (int)g_metaMatchStartPending]);
    // Emit only when BOTH sides are in. A single side isn't enough — we'd
    // ship a half-stale pair (the other side still holding a placeholder
    // or carrying over from the previous match).
    if (g_metaMatchStartPending &&
        g_metaLatestBlackPlayerInfo &&
        g_metaLatestWhitePlayerInfo) {
        meta_do_emit_match_start("set_player_info");
    }
}

// ---------------------------------------------------------------------------
// move. Called from the same observation site as UsiEngineOnMoveObserved
// — Hook_LowLevelObserve's AdapterTryMakeMoveOut. `usi` is the move that just
// landed; `sfen_after` is the resulting position; `side_to_move` is the side
// whose turn it is NEXT (= opposite of who just moved).
// ---------------------------------------------------------------------------
void MetaEmitMove(NSString *usi, NSString *sfen_after, int32_t side_to_move) {
    if (usi.length == 0) return;

    uint64_t now = mach_absolute_time();
    uint64_t prev = g_metaLastMoveMachTime;
    g_metaLastMoveMachTime = now;
    uint64_t elapsedMs = (prev > 0 && now > prev) ? meta_machTicksToMs(now - prev) : 0;

    // Side that just moved is the opposite of side_to_move (the "next"
    // side). If side_to_move is -1 (unknown), we can't infer who moved.
    int32_t movedSide = (side_to_move == 0) ? 1
                       : (side_to_move == 1) ? 0
                       : -1;

    g_metaPlyCounter++;

    // Authoritative ply comes from the SFEN's trailing moveNum: that's the
    // 1-based number of the move that will be played NEXT, so the move
    // that just landed is moveNum - 1. The counter is only a fallback for
    // when SFEN parsing fails (it'd lie across mid-match resumes, where
    // the SFEN keeps the game's real ply but the counter restarted at 0).
    int32_t plyFromSfen = -1;
    if (sfen_after.length > 0) {
        NSArray<NSString *> *parts = [sfen_after componentsSeparatedByString:@" "];
        // Position SFEN: <board> <side> <hand> <moveNum>. Anything with
        // fewer than 4 tokens isn't a complete position SFEN — fall back
        // to the counter.
        if (parts.count >= 4) {
            NSString *moveNumStr = parts[parts.count - 1];
            NSScanner *sc = [NSScanner scannerWithString:moveNumStr];
            int parsed = 0;
            if ([sc scanInt:&parsed] && sc.isAtEnd && parsed > 0) {
                plyFromSfen = (int32_t)(parsed - 1);
            }
        }
    }
    int32_t plyOut = (plyFromSfen > 0) ? plyFromSfen : g_metaPlyCounter;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"type"]       = @"move";
    d[@"ply"]        = @(plyOut);
    d[@"side"]       = (movedSide >= 0)
                           ? meta_sideName(movedSide)
                           : (id)[NSNull null];
    d[@"usi"]        = usi;
    d[@"elapsed_ms"] = @(elapsedMs);
    d[@"sfen_after"] = sfen_after ?: (id)[NSNull null];
    // Remaining time from the latest server-authoritative snapshot
    // (UpdateAuthoritativeSnapshot for Online / CPUStream modes). 0.0f
    // means no snapshot has arrived this match — AI and Local modes never
    // receive one, so we emit null for those. The values lag by at most one
    // server tick relative to the move that just landed, which is acceptable
    // since this is the same authoritative source the server uses for
    // adjudication. (ReactiveProperty<float> walking was the original plan
    // but its layout is still unverified; snapshot args are the simpler path.)
    float bTime = g_latestBlackTimeSec;
    float wTime = g_latestWhiteTimeSec;
    d[@"black_time_sec"] = (bTime > 0.0f) ? @(bTime) : (id)[NSNull null];
    d[@"white_time_sec"] = (wTime > 0.0f) ? @(wTime) : (id)[NSNull null];
    meta_emit_dict(d);
}

// ---------------------------------------------------------------------------
// match_end. Called from Hook_MatchModeObserve's END_HOOK after the result
// has been inferred. final_sfen comes from the post-match GameController
// state (the caller pulls it via inject_currentSfen — easier than rereading
// the cache here).
// ---------------------------------------------------------------------------
void MetaEmitMatchEnd(usi_match_result_t result,
                         NSString *final_sfen,
                         NSString *usi_text) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"type"]         = @"match_end";
    d[@"ended_at"]     = meta_iso8601_now() ?: (id)[NSNull null];
    d[@"result"]       = meta_resultName(result);
    d[@"total_moves"]  = @(g_metaPlyCounter);
    d[@"final_sfen"]   = final_sfen ?: (id)[NSNull null];
    // GameController.GetUSIText の生戻り値。bridge 側で「startpos moves ...」
    // または「sfen ... moves ...」として解釈して、これまで MetaEmitMove で
    // 積んできた Record を上書きするグランドトゥルースに使う。差分ベースで
    // 累積する経路だと飛び手 / drop の駒種未確定 / 重複発火などで誤差が
    // 入る余地があるので、対局終了時にここで一発で確定させる。
    d[@"usi_text"]     = usi_text ?: (id)[NSNull null];
    // Future: "kif_filename" once Step 3-B lands and we have a saved file
    // to point at.
    meta_emit_dict(d);
}

// ---------------------------------------------------------------------------
// MatchConfig stash / clear. Called by Hook_MatchModeObserve's Init hook
// with the cfg arg, and by the End hook with NULL.
// ---------------------------------------------------------------------------
void MetaSetMatchConfig(void *cfg) {
    g_metaMatchConfig = cfg;
    if (!cfg) {
        // Clearing means the match is over (or the next one hasn't started).
        // Drop the started-at cache too so a stale ISO doesn't leak across.
        g_metaMatchStartedAtISO = nil;
        // Drop the per-match PlayerInfo cache too. The next match's
        // OnMatchStart will arm fresh expectations; carrying stale
        // pointers across would race against the new Set*PlayerInfo
        // writes and could surface a previous opponent in the next
        // match_start.
        g_metaLatestBlackPlayerInfo = NULL;
        g_metaLatestWhitePlayerInfo = NULL;
        // A pending match_start that never emitted (timer didn't fire
        // before End — shouldn't happen given the 1.5s budget, but
        // guard anyway) is dropped: there's nothing useful to ship at
        // this point.
        g_metaMatchStartPending = false;
        g_metaPendingLocalPlayer = -1;
    }
}

#endif  // !IPA_CHINLAN
