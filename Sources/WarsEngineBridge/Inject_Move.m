#import "Internal.h"
#import <dlfcn.h>

// ===========================================================================
// Inject_Move — feed a CSA move into ShogiWars via GameController.SendMove().
//
// IMPORTANT: we call SendMove, NOT Move directly.
//
// GameController.SendMove(string csa, bool isKishin) is the entry point a
// human tap follows:
//
//   tap on board   -> SendMove(csa, false)
//                       -> MyTcpip.Send / MyDummyTcpip.Send   (server send)
//                       -> Move(csa, timeLeft, quiet)         (board update)
//                       -> waits for server to reply with the opponent move
//
// Calling Move() directly bypasses the server send half, so:
//   1. The CPU (or remote opponent) never receives the move and never
//      replies with theirs — the match stalls.
//   2. ShogiWars internal state is left half-updated; the next press path
//      dereferences something the Send half would have initialized and
//      crashes.
//
// Using SendMove is the same path a player-driven tap takes, so the
// downstream Move/Hook chain still emits the per-move CSA notification
// to the connected engine via HookMoveWithPly.
// ===========================================================================

typedef void *(*il2cpp_string_new_t)(const char *str);
static il2cpp_string_new_t fn_il2cpp_string_new = NULL;

static void resolveIl2cppFunctions(void) {
    if (fn_il2cpp_string_new) return;
    fn_il2cpp_string_new =
        (il2cpp_string_new_t)dlsym(RTLD_DEFAULT, "il2cpp_string_new");
    if (!fn_il2cpp_string_new) {
        IPALog(@"[INJECT] dlsym il2cpp_string_new failed");
    } else {
        IPALog([NSString stringWithFormat:
                  @"[INJECT] resolved il2cpp_string_new @%p",
                  fn_il2cpp_string_new]);
    }
}

BOOL inject_apply(NSString *csa) {
    if (!csa || csa.length == 0) {
        IPALog(@"[INJECT] inject_apply: empty csa");
        return NO;
    }

    void *gc = g_gameControllerCache;
    if (!gc) {
        IPALog(@"[INJECT] inject_apply: no GameController cached");
        return NO;
    }

    Move_t moveFn = orig_Move;
    SendMove_t sendMoveFn = orig_SendMove;
    if (!moveFn || !sendMoveFn) {
        IPALog([NSString stringWithFormat:
                  @"[INJECT] inject_apply: orig pointers not resolved "
                  @"(Move=%p SendMove=%p)", moveFn, sendMoveFn]);
        return NO;
    }

    resolveIl2cppFunctions();
    if (!fn_il2cpp_string_new) {
        IPALog(@"[INJECT] inject_apply: il2cpp_string_new unavailable");
        return NO;
    }

    __block BOOL success = NO;
    NSString *csaCopy = [csa copy];

    // GameController.SendMove must run on the Unity main thread —
    // anything it touches (PositionManager, MyTcpip, animations) is
    // single-threaded MonoBehaviour state.
    //
    // Csa_Engine.m::csa_handle_move_from_engine already dispatches us onto
    // the main queue before calling inject_apply, so we usually arrive
    // here on the main thread. dispatch_sync to the same queue we already
    // own would deadlock libdispatch ("dispatch_sync called on queue
    // already owned by current thread"). Branch on NSThread.isMainThread
    // so direct callers stay safe regardless of where they came from.
    void (^body)(void) = ^{
        @try {
            const char *utf8 = [csaCopy UTF8String];
            if (!utf8) {
                IPALog(@"[INJECT] inject_apply: utf8 conversion failed");
                return;
            }
            void *csaIl2cpp = fn_il2cpp_string_new(utf8);
            if (!csaIl2cpp) {
                IPALog(@"[INJECT] inject_apply: il2cpp_string_new returned NULL");
                return;
            }

            // Replicate the exact order a player tap follows:
            //   1. Move(csa, timeLeft, quiet)  — updates PositionManager
            //      and drives the UI piece-slide animation.
            //   2. SendMove(csa, isKishin)     — pushes the move to the
            //      server (MyDummyTcpip for Practice, MyTcpip for Online),
            //      which then echoes back the opponent's reply through
            //      OnMovesNormal -> Move(ply, csa, ...).
            //
            // Calling SendMove alone leaves the local board frozen — the
            // server processes the move but the UI never animates the
            // piece because Move() was never run on this side.
            bool ok = moveFn(gc, csaIl2cpp, /*timeLeft=*/0.0f, /*quiet=*/false);
            IPALog([NSString stringWithFormat:
                      @"[INJECT] Move(\"%@\") -> %d", csaCopy, (int)ok]);
            if (!ok) {
                IPALog(@"[INJECT] Move returned false — skipping SendMove");
                return;
            }
            sendMoveFn(gc, csaIl2cpp, /*isKishin=*/false);
            IPALog([NSString stringWithFormat:
                      @"[INJECT] SendMove(\"%@\") issued", csaCopy]);
            success = YES;
        } @catch (NSException *e) {
            IPALog([NSString stringWithFormat:
                      @"[INJECT] inject_apply threw: %@", e]);
        }
    };

    if ([NSThread isMainThread]) {
        body();
    } else {
        dispatch_sync(dispatch_get_main_queue(), body);
    }

    return success;
}
