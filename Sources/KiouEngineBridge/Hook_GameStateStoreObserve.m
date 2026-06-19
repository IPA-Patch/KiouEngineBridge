#import "Internal.h"

// ---------------------------------------------------------------------------
// RVAs — shared by both JB and chinlan paths.
// ---------------------------------------------------------------------------
#define RVA_GAMESTATESTORE_SET_BLACK_PLAYER_INFO 0x5A2CB64
#define RVA_GAMESTATESTORE_SET_WHITE_PLAYER_INFO 0x5A2CBA0
#define RVA_GAMESTATESTORE_NOTIFY_PIECE_MOVED    0x5A2CD24
#define RVA_GAMESTATESTORE_NOTIFY_STATE_SYNCED   0x5A2CE64
// SetCurrentPosition(Position) — assigns _currentPosition.Value, which is the
// ReactiveProperty MoveCountPresenter actually subscribes to. NotifyStateSynced
// only fires the _onStateSynced Subject, so for the move-count UI to update we
// must drive SetCurrentPosition on every committed move.
#define RVA_GAMESTATESTORE_SET_CURRENT_POSITION  0x5A2C06C

// ---------------------------------------------------------------------------
// Trampoline pointer types.
// ---------------------------------------------------------------------------
typedef void (*SetPlayerInfo_t)(void *self, void *playerInfo);
typedef void (*GState_NotifyPieceMoved_t)(void *self, uint32_t move,
                                          int32_t playerSide);
typedef void (*GState_NotifyStateSynced_t)(void *self, void *position);
typedef void (*GState_SetCurrentPosition_t)(void *self, void *position);

static void *g_lastGameStateStore = NULL;
static GState_NotifyStateSynced_t  g_GameStateStore_NotifyStateSynced  = NULL;
static GState_SetCurrentPosition_t g_GameStateStore_SetCurrentPosition = NULL;

void HookGStateRememberStore(void *self) {
    if (self) {
        g_lastGameStateStore = self;
        CsaSetGameStateStore(self);
    }
}

void ResolveGameStateStoreNotifyStateSynced(uintptr_t unityBase) {
    g_GameStateStore_NotifyStateSynced =
        (GState_NotifyStateSynced_t)(void *)(unityBase + RVA_GAMESTATESTORE_NOTIFY_STATE_SYNCED);
    g_GameStateStore_SetCurrentPosition =
        (GState_SetCurrentPosition_t)(void *)(unityBase + RVA_GAMESTATESTORE_SET_CURRENT_POSITION);
}

void HookGStateNotifyStateSyncedForCurrentPosition(void) {
    if (!g_lastGameStateStore || !g_gameCtrlCache) return;
    void *list = readPtr(g_gameCtrlCache, 0x10);
    if (!list) return;
    void *items = readPtr(list, 0x10);
    int32_t size = readI32(list, 0x18);
    if (size <= 0 || size > 4096 || !ptrLooksValid(items)) return;
    void *pos = readPtr(items, 0x20 + (size - 1) * 8);
    if (!pos) return;
    // SetCurrentPosition first so the ReactiveProperty<Position> CurrentPosition
    // fires (this is what MoveCountPresenter listens on). NotifyStateSynced
    // second for any other subscriber of the _onStateSynced Subject.
    if (g_GameStateStore_SetCurrentPosition) {
        g_GameStateStore_SetCurrentPosition(g_lastGameStateStore, pos);
    }
    if (g_GameStateStore_NotifyStateSynced) {
        g_GameStateStore_NotifyStateSynced(g_lastGameStateStore, pos);
    }
    IPALog([NSString stringWithFormat:
              @"[GSTATE-SYNC] SetCurrent+Notify store=%p pos=%p",
              g_lastGameStateStore, pos]);
}

#if !KIOU_CHINLAN
// Defined (zero-initialised) in the JB installer section below.
extern SetPlayerInfo_t orig_SetBlackPlayerInfo;
extern SetPlayerInfo_t orig_SetWhitePlayerInfo;
extern GState_NotifyPieceMoved_t orig_NotifyPieceMoved;
#endif

// ===========================================================================
// Hook bodies — compiled for BOTH JB and chinlan.
//
// On JB:      MSHookFunction wires these as the replacement function and
//             populates orig_* so the body can chain through.
// On chinlan: the cave dispatcher calls HookGState* (declared in Internal.h)
//              directly; orig-chaining is handled by the cave's displaced
//              prologue + `B orig+4`, so we never call orig_* here.
// ===========================================================================

void HookGStateSetBlackPlayerInfo(void *self, void *playerInfo) {
    HookGStateRememberStore(self);
    MetaOnPlayerInfoSet(/*side=*/0, playerInfo);
    CsaOnPlayerInfoSet(/*side=*/0, playerInfo);
#if !KIOU_CHINLAN
    if (orig_SetBlackPlayerInfo) orig_SetBlackPlayerInfo(self, playerInfo);
#else
    (void)self;
#endif
}

void HookGStateSetWhitePlayerInfo(void *self, void *playerInfo) {
    HookGStateRememberStore(self);
    MetaOnPlayerInfoSet(/*side=*/1, playerInfo);
    CsaOnPlayerInfoSet(/*side=*/1, playerInfo);
#if !KIOU_CHINLAN
    if (orig_SetWhitePlayerInfo) orig_SetWhitePlayerInfo(self, playerInfo);
#else
    (void)self;
#endif
}

// GameStateStore.NotifyPieceMoved(Move move, PlayerSide playerSide)
//
// arm64 ABI:
//   x0 = self (GameStateStore)
//   w1 = move (uint32, Sunfish.Move packed bits)
//   w2 = playerSide (int32, the side that just moved: 0=Black, 1=White)
//
// Both the local client's own moves (ADAPTER2 path) and incoming opponent
// moves (server state update path) pass through this chokepoint, making it
// the single authoritative site for move observation — both for the CSA
// engine driver (CsaEngineOnMoveObserved) and for the legacy meta sidecar
// (MetaEmitMove, a no-op on chinlan).
//
// On JB: orig is called first so the GameController has already applied the
// move and the live SFEN is post-move by the time we read it back.
// On chinlan: the cave runs the displaced prologue (which is the orig
// instruction) before calling the dispatcher, so the same ordering holds.
void HookGStateNotifyPieceMoved(void *self, uint32_t move, int32_t playerSide) {
    if (self) g_lastGameStateStore = self;
#if !KIOU_CHINLAN
    if (orig_NotifyPieceMoved) orig_NotifyPieceMoved(self, move, playerSide);
#endif

    NSString *sfen = SfenFromGameController(g_gameCtrlCache);
    NSString *usi  = moveToUsi((SfMove)move);

    // GameStateStore keeps two ReactiveProperty<float> clocks at offsets
    // 0x80 (black) / 0x90 (white). The R3/UniRx box stores the current
    // value at +0x20. Online matches keep these in sync with the server;
    // VsAI / Local use them for the on-screen clock. Treat ≥ 86340 s
    // (= 24 h − 60 s) as "no limit" and pass -1 so CSA omits the T field.
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

    IPALog([NSString stringWithFormat:
              @"[GSTATE-MOVE] NotifyPieceMoved self=%p moved_side=%d "
              @"usi=\"%@\" sfen=\"%@\"",
              self, (int)playerSide, usi ?: @"", sfen ?: @""]);

    // MetaEmitMove is a no-op on chinlan (Meta_Emitter is dropped).
    int32_t nextSide = (playerSide == 0) ? 1 : (playerSide == 1) ? 0 : -1;
    MetaEmitMove(usi, sfen, nextSide);

    // CSA engine driver: raw move bits + post-move SFEN + remaining clocks
    // → ships a `+7776FU,T10`-style notification to the connected engine.
    CsaEngineOnMoveObserved((uint32_t)move, playerSide, sfen,
                            blackRemain, whiteRemain);
}

// ===========================================================================
// Build-flavour-specific: installer + MetaOnPlayerInfoSet stub.
// ===========================================================================

#if KIOU_CHINLAN

// Cave dispatcher wires HookGState* at patch time; no runtime installation
// needed. MetaOnPlayerInfoSet is a no-op because Meta_Emitter is dropped on
// the chinlan build.
void InstallGameStateStoreObserveHook(uintptr_t unityBase) {
    ResolveGameStateStoreNotifyStateSynced(unityBase);
}
void MetaOnPlayerInfoSet(int32_t side, void *playerInfo) {
    (void)side; (void)playerInfo;
}

#else  // !KIOU_CHINLAN — JB / rootless build

SetPlayerInfo_t orig_SetBlackPlayerInfo = NULL;
SetPlayerInfo_t orig_SetWhitePlayerInfo = NULL;
GState_NotifyPieceMoved_t orig_NotifyPieceMoved = NULL;

void InstallGameStateStoreObserveHook(uintptr_t unityBase) {
    ResolveGameStateStoreNotifyStateSynced(unityBase);
    {
        uintptr_t addr = unityBase + RVA_GAMESTATESTORE_SET_BLACK_PLAYER_INFO;
        MSHookFunction((void *)addr,
                       (void *)HookGStateSetBlackPlayerInfo,
                       (void **)&orig_SetBlackPlayerInfo);
        IPALog([NSString stringWithFormat:
                  @"[GSTATE] hooked GameStateStore.SetBlackPlayerInfo "
                  @"@0x%lx (base+0x%x)",
                  (unsigned long)addr,
                  (unsigned)RVA_GAMESTATESTORE_SET_BLACK_PLAYER_INFO]);
    }
    {
        uintptr_t addr = unityBase + RVA_GAMESTATESTORE_SET_WHITE_PLAYER_INFO;
        MSHookFunction((void *)addr,
                       (void *)HookGStateSetWhitePlayerInfo,
                       (void **)&orig_SetWhitePlayerInfo);
        IPALog([NSString stringWithFormat:
                  @"[GSTATE] hooked GameStateStore.SetWhitePlayerInfo "
                  @"@0x%lx (base+0x%x)",
                  (unsigned long)addr,
                  (unsigned)RVA_GAMESTATESTORE_SET_WHITE_PLAYER_INFO]);
    }
    {
        uintptr_t addr = unityBase + RVA_GAMESTATESTORE_NOTIFY_PIECE_MOVED;
        MSHookFunction((void *)addr,
                       (void *)HookGStateNotifyPieceMoved,
                       (void **)&orig_NotifyPieceMoved);
        IPALog([NSString stringWithFormat:
                  @"[GSTATE] hooked GameStateStore.NotifyPieceMoved "
                  @"@0x%lx (base+0x%x)",
                  (unsigned long)addr,
                  (unsigned)RVA_GAMESTATESTORE_NOTIFY_PIECE_MOVED]);
    }
}

#endif  // !KIOU_CHINLAN
