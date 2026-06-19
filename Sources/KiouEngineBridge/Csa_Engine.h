#pragma once

#import <Foundation/Foundation.h>
#import <stdatomic.h>
#import <stdint.h>

#import "Csa_Convert.h"

// ===========================================================================
// Csa_Engine — CSA server-side state machine for the TCP transport.
//
// KEB acts as the CSA server (KIOU is the authoritative source of board
// state and clocks). The connecting peer is a CSA engine. The driver owns
// the post-connect handshake (LOGIN -> Game_Summary -> AGREE -> START), the
// per-move exchange (`+7776FU,T10` notifications and inbound move
// submissions), and the end-of-game signalling (`#WIN` / `#LOSE` / `#DRAW`).
//
// Symbols here are the integration surface that Hook_*.m and Tweak.m call
// into. The transport (Server_CSA.m) invokes
// `CsaEngineOnTcpClient{Connected,Disconnected}` from its accept queue, and
// passes inbound lines through `CsaEngineHandleLine` via the registered
// line handler.
// ===========================================================================

typedef enum {
    CSA_STATE_BOOT         = 0,  // tweak loaded, no TCP client
    CSA_STATE_LOGIN        = 1,  // client connected, awaiting LOGIN
    CSA_STATE_AGREE_WAIT   = 2,  // Game_Summary sent, awaiting AGREE
    CSA_STATE_PLAYING      = 3,  // START sent, in match
    CSA_STATE_GAME_OVER    = 4,  // match ended, waiting for next or LOGOUT
} csa_state_t;

// Install the line handler with the CSA transport. Called once at
// constructor time from Tweak.m, after KEBCsaServerStart binds the port.
void CsaEngineInstall(void);

// Send one CSA protocol line. Appends LF and pushes through the
// KEBCsaServerPush sink — no-op when no client is attached.
void CsaEngineSendLine(NSString *line);

// Push a multi-line block. Each line is sent verbatim with LF appended;
// empty lines are skipped to avoid CSA parsers tripping on blank input.
void CsaEngineSendBlock(NSString *block);

// Match lifecycle. Hook_MatchModeObserve.m calls these from the same
// dispatch_async(main_queue) block that latches local_player.
void CsaEngineOnMatchStart(int32_t local_player);

// `result` matches Usi_Engine's enum (kept for compatibility with the
// hook macros that still use usi_match_result_t).
void CsaEngineOnMatchEnd(usi_match_result_t result);

// Per-move observation, fired from Hook_GameStateStoreObserve.m's
// NotifyPieceMoved hook.
//   `move`        : KIOU Move bits
//   `playerSide`  : the side that just moved (0=Black, 1=White)
//   `sfenAfter`   : post-move SFEN read off the GameController (used to
//                   recover the (promoted) piece type sitting on the
//                   destination square — the upper-16 bits of the Move
//                   struct hold this but their layout is still under RE)
//   `blackTimeRemainSec` / `whiteTimeRemainSec`: post-move remaining clock
//                   values from GameStateStore (+0x80 / +0x90 + 0x20).
//                   Pass -1.0f when no live clock is available for that
//                   side (VsAI's CPU sentinel 86400s, open-seat modes,
//                   etc).
void CsaEngineOnMoveObserved(uint32_t move,
                             int32_t playerSide,
                             NSString *sfenAfter,
                             float blackTimeRemainSec,
                             float whiteTimeRemainSec);

// Convenience: read the current state for debug / log filtering.
csa_state_t CsaEngineCurrentState(void);

// Latest post-move remaining time (seconds) per side, updated on every
// CsaEngineOnMoveObserved call. NaN means "no value yet" (start of match or
// side's clock not available). Read by Csa_GameInfo to populate
// Remaining_Time+/- in the reconnect Game_Summary.
//
// _Atomic because the writer runs on the Unity main thread (the move
// observation hook) while the reader can run on the CSA accept queue (the
// reconnect Game_Summary path). `volatile` is not enough for cross-module
// cross-thread access — atomics give us a defined memory model.
extern _Atomic float g_csaLastBlackRemainSec;
extern _Atomic float g_csaLastWhiteRemainSec;
extern _Atomic int32_t g_csaByoyomiMs;
extern _Atomic int64_t g_csaTotalTimeMs;
