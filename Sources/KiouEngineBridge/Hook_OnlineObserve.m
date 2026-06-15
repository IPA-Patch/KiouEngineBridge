#import "Internal.h"

#import <mach/mach_time.h>

// ===========================================================================
// Hook_OnlineObserve — server-authoritative play extras.
//
// MatchController.ExecuteMoveAndGetResult (Hook_CommonObserve) already covers
// "a move was committed" for every mode. This file adds the two online-only
// signals that the common chokepoint can't deliver:
//
//   (A) OnlinePvPMode.UpdateAuthoritativeSnapshot(string sfen, PlayerSide,
//                                                 float blackTimeSec,
//                                                 float whiteTimeSec,
//                                                 int moveCount)
//       — full-position sync from the server. The SFEN arrives as a plain
//         System.String*, no Position / Sunfish decoding required.
//
//   (B) OnlinePvPMode.HandleMoveResult(IShogiGameStreamReply reply)
//       — the per-move reply envelope. The interesting strings (MoveUsi,
//         NewPositionSfen) live on the embedded IShogiMoveResultStatus.
//         We log the reply pointer here; the actual MoveResult layout
//         probe is deferred until we have a real reply to look at on
//         device (the concrete ShogiGameStreamReply field offset for
//         MoveResult is not pinned in dump.cs yet).
//
// CPUStreamMode has its own UpdateAuthoritativeSnapshot (0x59EB0E0). We
// will mirror the pattern in a separate Hook_CpuStreamObserve.m once we've
// confirmed it carries the same kind of SFEN string the online one does.
//
// RVAs (KIOU 1.0.1 build 11):
//
//   0x5A0A64C  OnlinePvPMode.UpdateAuthoritativeSnapshot
//                  (string, PlayerSide, float, float, int)
//   0x5A0CBD0  OnlinePvPMode.HandleMoveResult(IShogiGameStreamReply)
// ===========================================================================

#define RVA_ONLINE_UPDATE_SNAPSHOT     0x5A0A64C
#define RVA_ONLINE_HANDLE_RESULT       0x5A0CBD0
#define RVA_CPUSTREAM_UPDATE_SNAPSHOT  0x59EB0E0  // CPUStreamMode counterpart

// ---------------------------------------------------------------------------
// (A) UpdateAuthoritativeSnapshot
//
// arm64 ABI for instance method:
//   x0 = self (OnlinePvPMode)
//   x1 = sfen (System.String*)
//   w2 = turn (PlayerSide / int32)
//   s0 = blackTimeSec (float)
//   s1 = whiteTimeSec (float)
//   w3 = moveCount (int32)
// ---------------------------------------------------------------------------
typedef void (*UpdateAuthoritativeSnapshot_t)(void *self,
                                              void *sfenStr,
                                              int32_t turn,
                                              float blackTimeSec,
                                              float whiteTimeSec,
                                              int32_t moveCount);
static UpdateAuthoritativeSnapshot_t orig_UpdateAuthoritativeSnapshot = NULL;

void hook_UpdateAuthoritativeSnapshot(void *self,
                                      void *sfenStr,
                                      int32_t turn,
                                      float blackTimeSec,
                                      float whiteTimeSec,
                                      int32_t moveCount) {
    // The fact that we just received an authoritative snapshot is the
    // strongest "this is an online match" signal we have. Cache the
    // OnlinePvPMode self so Inject_Move can route to OnPlayerMoveAsync if
    // the user has opted into server-side injection.
    if (g_onlineModeCache != self) g_onlineModeCache = self;
    g_lastOnlineEvtUs = mach_absolute_time();
    if (sfenStr) g_authoritativeSfenString = sfenStr;

    NSString *sfen = il2cppStringToNSString(sfenStr);
    file_log([NSString stringWithFormat:
              @"[SNAPSHOT] online turn=%d move_count=%d "
              @"black=%.2fs white=%.2fs sfen=\"%@\"",
              (int)turn, (int)moveCount,
              (double)blackTimeSec, (double)whiteTimeSec,
              sfen ?: @""]);
    // Phase 2 doesn't surface snapshots over WS — Usi_Engine relies on
    // ADAPTER2 observations (which fire whenever the local engine applies
    // a move) for turn tracking. The file_log line above is enough to
    // debug authoritative-state drift after the fact.
    (void)sfen;
    if (orig_UpdateAuthoritativeSnapshot) {
        orig_UpdateAuthoritativeSnapshot(self, sfenStr, turn,
                                         blackTimeSec, whiteTimeSec,
                                         moveCount);
    }
}

// ---------------------------------------------------------------------------
// (B) HandleMoveResult — just record that a reply arrived, plus the pointer.
//
// arm64 ABI:
//   x0 = self (OnlinePvPMode)
//   x1 = reply (IShogiGameStreamReply*)
//
// We deliberately do NOT walk the reply struct yet. The interface vtable
// layout for the concrete ShogiGameStreamReply means the MoveResult field
// offset is brittle — dump.cs marks the property getter as a virtual slot,
// not a fixed field. Once we have one real reply pointer in hand on device,
// a follow-up commit will pin the offset by walking the first ~16 pointers
// and matching the one whose +0x10 string-length field decodes to a
// plausible USI move ("[1..10] chars, ascii"). That probe happens in this
// hook on first reply.
// ---------------------------------------------------------------------------
typedef void (*HandleMoveResult_t)(void *self, void *reply);
static HandleMoveResult_t orig_HandleMoveResult = NULL;

static uint32_t g_handleResultCount = 0;

void hook_HandleMoveResult(void *self, void *reply) {
    if (g_onlineModeCache != self) g_onlineModeCache = self;
    g_lastOnlineEvtUs = mach_absolute_time();

    uint32_t n = ++g_handleResultCount;
    if (n <= 3 || (n % 30) == 0) {
        // Log the first three replies in full and then sample every 30th to
        // keep the file from ballooning during long matches.
        file_log([NSString stringWithFormat:
                  @"[RESULT] online HandleMoveResult call#%u self=%p reply=%p",
                  n, self, reply]);
    }
    // Phase 2: HandleMoveResult is server-side bookkeeping; the USI engine
    // doesn't need to see it. file_log keeps a sampled trace for postmortems.
    if (orig_HandleMoveResult) orig_HandleMoveResult(self, reply);
}

// ---------------------------------------------------------------------------
// CPUStreamMode.UpdateAuthoritativeSnapshot — same signature as the Online
// one, different containing class. We mirror the Online behavior: cache the
// self pointer, record the snapshot timestamp, capture the il2cpp SFEN
// string pointer into the shared cache, and log a [SNAPSHOT cpu_stream]
// line so the bridge can correlate.
// ---------------------------------------------------------------------------
static UpdateAuthoritativeSnapshot_t orig_CpuStream_UpdateSnapshot = NULL;

void hook_CpuStream_UpdateSnapshot(void *self,
                                   void *sfenStr,
                                   int32_t turn,
                                   float blackTimeSec,
                                   float whiteTimeSec,
                                   int32_t moveCount) {
    if (g_cpuStreamModeCache != self) g_cpuStreamModeCache = self;
    g_lastCpuStreamEvtUs = mach_absolute_time();
    if (sfenStr) g_authoritativeSfenString = sfenStr;

    NSString *sfen = il2cppStringToNSString(sfenStr);
    file_log([NSString stringWithFormat:
              @"[SNAPSHOT] cpu_stream turn=%d move_count=%d "
              @"black=%.2fs white=%.2fs sfen=\"%@\"",
              (int)turn, (int)moveCount,
              (double)blackTimeSec, (double)whiteTimeSec,
              sfen ?: @""]);
    // Phase 2: see comment in hook_UpdateAuthoritativeSnapshot — snapshots
    // stay file_log-only and the USI engine tracks turns via ADAPTER2.
    (void)sfen;
    if (orig_CpuStream_UpdateSnapshot) {
        orig_CpuStream_UpdateSnapshot(self, sfenStr, turn,
                                      blackTimeSec, whiteTimeSec,
                                      moveCount);
    }
}

// ---------------------------------------------------------------------------
// Installer.
// ---------------------------------------------------------------------------
#if !KIOU_BINPATCH
void install_OnlineObserve_hook(uintptr_t unityBase) {
    uintptr_t addrSnap = unityBase + RVA_ONLINE_UPDATE_SNAPSHOT;
    MSHookFunction((void *)addrSnap,
                   (void *)hook_UpdateAuthoritativeSnapshot,
                   (void **)&orig_UpdateAuthoritativeSnapshot);
    file_log([NSString stringWithFormat:
              @"[ONLINE] hooked OnlinePvPMode.UpdateAuthoritativeSnapshot "
              @"@0x%lx (base+0x%x)",
              (unsigned long)addrSnap,
              (unsigned)RVA_ONLINE_UPDATE_SNAPSHOT]);

    uintptr_t addrRes = unityBase + RVA_ONLINE_HANDLE_RESULT;
    MSHookFunction((void *)addrRes,
                   (void *)hook_HandleMoveResult,
                   (void **)&orig_HandleMoveResult);
    file_log([NSString stringWithFormat:
              @"[ONLINE] hooked OnlinePvPMode.HandleMoveResult "
              @"@0x%lx (base+0x%x)",
              (unsigned long)addrRes,
              (unsigned)RVA_ONLINE_HANDLE_RESULT]);

    uintptr_t addrCpuSnap = unityBase + RVA_CPUSTREAM_UPDATE_SNAPSHOT;
    MSHookFunction((void *)addrCpuSnap,
                   (void *)hook_CpuStream_UpdateSnapshot,
                   (void **)&orig_CpuStream_UpdateSnapshot);
    file_log([NSString stringWithFormat:
              @"[ONLINE] hooked CPUStreamMode.UpdateAuthoritativeSnapshot "
              @"@0x%lx (base+0x%x)",
              (unsigned long)addrCpuSnap,
              (unsigned)RVA_CPUSTREAM_UPDATE_SNAPSHOT]);
}
#endif  // !KIOU_BINPATCH
// On the binpatch build, the three Online/CPUStream observation sites are
// routed via the static cave + SLOT dispatcher
// (KIOU_BR_HOOK_ONLINE_UPDATE_SNAPSHOT / _ONLINE_HANDLE_RESULT /
// _CPUSTREAM_UPDATE_SNAPSHOT in recipes/kiouenginebridge.py).
