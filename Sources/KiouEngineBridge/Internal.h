#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>

#import "il2cpp.h"
#import "hookengine.h"
#import "logging.h"

// ===========================================================================
// Internal.h — KiouEngineBridge-private declarations.
//
// KiouEngineBridge embeds a CSA server (TCP :4081) inside the KIOU process.
// Observation hooks latch live GameController / ShogiGameAdapter /
// OnlinePvPMode pointers and convert Sunfish.Move to CSA notation;
// the injection layer feeds CSA moves back into KIOU's own TryMakeMove /
// OnPlayerMoveAsync paths so the on-device match advances exactly as if the
// user had played the move.
//
// What the injection layer is allowed to do:
//   - Call il2cpp-generated methods as function pointers (TryMakeMove,
//     Sunfish.Move.Create, Position.ToSFEN, OnlinePvPMode.OnPlayerMoveAsync).
//   - Cache the `self` pointer observed via hooks for later injection calls.
//
// What the injection layer is NOT allowed to do:
//   - Touch il2cpp object fields directly. il2cpp.h is read-only; write-side
//     helpers (writeU8 / writeI32) are deliberately excluded.
//
// Hook installers — one per feature module, wired by Tweak.m:
//
//   InstallOnlineObserveHook         (Hook_OnlineObserve.m)
//   InstallLowLevelObserveHook       (Hook_LowLevelObserve.m)
//   InstallMatchModeObserveHook      (Hook_MatchModeObserve.m)
//   InstallGameStateStoreObserveHook (Hook_GameStateStoreObserve.m)
//   InstallGameOrchestratorObserveHook (Hook_GameOrchestratorObserve.m)
//   InstallAfkSuppressHook           (Hook_AfkSuppress.m)
//   InstallInjectHook                (Inject_Move.m)
// ===========================================================================

#ifndef BUILD_COMMIT
#define BUILD_COMMIT "unknown"
#endif

#ifndef BUILD_VERSION
#define BUILD_VERSION "0.0.0"
#endif

// ---------------------------------------------------------------------------
// orig() invocation policy.
//
// On the JB build, MSHookFunction installs a trampoline at the target site;
// the target function body NEVER runs unless our hook explicitly calls
// orig(args). Forgetting to do so silently turns the hook into a wholesale
// replacement — bad news for sites like ShogiGameAdapter.TryMakeMove whose
// side effects (appending to _positionHistory, committing the move) are the
// reason callers invoke it.
//
// On the chinlan build, the static cave runs the displaced prologue
// instruction and then branches to orig + 4 verbatim — so orig is already
// going to execute, and a second call from the hook body would double-run
// the target. The hook must NOT call orig in that case.
//
// KIOU_CALL_ORIG_VOID / KIOU_CALL_ORIG_RET hide the distinction. Hook bodies
// uniformly write `KIOU_CALL_ORIG_VOID(orig, self, ...)` / etc.; the macro
// expands to the original call on JB and to a no-op on chinlan.
//
// Use the _RET variant when the original returns a value the hook (or the
// caller) needs. `RET_T` is the return type; on chinlan the macro returns
// a value-initialised RET_T (i.e. `(RET_T){0}`), which the caller never
// actually consumes because the cave's `B orig + 4` re-enters the real
// function and that return value is what the caller sees.
// ---------------------------------------------------------------------------
#if KIOU_CHINLAN
#  define KIOU_CALL_ORIG_VOID(ORIG, ...)         ((void)0)
#  define KIOU_CALL_ORIG_RET(RET_T, ORIG, ...)   ((RET_T){0})
#else
#  define KIOU_CALL_ORIG_VOID(ORIG, ...)                                       \
       do { if ((ORIG)) (ORIG)(__VA_ARGS__); } while (0)
#  define KIOU_CALL_ORIG_RET(RET_T, ORIG, ...)                                 \
       ((ORIG) ? (ORIG)(__VA_ARGS__) : (RET_T){0})
#endif

// ---------------------------------------------------------------------------
// Per-module hook installers. Tweak.m calls each one once UnityFramework has
// shown up; each installer guards itself if invoked twice.
// ---------------------------------------------------------------------------
void InstallOnlineObserveHook(uintptr_t unityBase);
void InstallLowLevelObserveHook(uintptr_t unityBase);
void InstallMatchModeObserveHook(uintptr_t unityBase);
void InstallInjectHook(uintptr_t unityBase);
void InstallAfkSuppressHook(uintptr_t unityBase);
void InstallBackToTitleSuppressHook(uintptr_t unityBase);
void InstallGameOrchestratorObserveHook(uintptr_t unityBase);
void InstallGrpcLoggingHook(uintptr_t unityBase);

// Settings panel (Settings_UI.m). Installs the right-edge swipe gesture on
// the key window; retries automatically if the window is not yet available.
// Call once from the constructor after the log sink is initialized.
void KEBSettingsInstall(void);

// UnityFramework base address captured at install time. Exposed so the
// match-end auto-rematch path can resolve static il2cpp methods
// (CpuMatchStarter.StartCpuFreeMatchAsync etc.) from inside a dispatch_after
// block that doesn't carry the installer's unityBase on the stack.
extern uintptr_t g_unityBase;

// GameOrchestrator instance, captured the first time
// GameOrchestrator.ActivateAsync passes through our hook. Used by the
// match-end auto-rematch path to close the result overlay before kicking the
// next match. NULL until ActivateAsync has fired at least once.
extern void *volatile g_gameOrchestratorCache;

// ---------------------------------------------------------------------------
// CSA TCP server (Server_CSA.m). Boot once at constructor time, then any
// hook can push a single CSA-protocol line to whichever engine is currently
// connected. No-op when no engine is attached.
// ---------------------------------------------------------------------------
void KEBCsaServerStart(uint16_t port);
void KEBCsaServerPush(NSString *line);

// Tear down the current TCP client (if any). Used by the CSA engine driver
// when an inbound `LOGOUT` arrives, or to force a teardown on shutdown.
// Idempotent. Runs the actual close on the accept queue so it composes
// safely with concurrent KEBCsaServerPush calls.
void KEBCsaServerClose(void);

// Register a callback for inbound LF-terminated lines. The handler is
// invoked on the recv queue (a serial dispatch queue, NOT the main thread).
// `line` is already UTF-8-decoded with CR/LF terminators stripped; the
// caller may retain it freely. Replace by passing NULL.
typedef void (*kiou_csa_line_handler_t)(NSString *line);
void KEBCsaServerSetLineHandler(kiou_csa_line_handler_t fn);

// ---------------------------------------------------------------------------
// Observation-side instance cache, populated by Hook_LowLevelObserve.m and
// Hook_OnlineObserve.m as live ShogiGameAdapter / GameController /
// OnlinePvPMode pointers pass through their hooks. Inject_Move.m reads these
// to know who to invoke TryMakeMove on. NULL means "no live session in that
// role" — Inject_Move.m treats that as a no-op.
//
// `volatile` because the writers run on whatever thread Unity happens to be
// on, and the reader (injection path) runs on the WS recv queue. Pointer
// reads / writes are atomic on arm64 so we don't need a mutex; volatile is
// just to keep the compiler from caching across reads.
// ---------------------------------------------------------------------------
extern void *volatile g_gameCtrlCache;     // Project.ShogiCore.GameController*
extern void *volatile g_adapterCache;      // ShogiGameAdapter*
extern void *volatile g_onlineModeCache;   // OnlinePvPMode*

// MatchMode self pointers captured by Hook_MatchModeObserve.m. Populated
// from InitializeAsync (early — first thing in a match) and confirmed by
// each OnPlayerMoveAsync hit. Cleared from OnMatchEndAsync. The "official"
// injection path lives in OnPlayerMoveAsync — TryMakeMove only mutates the
// headless engine, OnPlayerMoveAsync also drives GameStateStore so the UI
// redraws.
extern void *volatile g_aiMatchModeCache;     // Project.Game.Logic.AIMatchMode*
extern void *volatile g_cpuStreamModeCache;   // Project.Game.Logic.CPUStreamMode*
extern void *volatile g_localPvPModeCache;    // Project.Game.Logic.LocalPvPMode*
extern void *volatile g_recordReplayModeCache;// Project.Game.Logic.RecordReplayMode*

// Latest server-authoritative SFEN, captured directly from the il2cpp
// string handed to UpdateAuthoritativeSnapshot on whichever server-driven
// mode is live (Online or CPUStream). Stored as the raw il2cpp string
// pointer so it can be handed straight back into Position.CreateFromSFEN
// without touching unmanaged char buffers. Cleared on OnMatchEndAsync to
// avoid feeding the next match the previous one's leftovers.
extern void *volatile g_authoritativeSfenString;

// Local-player side captured from InitializeAsync. Valid (-1, 0, 1) only on
// modes that have a fixed "this seat = human" assignment (AIMatchMode,
// CPUStreamMode, OnlinePvPMode). LocalPvPMode and RecordReplayMode don't
// pin a side — both seats are operator-driven — so we leave them at -1
// and treat any turn as injectable. -1 also means "haven't been
// initialized yet" for the gated modes.
//
// PlayerSide enum: Black=0, White=1.
extern int32_t volatile g_aiLocalPlayer;
extern int32_t volatile g_cpuStreamLocalPlayer;
extern int32_t volatile g_onlineLocalPlayer;

// Last-observed timestamps (mach_absolute_time ticks, converted to us in
// Inject_Move.m via mach_timebase). Updated by the corresponding hook
// before kiou_*_cache is set. Inject_Move uses these as a fresh-enough
// signal when picking a route automatically.
extern uint64_t volatile g_lastOnlineEvtUs;   // online snapshot/result
extern uint64_t volatile g_lastAdapterEvtUs;  // adapter / gamectrl tryMove
extern uint64_t volatile g_lastAiMatchEvtUs;     // AIMatchMode.OnPlayerMoveAsync
extern uint64_t volatile g_lastCpuStreamEvtUs;   // CPUStreamMode.OnPlayerMoveAsync
extern uint64_t volatile g_lastLocalPvPEvtUs;    // LocalPvPMode.OnPlayerMoveAsync
extern uint64_t volatile g_lastRecordReplayEvtUs;// RecordReplayMode.OnPlayerMoveAsync

// Latest server-authoritative remaining time (seconds). Updated by
// HookUpdateAuthoritativeSnapshot (Online) and HookCpuStreamUpdateSnapshot.
// 0.0f means no snapshot this match yet (AI / Local modes never receive one).
// Cleared on OnMatchEndAsync.
extern float volatile g_latestBlackTimeSec;
extern float volatile g_latestWhiteTimeSec;

// ---------------------------------------------------------------------------
// Original (untrampolined) function pointers captured by hook installers.
// Inject_Move.m calls these directly to advance the position without
// re-entering the observation hooks (which would log the injected move a
// second time). NULL until the relevant installer has run.
// ---------------------------------------------------------------------------
typedef bool (*Adapter_TryMakeMove_Out_t)(void *self, uint32_t mv, void *outMv);
typedef bool (*GameCtrl_TryMakeMove_t)(void *self, uint32_t mv);
typedef void *(*Position_ToSFEN_t)(void *position);
typedef void *(*Move_ToStringSFEN_t)(void *moveSelf);

// UniTask is a 16-byte struct (IUniTaskSource* + short token, padded). On
// arm64 AAPCS it's returned in the {x0, x1} register pair. C-side hooks
// that wrap an il2cpp method returning UniTask MUST also return a 16-byte
// struct, otherwise the trampoline writes garbage into x1 and the caller's
// `await` reads through a nonsense pointer the very next instruction.
//
// We model UniTask as two raw pointer-sized halves and never inspect the
// fields — we just hand whatever the original returned back to the caller.
typedef struct { void *r0; void *r1; } UniTaskRet;

// OnPlayerMoveAsync(Move, CancellationToken) -> UniTask. CancellationToken
// is a single-field struct (CancellationTokenSource*), passed in x2 as a
// value; NULL means "no cancellation", which is what we want for
// fire-and-forget injection.
typedef UniTaskRet (*OnPlayerMoveAsync_t)(void *self, uint32_t mv, void *ct);

extern Adapter_TryMakeMove_Out_t orig_AdapterTryMakeMoveOut;
extern GameCtrl_TryMakeMove_t    orig_GameCtrlTryMakeMove;
extern Position_ToSFEN_t         g_Position_ToSFEN;
extern Move_ToStringSFEN_t       g_Move_ToStringSFEN;

extern OnPlayerMoveAsync_t orig_AIMatchMode_OnPlayerMoveAsync;
extern OnPlayerMoveAsync_t orig_CPUStreamMode_OnPlayerMoveAsync;
extern OnPlayerMoveAsync_t orig_LocalPvPMode_OnPlayerMoveAsync;
extern OnPlayerMoveAsync_t orig_OnlinePvPMode_OnPlayerMoveAsync;
extern OnPlayerMoveAsync_t orig_RecordReplayMode_OnPlayerMoveAsync;

// ShogiGameAdapter -> GameController field offset. Re-export from
// Hook_LowLevelObserve.m so Inject_Move.m can rediscover the GameController
// from an Adapter pointer when the cache only has the adapter side.
#define KIOU_ADAPTER_OFF_GAME_CONTROLLER  0x10

// ---------------------------------------------------------------------------
// Injection result record — last N moves the WS handler asked us to replay.
// Kept in a ring buffer in Inject_Move.m. Exposed here so a future query
// endpoint (or a debug dump on SIGUSR1) can read it back without
// re-implementing the format.
// ---------------------------------------------------------------------------
#define KIOU_INJECT_RING_SIZE   64
#define KIOU_INJECT_USI_MAX     16
#define KIOU_INJECT_ROUTE_MAX   24
#define KIOU_INJECT_SFEN_MAX    256

typedef struct {
    uint64_t ts_us;                              // mach_absolute_time -> us
    char     usi_in[KIOU_INJECT_USI_MAX];        // raw inbound usi token
    char     route[KIOU_INJECT_ROUTE_MAX];       // "adapter"/"gamectrl"/"player_move"/"skip"
    bool     ok;                                 // TryMakeMove return value
    uint32_t move_raw;                           // Sunfish.Move uint32 we built
    char     sfen_after[KIOU_INJECT_SFEN_MAX];   // post-injection SFEN, possibly truncated
    char     error[KIOU_INJECT_ROUTE_MAX];       // "" on success, otherwise short reason
} kiou_inject_record_t;

// Dump the most recent ring contents into the shared file log. Intended for
// manual debugging (e.g. fired from a SIGUSR1 handler or at unload). Safe to
// call from any thread.
void KEBInjectDumpRecent(void);

// ---------------------------------------------------------------------------
// Injection bridge — called by Csa_Engine.m when the connected engine sends
// a move. Returns true if the move was injected successfully
// (= OPM + Adapter.TryMakeMove path succeeded). The returned `outSfenAfter`
// and `outRaw` are populated with the post-injection SFEN and Move uint32
// for logging convenience; both may be nil/0 on failure. Internally
// dispatches to the Unity main thread.
bool inject_apply(NSString *usi,
                  NSString **outSfenAfter,
                  uint32_t *outRaw,
                  NSString **outErr);

// Read the SFEN of whatever Position the resolver hands us — useful for
// the post-handshake kick when the WS client connects mid-game. Returns
// nil when no Position is reachable. Must be called on the main thread
// because it touches il2cpp accessors.
NSString *inject_currentSfen(void);

// Match result type — used by Hook_MatchModeObserve.m, Csa_Engine.m,
// Csa_GameInfo.m, and Meta_Emitter.m.
typedef enum {
    USI_RESULT_UNKNOWN = -1,
    USI_RESULT_WIN     = 0,
    USI_RESULT_LOSE    = 1,
    USI_RESULT_DRAW    = 2,
} usi_match_result_t;

// ---------------------------------------------------------------------------
// Csa_Engine.m — the CSA-protocol server-side state machine that drives
// the connected engine through Game_Summary / AGREE / per-move exchange /
// gameover. The state-machine + integration surface lives in Csa_Engine.h;
// the symbols below are the bare lifecycle callbacks Server_CSA.m needs.
// ---------------------------------------------------------------------------

// Lifecycle callbacks invoked by Server_CSA.m from the accept queue.
void CsaEngineOnTcpClientConnected(void);
void CsaEngineOnTcpClientDisconnected(void);

// Constructor-time installer — registers the inbound-line handler with
// Server_CSA.m. Call once from Tweak.m after KEBCsaServerStart binds.
void CsaEngineInstall(void);

// Match-lifecycle callbacks. Hook_MatchModeObserve.m forwards from its
// existing dispatch_async(main_queue) block.
void CsaEngineOnMatchStart(int32_t local_player);
void CsaEngineOnMatchEnd(usi_match_result_t result);

// Per-move notification, fired from Hook_GameStateStoreObserve.m.
//   `move`        : KIOU Move bits
//   `playerSide`  : the side that just moved (0=Black, 1=White)
//   `sfenAfter`   : post-move SFEN snapshot
//   `blackTimeRemainSec` / `whiteTimeRemainSec`: post-move remaining
//     clock values read straight off GameStateStore (+0x80 / +0x90 +
//     0x20). Pass -1.0f when no live clock is available for that side
//     (VsAI's CPU side uses 86400s sentinel, open-seat modes don't
//     surface clocks, etc).
void CsaEngineOnMoveObserved(uint32_t move,
                             int32_t playerSide,
                             NSString *sfenAfter,
                             float blackTimeRemainSec,
                             float whiteTimeRemainSec);

// ---------------------------------------------------------------------------
// Csa_GameInfo.m — MatchConfig / PlayerInfo readers + CSA Game_Summary /
// result block builders.
// ---------------------------------------------------------------------------

// Stash the MatchConfig pointer that Hook_MatchModeObserve.m's Init hook
// already cached for the legacy meta path. Called from the same Init macro
// alongside MetaSetMatchConfig.
void CsaSetMatchConfig(void *cfg);
void CsaSetGameStateStore(void *gss);

// Latest Online player-info pointer, captured from
// GameStateStore.Set{Black,White}PlayerInfo. side: 0=Black, 1=White.
void CsaOnPlayerInfoSet(int32_t side, void *playerInfo);

// Build the multi-line `BEGIN Game_Summary ... END Game_Summary` payload.
// `local_player` is the seat the user holds (0=Black, 1=White, -1 for
// open-seat modes). On success the derived Game_ID is written into
// `*outGameId` (may be NULL). Returns nil when MatchConfig has not been
// captured yet — the caller (Csa_Engine.m) defers Game_Summary delivery
// in that case.
// outGameId receives the Game_ID string (never nil on success).
// outStartSfen receives the SFEN of the starting position (nil when
// SfenFromGameController was unavailable). Callers may cache this as the
// initial g_csaPrevSfen so first-move validators have a board snapshot.
NSString *CsaBuildGameSummary(int32_t local_player,
                              NSString **outGameId,
                              NSString **outStartSfen);

// Build the CSA `#REASON` + `#OUTCOME` pair (e.g. `"#RESIGN\n#WIN"`).
// Returns nil for unknown results so the engine driver can suppress the
// result block when the outcome cannot be inferred.
NSString *CsaBuildMatchResult(usi_match_result_t result);

// ---------------------------------------------------------------------------
// Inject_Resign.m — invoke KIOU's resign / nyugyoku-declaration APIs when
// the CSA engine submits `%TORYO` / `%KACHI`. Stubbed in Csa_Stubs.m until
// Task 6 of the CSA migration plan lands.
// ---------------------------------------------------------------------------
void InjectResign(int32_t playerSide);
void InjectNyugyokuDeclaration(int32_t playerSide);

// ---------------------------------------------------------------------------
// Meta_Emitter.m — 1-line JSON metadata stream that runs alongside the USI
// protocol on the same WS port. Each line is prefixed with "meta " so the
// bridge can route them to its KIF assembler without confusing them with
// USI lines. All three emit functions are fire-and-forget — failures land
// in the file log but never throw.
// ---------------------------------------------------------------------------

// Stash the MatchConfig that InitializeAsync passes in. Called from
// Hook_MatchModeObserve's Init hook with the cfg arg, and from the End hook
// with NULL to clear it. Subsequent MetaEmitMatchStart reads off this.
void MetaSetMatchConfig(void *cfg);

// Emit "meta {type:match_start, ...}". Called right after OnMatchStart
// latches the local-player seat (so we can carry it in the payload).
void MetaEmitMatchStart(int32_t local_player);

// Emit "meta {type:move, ...}". Called from Hook_GameStateStoreObserve.
// side_to_move is the side whose turn it is NEXT.
void MetaEmitMove(NSString *usi, NSString *sfen_after, int32_t side_to_move);

// Emit "meta {type:match_end, ...}". Called from Hook_MatchModeObserve's
// END_HOOK after the result has been inferred. final_sfen is the SFEN read
// from the GameController right before the cache gets cleared. usi_text is
// the full game record (GameController.GetUSIText) — bridge 側でこれが
// 入っていれば、これまで積んだ move 経路の Record を上書きして
// グランドトゥルースとして使う。
void MetaEmitMatchEnd(usi_match_result_t result,
                         NSString *final_sfen,
                         NSString *usi_text);

// Called from Hook_GameStateStoreObserve's Set*PlayerInfo hooks when the
// matchmaking-resolved PlayerInfo arrives (Online). side: 0=Black, 1=White.
// If a match_start emit is pending and BOTH sides are now in, this fires
// match_start with the store-supplied PlayerInfo. CPU matches typically
// don't reach this — the 1.5s OnMatchStart fallback timer covers them.
void MetaOnPlayerInfoSet(int32_t side, void *playerInfo);

// Installer for the GameStateStore.Set*PlayerInfo hooks.
void InstallGameStateStoreObserveHook(uintptr_t unityBase);
void InstallMatchingFilterObserveHook(uintptr_t unityBase);
void InstallAccountObserveHook(uintptr_t unityBase);

// ---------------------------------------------------------------------------
// Account switching — written by Hook_AccountObserve.m. Calls
// TDAnalytics.SetDistinctId on the supplied UUID so the next login sequence
// authenticates as that account. The caller is expected to also restart the
// login flow (typically by relaunching the app or invoking RunLoginSequence).
// No-op when the unity base / TDAnalytics symbol has not yet been resolved.
// ---------------------------------------------------------------------------
void KEBSwitchAccount(NSString *uuid);

// Trigger BackToTitleSequence.RunAsync so KIOU returns to the title scene
// without exit() / app relaunch. Used by the Settings UI after a Switch tap.
// No-op if UnityFramework hasn't been mapped yet.
void KEBNavigateToTitleScene(void);

// ---------------------------------------------------------------------------
// Static chinlan dispatcher (chinlan build only).
//
// In the chinlan flavour, every hook site is redirected by a code cave to a
// single dispatcher function published into a reserved __DATA,__bss SLOT
// inside UnityFramework. The cave preserves X0-X7, materialises the slot
// address from `unityBase + KIOU_BR_HOOK_SLOT_RVA`, loads the function
// pointer, stuffs the per-site hook id into W6, calls the dispatcher, then
// restores X0-X7 and resumes orig via the displaced prologue + `B orig+4`.
//
// W6 is used for the hook id (not W2) so the dispatcher can forward the
// real call-site arguments in X0-X5/X7 to the hook function bodies; several
// Bridge sites carry a real argument in X2 (`OnPlayerMoveAsync`'s ct,
// `UpdateAuthoritativeSnapshot`'s turn, `Adapter.TryMakeMove(Move, out)`'s
// out pointer).
//
// Hook function bodies live unchanged in their respective Hook_*.m files —
// the dispatcher just maps hook_id back to the right hook_<foo>(self, ...)
// call. See docs/plans/kiou_engine_bridge_chinlan.md § 5 for the contract.
// ---------------------------------------------------------------------------

// RVA of the 8-byte slot the recipe reserves inside UnityFramework's
// __DATA,__bss. MUST match `HOOK_SLOT_RVA` in recipes/kiouenginebridge.py;
// if one moves, both move together (the recipe pins the slot at patch
// time, this header pins where the dylib publishes its dispatcher).
#define KIOU_BR_HOOK_SLOT_RVA 0x8F90CC0

// RVA of the entry-slot table inside UnityFramework. Each CAVE_ENTRY
// site reads its 8-byte slot at `ENTRY_SLOT_BASE_RVA + slot * 8` and
// BLRs the function pointer there. MUST match ENTRY_SLOT_BASE_RVA in
// recipes/kiouenginebridge.py.
//
// Previous placements at 0x8F90CD0 (last 8 B of __bss) and 0x091E90B8
// (last 32 slots of __common) both collided with KIOU runtime data:
// the __bss tail had slot[1+] spilling into the __bss/__common padding,
// and the __common tail contained a KIOU bitmask table written at
// runtime (0xE000…0001 et al.). The current placement at 0x091E91B8
// sits one word past __common's end (0x091E91B8 .. 0x091E93B8 exclusive),
// a region verified all-zero via frida MemoryAccessMonitor before and
// after a full login. See the same-named constant in the recipe for the
// reservation bound.
#define KIOU_BR_ENTRY_SLOT_BASE_RVA 0x091E91B8

// Reserved sibling RVA for a future in-framework inject-entry table.
// Branch F currently reconstructs bypass entries dylib-locally from cave
// geometry, but we still mirror the recipe's reserved address here so the
// reservation stays visible on both sides.
#define KIOU_BR_INJECT_ENTRY_TABLE_RVA 0x8F90C00

// Chinlan cave geometry. MUST mirror recipes/kiouenginebridge.py.
// Every cave is a fixed 84-byte payload allocated contiguously from the
// CAVE_REGION start in declaration order. The cave layout ends with:
//   cave+0x48: LDP X29, X30, [SP], #0x90   (epilogue's stack restore)
//   cave+0x4C: <displaced prologue insn>   (the site's original first 4 bytes)
//   cave+0x50: B   <orig + 4>              (PC-relative branch back into the
//                                          original method just past its
//                                          replaced first insn)
// Branch F's injection path calls into `cave + 0x4C`, i.e. straight into the
// displaced prologue followed by the branch back to `orig + 4`, so it
// bypasses the dispatcher AND avoids running the epilogue's LDP (which would
// trash the inject path's own frame). Calling cave+0x48 would pop the wrong
// X29/X30 pair off the caller's stack and corrupt the frame pointer.
#define KIOU_BR_CAVE_REGION_START  0x826A000
#define KIOU_BR_CAVE_SIZE          84
#define KIOU_BR_CAVE_BYPASS_OFFSET 0x4C


enum kiou_bridge_hook_id {
    KIOU_BR_HOOK_AI_INIT = 0,
    KIOU_BR_HOOK_CPUSTREAM_INIT,
    KIOU_BR_HOOK_LOCAL_INIT,
    KIOU_BR_HOOK_ONLINE_INIT,
    KIOU_BR_HOOK_REPLAY_INIT,

    KIOU_BR_HOOK_AI_START,
    KIOU_BR_HOOK_CPUSTREAM_START,
    KIOU_BR_HOOK_LOCAL_START,
    KIOU_BR_HOOK_ONLINE_START,
    KIOU_BR_HOOK_REPLAY_START,

    KIOU_BR_HOOK_AI_OPM,
    KIOU_BR_HOOK_CPUSTREAM_OPM,
    KIOU_BR_HOOK_LOCAL_OPM,
    KIOU_BR_HOOK_ONLINE_OPM,
    KIOU_BR_HOOK_REPLAY_OPM,

    KIOU_BR_HOOK_AI_END,
    KIOU_BR_HOOK_CPUSTREAM_END,
    KIOU_BR_HOOK_LOCAL_END,
    KIOU_BR_HOOK_ONLINE_END,
    KIOU_BR_HOOK_REPLAY_END,

    KIOU_BR_HOOK_ADAPTER_TRY_MAKE_MOVE_OUT,
    KIOU_BR_HOOK_ONLINE_UPDATE_SNAPSHOT,
    KIOU_BR_HOOK_ONLINE_HANDLE_RESULT,
    KIOU_BR_HOOK_CPUSTREAM_UPDATE_SNAPSHOT,
    KIOU_BR_HOOK_GAMEORCH_ACTIVATE,

    KIOU_BR_HOOK_GSTATE_SET_BLACK_PLAYER_INFO,
    KIOU_BR_HOOK_GSTATE_SET_WHITE_PLAYER_INFO,
    KIOU_BR_HOOK_GSTATE_NOTIFY_PIECE_MOVED,

    // KIOU_BR_HOOK_ACCOUNT_EXISTS — assigned an enum value so the cave
    // bypass entry table is computed the same way for entry caves as for
    // observer caves (bypass index = cave allocation order = enum value
    // for this row). The chinlan dispatcher does NOT switch on this id
    // (entry caves route through the entry slot table, not the observer
    // dispatcher), but Inject_Move-style bypass lookups still work.
    KIOU_BR_HOOK_ACCOUNT_EXISTS,
    KIOU_BR_HOOK_LOGIN_ARGS_CREATE,
    KIOU_BR_HOOK_REGISTER_USER_ARGS_CREATE,

    KIOU_BR_HOOK_GET_VALID_MATCH_FOUND_STATUS,
    KIOU_BR_HOOK_MATCH_STREAM_ARGS_CREATE,
    KIOU_BR_HOOK_RECEIVE_TIMEOUT_MOVENEXT,

    KIOU_BR_HOOK_RUN_LOGIN_SEQ_MOVENEXT,
    KIOU_BR_HOOK_GET_SELF_PROFILE_MOVENEXT,

    // HttpMessageInvoker.SendAsync — CAVE_ENTRY for x-user-id header swap
    // on account switch. Entry cave so the hook can rewrite request headers
    // before calling bypass to forward to orig.
    KIOU_BR_HOOK_HTTPMSGINVOKER_SEND_ASYNC,

    KIOU_BR_HOOK__COUNT,
};

// Entry-slot enum — one per CAVE_ENTRY row in recipes/kiouenginebridge.py.
// Slot N's hook function pointer lives at
// `unityBase + KIOU_BR_ENTRY_SLOT_BASE_RVA + N * 8`. KEBBridgeChinlanPublish
// writes the live hook function pointers into those slots.
enum kiou_bridge_entry_slot_id {
    KIOU_BR_ENTRY_SLOT_ACCOUNT_EXISTS = 0,
    KIOU_BR_ENTRY_SLOT_LOGIN_ARGS_CREATE,
    KIOU_BR_ENTRY_SLOT_REGISTER_USER_ARGS_CREATE,
    KIOU_BR_ENTRY_SLOT_GET_VALID_MATCH_FOUND_STATUS,
    KIOU_BR_ENTRY_SLOT_MATCH_STREAM_ARGS_CREATE,
    KIOU_BR_ENTRY_SLOT_RUN_LOGIN_SEQ_MOVENEXT,
    KIOU_BR_ENTRY_SLOT_GET_SELF_PROFILE_MOVENEXT,
    KIOU_BR_ENTRY_SLOT_HTTPMSGINVOKER_SEND_ASYNC,

    KIOU_BR_ENTRY_SLOT__COUNT,
};

// g_inject_entry is chinlan-only — it's populated by
// KEBBridgeChinlanPublish() with per-site cave-bypass entry pointers,
// so injection on chinlan can call the original OPM body without
// re-entering the dispatcher cave. On JB the trampolines installed by
// MSHookFunction already provide that bypass via `orig_*`, so the array
// is not defined and the helper macros short-circuit to `(ORIG)`.
#if KIOU_CHINLAN
extern void * volatile g_inject_entry[KIOU_BR_HOOK__COUNT];

// Return the fixed-allocation-order cave-bypass entry for one hook id.
// This assumes cave i lives at `CAVE_REGION_START + i * CAVE_SIZE`; if the
// recipe ever switches to a non-uniform allocator, update both sides.
static inline void *kiou_bridge_bypass_entry_for_hook(uint32_t hook_id) {
    if (hook_id >= KIOU_BR_HOOK__COUNT) return NULL;
    return (void *)(g_unityBase + KIOU_BR_CAVE_REGION_START +
                    (uintptr_t)hook_id * KIOU_BR_CAVE_SIZE +
                    KIOU_BR_CAVE_BYPASS_OFFSET);
}

#define KIOU_BR_CHINLAN_ORIG_OR_BYPASS(ORIG, HOOK_ID, TYPE) \
    ((ORIG) ? (ORIG) : (TYPE)g_inject_entry[(HOOK_ID)])

#define KIOU_BR_CHINLAN_INJECT_CALLABLES_READY() \
    (g_inject_entry[KIOU_BR_HOOK_AI_OPM] && \
     g_inject_entry[KIOU_BR_HOOK_CPUSTREAM_OPM] && \
     g_inject_entry[KIOU_BR_HOOK_LOCAL_OPM] && \
     g_inject_entry[KIOU_BR_HOOK_ONLINE_OPM] && \
     g_inject_entry[KIOU_BR_HOOK_REPLAY_OPM] && \
     g_inject_entry[KIOU_BR_HOOK_ADAPTER_TRY_MAKE_MOVE_OUT])
#else
// On JB the only callable is the trampoline that MSHookFunction wrote into
// `orig_*`. The bypass-entry path is chinlan-only, so the helper macros
// collapse to `(ORIG)`.
#define KIOU_BR_CHINLAN_ORIG_OR_BYPASS(ORIG, HOOK_ID, TYPE) (ORIG)
#define KIOU_BR_CHINLAN_INJECT_CALLABLES_READY()  1
#endif

#define KIOU_BR_CHINLAN_ADAPTER_CALLABLE() \
    KIOU_BR_CHINLAN_ORIG_OR_BYPASS(orig_AdapterTryMakeMoveOut, \
                                    KIOU_BR_HOOK_ADAPTER_TRY_MAKE_MOVE_OUT, \
                                    Adapter_TryMakeMove_Out_t)

#define KIOU_BR_CHINLAN_AI_OPM_CALLABLE() \
    KIOU_BR_CHINLAN_ORIG_OR_BYPASS(orig_AIMatchMode_OnPlayerMoveAsync, \
                                    KIOU_BR_HOOK_AI_OPM, \
                                    OnPlayerMoveAsync_t)

#define KIOU_BR_CHINLAN_CPUSTREAM_OPM_CALLABLE() \
    KIOU_BR_CHINLAN_ORIG_OR_BYPASS(orig_CPUStreamMode_OnPlayerMoveAsync, \
                                    KIOU_BR_HOOK_CPUSTREAM_OPM, \
                                    OnPlayerMoveAsync_t)

#define KIOU_BR_CHINLAN_LOCAL_OPM_CALLABLE() \
    KIOU_BR_CHINLAN_ORIG_OR_BYPASS(orig_LocalPvPMode_OnPlayerMoveAsync, \
                                    KIOU_BR_HOOK_LOCAL_OPM, \
                                    OnPlayerMoveAsync_t)

#define KIOU_BR_CHINLAN_ONLINE_OPM_CALLABLE() \
    KIOU_BR_CHINLAN_ORIG_OR_BYPASS(orig_OnlinePvPMode_OnPlayerMoveAsync, \
                                    KIOU_BR_HOOK_ONLINE_OPM, \
                                    OnPlayerMoveAsync_t)

#define KIOU_BR_CHINLAN_REPLAY_OPM_CALLABLE() \
    KIOU_BR_CHINLAN_ORIG_OR_BYPASS(orig_RecordReplayMode_OnPlayerMoveAsync, \
                                    KIOU_BR_HOOK_REPLAY_OPM, \
                                    OnPlayerMoveAsync_t)

#define KIOU_BR_EXPECTED_CAVE_COUNT KIOU_BR_HOOK__COUNT

#if KIOU_CHINLAN
_Static_assert(KIOU_BR_CAVE_SIZE == 84, "Branch F assumes 84-byte caves");
_Static_assert(KIOU_BR_CAVE_BYPASS_OFFSET == 0x4C,
               "Branch F assumes bypass entry at cave+0x4C "
               "(displaced prologue followed by B orig+4)");
#endif


// Dispatcher signature. Called from the cave with whatever was in X0-X5/X7
// at the original call site, plus a hook id loaded by the cave's
// `MOVZ W6, #imm`. The trailing void* x7 parameter ensures hook_id lands in
// W6 under AAPCS64 (8 integer-class parameters fill X0..X7 in order); X4,
// X5, X7 are placeholders for hooks that have extra register arguments.
typedef void (*kiou_bridge_dispatcher_t)(void *x0, void *x1, void *x2,
                                         void *x3, void *x4, void *x5,
                                         uint32_t hook_id, void *x7);

// Constructor helper. chinlan Tweak.m calls this exactly once after
// UnityFramework is mapped, in place of all install_*_hook calls.
// Publishes the dispatcher pointer into the slot at
// `g_unityBase + KIOU_BR_HOOK_SLOT_RVA` inside UnityFramework's
// __DATA,__bss. The dylib does NOT host its own copy of the slot — the
// cave reads from the framework's __bss, so the dispatcher pointer must
// live there.
void KEBBridgeChinlanPublish(void);

// ---------------------------------------------------------------------------
// Hook function bodies reached from the chinlan dispatcher. Defined in
// their respective Hook_*.m files; the dispatcher forwards each cave call
// to the matching body. Declared here so the dispatcher TU sees them.
//
// The bodies are written for the JB build (they call orig via
// KIOU_CALL_ORIG_*); on chinlan KIOU_CALL_ORIG_* expands to a no-op and
// orig runs via the cave's displaced prologue + `B orig+4` after the
// dispatcher returns.
// ---------------------------------------------------------------------------
UniTaskRet HookAiInit(void *self, void *cfg, void *store, void *adapter, void *ct);
UniTaskRet HookCpuStreamInit(void *self, void *cfg, void *store, void *adapter, void *ct);
UniTaskRet HookLocalInit(void *self, void *cfg, void *store, void *adapter, void *ct);
UniTaskRet HookOnlineInit(void *self, void *cfg, void *store, void *adapter, void *ct);
UniTaskRet HookReplayInit(void *self, void *cfg, void *store, void *adapter, void *ct);

void HookAiStart(void *self);
void HookCpuStreamStart(void *self);
void HookLocalStart(void *self);
void HookOnlineStart(void *self);
void HookReplayStart(void *self);

UniTaskRet HookAiOpm(void *self, uint32_t mv, void *ct);
UniTaskRet HookCpuStreamOpm(void *self, uint32_t mv, void *ct);
UniTaskRet HookLocalOpm(void *self, uint32_t mv, void *ct);
UniTaskRet HookOnlineOpm(void *self, uint32_t mv, void *ct);
UniTaskRet HookReplayOpm(void *self, uint32_t mv, void *ct);

UniTaskRet HookAiEnd(void *self, void *ct);
UniTaskRet HookCpuStreamEnd(void *self, void *ct);
UniTaskRet HookLocalEnd(void *self, void *ct);
UniTaskRet HookOnlineEnd(void *self, void *ct);
UniTaskRet HookReplayEnd(void *self, void *ct);

bool HookAdapterTryMakeMoveOut(void *self, uint32_t move, void *outMove);
void HookUpdateAuthoritativeSnapshot(void *self, void *sfenStr, int32_t turn,
                                      float blackTimeSec, float whiteTimeSec,
                                      int32_t moveCount);
void HookHandleMoveResult(void *self, void *reply);
void HookCpuStreamUpdateSnapshot(void *self, void *sfenStr, int32_t turn,
                                   float blackTimeSec, float whiteTimeSec,
                                   int32_t moveCount);
UniTaskRet HookGameOrchActivateAsync(void *self, void *setup,
                                       void *assetLoader, void *ct);

void HookGStateSetBlackPlayerInfo(void *self, void *playerInfo);
void HookGStateSetWhitePlayerInfo(void *self, void *playerInfo);
void HookGStateNotifyPieceMoved(void *self, uint32_t move, int32_t playerSide);

// AccountExists chinlan-side entry hook — see Hook_AccountObserve.m. Called
// directly by the entry cave (via the entry slot table); orig is invoked
// from inside this hook via the cave bypass entry, and the hook's bool
// return propagates straight back to the caller (cave tail is RET).
bool HookAccountExistsEntry(void *data);

// LoginArgs.Create / RegisterUserArgs.Create chinlan-side entry hooks. Both
// swap one il2cpp string argument (deviceId / distinctId) per the pending_*
// override slots, then call orig via the cave bypass entry and forward
// orig's return (the freshly built ILoginArgs* / IRegisterUserArgs*).
void *HookLoginArgsCreateEntry(void *deviceId, void *distinctId);
void *HookRegisterUserArgsCreateEntry(void *userName, void *distinctId);

// Matching filter chinlan-side entry hooks. GetValidMatchFoundStatus
// returns the orig status (so the JB-shape observable contract holds) but
// fires a ConnectionFailed JoinQueue at the matching stream when the seat
// doesn't match the user's preference. ArgsCreate is CAVE_ENTRY because
// its 7th C arg lands in W6 which CAVE_OBSERVER would clobber with hook_id.
void *HookGetValidMatchFoundStatusEntry(void *reply);
void *HookArgsCreateEntry(int32_t action, int32_t matchType,
                           int32_t rankRuleType, int32_t eventRuleType,
                           int32_t mstEventMatchId,
                           int32_t matchingClientType,
                           bool enableBeginnerSupport);

// MatchingHandler.ReceiveWithTimeoutAsync.MoveNext observer hook — declared
// here so the chinlan dispatcher can call it without recompiling against
// Hook_MatchingFilterObserve.m's internal symbol table.
void HookReceiveTimeoutMoveNext(void *self);

// MoveNext entry hooks (chinlan). The state machine fields they observe
// (LoginReply pointer, SelfUserProfileStatus rank list) only become
// populated *after* orig advances state to -2, so these hooks have to
// invoke orig themselves via the cave bypass entry before reading.
void HookRunLoginSeqMoveNextEntry(void *self);
void HookGetSelfProfileMoveNextEntry(void *self);
void *HookHttpMsgInvokerSendAsyncEntry(void *self, void *request, void *ct);
void HookGStateNotifyStateSyncedForCurrentPosition(void);
void ResolveGameStateStoreNotifyStateSynced(uintptr_t unityBase);
void HookGStateRememberStore(void *self);

// ---------------------------------------------------------------------------
// SfMove + low-level helpers, exported so observation hooks living in other
// files (Hook_GameStateStoreObserve.m's NotifyPieceMoved) can reuse the same
// SfMove→USI and GameController→SFEN conversion routines.
// ---------------------------------------------------------------------------
typedef uint32_t SfMove;

// Convert Sunfish.Move (32-bit packed) → USI move string ("7g7f" / "P*5e" /
// "8h2b+"). Returns nil on any failure. Implementation in
// Hook_LowLevelObserve.m.
NSString *moveToUsi(SfMove m);

// Read the live SFEN of a GameController by walking its PositionHistory and
// calling Position.ToSFEN. Returns nil on any failure. Implementation in
// Hook_LowLevelObserve.m.
NSString *SfenFromGameController(void *gameCtrl);

// Read the full game-record text via GameController.GetUSIText. Returns nil
// on any failure. Used by Meta_Emitter to attach the authoritative game
// record to the match_end meta payload. Implementation in
// Hook_LowLevelObserve.m.
NSString *UsiTextFromGameController(void *gameCtrl);

