#import "Internal.h"

// ===========================================================================
// Csa_Stubs — temporary shim during the CSA migration (Tasks 2-5).
//
// The hooks in Hook_*.m and Meta_Emitter.m still call into the legacy USI
// engine driver via UsiEngine* functions and the WebSocket sink via
// KEBWsServer*. The implementations of those symbols live in
// Server_WebSocket.m and Usi_Engine.m, which Task 2 deprecates by wrapping
// them in `#if 0` and dropping them from the build.
//
// To keep `make` green between Task 2 and Tasks 4-5 (where the real
// CsaEngine* / KEBCsaServer* implementations land and every hook call site
// is migrated), this file provides no-op shims for the symbols the hooks
// still reference. Once every hook has been switched over to the CSA
// callbacks, this file is deleted in Task 5.
//
// IMPORTANT: do NOT add any new call sites against these stubs. They exist
// solely to bridge the half-migrated build state. The TaskGet logs in the
// task tracker make this lifetime explicit.
// ===========================================================================

// ---------------------------------------------------------------------------
// WebSocket sink stubs. The real KEBCsaServer* family is introduced in
// Task 3; until then, every push is dropped silently.
// ---------------------------------------------------------------------------

void KEBWsServerStart(uint16_t port) {
    (void)port;
    file_log(@"[STUB] KEBWsServerStart called during CSA migration — no-op");
}

void KEBWsServerPush(NSString *line) {
    (void)line;
    // Drop silently. Logging every call would flood the file log because
    // Meta_Emitter.m emits meta lines on every match event.
}

void KEBWsServerSetTextHandler(kiou_ws_text_handler_t fn) {
    (void)fn;
    file_log(@"[STUB] KEBWsServerSetTextHandler called during CSA migration"
             @" — no-op");
}

// ---------------------------------------------------------------------------
// USI engine driver stubs. Real CsaEngine* callbacks land in Task 4; the
// call sites in Hook_LowLevelObserve.m and Hook_MatchModeObserve.m are
// rewritten in Task 5.
// ---------------------------------------------------------------------------

void UsiEngineOnMatchStart(int32_t local_player) {
    (void)local_player;
}

void UsiEngineOnMatchEnd(usi_match_result_t result) {
    (void)result;
}

void UsiEngineOnMoveObserved(NSString *usi,
                             NSString *sfen_after,
                             int32_t side_to_move) {
    (void)usi;
    (void)sfen_after;
    (void)side_to_move;
}

void UsiEngineOnWsClientConnected(void) {
    // no-op: WS transport is gone
}

void UsiEngineOnWsClientDisconnected(void) {
    // no-op: WS transport is gone
}

void UsiEngineSendLine(NSString *line) {
    (void)line;
    // no-op: USI line emission is being replaced by CsaEngineSendLine
}

void UsiEngineInstall(void) {
    file_log(@"[STUB] UsiEngineInstall called during CSA migration — no-op");
}

// ---------------------------------------------------------------------------
// CSA engine driver stubs. Real implementations land in Task 4 once
// Csa_Engine.m is written; until then Server_CSA.m's accept handler hits
// these no-ops so the build links.
// ---------------------------------------------------------------------------

void CsaEngineOnTcpClientConnected(void) {
    file_log(@"[STUB] CsaEngineOnTcpClientConnected — engine driver lands "
             @"in Task 4");
}

void CsaEngineOnTcpClientDisconnected(void) {
    file_log(@"[STUB] CsaEngineOnTcpClientDisconnected — engine driver "
             @"lands in Task 4");
}
