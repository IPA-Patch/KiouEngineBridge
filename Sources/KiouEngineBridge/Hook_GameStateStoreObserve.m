#import "Internal.h"

#if KIOU_BINPATCH
// This entire module is meta-sidecar-only. The binpatch flavour drops the
// meta sidecar (see docs/plans/kiou_engine_bridge_binpatch.md § 2), so the
// file compiles to nothing. InstallGameStateStoreObserveHook is a no-op
// shim defined at the bottom of this #if block so Tweak.m doesn't need its
// own #if to skip the call — keeping the constructor wiring uniform.
void InstallGameStateStoreObserveHook(uintptr_t unityBase) { (void)unityBase; }
void MetaOnPlayerInfoSet(int32_t side, void *playerInfo) {
    (void)side; (void)playerInfo;
}
#else

// ===========================================================================
// Hook_GameStateStoreObserve — capture Set*PlayerInfo calls on the store.
//
// Why this exists:
//   On Online matches, OnlinePvPMode.InitializeAsync runs BEFORE matchmaking
//   resolves the opponent identity. The MatchConfig the Init hook stashes
//   at that point holds the local-side placeholder name "プレイヤー" for
//   both sides — there's no useful player info there yet.
//
//   The real identity arrives later via two calls on the GameStateStore:
//
//     GameStateStore.SetBlackPlayerInfo(PlayerInfo)  RVA 0x5A2CB64
//     GameStateStore.SetWhitePlayerInfo(PlayerInfo)  RVA 0x5A2CBA0
//
//   Each writes the matchmaking-resolved PlayerInfo into the corresponding
//   ReactiveProperty. We hook both, stash the PlayerInfo pointer that
//   passes through, and tell Meta_Emitter that side N is now ready.
//
//   Meta_Emitter implements the actual "wait for both, then emit match_start"
//   policy. This file's only job is to surface the pointer.
//
// What this file deliberately doesn't do:
//   - Read PlayerInfo fields here. Meta_Emitter walks them when it builds
//     the JSON; we just hand over the pointer.
//   - Touch the inject path. SetPlayerInfo has nothing to do with moves.
//   - Hook the corresponding setters on other stores (MatchConfig has its
//     own set_BlackPlayer / set_WhitePlayer at dump.cs:1418157 — those
//     are early-bind for CPU matches and don't fire on Online).
// ===========================================================================

#define RVA_GAMESTATESTORE_SET_BLACK_PLAYER_INFO 0x5A2CB64
#define RVA_GAMESTATESTORE_SET_WHITE_PLAYER_INFO 0x5A2CBA0
// NotifyPieceMoved は自分手・相手手どちらの apply 時も通る GameStateStore
// 上のチョークポイント。ADAPTER2 (Hook_LowLevelObserve.m) は自分手しか
// 通らないので、MetaEmitMove の発火点はこちらに集約する。
#define RVA_GAMESTATESTORE_NOTIFY_PIECE_MOVED    0x5A2CD24

// ---------------------------------------------------------------------------
// Original (untrampolined) function pointers — chain through after stashing.
// SetPlayerInfo signatures are simple instance methods returning void with
// one PlayerInfo* argument, so no UniTask gymnastics needed.
// ---------------------------------------------------------------------------
typedef void (*SetPlayerInfo_t)(void *self, void *playerInfo);
static SetPlayerInfo_t orig_SetBlackPlayerInfo = NULL;
static SetPlayerInfo_t orig_SetWhitePlayerInfo = NULL;

// ---------------------------------------------------------------------------
// Hook bodies. Both share the same shape; the side argument to
// MetaOnPlayerInfoSet tells Meta_Emitter which slot was just written.
// ---------------------------------------------------------------------------
static void HookSetBlackPlayerInfo(void *self, void *playerInfo) {
    MetaOnPlayerInfoSet(/*side=*/0, playerInfo);
    CsaOnPlayerInfoSet(/*side=*/0, playerInfo);
    if (orig_SetBlackPlayerInfo) orig_SetBlackPlayerInfo(self, playerInfo);
}

static void HookSetWhitePlayerInfo(void *self, void *playerInfo) {
    MetaOnPlayerInfoSet(/*side=*/1, playerInfo);
    CsaOnPlayerInfoSet(/*side=*/1, playerInfo);
    if (orig_SetWhitePlayerInfo) orig_SetWhitePlayerInfo(self, playerInfo);
}

// ---------------------------------------------------------------------------
// GameStateStore.NotifyPieceMoved(Sunfish.Move move, PlayerSide playerSide)
//
// arm64 ABI:
//   x0 = self (GameStateStore)
//   w1 = move (uint32, Sunfish.Move packed bits)
//   w2 = playerSide (int32, the side that just moved: 0=Black, 1=White)
//
// 自分のクライアントが指したとき (ADAPTER2 経由) も、サーバから相手手の
// state 更新が降ってきたときも、最終的にこの NotifyPieceMoved を通る。
// したがってここで MetaEmitMove を 1 度だけ発火すれば、片肺 KIF
// 問題は解消する。MetaEmitMove は引数として「次の手番」を受け取る
// 設計なので、API は崩さずに `playerSide == 0 ? 1 : 0` で flip して渡す。
// ---------------------------------------------------------------------------
typedef void (*GameStateStore_NotifyPieceMoved_t)(void *self,
                                                  uint32_t move,
                                                  int32_t playerSide);
static GameStateStore_NotifyPieceMoved_t orig_NotifyPieceMoved = NULL;

static void HookNotifyPieceMoved(void *self,
                                  uint32_t move,
                                  int32_t playerSide) {
    // Call original FIRST so the GameController applies the move and the
    // live SFEN is in its post-move state when we read it back. Inject_Move
    // also relies on this same ordering (NotifyPieceMoved → ApplyImpl), so
    // we keep the original side-effect chain intact.
    if (orig_NotifyPieceMoved) orig_NotifyPieceMoved(self, move, playerSide);

    // sfen は g_gameCtrlCache 経由で読む。ADAPTER2 が live セッションで
    // 1 度でも走っていれば NULL ではない。相手手側 (ADAPTER2 を通らない)
    // でも、初手以降は同じ GameController インスタンスが使い回されるので
    // キャッシュは有効。
    NSString *sfen = SfenFromGameController(g_gameCtrlCache);
    NSString *usi  = moveToUsi((SfMove)move);

    // playerSide はこの NotifyPieceMoved 呼び出しの「指した側」。
    // MetaEmitMove は「次の手番」を引数に取るので flip して渡す。
    int32_t nextSide = (playerSide == 0) ? 1
                     : (playerSide == 1) ? 0
                     : -1;
    file_log([NSString stringWithFormat:
              @"[GSTATE-MOVE] NotifyPieceMoved self=%p moved_side=%d "
              @"usi=\"%@\" sfen=\"%@\"",
              self, (int)playerSide, usi ?: @"", sfen ?: @""]);

    // GameStateStore (dump.cs:1422268) keeps two ReactiveProperty<float>
    // clocks at offset 0x80 / 0x90. The underlying R3 / UniRx box stores
    // the current value at +0x20 (verified live with a probe sweep, see
    // commit history). Online matches keep these in sync with the server;
    // VsAI / Local matches use them for the on-screen clock too.
    //
    // Sanity check: VsAI emits 86400.0 (= 24 h) as the CPU side's clock to
    // mean "no time limit." Treat anything ≥ 86400 - 60 as "no clock" so we
    // don't ship bogus large T values.
    float blackRemain = -1.0f;
    float whiteRemain = -1.0f;
    {
        void *bRP = readPtr(self, 0x80);
        void *wRP = readPtr(self, 0x90);
        if (bRP) {
            float v = *(const float *)((const uint8_t *)bRP + 0x20);
            if (v > 0.0f && v < 86340.0f) blackRemain = v;
        }
        if (wRP) {
            float v = *(const float *)((const uint8_t *)wRP + 0x20);
            if (v > 0.0f && v < 86340.0f) whiteRemain = v;
        }
    }

    MetaEmitMove(usi, sfen, nextSide);
    // CSA engine driver wants the raw Move bits + post-move SFEN so it can
    // reconstruct the piece type at the destination square and ship a
    // `+7776FU,T10`-style notification.
    CsaEngineOnMoveObserved((uint32_t)move, playerSide, sfen,
                            blackRemain, whiteRemain);
}

// ---------------------------------------------------------------------------
// Installer. Called once from Tweak.m::installUnityHooks().
// ---------------------------------------------------------------------------
void InstallGameStateStoreObserveHook(uintptr_t unityBase) {
    {
        uintptr_t addr = unityBase + RVA_GAMESTATESTORE_SET_BLACK_PLAYER_INFO;
        MSHookFunction((void *)addr,
                       (void *)HookSetBlackPlayerInfo,
                       (void **)&orig_SetBlackPlayerInfo);
        file_log([NSString stringWithFormat:
                  @"[GSTATE] hooked GameStateStore.SetBlackPlayerInfo "
                  @"@0x%lx (base+0x%x)",
                  (unsigned long)addr,
                  (unsigned)RVA_GAMESTATESTORE_SET_BLACK_PLAYER_INFO]);
    }
    {
        uintptr_t addr = unityBase + RVA_GAMESTATESTORE_SET_WHITE_PLAYER_INFO;
        MSHookFunction((void *)addr,
                       (void *)HookSetWhitePlayerInfo,
                       (void **)&orig_SetWhitePlayerInfo);
        file_log([NSString stringWithFormat:
                  @"[GSTATE] hooked GameStateStore.SetWhitePlayerInfo "
                  @"@0x%lx (base+0x%x)",
                  (unsigned long)addr,
                  (unsigned)RVA_GAMESTATESTORE_SET_WHITE_PLAYER_INFO]);
    }
    {
        uintptr_t addr = unityBase + RVA_GAMESTATESTORE_NOTIFY_PIECE_MOVED;
        MSHookFunction((void *)addr,
                       (void *)HookNotifyPieceMoved,
                       (void **)&orig_NotifyPieceMoved);
        file_log([NSString stringWithFormat:
                  @"[GSTATE] hooked GameStateStore.NotifyPieceMoved "
                  @"@0x%lx (base+0x%x)",
                  (unsigned long)addr,
                  (unsigned)RVA_GAMESTATESTORE_NOTIFY_PIECE_MOVED]);
    }
}

#endif  // !KIOU_BINPATCH
