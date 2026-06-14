#import "Internal.h"

#import <mach/mach_time.h>

// ===========================================================================
// Hook_LowLevelObserve — committed-move observation at the position store.
//
// Live device testing (CPU match, AIMatchMode, 27 moves observed) confirmed
// which low-level entry points the game actually drives. Two fire per move,
// in this order, ~10 ms apart:
//
//   1. Project.ShogiCore.GameController.TryMakeMove(Move) @ 0x5D43210
//        — the underlying store mutation. We hook this and read the just-
//          appended Position back out to log the post-move SFEN.
//
//   2. ShogiGameAdapter.TryMakeMove(Move, out Move) @ 0x59D0DFC
//        — the adapter-layer wrapper that propagates the executed move
//          back to the caller. We hook this too as a cross-check; the SFEN
//          we read here should match whatever (1) just produced.
//
// Two related entry points that the trace showed do NOT fire during play:
//
//   - ShogiGameAdapter.TryMakeMove(Move) @ 0x59D0DD8 (no-out variant)
//   - MatchController.ExecuteMoveAndGetResult @ 0x59D8248
//
// We deliberately don't hook them. The dump.cs call-graph implied
// MatchController was the universal chokepoint; live AIMatchMode bypasses
// it entirely. The lesson is recorded in [[kiou-hook-multi-layer]]: when
// in doubt, hook the lowest store-mutation function, not the controller.
//
// SFEN extraction walks:
//   adapter._gameController (+0x10) -> GameController._positionHistory (+0x10)
//                                   -> List<Position>._items (+0x10)
//                                   -> _items[_size-1] (Position*)
// then calls Project.ShogiCore.Position.ToSFEN (0x5D44374). That getter
// reads only readonly fields, so it's safe to invoke from our hook context.
//
// All reads. No writes. Logs to NSTemporaryDirectory()/kiou_usi_proxy.log.
// ===========================================================================

#define RVA_ADAPTER_TRY_MAKE_MOVE_OUT      0x59D0DFC  // bool(this, Move, out Move)
#define RVA_GAMECTRL_TRY_MAKE_MOVE         0x5D43210  // bool(this, Move)
#define RVA_GAMECTRL_GET_USI_TEXT          0x5D44074  // string(this)
#define RVA_POSITION_TO_SFEN               0x5D44374  // string(this)
#define RVA_SUNFISH_MOVE_TO_STRING_SFEN    0x5D821B0  // string(Sunfish.Move*)
                                                     // value-type struct method:
                                                     // arm64 il2cpp passes the
                                                     // struct address as 'this'.

// ADAPTER_OFF_GAME_CONTROLLER is shared with Inject_Move.m via Internal.h.
#define ADAPTER_OFF_GAME_CONTROLLER        KIOU_ADAPTER_OFF_GAME_CONTROLLER
#define GC_OFF_POSITION_HISTORY            0x10  // List<Position>*
#define GC_OFF_MOVE_HISTORY                0x20  // List<Move>*
#define LIST_OFF_ITEMS                     0x10  // T[]*
#define LIST_OFF_SIZE                      0x18  // int32
#define ARRAY_OFF_ELEMS                    0x20  // first element

typedef uint32_t SfMove;

// Original (untrampolined) function pointers — definitions go here, the
// declarations live in Internal.h so Inject_Move.m can call them directly
// without re-entering this file's hooks (which would double-log the
// injected move).
Adapter_TryMakeMove_Out_t orig_AdapterTryMakeMoveOut = NULL;
GameCtrl_TryMakeMove_t    orig_GameCtrlTryMakeMove   = NULL;

// NativeFunction-style helpers, resolved once at install time. Position_ToSFEN
// and Move_ToStringSFEN are shared with Inject_Move.m (it needs ToSFEN to
// record the after-move SFEN); GetUSIText stays file-private.
typedef void *(*GetUSIText_t)(void *gameCtrl);
Position_ToSFEN_t   g_Position_ToSFEN     = NULL;
Move_ToStringSFEN_t g_Move_ToStringSFEN   = NULL;
static GetUSIText_t g_GameCtrl_GetUSIText = NULL;

// Decode the latest Position* out of a Project.ShogiCore.GameController.
static void *latestPositionFromGameController(void *gameCtrl) {
    if (!ptrLooksValid(gameCtrl)) return NULL;
    void *list = readPtr(gameCtrl, GC_OFF_POSITION_HISTORY);
    if (!list) return NULL;
    void *items = readPtr(list, LIST_OFF_ITEMS);
    int32_t size = readI32(list, LIST_OFF_SIZE);
    if (size <= 0 || size > 4096 || !ptrLooksValid(items)) return NULL;
    // items is a T[] (il2cpp array). Element 0 sits at +0x20, refs 8-byte spaced.
    void *posPtr = readPtr(items, ARRAY_OFF_ELEMS + (size - 1) * 8);
    return posPtr;
}

// Pull SFEN for the current state of a GameController via Position.ToSFEN.
// Returns nil on any failure — every step is guarded.
static NSString *sfenFromGameController(void *gameCtrl) {
    if (!g_Position_ToSFEN) return nil;
    void *pos = latestPositionFromGameController(gameCtrl);
    if (!pos) return nil;
    @try {
        void *strPtr = g_Position_ToSFEN(pos);
        return il2cppStringToNSString(strPtr);
    } @catch (NSException *e) {
        return nil;
    }
}

// Convert a Sunfish.Move (uint32) into its USI string form ("7g7f", "B*5e",
// "2e2h+", etc.) by calling Sunfish.Move.ToStringSFEN. The C# struct method
// expects 'this' to be the address of the Move value; we copy onto the stack
// and pass &local. The callee never escapes the pointer, so it's safe.
static NSString *moveToUsi(SfMove m) {
    if (!g_Move_ToStringSFEN) return nil;
    @try {
        SfMove local = m;
        void *strPtr = g_Move_ToStringSFEN(&local);
        return il2cppStringToNSString(strPtr);
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *describeMoveBits(SfMove m) {
    uint32_t to       = m & 0x7F;
    uint32_t from     = (m >> 7) & 0x7F;
    uint32_t promote  = (m >> 14) & 1;
    uint32_t drop     = (m >> 15) & 1;
    if (drop) {
        return [NSString stringWithFormat:@"drop=1 to=%u promote=%u raw=0x%x",
                to, promote, m];
    }
    return [NSString stringWithFormat:@"from=%u to=%u promote=%u raw=0x%x",
            from, to, promote, m];
}

// ---------------------------------------------------------------------------
// ShogiGameAdapter.TryMakeMove(Move, out Move)
// ---------------------------------------------------------------------------
static bool hook_AdapterTryMakeMoveOut(void *self, SfMove move, void *outMove) {
    // Update the injection-side cache before the original runs. Order matters:
    // we want g_adapterCache to be non-NULL as soon as anything goes through
    // this path, and we want g_gameCtrlCache to point at the same Adapter's
    // GameController. mach_absolute_time gives us a coarse "is this session
    // still live?" timestamp for the route picker in Inject_Move.m.
    if (g_adapterCache != self) g_adapterCache = self;
    void *gcSeen = readPtr(self, ADAPTER_OFF_GAME_CONTROLLER);
    if (gcSeen && g_gameCtrlCache != gcSeen) g_gameCtrlCache = gcSeen;
    g_lastAdapterEvtUs = mach_absolute_time();

    bool ok = orig_AdapterTryMakeMoveOut
                  ? orig_AdapterTryMakeMoveOut(self, move, outMove) : false;
    void *gameCtrl = readPtr(self, ADAPTER_OFF_GAME_CONTROLLER);
    NSString *sfen = sfenFromGameController(gameCtrl);
    SfMove executed = 0;
    if (ptrLooksValid(outMove)) {
        executed = (SfMove)(uint32_t)readI32(outMove, 0);
    }
    NSString *usi = moveToUsi(move);
    file_log([NSString stringWithFormat:
              @"[ADAPTER2] TryMakeMove self=%p ok=%d "
              @"usi=\"%@\" argMove={%@} outMove=0x%x sfen_after=\"%@\"",
              self, (int)ok, usi ?: @"", describeMoveBits(move),
              (unsigned)executed, sfen ?: @""]);

    // Phase 2: forward the observation to the USI engine driver. It decides
    // whether the next side to move is ours (= time to ask YaneuraOu for a
    // bestmove) or the opponent's (= just sit and wait).
    if (ok && sfen) {
        // Pull `side_to_move` straight from the SFEN's "b"/"w" token rather
        // than reach into Position internals — keeps this hook lean and
        // avoids the il2cpp call back into Position fields from the Unity
        // thread we're already on.
        int32_t sideToMove = -1;
        NSArray<NSString *> *parts = [sfen componentsSeparatedByString:@" "];
        if (parts.count >= 2) {
            NSString *side = parts[1];
            if ([side isEqualToString:@"b"]) sideToMove = 0;
            else if ([side isEqualToString:@"w"]) sideToMove = 1;
        }
        usi_engine_on_move_observed(usi, sfen, sideToMove);
    }
    return ok;
}

// ---------------------------------------------------------------------------
// Project.ShogiCore.GameController.TryMakeMove(Move)
// ---------------------------------------------------------------------------
static bool hook_GameCtrlTryMakeMove(void *self, SfMove move) {
    // Cache the GameController self pointer for the injection path. We don't
    // know an Adapter from here, so leave g_adapterCache alone — Inject_Move
    // can fall back to gamectrl-only routing if it never saw an adapter.
    if (g_gameCtrlCache != self) g_gameCtrlCache = self;
    g_lastAdapterEvtUs = mach_absolute_time();

    bool ok = orig_GameCtrlTryMakeMove
                  ? orig_GameCtrlTryMakeMove(self, move) : false;
    NSString *sfen = sfenFromGameController(self);
    NSString *usi  = moveToUsi(move);
    file_log([NSString stringWithFormat:
              @"[GAMECTRL] TryMakeMove self=%p ok=%d usi=\"%@\" move={%@} sfen_after=\"%@\"",
              self, (int)ok, usi ?: @"", describeMoveBits(move), sfen ?: @""]);
    // Phase 2 deliberately does NOT notify the USI engine from here —
    // ADAPTER2 fires ~10ms later for the same move and is the canonical
    // observation point (one move = one notification, no dedup needed).
    return ok;
}

// ---------------------------------------------------------------------------
// Installer. Wires the three hooks plus the NativeFunction-style trampolines
// we use to call ToSFEN / GetUSIText from within them.
// ---------------------------------------------------------------------------
void install_LowLevelObserve_hook(uintptr_t unityBase) {
    g_Position_ToSFEN =
        (Position_ToSFEN_t)(void *)(unityBase + RVA_POSITION_TO_SFEN);
    g_GameCtrl_GetUSIText =
        (GetUSIText_t)(void *)(unityBase + RVA_GAMECTRL_GET_USI_TEXT);
    g_Move_ToStringSFEN =
        (Move_ToStringSFEN_t)(void *)(unityBase + RVA_SUNFISH_MOVE_TO_STRING_SFEN);

    {
        uintptr_t addr = unityBase + RVA_ADAPTER_TRY_MAKE_MOVE_OUT;
        MSHookFunction((void *)addr,
                       (void *)hook_AdapterTryMakeMoveOut,
                       (void **)&orig_AdapterTryMakeMoveOut);
        file_log([NSString stringWithFormat:
                  @"[LOWLEVEL] hooked ShogiGameAdapter.TryMakeMove(Move,out) "
                  @"@0x%lx (base+0x%x)",
                  (unsigned long)addr,
                  (unsigned)RVA_ADAPTER_TRY_MAKE_MOVE_OUT]);
    }
    {
        uintptr_t addr = unityBase + RVA_GAMECTRL_TRY_MAKE_MOVE;
        MSHookFunction((void *)addr,
                       (void *)hook_GameCtrlTryMakeMove,
                       (void **)&orig_GameCtrlTryMakeMove);
        file_log([NSString stringWithFormat:
                  @"[LOWLEVEL] hooked GameController.TryMakeMove "
                  @"@0x%lx (base+0x%x)",
                  (unsigned long)addr, (unsigned)RVA_GAMECTRL_TRY_MAKE_MOVE]);
    }
}
