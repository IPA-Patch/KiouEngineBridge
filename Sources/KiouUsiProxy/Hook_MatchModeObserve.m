#import "Internal.h"

#import <mach/mach_time.h>

// ===========================================================================
// Hook_MatchModeObserve — capture every IMatchMode.OnPlayerMoveAsync entry.
//
// Why this exists:
//   The naive "Adapter.TryMakeMove" injection path moved the underlying
//   board state forward (SFEN advanced, ok=1) but the UI didn't redraw.
//   dump.cs shows that the official "human played a move" entry point is
//   IMatchMode.OnPlayerMoveAsync(Move, CancellationToken) — a per-concrete
//   method on each match mode that also touches GameStateStore, which is
//   what the UIBoardPresenter subscribes to. So if we call this method
//   instead of TryMakeMove the UI gets the same update path as a real
//   player tap.
//
//   But these methods are instance methods on per-mode singletons we can't
//   reach from anywhere static. So we hook each one solely to grab the
//   `self` pointer the first (and every subsequent) time the engine itself
//   uses it — typically during the "AI thinks of a move and replays it as
//   the player move" flow at startup of a CPU game, or any earlier path
//   that fires once. Once we've seen one, Inject_Move can replay future
//   inbound USI lines by calling the *original* (untrampolined) function
//   pointer on that cached `self`.
//
// What this file deliberately doesn't do:
//   - It doesn't intercept anything to change behaviour. The hooks run the
//     original immediately and return whatever it returned.
//   - It doesn't try to read field offsets out of the mode instance. The
//     only thing we want is the receiver pointer.
// ===========================================================================

// ---------------------------------------------------------------------------
// RVAs (KIOU 1.0.1 build 11). One per concrete IMatchMode implementor.
// Verified via tools/re/il2cpp_query.py method <name>.
// ---------------------------------------------------------------------------
#define RVA_AI_OPM             0x59E5268
#define RVA_CPUSTREAM_OPM      0x59E886C
#define RVA_LOCAL_OPM          0x59FF87C
#define RVA_ONLINE_OPM         0x5A012D8
#define RVA_RECORDREPLAY_OPM   0x5A2B3EC

#define RVA_AI_INIT            0x59E4E0C
#define RVA_CPUSTREAM_INIT     0x59E7B48
#define RVA_LOCAL_INIT         0x59FF7B0
#define RVA_ONLINE_INIT        0x5A00E90
#define RVA_RECORDREPLAY_INIT  0x5A2ADD0

#define RVA_AI_END             0x59E5958
#define RVA_CPUSTREAM_END      0x59EC818
#define RVA_LOCAL_END          0x59FF8F8
#define RVA_ONLINE_END         0x5A0139C
#define RVA_RECORDREPLAY_END   0x5A2B564

// OnMatchStart() — synchronous void, fires once after InitializeAsync has
// finished its sync prologue AND its async tail. By the time this runs the
// `_localPlayer` field is guaranteed to hold the user's seat assignment,
// which InitializeAsync may not have written yet at the moment we return
// from it (the assignment lives inside the async state machine and we
// observed it on-device returning before the field was populated).
#define RVA_AI_START           0x59E5000
#define RVA_CPUSTREAM_START    0x59E7D64
#define RVA_LOCAL_START        0x59FF878
#define RVA_ONLINE_START       0x59FFE3C
#define RVA_RECORDREPLAY_START 0x5A2B36C

// Field offset of `_localPlayer` (PlayerSide, int32) on each mode that has
// a fixed human-seat assignment. AIMatchMode keeps the field at 0x54,
// CPUStreamMode at 0x60, OnlinePvPMode at 0x4C.
#define OFF_AI_LOCALPLAYER          0x54
#define OFF_CPUSTREAM_LOCALPLAYER   0x60
#define OFF_ONLINE_LOCALPLAYER      0x4C

// ---------------------------------------------------------------------------
// MatchMode self caches + freshness timestamps. Definitions go here; the
// declarations live in Internal.h so Inject_Move.m can read them.
// ---------------------------------------------------------------------------
void *volatile g_aiMatchModeCache      = NULL;
void *volatile g_cpuStreamModeCache    = NULL;
void *volatile g_localPvPModeCache     = NULL;
void *volatile g_recordReplayModeCache = NULL;
// g_onlineModeCache is defined in Inject_Move.m (kept there because the
// online observer was the first place to populate it and the cache outlives
// this module's hook in the load order).

// Local-player side per mode. -1 means "not initialized" (or N/A).
int32_t volatile g_aiLocalPlayer        = -1;
int32_t volatile g_cpuStreamLocalPlayer = -1;
int32_t volatile g_onlineLocalPlayer    = -1;

uint64_t volatile g_lastAiMatchEvtUs       = 0;
uint64_t volatile g_lastCpuStreamEvtUs     = 0;
uint64_t volatile g_lastLocalPvPEvtUs      = 0;
uint64_t volatile g_lastRecordReplayEvtUs  = 0;

// ---------------------------------------------------------------------------
// Original (untrampolined) function pointers. Inject_Move.m calls these
// directly so its replay doesn't re-enter our hooks (which would log the
// injection twice).
// ---------------------------------------------------------------------------
OnPlayerMoveAsync_t orig_AIMatchMode_OnPlayerMoveAsync      = NULL;
OnPlayerMoveAsync_t orig_CPUStreamMode_OnPlayerMoveAsync    = NULL;
OnPlayerMoveAsync_t orig_LocalPvPMode_OnPlayerMoveAsync     = NULL;
OnPlayerMoveAsync_t orig_OnlinePvPMode_OnPlayerMoveAsync    = NULL;
OnPlayerMoveAsync_t orig_RecordReplayMode_OnPlayerMoveAsync = NULL;

// InitializeAsync(MatchConfig, GameStateStore, ShogiGameAdapter, CT) -> UniTask.
// We don't read MatchConfig — it's passed as a struct argument we don't
// need. self in x0, and the integer args fall through naturally; the
// MatchConfig struct is passed as a value, which on arm64 may consume
// additional registers, but we don't touch it so the precise calling
// convention doesn't matter.
typedef UniTaskRet (*InitializeAsync_t)(void *self, void *cfg, void *stateStore,
                                       void *gameAdapter, void *ct);
static InitializeAsync_t orig_AI_Init        = NULL;
static InitializeAsync_t orig_CPUStream_Init = NULL;
static InitializeAsync_t orig_Local_Init     = NULL;
static InitializeAsync_t orig_Online_Init    = NULL;
static InitializeAsync_t orig_Replay_Init    = NULL;

// OnMatchEndAsync(CT) -> UniTask. Same shape as OnPlayerMoveAsync but
// without the Move argument.
typedef UniTaskRet (*OnMatchEndAsync_t)(void *self, void *ct);
static OnMatchEndAsync_t orig_AI_End        = NULL;
static OnMatchEndAsync_t orig_CPUStream_End = NULL;
static OnMatchEndAsync_t orig_Local_End     = NULL;
static OnMatchEndAsync_t orig_Online_End    = NULL;
static OnMatchEndAsync_t orig_Replay_End    = NULL;

// OnMatchStart() -> void. Truly synchronous; no UniTask gymnastics.
typedef void (*OnMatchStart_t)(void *self);
static OnMatchStart_t orig_AI_Start        = NULL;
static OnMatchStart_t orig_CPUStream_Start = NULL;
static OnMatchStart_t orig_Local_Start     = NULL;
static OnMatchStart_t orig_Online_Start    = NULL;
static OnMatchStart_t orig_Replay_Start    = NULL;

// First-touch logging counters so we don't spam the log file every move.
// Log the first three calls per mode and every 30th after that.
static uint32_t g_aiSeen      = 0;
static uint32_t g_cpuStreamSeen   = 0;
static uint32_t g_localPvPSeen    = 0;
static uint32_t g_onlinePMSeen    = 0;
static uint32_t g_recordReplaySeen = 0;

static inline BOOL shouldLog(uint32_t n) {
    return n <= 3 || (n % 30) == 0;
}

// ---------------------------------------------------------------------------
// Hook bodies. All five share the same shape: stash self, bump the seen
// counter, occasionally log, then chain to the original. The UniTask return
// register convention means we MUST tail through the original — pretending
// to return void here would corrupt the caller's await frame.
// ---------------------------------------------------------------------------

#define DEFINE_OPM_HOOK(MODE_LOWER, MODE_TAG, CACHE_VAR, TS_VAR, SEEN_VAR, ORIG_VAR) \
    static UniTaskRet hook_##MODE_LOWER##_OPM(void *self, uint32_t mv, void *ct) {  \
        if ((CACHE_VAR) != self) (CACHE_VAR) = self;                                \
        (TS_VAR) = mach_absolute_time();                                            \
        uint32_t n = ++(SEEN_VAR);                                                  \
        if (shouldLog(n)) {                                                         \
            file_log([NSString stringWithFormat:                                    \
                      @"[MMODE] " MODE_TAG " OPM call#%u self=%p move=0x%x",       \
                      n, self, (unsigned)mv]);                                      \
        }                                                                           \
        if (ORIG_VAR) return (ORIG_VAR)(self, mv, ct);                              \
        return (UniTaskRet){ NULL, NULL };                                          \
    }

DEFINE_OPM_HOOK(ai,       "AIMatchMode",      g_aiMatchModeCache,
                g_lastAiMatchEvtUs,      g_aiSeen,
                orig_AIMatchMode_OnPlayerMoveAsync)
DEFINE_OPM_HOOK(cpustream, "CPUStreamMode",   g_cpuStreamModeCache,
                g_lastCpuStreamEvtUs,    g_cpuStreamSeen,
                orig_CPUStreamMode_OnPlayerMoveAsync)
DEFINE_OPM_HOOK(local,    "LocalPvPMode",     g_localPvPModeCache,
                g_lastLocalPvPEvtUs,     g_localPvPSeen,
                orig_LocalPvPMode_OnPlayerMoveAsync)
DEFINE_OPM_HOOK(online,   "OnlinePvPMode",    g_onlineModeCache,
                g_lastOnlineEvtUs,       g_onlinePMSeen,
                orig_OnlinePvPMode_OnPlayerMoveAsync)
DEFINE_OPM_HOOK(replay,   "RecordReplayMode", g_recordReplayModeCache,
                g_lastRecordReplayEvtUs, g_recordReplaySeen,
                orig_RecordReplayMode_OnPlayerMoveAsync)

#undef DEFINE_OPM_HOOK

// ---------------------------------------------------------------------------
// InitializeAsync hooks. We invoke the original, then capture `self` and (on
// the three modes with a `_localPlayer` field) read the player side. Order
// matters: InitializeAsync is the synchronous prelude to UniTask kickoff —
// `_localPlayer` is assigned inside the original method body (in the sync
// part, before any await), so by the time we return from the original the
// field is populated.
//
// We also stash self before calling the original so an early crash in
// InitializeAsync (defensive paranoia — it never actually crashes here)
// still leaves us with a reachable mode pointer for Inject_Move's debug
// dump.
// ---------------------------------------------------------------------------

#define DEFINE_INIT_HOOK(MODE_LOWER, MODE_TAG, CACHE_VAR, ORIG_VAR)                     \
    static UniTaskRet hook_##MODE_LOWER##_Init(void *self, void *cfg,                   \
                                               void *store, void *adapter,              \
                                               void *ct) {                              \
        if ((CACHE_VAR) != self) (CACHE_VAR) = self;                                    \
        /* Capture the adapter the moment IMatchMode.InitializeAsync hands */          \
        /* it over. Without this, g_adapterCache stays NULL until the first */         \
        /* CPU move flows through Hook_LowLevelObserve, which means the */             \
        /* local TryMakeMove side of the injection (the part that nudges */            \
        /* the UI when OPM alone doesn't) can't fire on the very first move. */        \
        if (adapter && g_adapterCache != adapter) {                                    \
            g_adapterCache = adapter;                                                   \
            void *gc = readPtr(adapter, KIOU_ADAPTER_OFF_GAME_CONTROLLER);              \
            if (gc && g_gameCtrlCache != gc) g_gameCtrlCache = gc;                      \
        }                                                                               \
        UniTaskRet ret = { NULL, NULL };                                                \
        if (ORIG_VAR) ret = (ORIG_VAR)(self, cfg, store, adapter, ct);                  \
        file_log([NSString stringWithFormat:                                            \
                  @"[MMODE] " MODE_TAG " Init self=%p store=%p adapter=%p",             \
                  self, store, adapter]);                                               \
        return ret;                                                                     \
    }

// Init only caches the self pointer — `_localPlayer` lives behind an
// async assignment we can't see synchronously, so it gets read in
// OnMatchStart below.
DEFINE_INIT_HOOK(ai,        "AIMatchMode",      g_aiMatchModeCache,
                 orig_AI_Init)
DEFINE_INIT_HOOK(cpustream, "CPUStreamMode",    g_cpuStreamModeCache,
                 orig_CPUStream_Init)
DEFINE_INIT_HOOK(local,     "LocalPvPMode",     g_localPvPModeCache,
                 orig_Local_Init)
DEFINE_INIT_HOOK(online,    "OnlinePvPMode",    g_onlineModeCache,
                 orig_Online_Init)
DEFINE_INIT_HOOK(replay,    "RecordReplayMode", g_recordReplayModeCache,
                 orig_Replay_Init)

#undef DEFINE_INIT_HOOK

// ---------------------------------------------------------------------------
// OnMatchStart hooks. Fires AFTER InitializeAsync's async body has run, so
// `_localPlayer` is guaranteed to be populated by now on the three modes
// that have it. We invoke the original first, then read the field — this
// matches the "engine state must be ready" contract OnMatchStart's
// implementation depends on, and means even if the field were somehow
// computed inside OnMatchStart itself we'd still pick up the final value.
//
// LocalPvPMode / RecordReplayMode have no seat assignment to record, so
// we just call through.
// ---------------------------------------------------------------------------

#define DEFINE_START_HOOK(MODE_LOWER, MODE_TAG, CACHE_VAR, LP_CACHE, LP_OFFSET, ORIG_VAR) \
    static void hook_##MODE_LOWER##_Start(void *self) {                                   \
        if ((CACHE_VAR) != self) (CACHE_VAR) = self;                                      \
        if (ORIG_VAR) (ORIG_VAR)(self);                                                   \
        int32_t lp = -1;                                                                  \
        if ((LP_OFFSET) != 0 && self) {                                                   \
            lp = readI32(self, (LP_OFFSET));                                              \
            (LP_CACHE) = lp;                                                              \
        }                                                                                 \
        file_log([NSString stringWithFormat:                                              \
                  @"[MMODE] " MODE_TAG " Start self=%p localPlayer=%d",                   \
                  self, (int)lp]);                                                        \
        /* Tell the USI engine driver that a match just started so it can */              \
        /* prep its state machine and (when we're the side to move first) */              \
        /* kickstart a position+go without waiting for the first observed */              \
        /* opponent move. */                                                              \
        usi_engine_on_match_start(lp);                                                    \
    }

// AIMatchMode / CPUStreamMode / OnlinePvPMode capture _localPlayer.
DEFINE_START_HOOK(ai,        "AIMatchMode",      g_aiMatchModeCache,
                  g_aiLocalPlayer,        OFF_AI_LOCALPLAYER,        orig_AI_Start)
DEFINE_START_HOOK(cpustream, "CPUStreamMode",    g_cpuStreamModeCache,
                  g_cpuStreamLocalPlayer, OFF_CPUSTREAM_LOCALPLAYER, orig_CPUStream_Start)
DEFINE_START_HOOK(online,    "OnlinePvPMode",    g_onlineModeCache,
                  g_onlineLocalPlayer,    OFF_ONLINE_LOCALPLAYER,    orig_Online_Start)

// LocalPvPMode / RecordReplayMode have no `_localPlayer` — pass offset 0
// and the macro skips the read.
static int32_t volatile g_unusedLocalPlayerSlot = -1;
DEFINE_START_HOOK(local,  "LocalPvPMode",     g_localPvPModeCache,
                  g_unusedLocalPlayerSlot, 0, orig_Local_Start)
DEFINE_START_HOOK(replay, "RecordReplayMode", g_recordReplayModeCache,
                  g_unusedLocalPlayerSlot, 0, orig_Replay_Start)

#undef DEFINE_START_HOOK

// ---------------------------------------------------------------------------
// OnMatchEndAsync hooks. Clear the mode self cache and (for the three
// fixed-seat modes) reset `_localPlayer` to "unknown" (-1). We do the
// clear BEFORE calling the original so that if the original tears down
// state asynchronously, Inject_Move's route picker stops picking this
// mode immediately rather than racing the teardown.
// ---------------------------------------------------------------------------

#define DEFINE_END_HOOK(MODE_LOWER, MODE_TAG, CACHE_VAR, LP_CACHE, HAS_LP, ORIG_VAR) \
    static UniTaskRet hook_##MODE_LOWER##_End(void *self, void *ct) {               \
        file_log([NSString stringWithFormat:                                        \
                  @"[MMODE] " MODE_TAG " End self=%p", self]);                      \
        (CACHE_VAR) = NULL;                                                         \
        if (HAS_LP) (LP_CACHE) = -1;                                                \
        /* Whichever match owned the cached SFEN is over now. Clear it so the */    \
        /* next match doesn't inherit a stale board on its first injection. */     \
        g_authoritativeSfenString = NULL;                                           \
        /* Roll the USI engine state machine back to READY so a new game's */       \
        /* usinewgame is sent before the next position+go. */                       \
        usi_engine_on_match_end();                                                  \
        if (ORIG_VAR) return (ORIG_VAR)(self, ct);                                  \
        return (UniTaskRet){ NULL, NULL };                                          \
    }

DEFINE_END_HOOK(ai,        "AIMatchMode",      g_aiMatchModeCache,
                g_aiLocalPlayer,        true,  orig_AI_End)
DEFINE_END_HOOK(cpustream, "CPUStreamMode",    g_cpuStreamModeCache,
                g_cpuStreamLocalPlayer, true,  orig_CPUStream_End)
DEFINE_END_HOOK(online,    "OnlinePvPMode",    g_onlineModeCache,
                g_onlineLocalPlayer,    true,  orig_Online_End)
DEFINE_END_HOOK(local,     "LocalPvPMode",     g_localPvPModeCache,
                g_unusedLocalPlayerSlot, false, orig_Local_End)
DEFINE_END_HOOK(replay,    "RecordReplayMode", g_recordReplayModeCache,
                g_unusedLocalPlayerSlot, false, orig_Replay_End)

#undef DEFINE_END_HOOK

// ---------------------------------------------------------------------------
// Installer. Wires up all five hooks.
// ---------------------------------------------------------------------------
void install_MatchModeObserve_hook(uintptr_t unityBase) {
    struct { const char *tag; const char *what; uintptr_t rva;
             void *hook; void **origSlot; } entries[] = {
        // OnPlayerMoveAsync — confirms the mode self pointer + populates
        // freshness timestamps used by the route picker.
        { "AIMatchMode",      "OnPlayerMoveAsync", RVA_AI_OPM,
          (void *)hook_ai_OPM,        (void **)&orig_AIMatchMode_OnPlayerMoveAsync },
        { "CPUStreamMode",    "OnPlayerMoveAsync", RVA_CPUSTREAM_OPM,
          (void *)hook_cpustream_OPM, (void **)&orig_CPUStreamMode_OnPlayerMoveAsync },
        { "LocalPvPMode",     "OnPlayerMoveAsync", RVA_LOCAL_OPM,
          (void *)hook_local_OPM,     (void **)&orig_LocalPvPMode_OnPlayerMoveAsync },
        { "OnlinePvPMode",    "OnPlayerMoveAsync", RVA_ONLINE_OPM,
          (void *)hook_online_OPM,    (void **)&orig_OnlinePvPMode_OnPlayerMoveAsync },
        { "RecordReplayMode", "OnPlayerMoveAsync", RVA_RECORDREPLAY_OPM,
          (void *)hook_replay_OPM,    (void **)&orig_RecordReplayMode_OnPlayerMoveAsync },

        // InitializeAsync — primary cache population, plus _localPlayer
        // capture on the seat-fixed modes.
        { "AIMatchMode",      "InitializeAsync", RVA_AI_INIT,
          (void *)hook_ai_Init,        (void **)&orig_AI_Init },
        { "CPUStreamMode",    "InitializeAsync", RVA_CPUSTREAM_INIT,
          (void *)hook_cpustream_Init, (void **)&orig_CPUStream_Init },
        { "LocalPvPMode",     "InitializeAsync", RVA_LOCAL_INIT,
          (void *)hook_local_Init,     (void **)&orig_Local_Init },
        { "OnlinePvPMode",    "InitializeAsync", RVA_ONLINE_INIT,
          (void *)hook_online_Init,    (void **)&orig_Online_Init },
        { "RecordReplayMode", "InitializeAsync", RVA_RECORDREPLAY_INIT,
          (void *)hook_replay_Init,    (void **)&orig_Replay_Init },

        // OnMatchEndAsync — clear the cache so cross-match dispatch can't
        // dispatch on a stale mode pointer.
        { "AIMatchMode",      "OnMatchEndAsync", RVA_AI_END,
          (void *)hook_ai_End,        (void **)&orig_AI_End },
        { "CPUStreamMode",    "OnMatchEndAsync", RVA_CPUSTREAM_END,
          (void *)hook_cpustream_End, (void **)&orig_CPUStream_End },
        { "LocalPvPMode",     "OnMatchEndAsync", RVA_LOCAL_END,
          (void *)hook_local_End,     (void **)&orig_Local_End },
        { "OnlinePvPMode",    "OnMatchEndAsync", RVA_ONLINE_END,
          (void *)hook_online_End,    (void **)&orig_Online_End },
        { "RecordReplayMode", "OnMatchEndAsync", RVA_RECORDREPLAY_END,
          (void *)hook_replay_End,    (void **)&orig_Replay_End },

        // OnMatchStart — synchronous prelude to live play; this is when we
        // read _localPlayer reliably for the seat-fixed modes.
        { "AIMatchMode",      "OnMatchStart", RVA_AI_START,
          (void *)hook_ai_Start,        (void **)&orig_AI_Start },
        { "CPUStreamMode",    "OnMatchStart", RVA_CPUSTREAM_START,
          (void *)hook_cpustream_Start, (void **)&orig_CPUStream_Start },
        { "LocalPvPMode",     "OnMatchStart", RVA_LOCAL_START,
          (void *)hook_local_Start,     (void **)&orig_Local_Start },
        { "OnlinePvPMode",    "OnMatchStart", RVA_ONLINE_START,
          (void *)hook_online_Start,    (void **)&orig_Online_Start },
        { "RecordReplayMode", "OnMatchStart", RVA_RECORDREPLAY_START,
          (void *)hook_replay_Start,    (void **)&orig_Replay_Start },
    };
    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        uintptr_t addr = unityBase + entries[i].rva;
        MSHookFunction((void *)addr, entries[i].hook, entries[i].origSlot);
        file_log([NSString stringWithFormat:
                  @"[MMODE] hooked %s.%s @0x%lx (base+0x%lx)",
                  entries[i].tag, entries[i].what,
                  (unsigned long)addr, (unsigned long)entries[i].rva]);
    }
}
