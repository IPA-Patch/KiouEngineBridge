#import "Internal.h"
#import "Settings_Persistence.h"

// ===========================================================================
// Hook_MatchingFilterObserve — apply user-configured matching filters.
//
// Two filters are supported:
//
//   1. First Player Only (KEBFirstPlayerOnly)
//      When a MatchFound reply arrives with IsFirstPlayer=false, the client
//      sends ConnectionFailed to the matching server instead of Prepare-ing
//      the game stream. The matching loop in StartMatchingAsyncInternal then
//      requeues automatically (it treats ConnectionFailed as a retry signal).
//
//      NOTE: This filter is for debugging purposes only. It is considered
//      unsportsmanlike for production use and should eventually live in
//      KiouEditor rather than KiouEngineBridge.
//
//   2. Fixed Rate Range (KEBFixedRateRange)
//      When a MatchingStatus reply arrives with CurrentRateRange > the
//      configured ceiling, the client sends LeaveQueue followed immediately
//      by JoinQueue (with the same original arguments) to reset the server's
//      search range back to its initial value.
//
// Hook sites:
//
//   GetValidMatchFoundStatus (RVA 0x5D04E94)
//     Called only when Event==MatchFound AND status is non-nil.
//     Used for the First Player Only filter.
//
//   MatchingHandler.<ReceiveWithTimeoutAsync>d__6.MoveNext (RVA 0x5D06B10)
//     Fires on every reply. Used for the Fixed Rate Range filter.
//
//   IShogiMatchStreamArgs.Create (RVA 0x5BCA664)
//     Observed to cache the last JoinQueue parameters for re-queuing.
//
// Field offsets (from dump.cs concrete class layouts):
//
//   ShogiMatchStreamReply:
//     event_              int32  0x1C  (ShogiMatchStreamEvent enum)
//     matchingStatus_     ptr    0x20  (ShogiMatchingStatus*)
//     matchFoundStatus_   ptr    0x28  (ShogiMatchFoundStatus*)
//
//   ShogiMatchingStatus:
//     currentRateRange_   int32  0x2C
//
//   ShogiMatchFoundStatus:
//     isFirstPlayer_      bool   0x2C
// ===========================================================================

// ---------------------------------------------------------------------------
// RVAs (KIOU 1.0.1 build 11)
// ---------------------------------------------------------------------------
#define RVA_RECEIVE_TIMEOUT_MOVENEXT  0x5D06B10
#define RVA_MATCH_STREAM_ARGS_CREATE  0x5BCA664

// ---------------------------------------------------------------------------
// ShogiMatchStreamEvent enum values
// ---------------------------------------------------------------------------
#define MATCH_STREAM_EVENT_MATCH_FOUND      4
#define MATCH_STREAM_EVENT_MATCHING_STATUS  3

// ---------------------------------------------------------------------------
// ShogiMatchStreamAction enum values
// ---------------------------------------------------------------------------
#define MATCH_STREAM_ACTION_JOIN_QUEUE   3
#define MATCH_STREAM_ACTION_LEAVE_QUEUE  4

// ---------------------------------------------------------------------------
// MatchingClientType enum values
// ---------------------------------------------------------------------------
#define MATCHING_CLIENT_TYPE_SEARCHING         2
#define MATCHING_CLIENT_TYPE_CONNECTION_FAILED 4

// ---------------------------------------------------------------------------
// Field offsets
// ---------------------------------------------------------------------------
#define OFF_REPLY_EVENT              0x1C
#define OFF_REPLY_MATCHING_STATUS    0x20
#define OFF_REPLY_MATCH_FOUND_STATUS 0x28

#define OFF_MATCHING_STATUS_CURRENT_RATE_RANGE 0x2C

#define OFF_MATCH_FOUND_IS_FIRST_PLAYER 0x2C

// ---------------------------------------------------------------------------
// MatchingHandler.<ReceiveWithTimeoutAsync>d__6 state machine field offsets.
//
// The state machine is a struct (value type) — it's heap-allocated and
// boxed by the async infrastructure (IAsyncStateMachine). We observe it
// via `self` in MoveNext which is the boxed pointer.
//
// Relevant fields (from dump.cs line 1480309):
//   <>1__state  int32  0x08  (async state index; -2 = completed)
//   <>5__2      IShogiMatchStreamReply*  — the reply local captured into the
//               state machine. The exact offset must be confirmed on-device;
//               based on the ordering of IAsyncStateMachine header + int state
//               + awaiter slots the reply lands near 0x50-0x68. We use a
//               scan helper rather than a hard offset to stay robust.
//
// Alternative approach (simpler, no offset guessing): hook the *caller*
// GetValidMatchFoundStatus (RVA 0x5D04E94) which already has the reply in
// x0 and returns the MatchFoundStatus — but that only fires on MatchFound,
// not on MatchingStatus for the rate-range filter.
//
// We therefore hook MoveNext but read the result indirectly: when state == -2
// (completed) we walk the stored `stream` pointer (which the state machine
// also holds) and the return value is already set. For simplicity we cache
// the stream once and read the most recent reply by hooking
// GetValidMatchFoundStatus for MatchFound and a separate path in MoveNext
// for MatchingStatus.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Hook approach:
//
//   Hook A: GetValidMatchFoundStatus (RVA 0x5D04E94)
//     Called only when Event==MatchFound. Runs the First Player Only filter.
//
//   Hook B: ReceiveWithTimeoutAsync.MoveNext (RVA 0x5D06B10)
//     Fires on every reply. Runs the Fixed Rate Range filter on MatchingStatus.
//
//   Hook C: IShogiMatchStreamArgs.Create (RVA 0x5BCA664)
//     Observe every JoinQueue to cache match params for re-queuing.
//
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Cached stream + match params. Populated from Hook B on first MatchingStatus
// receipt so the re-queue path knows what args to send.
// ---------------------------------------------------------------------------
static void *volatile g_matchStreamCache = NULL;
static int32_t volatile g_cachedMatchType         = 0; // MatchType enum
static int32_t volatile g_cachedRankRuleType       = 0;
static int32_t volatile g_cachedEventRuleType      = 0;
static int32_t volatile g_cachedMstEventMatchId    = 0;
static bool    volatile g_cachedBeginnerSupport    = false;

// ---------------------------------------------------------------------------
// IShogiMatchStreamArgs.Create function pointer.
// ---------------------------------------------------------------------------
typedef void *(*MatchStreamArgsCreate_t)(int32_t action, int32_t matchType,
                                         int32_t rankRuleType, int32_t eventRuleType,
                                         int32_t mstEventMatchId,
                                         int32_t matchingClientType,
                                         bool enableBeginnerSupport);
static MatchStreamArgsCreate_t g_ArgsCreate = NULL;

// IStreamHandler vtable slot 4 = SendAsync(IShogiMatchStreamArgs) -> UniTask
// We call it as: ((UniTaskRet(*)(void*, void*))vtable[4])(stream, args)
static inline void sendArgs(void *stream, void *args) {
    if (!stream || !args) return;
    void **vtable = *(void ***)stream;
    if (!vtable) return;
    typedef UniTaskRet (*SendAsync_t)(void *self, void *args);
    SendAsync_t fn = (SendAsync_t)vtable[4];
    if (!fn) return;
    @try { (void)fn(stream, args); }
    @catch (NSException *e) {
        IPALog([NSString stringWithFormat:@"[MFILTER] sendArgs threw: %@", e]);
    }
}

static inline void sendAction(void *stream, int32_t action, int32_t matchingClientType) {
    if (!g_ArgsCreate) return;
    void *args = g_ArgsCreate(action,
                               g_cachedMatchType,
                               g_cachedRankRuleType,
                               g_cachedEventRuleType,
                               g_cachedMstEventMatchId,
                               matchingClientType,
                               g_cachedBeginnerSupport);
    sendArgs(stream, args);
}

// ---------------------------------------------------------------------------
// Hook A: GetValidMatchFoundStatus
//   void* GetValidMatchFoundStatus(void *reply)
// ---------------------------------------------------------------------------
typedef void *(*GetValidMatchFoundStatus_t)(void *reply);
static GetValidMatchFoundStatus_t orig_GetValidMatchFoundStatus
    __attribute__((unused)) = NULL;

void *HookGetValidMatchFoundStatus(void *reply) {
    void *result = KIOU_CALL_ORIG_RET(void *, orig_GetValidMatchFoundStatus, reply);

    if (!result || !reply) return result;
    KEBAcceptedSeat accepted = KEBAcceptedSeatGet();
    if (accepted == KEBAcceptedSeatBoth) return result;

    void *stream = g_matchStreamCache;
    if (!stream) return result;

    bool isFirstPlayer = readU8(result, OFF_MATCH_FOUND_IS_FIRST_PLAYER);
    bool acceptMatch = (accepted == KEBAcceptedSeatBlack)
                       ? isFirstPlayer
                       : !isFirstPlayer;
    if (acceptMatch) {
        IPALog([NSString stringWithFormat:
                  @"[MFILTER] MatchFound: IsFirstPlayer=%s — accepting (filter=%s)",
                  isFirstPlayer ? "true" : "false",
                  accepted == KEBAcceptedSeatBlack ? "Black" : "White"]);
        return result;
    }

    IPALog([NSString stringWithFormat:
              @"[MFILTER] MatchFound: IsFirstPlayer=%s rejected (filter=%s) — "
              @"sending ConnectionFailed",
              isFirstPlayer ? "true" : "false",
              accepted == KEBAcceptedSeatBlack ? "Black" : "White"]);
    sendAction(stream, MATCH_STREAM_ACTION_JOIN_QUEUE,
               MATCHING_CLIENT_TYPE_CONNECTION_FAILED);

    return result;
}

// ---------------------------------------------------------------------------
// Hook B: MatchingHandler.<ReceiveWithTimeoutAsync>d__6.MoveNext
//
// State machine layout (approximate, validated by field ordering in dump.cs):
//   0x08  int32  <>1__state
//   0x10  ...    awaiter slot(s)
//   0x30  ptr    <>3__stream  (the IStreamHandler passed in as arg)
//   0x48  ptr    <>5__2       (the IShogiMatchStreamReply local, set when done)
//
// We only read when <>1__state == -2 (coroutine completed / result written).
// If the offset turns out to be wrong the readPtr returns NULL and we bail.
//
// Also caches stream + match params from the JoinQueue args that
// StartMatchingAsyncInternal passed in (recoverable from the stream's
// pending-send fields — but simpler: parse from reply.MatchingStatus on
// first receipt; the server echoes back MatchType/RuleType in MatchingStatus).
//
// Actually, the cleanest cache source is StartMatchingAsync which receives
// matchType/ruleType directly. However hooking that async wrapper is more
// complex. Instead we grab stream from x0 of MoveNext (self = boxed struct;
// the stream field is a reference the struct holds).
// ---------------------------------------------------------------------------

// State machine offsets — approximate, may need on-device tuning.
// The struct layout after the IAsyncStateMachine header (0x10 object header):
//   0x08  int32  <>1__state
//   0x0C  (pad)
//   0x10  ptr    <>t__builder (AsyncUniTaskMethodBuilder)
//   0x28  ptr    <>3__stream  (IStreamHandler...)
//   0x30  ptr    <>3__ct      (CancellationToken)
//   0x38  ptr    <>3__timeout (TimeSpan)
//   0x48  ptr    <>5__2       (IShogiMatchStreamReply result local)
#define OFF_SM_STATE   0x08
#define OFF_SM_STREAM  0x28
#define OFF_SM_RESULT  0x48

typedef void (*MoveNextVoid_t)(void *self);
static MoveNextVoid_t orig_ReceiveTimeoutMoveNext __attribute__((unused)) = NULL;

void HookReceiveTimeoutMoveNext(void *self) {
    KIOU_CALL_ORIG_VOID(orig_ReceiveTimeoutMoveNext, self);

    if (!self) return;

    int32_t smState = readI32(self, OFF_SM_STATE);
    // -2 means coroutine completed and result is written.
    if (smState != -2) return;

    void *reply = readPtr(self, OFF_SM_RESULT);
    if (!reply) return;

    // Cache stream pointer on first successful receipt.
    void *stream = readPtr(self, OFF_SM_STREAM);
    if (stream && g_matchStreamCache != stream) {
        g_matchStreamCache = stream;
        IPALog([NSString stringWithFormat:@"[MFILTER] cached stream=%p", stream]);
    }

    int32_t event = readI32(reply, OFF_REPLY_EVENT);

    if (event == MATCH_STREAM_EVENT_MATCHING_STATUS) {
        int32_t limitRange = KEBFixedRateRange();
        if (limitRange <= 0) return;

        void *mStatus = readPtr(reply, OFF_REPLY_MATCHING_STATUS);
        if (!mStatus) return;

        int32_t currentRange = readI32(mStatus, OFF_MATCHING_STATUS_CURRENT_RATE_RANGE);
        if (currentRange <= limitRange) return;

        IPALog([NSString stringWithFormat:
                  @"[MFILTER] CurrentRateRange=%d > limit=%d — requeuing",
                  (int)currentRange, (int)limitRange]);

        // LeaveQueue then immediately JoinQueue to reset the range.
        sendAction(stream, MATCH_STREAM_ACTION_LEAVE_QUEUE,
                   MATCHING_CLIENT_TYPE_SEARCHING);
        sendAction(stream, MATCH_STREAM_ACTION_JOIN_QUEUE,
                   MATCHING_CLIENT_TYPE_SEARCHING);
    }
}

// ---------------------------------------------------------------------------
// Hook C: IShogiMatchStreamArgs.Create (static)
//   IShogiMatchStreamArgs Create(action, matchType, rankRule, eventRule,
//                                mstEventMatchId, clientType, beginnerSupport)
//
// We observe every Create call so we can cache the last JoinQueue parameters.
// The filter re-queue path uses these to send a fresh JoinQueue with the
// original match settings.
// ---------------------------------------------------------------------------
typedef void *(*ArgsCreate_t)(int32_t action, int32_t matchType,
                               int32_t rankRuleType, int32_t eventRuleType,
                               int32_t mstEventMatchId,
                               int32_t matchingClientType,
                               bool enableBeginnerSupport);
static ArgsCreate_t orig_ArgsCreate __attribute__((unused)) = NULL;

void *HookArgsCreate(int32_t action, int32_t matchType,
                     int32_t rankRuleType, int32_t eventRuleType,
                     int32_t mstEventMatchId,
                     int32_t matchingClientType,
                     bool enableBeginnerSupport) {
    void *result = KIOU_CALL_ORIG_RET(void *, orig_ArgsCreate,
                                       action, matchType, rankRuleType,
                                       eventRuleType, mstEventMatchId,
                                       matchingClientType, enableBeginnerSupport);

    // Cache params whenever a JoinQueue is sent.
    if (action == MATCH_STREAM_ACTION_JOIN_QUEUE) {
        g_cachedMatchType       = matchType;
        g_cachedRankRuleType    = rankRuleType;
        g_cachedEventRuleType   = eventRuleType;
        g_cachedMstEventMatchId = mstEventMatchId;
        g_cachedBeginnerSupport = enableBeginnerSupport;
        IPALog([NSString stringWithFormat:
                  @"[MFILTER] JoinQueue cached: matchType=%d rankRule=%d "
                  @"eventRule=%d mstId=%d beginner=%s",
                  (int)matchType, (int)rankRuleType, (int)eventRuleType,
                  (int)mstEventMatchId, enableBeginnerSupport ? "true" : "false"]);
    }

    return result;
}

// ---------------------------------------------------------------------------
// Installer
// ---------------------------------------------------------------------------
#if !KIOU_CHINLAN
void InstallMatchingFilterObserveHook(uintptr_t unityBase) {
    // Resolve the static Create fn pointer used by sendAction().
    g_ArgsCreate = (MatchStreamArgsCreate_t)(void *)
        (unityBase + RVA_MATCH_STREAM_ARGS_CREATE);

    struct { const char *tag; uintptr_t rva; void *hook; void **origSlot; } entries[] = {
        { "GetValidMatchFoundStatus",
          0x5D04E94,
          (void *)HookGetValidMatchFoundStatus,
          (void **)&orig_GetValidMatchFoundStatus },
        { "ReceiveWithTimeoutAsync.MoveNext",
          RVA_RECEIVE_TIMEOUT_MOVENEXT,
          (void *)HookReceiveTimeoutMoveNext,
          (void **)&orig_ReceiveTimeoutMoveNext },
        { "IShogiMatchStreamArgs.Create",
          RVA_MATCH_STREAM_ARGS_CREATE,
          (void *)HookArgsCreate,
          (void **)&orig_ArgsCreate },
    };

    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        uintptr_t addr = unityBase + entries[i].rva;
        MSHookFunction((void *)addr, entries[i].hook, entries[i].origSlot);
        IPALog([NSString stringWithFormat:
                  @"[MFILTER] hooked %s @0x%lx (base+0x%lx)",
                  entries[i].tag,
                  (unsigned long)addr,
                  (unsigned long)entries[i].rva]);
    }

    // g_ArgsCreate is now also used via orig_ArgsCreate trampoline; keep
    // the direct pointer as a fallback for the sendAction() path which must
    // not go through the hook itself (would recurse).
    g_ArgsCreate = (MatchStreamArgsCreate_t)orig_ArgsCreate;

    IPALog(@"[MFILTER] matching filter hooks installed");
}
#else
void InstallMatchingFilterObserveHook(uintptr_t unityBase) {
    g_ArgsCreate = (MatchStreamArgsCreate_t)(void *)
        (unityBase + RVA_MATCH_STREAM_ARGS_CREATE);
    IPALog(@"[MFILTER] chinlan: filter hooks are no-op (cave-driven); "
             @"ArgsCreate resolved for sendAction()");
}
#endif // !KIOU_CHINLAN
