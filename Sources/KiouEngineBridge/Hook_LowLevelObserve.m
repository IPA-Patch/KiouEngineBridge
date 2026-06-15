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
// All reads. No writes. Logs to NSTemporaryDirectory()/kiouenginebridge.log.
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

// SfMove typedef は Internal.h に移動 (Hook_GameStateStoreObserve.m など
// 他ファイルから moveToUsi を呼びたいので公開シグネチャ側に置いた)。

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
//
// Exported (declared in Internal.h) so Hook_GameStateStoreObserve.m can
// read the live SFEN after NotifyPieceMoved without re-implementing the
// PositionHistory walk.
NSString *sfenFromGameController(void *gameCtrl) {
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

// Pull the full game-record text via Project.ShogiCore.GameController.GetUSIText.
// KIOU の GameController が握っている手順を「startpos moves ...」/「sfen ...
// moves ...」のような USI 文字列で返してくれる。 match_end の meta payload
// に乗せて bridge 側 (Meta_Emitter → Match.finish) で完全な棋譜の
// グランドトゥルースとして使う。Returns nil on any failure.
//
// Exported (declared in Internal.h) so Meta_Emitter.m can pull the
// snapshot right before it ships match_end.
NSString *usiTextFromGameController(void *gameCtrl) {
    if (!g_GameCtrl_GetUSIText) return nil;
    if (!ptrLooksValid(gameCtrl)) return nil;
    @try {
        void *strPtr = g_GameCtrl_GetUSIText(gameCtrl);
        return il2cppStringToNSString(strPtr);
    } @catch (NSException *e) {
        return nil;
    }
}

// Convert a PSC (Project.ShogiCore) Move (uint32) into its USI string form
// ("7g7f", "B*5e", "2e2h+", etc.).
//
// 重要: 以前は Sunfish.Move.ToStringSFEN を呼んでいたが、これは Sunfish
// engine 内部の「file 9 = 高 index」規則で文字列化する。一方 KIOU 内部の
// Move bits (= NotifyPieceMoved / Adapter に流れるもの) は
// Project.ShogiCore.Square 規則 (SQ11=0, SQ19=8, SQ91=72, file 1 が低 index、
// USI 標準と一致) で from/to を持っている。Sunfish 経由だと筋番号が反転
// した USI が出てしまい、bridge 側で tsshogi が解釈できない (Inject_Move.m
// の commit history コメント 256-280 行に背景あり)。
//
// 自前変換に切り替えて、Inject_Move の inject_buildMove と同じ規則で
// square (0..80) → "<file><rank>" を起こす。
//
//   square = (file - 1) * 9 + (rank - 'a')
//   file_idx = square / 9  → USI '1' + file_idx
//   rank_idx = square % 9  → USI 'a' + rank_idx
//
// Bit layout (Inject_Move.m:259-264 参照):
//   bit[6:0]   to
//   bit[13:7]  from
//   bit[14]    promote
//   bit[15]    drop
//   upper 16   movingPiece など (drop の駒種もここ。レイアウト未確定)
//
// drop 時の駒種は upper-16 のレイアウトが reverse engineering 待ちのため、
// 当面 `?` プレースホルダで出す。bridge 側ログで raw bits を見ながら
// 突き合わせ → 後続コミットで精度上げる。
//
// Exported (declared in Internal.h) so Hook_GameStateStoreObserve.m can reuse
// the same Move→USI conversion when emitting meta for both sides.
NSString *moveToUsi(SfMove m) {
    uint32_t to       = m & 0x7F;
    uint32_t from     = (m >> 7) & 0x7F;
    uint32_t promote  = (m >> 14) & 1;
    uint32_t drop     = (m >> 15) & 1;

    if (to > 80) return nil;
    char toFile = (char)('1' + (to / 9));
    char toRank = (char)('a' + (to % 9));

    if (drop) {
        // 駒種は upper-16 のレイアウト未確定なので '?' を使う。bridge 側で
        // sfen_after を見れば駒種は逆算できるので、まずは KIOU 内部の Move
        // が正しく drop と認識されていることだけ担保する。
        char piece = '?';
        return [NSString stringWithFormat:@"%c*%c%c", piece, toFile, toRank];
    }

    if (from > 80) return nil;
    char fromFile = (char)('1' + (from / 9));
    char fromRank = (char)('a' + (from % 9));

    if (promote) {
        return [NSString stringWithFormat:@"%c%c%c%c+",
                fromFile, fromRank, toFile, toRank];
    }
    return [NSString stringWithFormat:@"%c%c%c%c",
            fromFile, fromRank, toFile, toRank];
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
bool hook_AdapterTryMakeMoveOut(void *self, SfMove move, void *outMove) {
    // Update the injection-side cache before the original runs. Order matters:
    // we want g_adapterCache to be non-NULL as soon as anything goes through
    // this path, and we want g_gameCtrlCache to point at the same Adapter's
    // GameController. mach_absolute_time gives us a coarse "is this session
    // still live?" timestamp for the route picker in Inject_Move.m.
    if (g_adapterCache != self) g_adapterCache = self;
    void *gcSeen = readPtr(self, ADAPTER_OFF_GAME_CONTROLLER);
    if (gcSeen && g_gameCtrlCache != gcSeen) g_gameCtrlCache = gcSeen;
    g_lastAdapterEvtUs = mach_absolute_time();

    // Run the original synchronously on the JB build (no-op on binpatch
    // because the cave handles orig via the displaced prologue + B orig+4).
    // The return value flows back to the caller verbatim — KIOU's caller
    // checks it to know whether the move actually committed.
    bool ok = KIOU_CALL_ORIG_RET(bool, orig_AdapterTryMakeMoveOut,
                                 self, move, outMove);

    // orig has completed by this point on JB (synchronous call above) and
    // will complete on binpatch before the deferred block fires (the cave's
    // `B orig+4` lands inside the current main-runloop iteration). Either
    // way the dispatched block observes the post-move PositionHistory.
    //
    // outMove cannot be read from inside the deferred block: the caller's
    // stack frame is gone by then. Instead we copy `move` by value (it's a
    // packed uint32_t) and reconstruct the USI string from it via moveToUsi
    // inside the block. The post-move SFEN walks PositionHistory[size-1]
    // off the cached GameController, which is post-orig truth regardless of
    // outMove.
    void *selfCap = self;
    uint32_t mv_copy = (uint32_t)move;
    dispatch_async(dispatch_get_main_queue(), ^{
        void *gameCtrl = readPtr(selfCap, ADAPTER_OFF_GAME_CONTROLLER);
        NSString *sfen = sfenFromGameController(gameCtrl);
        NSString *usi  = moveToUsi((SfMove)mv_copy);
        file_log([NSString stringWithFormat:
                  @"[ADAPTER2] TryMakeMove self=%p "
                  @"usi=\"%@\" argMove={%@} sfen_after=\"%@\"",
                  selfCap, usi ?: @"", describeMoveBits((SfMove)mv_copy),
                  sfen ?: @""]);

        // Phase 2: forward the observation to the USI engine driver. It
        // decides whether the next side to move is ours (= time to ask
        // YaneuraOu for a bestmove) or the opponent's (= just sit and wait).
        if (sfen) {
            // Pull `side_to_move` straight from the SFEN's "b"/"w" token
            // rather than reach into Position internals — keeps this hook
            // lean and avoids the il2cpp call back into Position fields
            // from the Unity thread we're already on.
            int32_t sideToMove = -1;
            NSArray<NSString *> *parts =
                [sfen componentsSeparatedByString:@" "];
            if (parts.count >= 2) {
                NSString *side = parts[1];
                if ([side isEqualToString:@"b"]) sideToMove = 0;
                else if ([side isEqualToString:@"w"]) sideToMove = 1;
            }
            usi_engine_on_move_observed(usi, sfen, sideToMove);
            // meta_emit_move はここでは出さない — ADAPTER2 は「自分のクライアント
            // が指した手」しか通らない (オンライン対戦では相手手はサーバ state
            // 経由で来る) ので、ここで出すと自分側 ply のみの片肺 KIF になる。
            // 両手番分の meta は Hook_GameStateStoreObserve.m の
            // NotifyPieceMoved フックに集約してある。
        }
    });

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
// Installer. Resolves NativeFunction-style trampolines (ToSFEN / GetUSIText /
// Move.ToStringSFEN) — needed by BOTH builds, because Inject_Move and the
// observation hooks both call them as function pointers. Then, on the JB
// build only, installs the two MSHookFunction site hooks; on the binpatch
// build the symbol-pointer resolves remain but the hook wires are
// orchestrated by the static cave + SLOT dispatcher.
// ---------------------------------------------------------------------------
void install_LowLevelObserve_hook(uintptr_t unityBase) {
    g_Position_ToSFEN =
        (Position_ToSFEN_t)(void *)(unityBase + RVA_POSITION_TO_SFEN);
    g_GameCtrl_GetUSIText =
        (GetUSIText_t)(void *)(unityBase + RVA_GAMECTRL_GET_USI_TEXT);
    g_Move_ToStringSFEN =
        (Move_ToStringSFEN_t)(void *)(unityBase + RVA_SUNFISH_MOVE_TO_STRING_SFEN);

#if !KIOU_BINPATCH
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
#else
    // On binpatch:
    //   ShogiGameAdapter.TryMakeMove(Move,out) → routed via cave entry
    //     KIOU_BR_HOOK_ADAPTER_TRY_MAKE_MOVE_OUT in
    //     recipes/kiouenginebridge.py.
    //   GameController.TryMakeMove(Move) → NOT in CAVE_PATCHES. It was a
    //     log-only hook on the JB build, and its observation is fully
    //     covered by hook_AdapterTryMakeMoveOut for every move that
    //     reaches the board. Dropping it on binpatch saves a cave and
    //     keeps the hook surface tight.
    file_log(@"[LOWLEVEL] binpatch build — site hooks driven by cave/SLOT, "
             @"symbol pointers resolved.");
#endif  // !KIOU_BINPATCH
}
