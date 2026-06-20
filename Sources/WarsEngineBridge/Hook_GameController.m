#import "Internal.h"
#import "Settings_Persistence.h"

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
// GameDialogButtonManager.OnRevengeMenu(bool isUseBackFilterEvent) — RVA 0x1598BB8.
// Shows the iOS "play again?" dialog after a match ends. Suppressed
// unconditionally so the dialog never appears.
#define RVA_ON_REVENGE_MENU 0x1598BB8
// Native.ShowAndroidAlertDialog(title, message, cancel, other) — RVA 0x1534934.
// Despite the name, this is the cross-platform dialog wrapper used on iOS too.
// We suppress the "Continue?" dialog that pops up on match end by matching on
// the message string when skip_revenge_dialog is on.
#define RVA_SHOW_ANDROID_ALERT_DIALOG 0x1534934
// DialogManager.ShowSelectDialog(msg, Action) — RVA 0x153CC68 (instance method).
// DialogManager.ShowSelectDialog(title, msg, Action) — RVA 0x153CCD8.
// These present the OK/Cancel two-button dialogs (e.g. "Continue?" after
// match end). Hooked observation-only for now to identify each call site.
#define RVA_SHOW_SELECT_DIALOG_2 0x153CC68
#define RVA_SHOW_SELECT_DIALOG_3 0x153CCD8
// ShowResignAlertDialog (static, void) — RVA 0x154B72C. Entry point that
// triggers the "Resign confirmation" dialog. Hooked so we can set a flag
// for Hook_AlertObserve to auto-confirm when skip_resign_dialog is on.
#define RVA_SHOW_RESIGN_ALERT_DIALOG 0x154B72C
// Wars.Dialog.Confirm(title, message, Action ok, Action cancel) — RVA 0x1624A38.
// The real entry point for confirmation dialogs (the resign dialog goes
// through here, despite ShowResignAlertDialog also existing). Hooked so we
// can mark the next UIAlertController presentation as a confirm dialog and
// auto-invoke the OK callback when skip_resign_dialog is on.
#define RVA_DIALOG_CONFIRM_4 0x1624A38
// GameDialogButtonManager.OnToryo() — RVA 0x1599818. The click handler that
// the in-game toryo button calls. Triggers the resign confirmation flow with
// the OK callback wired up to actually resign. Used as the entry point for
// CSA-driven %TORYO so the dialog is identical to the manual path.
#define RVA_ON_TORYO 0x1599818

// Flag bridged across translation units. Defined in Hook_AlertObserve.m.
extern _Atomic bool g_webNextAlertIsResign;

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
// GameDialogButtonManager instance — captured from any of our hooks on its
// instance methods (OnRevengeMenu / Wars.Dialog.Confirm invocations from it
// etc.). Used by Inject_Resign to call OnToryo() directly instead of going
// through ShowResignAlertDialog whose OK callback is a no-op on the CSA path.
void *volatile g_gameDialogButtonManagerCache = NULL;
typedef void (*OnToryo_t)(void *self);
OnToryo_t g_OnToryo = NULL;
ToryoFinish_t g_ToryoFinish = NULL;
#define RVA_TORYO_FINISH 0x1591734

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
// Live-position chain.
//   GameController.get_GameData()   RVA 0x158D510  (static)
//   GameData.get_Position()         RVA 0x1596B94  (instance -> Position*)
//   Position.ToString()             RVA 0x1600194  (instance -> System.String*)
// ---------------------------------------------------------------------------
#define RVA_GC_GET_GAMEDATA       0x158D510
#define RVA_GAMEDATA_GET_POSITION 0x1596B94
#define RVA_POSITION_TO_STRING    0x1600194

typedef void *(*GC_GetGameData_t)(void);
typedef void *(*GameData_GetPosition_t)(void *gameData);
typedef void *(*Position_ToString_t)(void *position);

static GC_GetGameData_t        g_GC_GetGameData        = NULL;
static GameData_GetPosition_t  g_GameData_GetPosition  = NULL;
static Position_ToString_t     g_Position_ToString     = NULL;

// Convert a single board row from Position.ToString() format to CSA format.
// ToString uses '*' (1 char) for empty, '+XX'/'-XX' (3 chars) for pieces.
// CSA uses ' * ' (3 chars) for empty, '+XX'/'-XX' (3 chars) for pieces.
static NSString *csaRowFromToStringRow(NSString *row) {
    NSMutableString *out = [NSMutableString stringWithCapacity:27];
    NSUInteger i = 0, len = row.length;
    while (i < len) {
        unichar c = [row characterAtIndex:i];
        if (c == '*') {
            [out appendString:@" * "];
            i++;
        } else if ((c == '+' || c == '-') && i + 2 < len) {
            [out appendString:[row substringWithRange:NSMakeRange(i, 3)]];
            i += 3;
        } else {
            i++;
        }
    }
    return out;
}

// Read the live board from GameController.GameData.Position.ToString() and
// return a CSA position block string (the lines between BEGIN/END Position).
// Returns nil on any failure.
NSString *WarsLiveSfen(void) {
    if (!g_GC_GetGameData || !g_GameData_GetPosition || !g_Position_ToString) {
        IPALog([NSString stringWithFormat:
                  @"[GC] WarsLiveSfen: chain not ready "
                  @"(GetGameData=%p GetPosition=%p ToString=%p)",
                  g_GC_GetGameData, g_GameData_GetPosition, g_Position_ToString]);
        return nil;
    }
    NSString *result = nil;
    @try {
        void *gd = g_GC_GetGameData();
        if (!gd) {
            IPALog(@"[GC] WarsLiveSfen: GetGameData() returned nil");
            return nil;
        }
        void *pos = g_GameData_GetPosition(gd);
        if (!pos) {
            IPALog([NSString stringWithFormat:
                      @"[GC] WarsLiveSfen: GetPosition(gd=%p) returned nil", gd]);
            return nil;
        }
        void *strObj = g_Position_ToString(pos);
        NSString *raw = il2cppStr(strObj);
        IPALog([NSString stringWithFormat:
                  @"[GC] WarsLiveSfen: raw ToString=\"%@\"", raw]);

        // Position.ToString() format (from ShogiWars dump.cs):
        //   "[Board: board=\n<row1>\n...<row9>\n] <side> <hands> <ply> ..."
        // where each row uses '*' for empty squares and '+XX'/'-XX' for pieces.
        //
        // We parse this into a CSA position block directly, since it's already
        // close to CSA format — just needs P1..P9 row labels and ' * ' for empty.

        // Split by newline.
        NSArray<NSString *> *lines = [raw componentsSeparatedByString:@"\n"];
        if (lines.count < 11) {
            IPALog([NSString stringWithFormat:
                      @"[GC] WarsLiveSfen: too few lines (%lu) in raw",
                      (unsigned long)lines.count]);
            return nil;
        }

        // Line 0: "[Board: board=" — skip.
        // Lines 1..9: board rows.
        // Line 10: "] <side> <hands> <ply> ..."
        NSMutableString *csaPos = [NSMutableString string];
        for (int row = 1; row <= 9; row++) {
            NSString *csaRow = csaRowFromToStringRow(lines[row]);
            [csaPos appendFormat:@"P%d%@\n", row, csaRow];
        }

        // Parse tail line: "] <side> <initSfen> <stands> <ply> [hash]"
        // Position.ToString() format confirmed from live log:
        //   "] b lnsgkgsnl/... - 1 <hash>"
        //   tailParts[0] = side ("b"/"w")
        //   tailParts[1] = InitSfen (skip)
        //   tailParts[2] = Stands ("-" when no pieces in hand)
        //   tailParts[3] = Ply
        NSString *tail = lines[10];
        if ([tail hasPrefix:@"] "]) tail = [tail substringFromIndex:2];
        NSArray<NSString *> *tailParts = [tail componentsSeparatedByString:@" "];
        IPALog([NSString stringWithFormat:@"[GC] WarsLiveSfen: tail parts=%lu \"%@\"",
                (unsigned long)tailParts.count, tail]);

        // side: "b" -> "+", "w" -> "-"
        NSString *side = @"+";
        if (tailParts.count >= 1) {
            side = [tailParts[0] isEqualToString:@"w"] ? @"-" : @"+";
        }

        // Stands (pieces in hand) is NOT in the tail — call get_Stands() directly.
        // pos is valid here since g_Position_ToString(pos) just succeeded above.
        typedef void *(*Position_GetStands_t)(void *position);
        static Position_GetStands_t s_GetStands = NULL;
        if (!s_GetStands && g_GC_GetGameData) {
            extern uintptr_t g_unityBase;
            s_GetStands = (Position_GetStands_t)(void *)(g_unityBase + 0x15FFF04);
        }
        NSString *standsStr = @"-";
        if (s_GetStands) {
            void *standsObj = s_GetStands(pos);
            NSString *s = il2cppStr(standsObj);
            if (s.length > 0) standsStr = s;
        }
        IPALog([NSString stringWithFormat:@"[GC] WarsLiveSfen: stands=\"%@\"", standsStr]);
        if ([standsStr isEqualToString:@"-"]) {
            [csaPos appendString:@"P+\nP-\n"];
        } else {
            [csaPos appendFormat:@"P+%@\nP-\n", standsStr];
        }

        [csaPos appendString:side];

        IPALog([NSString stringWithFormat:@"[GC] WarsLiveSfen: csaPos=\n%@", csaPos]);
        result = csaPos;

    } @catch (NSException *e) {
        IPALog([NSString stringWithFormat:@"[GC] WarsLiveSfen threw: %@", e]);
    }
    return result;
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

// ---------------------------------------------------------------------------
// Hook: GameDialogButtonManager.OnRevengeMenu(bool isUseBackFilterEvent)
//
// The "play again?" dialog after a match ends. Suppressed unconditionally —
// we never want this dialog to appear. Skip orig so nothing happens.
// ---------------------------------------------------------------------------
typedef void (*OnRevengeMenu_t)(void *self, bool isUseBackFilterEvent);
static OnRevengeMenu_t orig_OnRevengeMenu = NULL;

void HookOnRevengeMenu(void *self, bool isUseBackFilterEvent) {
    if (self) g_gameDialogButtonManagerCache = self;
    bool skip = WEBSkipRevengeDialog();
    IPALog([NSString stringWithFormat:
              @"[GC] OnRevengeMenu self=%p isUseBackFilterEvent=%d skip=%d",
              self, (int)isUseBackFilterEvent, (int)skip]);
    if (skip) return;
    WARS_CALL_ORIG_VOID(orig_OnRevengeMenu, self, isUseBackFilterEvent);
}

// ---------------------------------------------------------------------------
// Hook: Native.ShowAndroidAlertDialog(title, message, cancelButton, otherButton)
//
// The "Continue?" dialog after match end goes through this static method
// (the name is misleading — it's used on iOS too). Suppressed when
// skip_revenge_dialog is on. Always logs the message so we can identify
// other dialog use sites later.
// ---------------------------------------------------------------------------
typedef void (*ShowAndroidAlertDialog_t)(void *title, void *message,
                                          void *cancelButton, void *otherButton);
static ShowAndroidAlertDialog_t orig_ShowAndroidAlertDialog = NULL;

void HookShowAndroidAlertDialog(void *titleStr, void *messageStr,
                                 void *cancelStr, void *otherStr) {
    NSString *title  = il2cppStr(titleStr);
    NSString *msg    = il2cppStr(messageStr);
    NSString *cancel = il2cppStr(cancelStr);
    NSString *other  = il2cppStr(otherStr);
    IPALog([NSString stringWithFormat:
              @"[GC] ShowAlertDialog title=\"%@\" msg=\"%@\" cancel=\"%@\" other=\"%@\"",
              title, msg, cancel, other]);
    // Observation only — always forward to orig so the dialog behaviour is
    // unchanged. Once we have enough samples in the logs to identify which
    // call sites correspond to which dialogs, we can decide what to suppress.
    WARS_CALL_ORIG_VOID(orig_ShowAndroidAlertDialog, titleStr, messageStr, cancelStr, otherStr);
}

// ---------------------------------------------------------------------------
// Hook: DialogManager.ShowSelectDialog overloads
// These produce the OK/Cancel two-button dialogs (the "Continue?" prompt
// after match end likely comes through here). Observation only.
// ---------------------------------------------------------------------------
typedef int32_t (*ShowSelectDialog2_t)(void *self, void *msg, void *del);
typedef int32_t (*ShowSelectDialog3_t)(void *self, void *title, void *msg, void *del);
static ShowSelectDialog2_t orig_ShowSelectDialog2 = NULL;
static ShowSelectDialog3_t orig_ShowSelectDialog3 = NULL;

int32_t HookShowSelectDialog2(void *self, void *msgStr, void *del) {
    NSString *msg = il2cppStr(msgStr);
    IPALog([NSString stringWithFormat:
              @"[GC] ShowSelectDialog(msg) self=%p msg=\"%@\" del=%p",
              self, msg, del]);
    if (orig_ShowSelectDialog2) return orig_ShowSelectDialog2(self, msgStr, del);
    return 0;
}

int32_t HookShowSelectDialog3(void *self, void *titleStr, void *msgStr, void *del) {
    NSString *title = il2cppStr(titleStr);
    NSString *msg   = il2cppStr(msgStr);
    IPALog([NSString stringWithFormat:
              @"[GC] ShowSelectDialog(title,msg) self=%p title=\"%@\" msg=\"%@\" del=%p",
              self, title, msg, del]);
    if (orig_ShowSelectDialog3) return orig_ShowSelectDialog3(self, titleStr, msgStr, del);
    return 0;
}

// ---------------------------------------------------------------------------
// Hook: ShowResignAlertDialog() — static, no args.
// Sets g_webNextAlertIsResign so the swizzle in Hook_AlertObserve.m can
// auto-confirm the dialog when skip_resign_dialog is on. Always forwards.
// ---------------------------------------------------------------------------
typedef void (*ShowResignAlertDialogOrig_t)(void);
static ShowResignAlertDialogOrig_t orig_ShowResignAlertDialog_hook = NULL;

void HookShowResignAlertDialog(void) {
    IPALog(@"[GC] ShowResignAlertDialog called");
    atomic_store(&g_webNextAlertIsResign, true);
    if (orig_ShowResignAlertDialog_hook) orig_ShowResignAlertDialog_hook();
}

// ---------------------------------------------------------------------------
// Hook: GameDialogButtonManager.OnToryo() — captures self so InjectResign
// can later call OnToryo directly when CSA TORYO arrives.
// ---------------------------------------------------------------------------
typedef void (*OnToryoOrig_t)(void *self);
static OnToryoOrig_t orig_OnToryo = NULL;

void HookOnToryo(void *self) {
    if (self) g_gameDialogButtonManagerCache = self;
    IPALog([NSString stringWithFormat:
              @"[GC] OnToryo self=%p (cached)", self]);
    WARS_CALL_ORIG_VOID(orig_OnToryo, self);
}

// ---------------------------------------------------------------------------
// Hook: Wars.Dialog.Confirm(title, msg, Action ok, Action cancel)
// Logs every confirmation dialog and sets the resign flag so the swizzle
// can auto-confirm.
// ---------------------------------------------------------------------------
typedef void (*DialogConfirm4_t)(void *titleStr, void *messageStr,
                                  void *okAction, void *cancelAction);
static DialogConfirm4_t orig_DialogConfirm4 = NULL;

void HookDialogConfirm4(void *titleStr, void *messageStr,
                         void *okAction, void *cancelAction) {
    NSString *title = il2cppStr(titleStr);
    NSString *msg   = il2cppStr(messageStr);
    IPALog([NSString stringWithFormat:
              @"[GC] Wars.Dialog.Confirm title=\"%@\" msg=\"%@\" ok=%p cancel=%p",
              title, msg, okAction, cancelAction]);
    // Mark so the UIAlertController swizzle auto-confirms the next dialog.
    // This catches BOTH the resign confirmation and any other Confirm() call,
    // so the swizzle's skip_resign_dialog gate decides whether to act.
    atomic_store(&g_webNextAlertIsResign, true);
    if (orig_DialogConfirm4) orig_DialogConfirm4(titleStr, messageStr,
                                                  okAction, cancelAction);
}

// ===========================================================================
// Installer
// ===========================================================================

#if !WARS_CHINLAN

void InstallGameControllerHook(uintptr_t unityBase) {
    // Resolve static helpers.
    g_GetIsBlack = (GetIsBlack_t)(void *)(unityBase + RVA_GET_IS_BLACK);
    g_GetColor   = (GetColor_t)(void *)(unityBase + RVA_GET_COLOR);

    g_GC_GetGameData       = (GC_GetGameData_t)(void *)(unityBase + RVA_GC_GET_GAMEDATA);
    g_GameData_GetPosition = (GameData_GetPosition_t)(void *)(unityBase + RVA_GAMEDATA_GET_POSITION);
    g_Position_ToString    = (Position_ToString_t)(void *)(unityBase + RVA_POSITION_TO_STRING);
    g_OnToryo              = (OnToryo_t)(void *)(unityBase + RVA_ON_TORYO);
    g_ToryoFinish          = (ToryoFinish_t)(void *)(unityBase + RVA_TORYO_FINISH);
    IPALog([NSString stringWithFormat:
              @"[GC] live-pos: GetGameData=%p GetPosition=%p ToString=%p "
              @"OnToryo=%p ToryoFinish=%p",
              g_GC_GetGameData, g_GameData_GetPosition, g_Position_ToString,
              g_OnToryo, g_ToryoFinish]);

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
        { "GameDialogButtonManager.OnRevengeMenu",
          RVA_ON_REVENGE_MENU, (void *)HookOnRevengeMenu,
          (void **)&orig_OnRevengeMenu },
        { "Native.ShowAndroidAlertDialog",
          RVA_SHOW_ANDROID_ALERT_DIALOG, (void *)HookShowAndroidAlertDialog,
          (void **)&orig_ShowAndroidAlertDialog },
        { "DialogManager.ShowSelectDialog(msg,del)",
          RVA_SHOW_SELECT_DIALOG_2, (void *)HookShowSelectDialog2,
          (void **)&orig_ShowSelectDialog2 },
        { "DialogManager.ShowSelectDialog(title,msg,del)",
          RVA_SHOW_SELECT_DIALOG_3, (void *)HookShowSelectDialog3,
          (void **)&orig_ShowSelectDialog3 },
        { "ShowResignAlertDialog",
          RVA_SHOW_RESIGN_ALERT_DIALOG, (void *)HookShowResignAlertDialog,
          (void **)&orig_ShowResignAlertDialog_hook },
        { "Wars.Dialog.Confirm(title,msg,ok,cancel)",
          RVA_DIALOG_CONFIRM_4, (void *)HookDialogConfirm4,
          (void **)&orig_DialogConfirm4 },
        { "GameDialogButtonManager.OnToryo",
          RVA_ON_TORYO, (void *)HookOnToryo,
          (void **)&orig_OnToryo },
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
