#import "Internal.h"

// ===========================================================================
// Hook_GameController — observe ShogiWars match lifecycle via GameController.
//
// ShogiWars drives all match flow through a singleton GameController
// (MonoBehaviour). We hook four methods that cover the full CSA surface:
//
//   OnGameStart(GameStartJson)      — match start; board + player info
//   OnMovesNormal(XmlDocument)      — opponent move received from server
//   OnFinishGame(FinishedGameInfo)  — match end; result + reason
//   SendMove(string move, bool)     — local player submitted a move
//
// All RVAs are pinned to ShogiWars 11.0.1 (CFBundleVersion 28).
// Prologue bytes are verified against the extracted UnityFramework.
// ===========================================================================

// ---------------------------------------------------------------------------
// RVAs — ShogiWars 11.0.1 (CFBundleVersion 28), __TEXT vmaddr=0x0.
//
// Prologue bytes listed for verify_sites cross-check:
//   OnGameStart       0x158F3BC  f85fbca9  STP X27,X23,[SP,#-0x40]!
//   OnMovesNormal     0x159002C  f657bda9  STP X22,X21,[SP,#-0x30]!
//   OnFinishGame      0x1590BA8  f44fbea9  STP X20,X19,[SP,#-0x20]!
//   SendMove          0x1591508  f85fbca9  STP X27,X23,[SP,#-0x40]!
// ---------------------------------------------------------------------------
#define RVA_ON_GAME_START   0x158F3BC
#define RVA_ON_MOVES_NORMAL 0x159002C
#define RVA_ON_FINISH_GAME  0x1590BA8
#define RVA_SEND_MOVE       0x1591508
// GameController.Move(string csa, float timeLeft, bool quiet)
// Central path for all committed moves — server-received opponent moves
// (via OnMovesNormal -> Move) and locally-tapped moves (via SendMove ->
// Move) both flow through here. Hooking it gives us a single observation
// point with CSA text and timeLeft already populated.
#define RVA_MOVE_CSA_TIME   0x1583A10
// GameController.Move(int ply, string csa, float timeLeft, bool quiet)
// Server-applied opponent moves (ApplyOppMove -> Move(ply,csa,...)) come
// through this overload, not the (csa,timeLeft,quiet) one. Hooking both
// gives us coverage for both directions.
#define RVA_MOVE_PLY_CSA    0x1590DF4

// ---------------------------------------------------------------------------
// Offsets into il2cpp string objects (System.String).
// System.String layout: object header (0x10) + int32 length @0x10 +
// char[] data starting @0x14 (UTF-16LE, no null terminator).
// ---------------------------------------------------------------------------
#define IL2CPP_STRING_LENGTH_OFF  0x10
#define IL2CPP_STRING_DATA_OFF    0x14

// ---------------------------------------------------------------------------
// Offsets into GameStartJson (see dump.cs TypeDefIndex 2248).
// Fields confirmed against ShogiWars 11.0.1 dump:
//   string name           @0x10
//   string gtype          @0x18
//   int    init_pos_type  @0x20
//   int    opponent_type  @0x24
//   int    handicap       @0x28
//   string init_pos       @0x30   — SFEN of starting position
//   GamePlayerJson sente  @0x38
//   GamePlayerJson gote   @0x40
//   int sente_time_limit  @0x48
//   int gote_time_limit   @0x4C
//   int sente_byoyomi     @0x50
//   int gote_byoyomi      @0x54
// ---------------------------------------------------------------------------
#define OFF_GSJ_NAME             0x10
#define OFF_GSJ_GTYPE            0x18
#define OFF_GSJ_OPPONENT_TYPE    0x24
#define OFF_GSJ_INIT_POS         0x30
#define OFF_GSJ_SENTE            0x38
#define OFF_GSJ_GOTE             0x40
#define OFF_GSJ_SENTE_TIME_LIMIT 0x48
#define OFF_GSJ_GOTE_TIME_LIMIT  0x4C
#define OFF_GSJ_SENTE_BYOYOMI    0x50
#define OFF_GSJ_GOTE_BYOYOMI     0x54

// ---------------------------------------------------------------------------
// Offsets into GamePlayerJson (TypeDefIndex 2245).
//   string avatar      @0x10
//   string name        @0x18
//   int    points      @0x20
//   GameRecordJson game_record @0x28
//       int dan        @0x14 inside GameRecordJson
//   string favsenpou   @0x38
// ---------------------------------------------------------------------------
#define OFF_GPJ_NAME             0x18
#define OFF_GPJ_POINTS           0x20
#define OFF_GPJ_GAME_RECORD      0x28
#define OFF_GRJ_DAN              0x14   // inside GameRecordJson
#define OFF_GPJ_FAVSENPOU        0x38

// ---------------------------------------------------------------------------
// Offsets into FinishedGameInfo (TypeDefIndex 2448).
//   string Result  @0x10
//   string Winner  @0x18
//   string Loser   @0x20
//   string Reason  @0x28
// ---------------------------------------------------------------------------
#define OFF_FGI_RESULT  0x10
#define OFF_FGI_WINNER  0x18
#define OFF_FGI_LOSER   0x20
#define OFF_FGI_REASON  0x28

// ---------------------------------------------------------------------------
// GameController.IsBlack / Color helpers.
// IsBlack RVA: 0x1583AA0  Color RVA: 0x158D82C  (static methods, no self)
// ---------------------------------------------------------------------------
#define RVA_GET_IS_BLACK 0x1583AA0
#define RVA_GET_COLOR    0x158D82C

typedef bool     (*GetIsBlack_t)(void);
typedef int32_t  (*GetColor_t)(void);

static GetIsBlack_t g_GetIsBlack = NULL;
static GetColor_t   g_GetColor   = NULL;

// ---------------------------------------------------------------------------
// GameController instance cache + original function pointers.
// Definitions here; declarations in Internal.h.
// ---------------------------------------------------------------------------
void *volatile g_gameControllerCache = NULL;

OnGameStart_t   orig_OnGameStart   = NULL;
OnMovesNormal_t orig_OnMovesNormal = NULL;
OnFinishGame_t  orig_OnFinishGame  = NULL;
SendMove_t      orig_SendMove      = NULL;
Move_t          orig_Move          = NULL;
MoveWithPly_t   orig_MoveWithPly   = NULL;
ShowResignAlertDialog_t g_ShowResignAlertDialog = NULL;

// Use il2cppStringToNSString from Sources/Chinlan/il2cpp.h.
// That helper returns nil on bad pointers; coerce to @"" for log convenience.
static inline NSString *il2cppStr(void *str) {
    NSString *s = il2cppStringToNSString(str);
    return s ?: @"";
}

// ---------------------------------------------------------------------------
// GameStartJson snapshot stored for Csa_GameInfo.
// ---------------------------------------------------------------------------
static void *g_lastGameStartJson = NULL;

// ---------------------------------------------------------------------------
// Hook: GameController.OnGameStart(GameStartJson gameStartData)
//
// Called when the server sends the GAME_START message. gameStartData holds
// the full match config: player info, time control, starting position.
// We stash self and gameStartJson for later use, then notify the CSA engine.
// ---------------------------------------------------------------------------
void HookOnGameStart(void *self, void *gameStartJson) {
    g_gameControllerCache = self;
    g_lastGameStartJson   = gameStartJson;
    CsaSetGameStart(gameStartJson);

    // GameController.Color returns the local player's colour as the
    // canonical 0=sente / 1=gote enum. GameController.IsBlack flips its
    // meaning depending on the match mode (it's not "local player is
    // sente"), so Color is the reliable source here.
    int32_t color = -1;
    if (g_GetColor) {
        @try { color = g_GetColor(); } @catch (...) {}
    }
    bool isBlack = (color == 0);

    NSString *name  = il2cppStr(readPtr(gameStartJson, OFF_GSJ_NAME));
    NSString *gtype = il2cppStr(readPtr(gameStartJson, OFF_GSJ_GTYPE));
    NSString *sfen  = il2cppStr(readPtr(gameStartJson, OFF_GSJ_INIT_POS));
    int32_t senteTime   = readI32(gameStartJson, OFF_GSJ_SENTE_TIME_LIMIT);
    int32_t goteTime    = readI32(gameStartJson, OFF_GSJ_GOTE_TIME_LIMIT);
    int32_t senteByoyomi = readI32(gameStartJson, OFF_GSJ_SENTE_BYOYOMI);
    int32_t goteByoyomi  = readI32(gameStartJson, OFF_GSJ_GOTE_BYOYOMI);

    IPALog([NSString stringWithFormat:
              @"[GC] OnGameStart self=%p color=%d isBlack=%d name=%@ gtype=%@ "
              @"sente_time=%d gote_time=%d sente_byoyomi=%d gote_byoyomi=%d "
              @"sfen=%@",
              self, (int)color, (int)isBlack, name, gtype,
              (int)senteTime, (int)goteTime,
              (int)senteByoyomi, (int)goteByoyomi,
              sfen]);

    WARS_CALL_ORIG_VOID(orig_OnGameStart, self, gameStartJson);

    // Notify CSA engine after orig so any internal state it sets up is ready.
    dispatch_async(dispatch_get_main_queue(), ^{
        CsaEngineOnMatchStart(isBlack, gameStartJson);
    });
}

// ---------------------------------------------------------------------------
// Hook: GameController.OnMovesNormal(XmlDocument xml)
//
// Called when the server pushes an opponent move (MOVES command, type NORMAL).
// The XmlDocument carries the CSA move string and remaining time. We extract
// these and forward to the CSA engine driver.
//
// The XmlDocument is Mono's System.Xml.XmlDocument — it's easier to let the
// original run first and then call GameController.Move() ourselves, but the
// move info we need for CSA (csa string, time_left) lives in the xml tree.
// We extract it via the il2cpp XmlDocument accessors before calling orig.
//
// XmlDocument structure (Mono, il2cpp-compiled):
//   We walk DocumentElement → first ChildNode looking for <move> elements.
//   Each <move> has attributes:
//     m    — CSA move string (e.g. "+7776FU")
//     t    — time_left as float string
// For now we rely on orig_OnMovesNormal calling GameController.Move internally
// and hook SendMove to observe the move actually committed.
// ---------------------------------------------------------------------------
void HookOnMovesNormal(void *self, void *xmlDocument) {
    if (self) g_gameControllerCache = self;

    IPALog([NSString stringWithFormat:
              @"[GC] OnMovesNormal self=%p xml=%p", self, xmlDocument]);

    // Let the original apply the move to the board. The CSA notification
    // happens downstream when GameController.Move(csa, timeLeft, quiet) is
    // invoked — both server-sourced opponent moves and locally-tapped ones
    // funnel through that central method, so observing here would
    // double-emit.
    WARS_CALL_ORIG_VOID(orig_OnMovesNormal, self, xmlDocument);
}

// ---------------------------------------------------------------------------
// Hook: GameController.Move(string csa, float timeLeft, bool quiet)
//
// The single authoritative "commit a move on the live board" entry point.
// Both inbound (server XML -> OnMovesNormal -> Move) and outbound (local
// tap -> SendMove -> Move) paths funnel through here. We observe CSA text
// + timeLeft directly and forward to the CSA engine driver.
//
// IMPORTANT: inject_apply also calls Move() to inject engine-supplied
// moves. To avoid echoing those back to the connected engine, the inject
// path uses `orig_Move` (the trampoline saved by MSHookFunction) which
// skips this hook body. So everything that lands here is a "real" move
// from ShogiWars itself.
// ---------------------------------------------------------------------------
void HookMove(void *self, void *csaStr, float timeLeft, bool quiet) {
    if (self) g_gameControllerCache = self;

    NSString *csa = il2cppStr(csaStr);
    IPALog([NSString stringWithFormat:
              @"[GC] Move self=%p csa=%@ timeLeft=%.2f quiet=%d",
              self, csa, timeLeft, (int)quiet]);

    // CSA notification is emitted from HookMoveWithPly. This overload calls
    // the (ply, csa, timeLeft, quiet) overload internally, so observing
    // here would double-emit locally-tapped moves. Opponent moves only
    // come through the (ply, ...) overload, so the downstream hook covers
    // both directions with a single emission per move.
    WARS_CALL_ORIG_VOID(orig_Move, self, csaStr, timeLeft, quiet);
}

// ---------------------------------------------------------------------------
// Hook: GameController.Move(int ply, string csa, float timeLeft, bool quiet)
//
// Server-applied opponent moves arrive through this overload via
// ApplyOppMove(XmlDocument) -> Move(ply, csa, timeLeft, quiet). The
// (csa, timeLeft, quiet) overload above only catches locally-initiated
// commits, so without this hook the engine never learns the opponent's
// moves.
// ---------------------------------------------------------------------------
bool HookMoveWithPly(void *self, int32_t ply, void *csaStr,
                     float timeLeft, bool quiet) {
    if (self) g_gameControllerCache = self;

    NSString *csa = il2cppStr(csaStr);
    IPALog([NSString stringWithFormat:
              @"[GC] MovePly self=%p ply=%d csa=%@ timeLeft=%.2f quiet=%d",
              self, (int)ply, csa, timeLeft, (int)quiet]);

    bool result = false;
    if (orig_MoveWithPly) {
        result = orig_MoveWithPly(self, ply, csaStr, timeLeft, quiet);
    }

    if (csa.length > 0) {
        unichar sign = [csa characterAtIndex:0];
        if (sign == '+' || sign == '-') {
            bool isBlackMove = (sign == '+');
            CsaEngineOnMoveObserved(csa, timeLeft, isBlackMove);
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Hook: GameController.OnFinishGame(FinishedGameInfo info)
//
// Called when GAME_FINISHED arrives from the server. FinishedGameInfo carries:
//   Result : "WIN_LOSE" | "DRAW"
//   Winner : player id of winner (empty on draw)
//   Loser  : player id of loser (empty on draw)
//   Reason : "TORYO" | "CHECKMATE" | "TIMEOUT" | "DISCONNECT" |
//            "SENNICHI" | "OUTE_SENNICHI" | "ENTERINGKING" | "PLY_LIMIT" |
//            "MAINTENANCE"
// ---------------------------------------------------------------------------
void HookOnFinishGame(void *self, void *finishedGameInfo) {
    if (self) g_gameControllerCache = self;

    NSString *result = il2cppStr(readPtr(finishedGameInfo, OFF_FGI_RESULT));
    NSString *winner = il2cppStr(readPtr(finishedGameInfo, OFF_FGI_WINNER));
    NSString *loser  = il2cppStr(readPtr(finishedGameInfo, OFF_FGI_LOSER));
    NSString *reason = il2cppStr(readPtr(finishedGameInfo, OFF_FGI_REASON));

    IPALog([NSString stringWithFormat:
              @"[GC] OnFinishGame self=%p result=%@ winner=%@ loser=%@ reason=%@",
              self, result, winner, loser, reason]);

    WARS_CALL_ORIG_VOID(orig_OnFinishGame, self, finishedGameInfo);

    // Infer win/lose/draw from the engine's perspective.
    web_match_result_t webResult = WEB_RESULT_UNKNOWN;

    if ([result isEqualToString:@"DRAW"]) {
        webResult = WEB_RESULT_DRAW;
    } else if ([result isEqualToString:@"WIN_LOSE"]) {
        // GameController.IsBlack returns whether the local player is sente.
        // Winner / Loser fields are user ids — but we can infer from Color.
        int32_t color = -1;
        if (g_GetColor) {
            @try { color = g_GetColor(); } @catch (...) {}
        }
        // color: 0=Black=sente, 1=White=gote (from GameController.Color).
        // winner == "sente" when sente won, "gote" when gote won.
        // Map to win/lose from local player perspective.
        if ([winner length] > 0 && [loser length] > 0) {
            bool localIsSente = (color == 0);
            bool senteWon = [winner isEqualToString:@"sente"];
            webResult = (localIsSente == senteWon) ? WEB_RESULT_WIN : WEB_RESULT_LOSE;
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        CsaEngineOnMatchEnd(webResult, reason);
    });
}

// ---------------------------------------------------------------------------
// Hook: GameController.SendMove(string move, bool isKishin)
//
// Called when the local player submits a move (or when injection feeds one
// back). This is the single observation point for local-side moves — both
// human taps and our CSA injection flow through here.
//
// We read the CSA move string and forward to the CSA engine driver so it can
// emit the "+7776FU,T<n>" notification to the connected engine.
// ---------------------------------------------------------------------------
void HookSendMove(void *self, void *moveStr, bool isKishin) {
    if (self) g_gameControllerCache = self;

    NSString *csa = il2cppStr(moveStr);
    IPALog([NSString stringWithFormat:
              @"[GC] SendMove self=%p csa=%@ isKishin=%d",
              self, csa, (int)isKishin]);

    // CSA notification happens in HookMove() — every SendMove eventually
    // calls GameController.Move(csa, timeLeft, quiet) internally, so
    // observing here would double-emit.
    WARS_CALL_ORIG_VOID(orig_SendMove, self, moveStr, isKishin);
}

// ===========================================================================
// Installer
// ===========================================================================

#if !WARS_CHINLAN

void InstallGameControllerHook(uintptr_t unityBase) {
    // Resolve static helpers.
    g_GetIsBlack = (GetIsBlack_t)(void *)(unityBase + RVA_GET_IS_BLACK);
    g_GetColor   = (GetColor_t)(void *)(unityBase + RVA_GET_COLOR);

    struct {
        const char *tag;
        uintptr_t   rva;
        void       *hook;
        void      **origSlot;
    } entries[] = {
        { "GameController.OnGameStart",
          RVA_ON_GAME_START,   (void *)HookOnGameStart,
          (void **)&orig_OnGameStart },
        { "GameController.OnMovesNormal",
          RVA_ON_MOVES_NORMAL, (void *)HookOnMovesNormal,
          (void **)&orig_OnMovesNormal },
        { "GameController.OnFinishGame",
          RVA_ON_FINISH_GAME,  (void *)HookOnFinishGame,
          (void **)&orig_OnFinishGame },
        { "GameController.SendMove",
          RVA_SEND_MOVE,       (void *)HookSendMove,
          (void **)&orig_SendMove },
        { "GameController.Move(csa,timeLeft,quiet)",
          RVA_MOVE_CSA_TIME,   (void *)HookMove,
          (void **)&orig_Move },
        { "GameController.Move(ply,csa,timeLeft,quiet)",
          RVA_MOVE_PLY_CSA,    (void *)HookMoveWithPly,
          (void **)&orig_MoveWithPly },
    };

    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        uintptr_t addr = unityBase + entries[i].rva;
        MSHookFunction((void *)addr, entries[i].hook, entries[i].origSlot);
        IPALog([NSString stringWithFormat:
                  @"[GC] hooked %s @0x%lx (base+0x%lx)",
                  entries[i].tag,
                  (unsigned long)addr,
                  (unsigned long)entries[i].rva]);
    }

    IPALog(@"[GC] InstallGameControllerHook done");
}

#else   // WARS_CHINLAN

void InstallGameControllerHook(uintptr_t unityBase) {
    g_GetIsBlack = (GetIsBlack_t)(void *)(unityBase + RVA_GET_IS_BLACK);
    g_GetColor   = (GetColor_t)(void *)(unityBase + RVA_GET_COLOR);
    orig_Move    = (Move_t)(void *)(unityBase + RVA_MOVE_CSA_TIME);
    IPALog(@"[GC] chinlan: cave dispatcher active, orig_* slots left NULL");
}

#endif  // !WARS_CHINLAN
