#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>

#import <stdatomic.h>

#import "il2cpp.h"
#import "hookengine.h"
#import "logging.h"

// ===========================================================================
// Internal.h — WarsEngineBridge-private declarations.
//
// WarsEngineBridge embeds a CSA server (TCP :4081) inside the ShogiWars
// process. Observation hooks latch live GameController pointers and convert
// CSA moves back into the game's SendMove path; the injection layer calls
// GameController.Move(csa, timeLeft) so the on-device match advances exactly
// as if the user had played the move.
//
// ShogiWars architecture differs fundamentally from KIOU:
//   - The game logic lives in Mono-compiled C# (not il2cpp ahead-of-time),
//     so all hook targets are resolved by RVA into the UnityFramework binary.
//   - Match flow is driven by GameController (a singleton MonoBehaviour)
//     rather than a family of IMatchMode async state machines.
//   - Moves arrive as CSA XML from the server (OnMovesNormal) rather than
//     from a unified OnPlayerMoveAsync notification.
//   - Time control data is per-player (sente_byoyomi / gote_byoyomi) and
//     carried in GameStartJson; remaining time is a float timeLeft field
//     on each MoveJson record.
//
// Hook installers — one per feature module, wired by Tweak.m:
//
//   InstallGameControllerHook   (Hook_GameController.m)
//   InstallResignHook           (Inject_Resign.m)
// ===========================================================================

#ifndef WARS_ENGINE_BRIDGE_COMMIT
#define WARS_ENGINE_BRIDGE_COMMIT "unknown"
#endif

#ifndef WARS_ENGINE_BRIDGE_VERSION
#define WARS_ENGINE_BRIDGE_VERSION "0.0.0"
#endif

// ---------------------------------------------------------------------------
// orig() invocation policy.
//
// On the JB build, MSHookFunction installs a trampoline at the target site;
// the target function body NEVER runs unless our hook explicitly calls
// orig(args).
//
// On the chinlan build, the static cave runs the displaced prologue
// instruction and then branches to orig + 4 verbatim — so orig is already
// going to execute, and a second call from the hook body would double-run
// the target. The hook must NOT call orig in that case.
//
// WARS_CALL_ORIG_VOID / WARS_CALL_ORIG_RET hide the distinction.
// ---------------------------------------------------------------------------
#if WARS_CHINLAN
#  define WARS_CALL_ORIG_VOID(ORIG, ...)        ((void)0)
#  define WARS_CALL_ORIG_RET(RET_T, ORIG, ...)  ((RET_T){0})
#else
#  define WARS_CALL_ORIG_VOID(ORIG, ...)                                      \
       do { if ((ORIG)) (ORIG)(__VA_ARGS__); } while (0)
#  define WARS_CALL_ORIG_RET(RET_T, ORIG, ...)                                \
       ((ORIG) ? (ORIG)(__VA_ARGS__) : (RET_T){0})
#endif

// ---------------------------------------------------------------------------
// Per-module hook installers. Tweak.m calls each one once UnityFramework has
// shown up; each installer guards itself if invoked twice.
// ---------------------------------------------------------------------------
void InstallGameControllerHook(uintptr_t unityBase);
void InstallResignHook(uintptr_t unityBase);
void InstallNoLoginDialogHook(uintptr_t unityBase);

// ---------------------------------------------------------------------------
// CSA TCP server (Server_CSA.m). Booted once at constructor time.
// ---------------------------------------------------------------------------
void WEBCsaServerStart(uint16_t port);
void WEBCsaServerPush(NSString *line);
void WEBCsaServerClose(void);

typedef void (*wars_csa_line_handler_t)(NSString *line);
void WEBCsaServerSetLineHandler(wars_csa_line_handler_t fn);

// ---------------------------------------------------------------------------
// UnityFramework base address captured at install time.
// ---------------------------------------------------------------------------
extern uintptr_t g_unityBase;

// ---------------------------------------------------------------------------
// GameController instance cache.
// Populated by Hook_GameController.m from Awake / OnGameStart.
// NULL until the scene has loaded at least once.
// ---------------------------------------------------------------------------
extern void *volatile g_gameControllerCache;

// ---------------------------------------------------------------------------
// Match result type used by Hook_GameController.m and Csa_Engine.m.
// ---------------------------------------------------------------------------
typedef enum {
    WEB_RESULT_UNKNOWN = -1,
    WEB_RESULT_WIN     = 0,
    WEB_RESULT_LOSE    = 1,
    WEB_RESULT_DRAW    = 2,
} web_match_result_t;

// ---------------------------------------------------------------------------
// Csa_Engine.m — CSA protocol state machine.
// ---------------------------------------------------------------------------
void CsaEngineInstall(void);
void CsaEngineOnTcpClientConnected(void);
void CsaEngineOnTcpClientDisconnected(void);
void CsaEngineOnMatchStart(bool isBlack, void *gameStartJson);
void CsaEngineOnMoveObserved(NSString *csa, float timeLeft, bool isBlack);
void CsaEngineOnMatchEnd(web_match_result_t result, NSString *reason);

// ---------------------------------------------------------------------------
// Csa_GameInfo.m — Game_Summary / result block builders.
// ---------------------------------------------------------------------------
void CsaSetGameStart(void *gameStartJson);

// Build "BEGIN Game_Summary … END Game_Summary". Returns nil if GameStart has
// not been captured yet. outGameId receives the derived Game_ID string.
NSString *CsaBuildGameSummary(bool isBlack, NSString **outGameId);

// Mark that at least one move has been observed in the current match.
// Called by Csa_Engine when a move is observed; enables live SFEN on reconnect.
void CsaSetMoveObserved(void);

// Build "#REASON\n#OUTCOME". Returns nil for unknown outcomes.
NSString *CsaBuildMatchResult(web_match_result_t result, NSString *reason);

// Remaining-time cache (seconds), updated by CsaEngineOnMoveObserved and
// read by both Csa_Engine.m (for %%TIME replies) and Csa_GameInfo.m (for
// Remaining_Time+/- in Game_Summary). NaN means no observation yet.
extern _Atomic float g_csaLastSenteRemainSec;
extern _Atomic float g_csaLastGoteRemainSec;

// Read the live board SFEN from GameController.GameData.Position.ToString().
// Returns "board side hands ply" SFEN string, or nil on any failure.
// Implemented in Hook_GameController.m.
NSString *WarsLiveSfen(void);

// ---------------------------------------------------------------------------
// Settings_UI.m — in-process settings sheet (right-edge swipe to open).
// ---------------------------------------------------------------------------
void WEBSettingsInstall(void);
void WEBPresentSettings(void);

// ---------------------------------------------------------------------------
// Hook_AlertObserve.m — swizzle UIViewController -presentViewController:
// animated:completion: to log every UIAlertController shown by the app.
// ---------------------------------------------------------------------------
void InstallAlertObserveHook(void);

// ---------------------------------------------------------------------------
// Inject_Move.m — feed a CSA move back into GameController.SendMove.
//
// Called by Csa_Engine.m when the connected engine submits a move.
// Dispatches to the Unity main thread internally. Returns YES on success.
// ---------------------------------------------------------------------------
BOOL inject_apply(NSString *csa);

// ---------------------------------------------------------------------------
// Inject_Resign.m — call ShowResignAlertDialog when the engine sends %TORYO.
// ---------------------------------------------------------------------------
void InjectResign(void);

// ---------------------------------------------------------------------------
// Original function pointers captured by Hook_GameController.m.
// Inject_Move.m calls these to advance the position without re-entering the
// observation hooks. NULL until the relevant installer has run.
// ---------------------------------------------------------------------------

// GameController.OnGameStart(GameStartJson)  RVA: 0x158F3BC
typedef void (*OnGameStart_t)(void *self, void *gameStartJson);

// GameController.OnMovesNormal(XmlDocument)  RVA: 0x159002C
typedef void (*OnMovesNormal_t)(void *self, void *xmlDocument);

// GameController.OnFinishGame(FinishedGameInfo)  RVA: 0x1590BA8
typedef void (*OnFinishGame_t)(void *self, void *finishedGameInfo);

// GameController.SendMove(string move, bool isKishin)  RVA: 0x1591508
typedef void (*SendMove_t)(void *self, void *moveStr, bool isKishin);

// GameController.Move(string csa, float timeLeft, bool quiet)  RVA: 0x1583A10
typedef bool (*Move_t)(void *self, void *csaStr, float timeLeft, bool quiet);

// GameController.Move(int ply, string csa, float timeLeft, bool quiet)  RVA: 0x1590DF4
// AAPCS64: self=x0, ply=w1, csa=x2, timeLeft=s0, quiet=w3.
typedef bool (*MoveWithPly_t)(void *self, int32_t ply, void *csaStr,
                              float timeLeft, bool quiet);

// ShowResignAlertDialog()  RVA: 0x154B72C  (static, no self)
typedef void (*ShowResignAlertDialog_t)(void);

extern OnGameStart_t   orig_OnGameStart;
extern OnMovesNormal_t orig_OnMovesNormal;
extern OnFinishGame_t  orig_OnFinishGame;
extern SendMove_t      orig_SendMove;
extern Move_t          orig_Move;
extern MoveWithPly_t   orig_MoveWithPly;
extern ShowResignAlertDialog_t g_ShowResignAlertDialog;

// ---------------------------------------------------------------------------
// Chinlan dispatcher (chinlan build only).
// ---------------------------------------------------------------------------
#if WARS_CHINLAN

// RVA of the 8-byte __DATA,__bss slot the dylib constructor publishes its
// dispatcher pointer into. Must match HOOK_SLOT_RVA in recipes/warsenginebridge.py.
#define WARS_BR_HOOK_SLOT_RVA 0x0  // TODO: probe on ShogiWars UnityFramework

#define WARS_BR_CAVE_REGION_START  0x0  // TODO: find suitable zero-fill region
#define WARS_BR_CAVE_SIZE          84
#define WARS_BR_CAVE_BYPASS_OFFSET 0x4C

enum wars_bridge_hook_id {
    WARS_BR_HOOK_ON_GAME_START = 0,
    WARS_BR_HOOK_ON_MOVES_NORMAL,
    WARS_BR_HOOK_ON_FINISH_GAME,
    WARS_BR_HOOK_SEND_MOVE,
    WARS_BR_HOOK__COUNT,
};

extern void *volatile g_wars_inject_entry[WARS_BR_HOOK__COUNT];

typedef void (*wars_bridge_dispatcher_t)(void *x0, void *x1, void *x2,
                                         void *x3, void *x4, void *x5,
                                         uint32_t hook_id, void *x7);

void WEBBridgeChinlanPublish(void);

#endif  // WARS_CHINLAN
