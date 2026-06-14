#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>

#import "kiou_il2cpp.h"
#import "kiou_hookengine.h"
#import "kiou_logging.h"

// ===========================================================================
// Internal.h — KiouUsiProxy-private declarations.
//
// This tweak primarily observes KIOU state and pushes SFEN / USI strings out
// over a WebSocket sink. As of the move-injection phase it also accepts
// inbound text frames from the host (typically "bestmove <usi>" lines from a
// USI engine bridge) and replays them into the game's TryMakeMove path so the
// local board advances exactly as if the user had played the move.
//
// What the injection layer is allowed to do:
//   - Call il2cpp-generated methods as function pointers (TryMakeMove,
//     Sunfish.Move.Drop, Position.ToSFEN, OnlinePvPMode.OnPlayerMoveAsync).
//   - Cache the `self` pointer observed flowing through TryMakeMove /
//     UpdateAuthoritativeSnapshot hooks so it can be reused as receiver.
//
// What the injection layer is NOT allowed to do:
//   - Touch il2cpp object fields directly. The shared header
//     `kiou_il2cpp.h` is intentionally read-only, and the write-side helpers
//     (writeU8 / writeI32) that KiouEditor declares in its own Internal.h
//     are still NOT included here. Any future "let's tweak a board field"
//     regression must opt in explicitly by adding those helpers — they
//     don't sneak in via the shared header.
//
// Online ratings games: by default an injected move goes through the local
// GameController only (route = "gamectrl") and is reverted by the next
// server-authoritative snapshot. Forwarding the move to the server via
// OnlinePvPMode.OnPlayerMoveAsync is gated behind BOTH an environment
// variable AND a flag file on disk so a host that only knows how to send
// `bestmove <usi>` cannot trip the ratings-impacting path by accident.
// See Inject_Move.m for the exact gate.
//
// Hook installers are added per feature module:
//
//   install_OnlineObserve_hook    (Hook_OnlineObserve.m)
//   install_LowLevelObserve_hook  (Hook_LowLevelObserve.m)
//   install_MatchModeObserve_hook (Hook_MatchModeObserve.m)
//   install_Inject_hook           (Inject_Move.m)
//   usi_engine_install            (Usi_Engine.m, Phase 2 — USI client)
//
// Tweak.m wires them up the same way KiouEditor/Tweak.m does — scan dyld
// for UnityFramework, dispatch each installer once with the base address.
//
// Phase 2 architecture (USI mode):
//   The tweak acts as a USI CLIENT (= USI User in the USI spec). YaneuraOu
//   is the USI ENGINE — it connects to us as a WebSocket client and we
//   drive it with `usi` / `isready` / `usinewgame` / `position sfen ...` /
//   `go ...`. When the observation hooks see that it's our turn, we ship
//   the current SFEN to YaneuraOu, wait for its `bestmove <usi>`, and feed
//   that move back into KIOU via the Phase 1 injection path. The match
//   continues until [MMODE] OnMatchEndAsync clears the cache.
// ===========================================================================

#ifndef KIOU_USI_PROXY_COMMIT
#define KIOU_USI_PROXY_COMMIT "unknown"
#endif

// ---------------------------------------------------------------------------
// Per-module hook installers. Tweak.m calls each one once UnityFramework has
// shown up; each installer guards itself if invoked twice.
// ---------------------------------------------------------------------------
void install_OnlineObserve_hook(uintptr_t unityBase);
void install_LowLevelObserve_hook(uintptr_t unityBase);
void install_MatchModeObserve_hook(uintptr_t unityBase);
void install_Inject_hook(uintptr_t unityBase);
void usi_engine_install(void);

// ---------------------------------------------------------------------------
// WebSocket server (Server_WebSocket.m). Boot once at constructor time,
// then any hook can push a single JSON-encoded line to whichever host is
// currently connected. No-op when no host is attached.
// ---------------------------------------------------------------------------
void kiou_ws_server_start(uint16_t port);
void kiou_ws_server_push(NSString *json);

// Register a callback for inbound TEXT frames (opcode 0x1). The handler is
// invoked on the recv queue (a serial dispatch queue, NOT the main thread).
// `data` is NOT null-terminated; treat it as a length-bounded byte slice and
// copy what you need before returning — the buffer is freed by the recv loop
// immediately after the handler returns. Replace by passing NULL.
typedef void (*kiou_ws_text_handler_t)(const char *data, size_t len);
void kiou_ws_server_set_text_handler(kiou_ws_text_handler_t fn);

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
void kiou_inject_dumpRecent(void);

// ---------------------------------------------------------------------------
// Injection bridge — called by Usi_Engine.m when YaneuraOu sends us a
// `bestmove <usi>`. Returns true if the move was injected successfully
// (= OPM + Adapter.TryMakeMove path succeeded). The returned `outSfenAfter`
// and `outRaw` are populated with the post-injection SFEN and Move uint32
// for logging convenience; both may be nil/0 on failure. Internally
// dispatches to the Unity main thread.
bool inject_apply(NSString *usi,
                  NSString **outSfenAfter,
                  uint32_t *outRaw,
                  NSString **outErr);

// ---------------------------------------------------------------------------
// Usi_Engine.m — the USI-client state machine that drives YaneuraOu and
// feeds its bestmove back into KIOU.
// ---------------------------------------------------------------------------

typedef enum {
    USI_STATE_BOOT       = 0,  // tweak loaded, no ws client yet
    USI_STATE_HANDSHAKE  = 1,  // ws client connected, awaiting usiok
    USI_STATE_READY      = 2,  // readyok received, ready for new game
    USI_STATE_THINKING   = 3,  // go sent, awaiting bestmove
    USI_STATE_INJECTING  = 4,  // bestmove received, applying to KIOU
} usi_state_t;

// Notified by Hook_LowLevelObserve.m::hook_AdapterTryMakeMoveOut every time
// a move lands on the board. `usi` is the move that was just applied,
// `sfen_after` is the resulting position, `side_to_move` is the side that
// will move next (0=Black, 1=White). The engine compares side_to_move
// against the cached local-player side to decide whether to send a new
// `position` + `go` to YaneuraOu.
void usi_engine_on_move_observed(NSString *usi,
                                 NSString *sfen_after,
                                 int32_t side_to_move);

// Match lifecycle hooks. `local_player` is 0 (Black) or 1 (White), or -1
// when the seat isn't fixed (LocalPvP / RecordReplay).
void usi_engine_on_match_start(int32_t local_player);
void usi_engine_on_match_end(void);

// WS client connection lifecycle. Server_WebSocket.m calls these from the
// accept queue so the engine can drive the handshake.
void usi_engine_on_ws_client_connected(void);
void usi_engine_on_ws_client_disconnected(void);

// Send a literal USI line out to the engine (without trailing newline —
// the helper adds one). Safe to call from any thread; serializes onto the
// WS accept queue via kiou_ws_server_push.
void usi_engine_send_line(NSString *line);
