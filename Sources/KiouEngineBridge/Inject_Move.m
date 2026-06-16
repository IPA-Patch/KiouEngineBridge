#import "Internal.h"

#import <ctype.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <string.h>
#import <unistd.h>

// ===========================================================================
// Inject_Move — host-driven move injection.
//
// The WebSocket server hands us inbound text frames carrying USI "bestmove
// <usi>" lines (or just "<usi>") from whatever bridge the host is running.
// We parse the USI token, build a Sunfish.Move uint32, decide which il2cpp
// entry point to invoke (CPU = Adapter, Online = GameController-only by
// default, opt-in = OnlinePvPMode.OnPlayerMoveAsync), and replay it on the
// Unity main thread.
//
// Hard constraints:
//   - No raw memory writes. Every mutation goes through an il2cpp method,
//     never through writeU8/writeI32. The shared header doesn't even
//     expose those, and we don't import a private one.
//   - No re-entry of the observation hooks. We hold the original (un-
//     trampolined) function pointers that Hook_LowLevelObserve captured
//     and call those directly, so the WS bridge doesn't get a double-
//     notification for moves it asked us to play.
//   - Online ratings protection. Server-side forwarding is gated behind
//     BOTH `KIOU_ENGINE_BRIDGE_PLAYER_MOVE=1` in the process env AND a
//     flag file at /var/mobile/Documents/kiou_engine_bridge_player_move.flag.
//     Both
//     are required, both are read once at install time. Default is local
//     preview only.
// ===========================================================================

// ---------------------------------------------------------------------------
// RVAs (KIOU 1.0.1 build 11). The TryMakeMove RVAs are owned by
// Hook_LowLevelObserve.m via MSHookFunction; the OnPlayerMoveAsync RVAs are
// owned by Hook_MatchModeObserve.m. The rest are NativeFunction-style
// helpers we call into to build moves the game-side code actually accepts.
// ---------------------------------------------------------------------------
#define RVA_SUNFISH_MOVE_DROP              0x5D86AD8  // Sunfish.Move.Drop(PieceType, Square) — legacy
#define RVA_POSITION_GET_PIECE             0x5D3A1C8  // Position.GetPiece(Square) -> Piece
#define RVA_PIECE_GET_PIECETYPE            0x5D3A1FC  // PieceExtensions.GetPieceType(Piece) -> PieceType
#define RVA_PSC_MOVE_CREATE                0x5D4536C  // Move.Create(from,to,movingPiece,promote,captured)
#define RVA_PSC_MOVE_CREATE_DROP           0x5D4538C  // Move.CreateDrop(PieceType, Square)
#define RVA_POSITION_CREATE_FROM_SFEN      0x5D42650  // Position.CreateFromSFEN(string sfen)
#define RVA_POSITION_CREATE_BY_TYPE        0x5D423F8  // Position.CreateByInitialPositionType(InitialPositionType)
#define RVA_GAMESTATESTORE_NOTIFY_PIECE_MOVED  0x5A2CD24  // GameStateStore.NotifyPieceMoved(Move, PlayerSide)
#define RVA_GAMESTATESTORE_NOTIFY_STATE_SYNCED 0x5A2CE64  // GameStateStore.NotifyStateSynced(Position)
#define RVA_BOARDPRESENTER_PLAY_MOVE_ANIMATION 0x5968894  // BoardPresenter.PlayMoveAnimationAsync(Move, CT) -> UniTask

// GameOrchestrator -> BoardPresenter field offset (dump.cs:1211404).
#define OFF_GAMEORCH_BOARD_PRESENTER 0x108

// How long to wait between firing the move animation and committing the
// underlying TryMakeMove. The animation itself runs on the order of
// ~0.3s in KIOU; we add ~0.1s headroom so even a slightly long animation
// completes before the board snaps to the post-move state. Tunable —
// raise it if the animation visibly clips, lower it if responsiveness
// suffers across rapid back-to-back injections.
#define INJECT_ANIMATION_DELAY_SEC 0.40

// _stateStore field offsets per IMatchMode concrete implementor. Verified
// against dump.cs:1419817 (AI), 1420396 (CPUStream), 1421565 (Online),
// 1420717 (Local), 1422103 (Replay). LocalPvP / RecordReplay don't pin a
// seat so their per-move "who just moved" is ambiguous — we skip the
// NotifyPieceMoved call there rather than guess.
#define OFF_AI_STATESTORE         0x40
#define OFF_CPUSTREAM_STATESTORE  0x48
#define OFF_ONLINE_STATESTORE     0x28
#define OFF_LOCAL_STATESTORE      0x10
#define OFF_REPLAY_STATESTORE     0x10

// ---------------------------------------------------------------------------
// Instance cache definitions — declarations live in Internal.h. Each is a
// volatile pointer because writers are on Unity threads and we read on the
// recv queue / main queue. Pointer reads/writes on arm64 are atomic so we
// don't need a lock; volatile just keeps the compiler from caching across
// reads.
// ---------------------------------------------------------------------------
void *volatile g_gameCtrlCache   = NULL;
void *volatile g_adapterCache    = NULL;
void *volatile g_onlineModeCache = NULL;  // shared with Hook_OnlineObserve.m
void *volatile g_authoritativeSfenString = NULL;  // shared with snapshot hooks
uint64_t volatile g_lastOnlineEvtUs  = 0;
uint64_t volatile g_lastAdapterEvtUs = 0;

// ---------------------------------------------------------------------------
// Function pointers we resolve at install time.
// ---------------------------------------------------------------------------

// Sunfish.Move.Drop(PieceType, Square) — kept resolved as a legacy fallback.
// We no longer use it for CPUStreamMode / OnlinePvPMode because those modes
// expect a Project.ShogiCore.Move (different bit layout, with the moving
// piece encoded in the upper half of _value). Live observation of the game's
// own moves consistently shows the upper 16 bits non-zero, which Sunfish-
// shaped moves don't produce.
typedef uint32_t (*SunfishMoveDrop_t)(uint32_t pieceTypeRaw, uint32_t squareRaw);
static SunfishMoveDrop_t g_SunfishMoveDrop = NULL;

// Project.ShogiCore native helpers. All four are static or instance methods
// that operate on enum-backed structs (Square / PieceType / Piece are
// enum-of-int), so the il2cpp ABI passes them as 32-bit integer args in
// the natural argument registers. Move is a 1-field struct wrapping uint,
// returned in w0 — we model it as uint32_t and let the call site treat the
// result as opaque.
typedef int32_t  (*Position_GetPiece_t)(void *position, int32_t square);
typedef int32_t  (*Piece_GetPieceType_t)(int32_t piece);
typedef uint32_t (*PSCMove_Create_t)(int32_t from, int32_t to,
                                    int32_t movingPiece, bool promote,
                                    int32_t capturedPiece);
typedef uint32_t (*PSCMove_CreateDrop_t)(int32_t pieceType, int32_t square);
typedef void *(*Position_CreateFromSFEN_t)(void *sfenString);
typedef void *(*Position_CreateByType_t)(int32_t initialType);

static Position_GetPiece_t       g_Position_GetPiece       = NULL;
static Piece_GetPieceType_t      g_Piece_GetPieceType      = NULL;
static PSCMove_Create_t          g_PSCMove_Create          = NULL;
static PSCMove_CreateDrop_t      g_PSCMove_CreateDrop      = NULL;
static Position_CreateFromSFEN_t g_Position_CreateFromSFEN = NULL;
static Position_CreateByType_t   g_Position_CreateByType   = NULL;

// GameStateStore.NotifyPieceMoved(Move, PlayerSide) — drives the
// _lastMove ReactiveProperty + the "piece animation" subjects. By itself
// this didn't flip the _currentMovePlayer / _currentTurn UI on the device
// (live verification, AIMatchMode CPU run), so we pair it with
// NotifyStateSynced below.
typedef void (*GameStateStore_NotifyPieceMoved_t)(void *self, uint32_t move,
                                                  int32_t playerSide);
static GameStateStore_NotifyPieceMoved_t g_GameStateStore_NotifyPieceMoved = NULL;

// GameStateStore.NotifyStateSynced(Position) — the "the engine has caught
// up to here" notification that the in-app UI subscribes to via the
// _onStateSynced Subject. MoveCountPresenter listens on this; presumably
// the turn-text presenter does too. Without firing this the side-to-move
// UI stays on "your turn" after we inject, even though the board itself
// (BoardPresenter, which listens on a different subject) updates fine.
typedef void (*GameStateStore_NotifyStateSynced_t)(void *self, void *position);
static GameStateStore_NotifyStateSynced_t g_GameStateStore_NotifyStateSynced = NULL;

// BoardPresenter.PlayMoveAnimationAsync(Move, CancellationToken) -> UniTask.
// We fire this BEFORE TryMakeMove so the animation runs against the
// pre-move board state, then sleep INJECT_ANIMATION_DELAY_SEC and commit
// the underlying move. We don't await the UniTask — its internal layout is
// load-bearing and unverified; a fixed delay is good enough.
typedef UniTaskRet (*BoardPresenter_PlayMoveAnimationAsync_t)(void *self,
                                                              uint32_t move,
                                                              void *ct);
static BoardPresenter_PlayMoveAnimationAsync_t g_BoardPresenter_PlayMoveAnimationAsync = NULL;

// Forward declaration — defined further down where the il2cpp accessors
// live; the move builder uses it to read the from-square's piece.
static void *inject_latestPositionFromCachedGameCtrl(void);

// OnPlayerMoveAsync originals come from Hook_MatchModeObserve.m via the
// extern table declared in Internal.h. We just dispatch on which mode cache
// is fresh at injection time.

// ---------------------------------------------------------------------------
// Online-server gate state. Online's OnPlayerMoveAsync forwards the move to
// the rating-affecting backend over gRPC. We now opt in unconditionally so
// FriendMatch / RankMatch auto-play through the WASM engine works the same
// way CPU games do — the previous env/flag-file gate is wired off.
//
// What this enables:
//   - UsiEngineOnMatchStart fires with the OnlinePvPMode's _localPlayer,
//     so the engine knows which seat to think for.
//   - Injection's route picker treats online_opm as eligible just like the
//     CPU-side routes, so a bestmove from the WASM engine lands through
//     OPM → server, not just the headless adapter.
//
// User explicitly approved this — see KiouEngineBridge/CLAUDE-style note in the
// repo if you're auditing. The previous default (off) protected ratings;
// flipping it now means the tweak will play ranked games.
// ---------------------------------------------------------------------------
static bool g_onlineServerSendAllowed = true;

// ---------------------------------------------------------------------------
// mach_absolute_time -> microseconds. Cached timebase.
// ---------------------------------------------------------------------------
static uint64_t inject_machTicksToUs(uint64_t ticks) {
    static mach_timebase_info_data_t s_tb = {0, 0};
    if (s_tb.denom == 0) mach_timebase_info(&s_tb);
    if (s_tb.denom == 0) return 0;
    // ticks * numer / denom -> ns, then / 1000 -> us. Guard against the
    // multiply overflowing by doing the divide first when numer == denom
    // (the common case on arm64 where 1 tick == 1 ns).
    if (s_tb.numer == s_tb.denom) return ticks / 1000;
    return (ticks * s_tb.numer) / s_tb.denom / 1000;
}

// ---------------------------------------------------------------------------
// USI parsing.
//
// Acceptable shapes:
//   "bestmove 7g7f"
//   "bestmove 7g7f ponder 8c8d"   -- ponder tail discarded
//   "bestmove resign"             -- skipped
//   "bestmove win"                -- skipped
//   "bestmove (none)"             -- skipped
//   "7g7f"                        -- bare move also accepted
//
// On success: returns true, *outUsi gets the trimmed USI token
// (null-terminated, up to KIOU_INJECT_USI_MAX-1 chars).
// On skip (resign/win/none): returns false, *outSkipReason gets a short tag.
// On parse failure: returns false, *outSkipReason = "parse".
// ---------------------------------------------------------------------------
static bool inject_extractUsiToken(const char *line, size_t lineLen,
                                   char outUsi[KIOU_INJECT_USI_MAX],
                                   const char **outSkipReason) {
    // Trim leading whitespace / control chars.
    size_t i = 0;
    while (i < lineLen && (line[i] == ' ' || line[i] == '\t' ||
                           line[i] == '\r' || line[i] == '\n')) i++;
    if (i >= lineLen) { *outSkipReason = "empty"; return false; }

    // Optional "bestmove " prefix.
    const char *bm = "bestmove";
    size_t bmLen = strlen(bm);
    if (lineLen - i >= bmLen && strncmp(line + i, bm, bmLen) == 0 &&
        (lineLen - i == bmLen || line[i + bmLen] == ' ' ||
         line[i + bmLen] == '\t')) {
        i += bmLen;
        while (i < lineLen && (line[i] == ' ' || line[i] == '\t')) i++;
    }

    // First token up to next whitespace.
    size_t tokStart = i;
    while (i < lineLen && line[i] != ' ' && line[i] != '\t' &&
           line[i] != '\r' && line[i] != '\n') i++;
    size_t tokLen = i - tokStart;
    if (tokLen == 0) { *outSkipReason = "empty"; return false; }
    if (tokLen >= KIOU_INJECT_USI_MAX) {
        *outSkipReason = "toolong";
        return false;
    }

    // Skip non-move tokens.
    if (tokLen == 6 && strncmp(line + tokStart, "resign", 6) == 0) {
        *outSkipReason = "resign";
        return false;
    }
    if (tokLen == 3 && strncmp(line + tokStart, "win", 3) == 0) {
        *outSkipReason = "win";
        return false;
    }
    if (tokLen == 6 && strncmp(line + tokStart, "(none)", 6) == 0) {
        *outSkipReason = "none";
        return false;
    }

    memcpy(outUsi, line + tokStart, tokLen);
    outUsi[tokLen] = '\0';
    return true;
}

// ---------------------------------------------------------------------------
// USI token -> Sunfish.Move (uint32).
//
// Sunfish.Move bit layout (from dump.cs constants):
//   bit[6:0]   to    = Square._number = file*9 + rank
//   bit[13:7]  from  = same encoding
//   bit[14]    promote flag
//   bit[15]    drop flag (when 1, upper-16 carries piece kind — we let
//              Sunfish.Move.Drop construct that one for us)
//
// USI file char '1'..'9' -> Sunfish file index 8..0 (Sunfish file 0 = 9筋).
// USI rank char 'a'..'i' -> Sunfish rank index 0..8.
// ---------------------------------------------------------------------------

// Returns the 0-indexed file or -1 on failure.
//
// History: the earlier `'9' - c` mapping looked right when matched against
// the observation hook's emitted USI strings ("3g3f" had raw=0x11e3b with
// from=60, which decomposes as file_idx=6 + rank_idx=6 under that
// formula). But the observation hook gets its USI through
// `Sunfish.Move.ToStringSFEN`, which uses the Sunfish-engine internal
// convention where file 9 is the high index — i.e. it CALLS that file "9"
// when the underlying square is what dump.cs enums name SQ1?. As a
// result, the "3g" we see in ADAPTER2 logs is really the SQ73 square the
// rest of the game considers file 7, just printed backwards.
//
// The Project.ShogiCore.Square enum (SQ11=0, SQ12=1, ..., SQ19=8,
// SQ21=9, ..., SQ91=72) numbers files 1..9 from low to high index, which
// matches the USI standard. Live tests with USI "8g8f" produced a board
// change on file 2 (not file 8), confirming the bit field this game's
// Move.Create cares about is the SQ<file><rank> ordering, not Sunfish's.
//
// So: USI file '1' -> 0, '2' -> 1, ..., '9' -> 8.
static int inject_fileFromUsi(char c) {
    if (c < '1' || c > '9') return -1;
    return c - '1';  // '1' -> 0, '7' -> 6, '9' -> 8
}

static int inject_rankFromUsi(char c) {
    if (c < 'a' || c > 'i') return -1;
    return c - 'a';
}

static int inject_pieceRawFromUsi(char c) {
    switch (c) {
        case 'P': return 0;  // Pawn
        case 'L': return 1;  // Lance
        case 'N': return 2;  // Knight
        case 'S': return 3;  // Silver
        case 'G': return 4;  // Gold
        case 'B': return 5;  // Bishop
        case 'R': return 6;  // Rook
        default:  return -1;
    }
}

// Map the inbound USI piece letter (P/L/N/S/G/B/R) to the
// Project.ShogiCore.PieceType enum value, which is what Move.CreateDrop
// expects. (Note: Sunfish has its own zero-indexed table — we keep
// inject_pieceRawFromUsi for the Sunfish fallback path but this mapping
// is the canonical one for the game.)
static int inject_pscPieceTypeFromUsiPiece(char c) {
    switch (c) {
        case 'P': return 1;  // Pawn
        case 'L': return 2;  // Lance
        case 'N': return 3;  // Knight
        case 'S': return 4;  // Silver
        case 'B': return 5;  // Bishop
        case 'R': return 6;  // Rook
        case 'G': return 7;  // Gold
        default:  return -1;
    }
}

// PSC Square = file * 9 + (rank-1). Note that PSC uses a "1-indexed by
// file, 0-indexed by rank inside that block" encoding via enum constants
// (SQ11=0, SQ12=1, ..., SQ19=8, SQ21=9, ...), which works out to the
// same arithmetic as Sunfish: (9-usi_file) * 9 + (usi_rank-'a').
//
// Pull the authoritative-SFEN il2cpp string pointer. We prefer the cached
// pointer captured by the UpdateAuthoritativeSnapshot hooks (which see
// every server update) and fall back to reading the mode's own
// `_authoritativeSfen` field as a backstop in case the snapshot hook
// hasn't fired yet on this match. Returns the raw il2cpp string pointer
// (NOT a copy) so it can be handed straight back into a Position factory
// method that expects an il2cpp string.
static void *inject_authoritativeSfenString(void) {
    void *cached = g_authoritativeSfenString;
    if (cached) return cached;
    if (g_cpuStreamModeCache) {
        void *strPtr = readPtr((void *)g_cpuStreamModeCache, 0xD0);
        if (strPtr) return strPtr;
    }
    if (g_onlineModeCache) {
        void *strPtr = readPtr((void *)g_onlineModeCache, 0x90);
        if (strPtr) return strPtr;
    }
    return NULL;
}

// Resolve a Position to query for piece info. Tries hardest-to-stalest:
//   1. The latest entry in GameController._positionHistory (= what the
//      local engine has replayed so far). This is what
//      [INJECT]'s post-move SFEN logging already uses.
//   2. The server-authoritative SFEN parsed via
//      Project.ShogiCore.Position.CreateFromSFEN — used on first move /
//      resume when the local engine hasn't caught up yet.
// Returns a Position* or NULL.
//
// `outFromSfen` is set to true when the result came from CreateFromSFEN;
// callers can use that signal to surface "we read piece info from the
// server snapshot" in the injection log without re-deriving it.
static void *inject_resolvePosition(bool *outFromSfen) {
    if (outFromSfen) *outFromSfen = false;

    // Path 1: local engine's position history. This is the freshest source
    // once the engine has caught up — including the resume case, where the
    // adapter has already been wired up with the mid-game state by the
    // time we get here. The earlier "empty 7g" case turned out to be a
    // resume from a game where 7g7f was already played, not a stale cache,
    // so the GameCtrl pick was actually correct.
    void *pos = inject_latestPositionFromCachedGameCtrl();
    if (pos) {
        // Read the SFEN of this position so the bridge can see the same
        // board state we're about to use for move construction. Essential
        // for the resume case: the host has no way to know mid-game state
        // unless we surface it.
        NSString *sfen = nil;
        if (g_Position_ToSFEN) {
            @try {
                void *strPtr = g_Position_ToSFEN(pos);
                sfen = il2cppStringToNSString(strPtr);
            } @catch (NSException *e) { }
        }
        file_log([NSString stringWithFormat:
                  @"[INJECT-DBG] resolvePosition via GameCtrl pos=%p "
                  @"sfen=\"%@\"", pos, sfen ?: @""]);
        return pos;
    }

    // Path 2: server-authoritative SFEN. Populated by
    // UpdateAuthoritativeSnapshot on Online/CPUStream; absent on a fresh
    // (non-resumed) match, since the standard opening is implicit.
    void *sfenStr = inject_authoritativeSfenString();
    if (sfenStr && g_Position_CreateFromSFEN) {
        NSString *sfenDisplay = il2cppStringToNSString(sfenStr);
        @try {
            void *built = g_Position_CreateFromSFEN(sfenStr);
            if (built && outFromSfen) *outFromSfen = true;
            file_log([NSString stringWithFormat:
                      @"[INJECT-DBG] resolvePosition via SFEN strPtr=%p "
                      @"built=%p sfen=\"%@\"",
                      sfenStr, built, sfenDisplay ?: @"<unreadable>"]);
            if (built) return built;
        } @catch (NSException *e) {
            file_log([NSString stringWithFormat:
                      @"[INJECT-DBG] resolvePosition: CreateFromSFEN threw "
                      @"sfen=\"%@\" exc=%@",
                      sfenDisplay ?: @"<unreadable>", e]);
        }
    }

    // Path 3: fall back to the standard opening Position. This handles the
    // common case of a brand-new CPU match where the server never sends a
    // snapshot for the starting board (the standard layout is implicit on
    // both ends). InitialPositionType.Standard = 0.
    if (g_Position_CreateByType) {
        @try {
            void *built = g_Position_CreateByType(0);
            if (built && outFromSfen) *outFromSfen = true;
            file_log([NSString stringWithFormat:
                      @"[INJECT-DBG] resolvePosition via standard opening "
                      @"built=%p (no GameCtrl, no authoritativeSfen)", built]);
            if (built) return built;
        } @catch (NSException *e) {
            file_log([NSString stringWithFormat:
                      @"[INJECT-DBG] resolvePosition: CreateByType threw "
                      @"exc=%@", e]);
        }
    }

    file_log(@"[INJECT-DBG] resolvePosition: all paths exhausted");
    return NULL;
}

// Look up the piece sitting on a square, going through the resolved
// Position. Returns the Piece enum (with color baked in) on success,
// 0 for an empty square, or -1 when no Position is reachable at all.
static int32_t inject_pieceAtSquare(int32_t square) {
    if (!g_Position_GetPiece) return -1;
    bool fromSfen = false;
    void *pos = inject_resolvePosition(&fromSfen);
    if (!pos) return -1;
    @try {
        return g_Position_GetPiece(pos, square);
    } @catch (NSException *e) {
        return -1;
    }
}

// USI -> Project.ShogiCore.Move (uint32). The game-side Move struct packs
// moving piece and captured piece into the upper 16 bits — we don't try to
// reverse-engineer the layout, we just hand the inputs to Move.Create /
// Move.CreateDrop and let the game do the bit shuffling itself.
static bool inject_buildMove(const char *usi, uint32_t *outMove,
                             const char **outErr) {
    size_t n = strlen(usi);
    if (n < 4) { *outErr = "tooshort"; return false; }

    // Drop move: shape "X*<file><rank>"
    if (usi[1] == '*') {
        if (n != 4) { *outErr = "dropfmt"; return false; }
        int pt    = inject_pscPieceTypeFromUsiPiece(usi[0]);
        int toFile = inject_fileFromUsi(usi[2]);
        int toRank = inject_rankFromUsi(usi[3]);
        if (pt < 0 || toFile < 0 || toRank < 0) {
            *outErr = "dropchar";
            return false;
        }
        if (!g_PSCMove_CreateDrop) {
            *outErr = "nodrop";
            return false;
        }
        int32_t toSq = toFile * 9 + toRank;
        *outMove = g_PSCMove_CreateDrop(pt, toSq);
        return true;
    }

    // Normal move: "<f><r><f><r>" or "<f><r><f><r>+"
    if (n != 4 && !(n == 5 && usi[4] == '+')) {
        *outErr = "fmt";
        return false;
    }
    int fromFile = inject_fileFromUsi(usi[0]);
    int fromRank = inject_rankFromUsi(usi[1]);
    int toFile   = inject_fileFromUsi(usi[2]);
    int toRank   = inject_rankFromUsi(usi[3]);
    bool promote = (n == 5 && usi[4] == '+');
    if (fromFile < 0 || fromRank < 0 || toFile < 0 || toRank < 0) {
        *outErr = "char";
        return false;
    }
    int32_t fromSq = fromFile * 9 + fromRank;
    int32_t toSq   = toFile   * 9 + toRank;

    if (!g_PSCMove_Create || !g_Piece_GetPieceType) {
        *outErr = "nocreate";
        return false;
    }

    // Read the piece sitting on the from-square so we can tell the game
    // which piece is moving. The "captured" arg can stay at PieceType.None
    // (0); the game will fill it in itself when it applies the move.
    int32_t pieceAtFrom = inject_pieceAtSquare(fromSq);
    if (pieceAtFrom < 0) {
        *outErr = "no_board";
        return false;
    }
    if (pieceAtFrom == 0) {
        // Empty square — refuse rather than feed the game an illegal move.
        *outErr = "empty_from";
        return false;
    }
    int32_t pieceType = 0;
    @try {
        pieceType = g_Piece_GetPieceType(pieceAtFrom);
    } @catch (NSException *e) {
        *outErr = "piece_extract";
        return false;
    }
    if (pieceType <= 0 || pieceType > 14) {
        *outErr = "piece_invalid";
        return false;
    }

    *outMove = g_PSCMove_Create(fromSq, toSq, pieceType, promote, 0);
    file_log([NSString stringWithFormat:
              @"[INJECT-DBG] buildMove usi=\"%s\" fromSq=%d toSq=%d "
              @"pieceAtFrom=0x%x pieceType=%d promote=%d => raw=0x%x",
              usi, (int)fromSq, (int)toSq,
              (unsigned)pieceAtFrom, (int)pieceType, (int)promote,
              (unsigned)*outMove]);
    return true;
}

// ---------------------------------------------------------------------------
// Route selection. inbound USI lines carry no routing hint, so we infer from
// what the observation hooks have most recently seen.
// ---------------------------------------------------------------------------
typedef enum {
    KIOU_ROUTE_NONE = 0,
    KIOU_ROUTE_AI_OPM,         // AIMatchMode.OnPlayerMoveAsync (CPU games)
    KIOU_ROUTE_CPUSTREAM_OPM,  // CPUStreamMode.OnPlayerMoveAsync (server AI)
    KIOU_ROUTE_LOCAL_OPM,      // LocalPvPMode.OnPlayerMoveAsync (hot-seat)
    KIOU_ROUTE_ONLINE_OPM,     // OnlinePvPMode.OnPlayerMoveAsync (online ratings)
    KIOU_ROUTE_REPLAY_OPM,     // RecordReplayMode.OnPlayerMoveAsync (kifu replay)
    KIOU_ROUTE_ADAPTER,        // ShogiGameAdapter.TryMakeMove (fallback, no UI)
    KIOU_ROUTE_GAMECTRL,       // GameController.TryMakeMove (last resort, no UI)
} kiou_route_t;

static const char *inject_routeName(kiou_route_t r) {
    switch (r) {
        case KIOU_ROUTE_AI_OPM:        return "ai_opm";
        case KIOU_ROUTE_CPUSTREAM_OPM: return "cpustream_opm";
        case KIOU_ROUTE_LOCAL_OPM:     return "local_opm";
        case KIOU_ROUTE_ONLINE_OPM:    return "online_opm";
        case KIOU_ROUTE_REPLAY_OPM:    return "replay_opm";
        case KIOU_ROUTE_ADAPTER:       return "adapter";
        case KIOU_ROUTE_GAMECTRL:      return "gamectrl";
        default:                       return "none";
    }
}

// Route selection — purely cache-based. If we have ever seen the relevant
// IMatchMode instance flow through one of the observation hooks, that cache
// is assumed to still hold the live game's mode. The il2cpp Boehm GC is
// non-moving, so the address stays valid as long as the object stays alive,
// and an in-progress match keeps a strong root on its match controller, so
// the address keeps working for the entire match.
//
// The hazard: when the player ends the match and starts a new one, the old
// instance is potentially freed and a new one takes its place. Until we add
// a match-end hook (Phase 2) to clear these caches, the worst case is that
// we try to dispatch on a stale pointer. That's why we still prefer the
// freshest observed timestamp when multiple mode caches are populated —
// it's an ordering hint, not a gate. Branch F reconstructs per-site bypass
// trampolines from the fixed cave geometry, so binpatch injection can call
// OPM / Adapter without re-entering the dispatcher cave.
static kiou_route_t inject_pickRoute(void) {
    // Pick the mode whose OPM observation timestamp is the newest, treating
    // "never observed" (ts == 0) as infinitely old. The actual route call
    // only requires a live cached receiver; on binpatch the callable can be
    // the reconstructed cave-bypass entry even when orig_* is NULL.
    struct { void *cache; bool callable; uint64_t ts;
             kiou_route_t route; bool gated; } modes[] = {
        { g_aiMatchModeCache,      KIOU_BR_BINPATCH_AI_OPM_CALLABLE() != NULL,
          g_lastAiMatchEvtUs,       KIOU_ROUTE_AI_OPM,        false },
        { g_localPvPModeCache,     KIOU_BR_BINPATCH_LOCAL_OPM_CALLABLE() != NULL,
          g_lastLocalPvPEvtUs,      KIOU_ROUTE_LOCAL_OPM,     false },
        { g_cpuStreamModeCache,    KIOU_BR_BINPATCH_CPUSTREAM_OPM_CALLABLE() != NULL,
          g_lastCpuStreamEvtUs,     KIOU_ROUTE_CPUSTREAM_OPM, false },
        { g_recordReplayModeCache, KIOU_BR_BINPATCH_REPLAY_OPM_CALLABLE() != NULL,
          g_lastRecordReplayEvtUs,  KIOU_ROUTE_REPLAY_OPM,    false },
        { g_onlineModeCache,       KIOU_BR_BINPATCH_ONLINE_OPM_CALLABLE() != NULL,
          g_lastOnlineEvtUs,        KIOU_ROUTE_ONLINE_OPM,
          !g_onlineServerSendAllowed },
    };

    kiou_route_t best = KIOU_ROUTE_NONE;
    uint64_t bestTs = 0;
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
        if (!modes[i].cache || !modes[i].callable) continue;
        if (modes[i].gated) continue;
        if (modes[i].ts < bestTs) continue;  // older than current best
        bestTs = modes[i].ts;
        best   = modes[i].route;
    }
    if (best != KIOU_ROUTE_NONE) return best;

    // No OPM cache live — fall back to headless engine writes so the
    // bridge can at least drive the SFEN forward. GameCtrl stays JB-only:
    // binpatch does not publish a bypass entry for it.
    if (g_adapterCache && KIOU_BR_BINPATCH_ADAPTER_CALLABLE()) {
        return KIOU_ROUTE_ADAPTER;
    }
    if (g_gameCtrlCache && orig_GameCtrlTryMakeMove) return KIOU_ROUTE_GAMECTRL;
    return KIOU_ROUTE_NONE;
}

// ---------------------------------------------------------------------------
// Ring buffer for recent injections. Single producer (the recv-queue handler
// after the main-thread dispatch returns), so a simple mutex is overkill,
// but KEBInjectDumpRecent() can be called from any thread (signal handler
// etc.), so a lock is the cheapest correct option.
// ---------------------------------------------------------------------------
static kiou_inject_record_t g_ring[KIOU_INJECT_RING_SIZE];
static size_t g_ringHead = 0;
static size_t g_ringCount = 0;
static pthread_mutex_t g_ringMu = PTHREAD_MUTEX_INITIALIZER;

static void inject_pushRecord(const kiou_inject_record_t *rec) {
    pthread_mutex_lock(&g_ringMu);
    g_ring[g_ringHead] = *rec;
    g_ringHead = (g_ringHead + 1) % KIOU_INJECT_RING_SIZE;
    if (g_ringCount < KIOU_INJECT_RING_SIZE) g_ringCount++;
    pthread_mutex_unlock(&g_ringMu);
}

void KEBInjectDumpRecent(void) {
    pthread_mutex_lock(&g_ringMu);
    size_t count = g_ringCount;
    size_t head  = g_ringHead;
    file_log([NSString stringWithFormat:@"[INJECT] === recent (%zu) ===",
              count]);
    for (size_t i = 0; i < count; i++) {
        // Walk from oldest to newest.
        size_t idx = (head + KIOU_INJECT_RING_SIZE - count + i)
                     % KIOU_INJECT_RING_SIZE;
        kiou_inject_record_t *r = &g_ring[idx];
        file_log([NSString stringWithFormat:
                  @"[INJECT] t=%llu usi=\"%s\" route=%s ok=%d "
                  @"raw=0x%x err=\"%s\" sfen=\"%s\"",
                  (unsigned long long)r->ts_us,
                  r->usi_in, r->route, (int)r->ok,
                  (unsigned)r->move_raw, r->error, r->sfen_after]);
    }
    pthread_mutex_unlock(&g_ringMu);
}

// ---------------------------------------------------------------------------
// Walk the cached GameController to the latest Project.ShogiCore.Position.
// Returns NULL if the cache is empty or the chain looks corrupt.
// ---------------------------------------------------------------------------
static void *inject_latestPositionFromCachedGameCtrl(void) {
    void *gc = g_gameCtrlCache;
    if (!gc) return NULL;
    // GameController -> _positionHistory (List<Position>) -> _items[size-1]
    void *list = readPtr(gc, 0x10);
    if (!list) return NULL;
    void *items = readPtr(list, 0x10);
    int32_t size = readI32(list, 0x18);
    if (size <= 0 || size > 4096 || !ptrLooksValid(items)) return NULL;
    return readPtr(items, 0x20 + (size - 1) * 8);
}

// Read the side-to-move out of whatever Position the resolver hands us
// (local engine first, falling back to the server-authoritative SFEN
// parsed via Position.CreateFromSFEN). Project.ShogiCore.Position stores
// `_sideToMove` as a readonly PlayerSide (int32) at offset 0x20. Returns
// -1 when no Position is reachable so the caller can skip the turn check
// rather than guess.
static int32_t inject_sideToMoveFromPosition(void) {
    void *pos = inject_resolvePosition(NULL);
    if (!pos) return -1;
    int32_t side = readI32(pos, 0x20);
    if (side != 0 && side != 1) return -1;
    return side;
}

// Dispatch to whichever side-to-move source is most authoritative for the
// route we're about to inject on. We always prefer the local
// GameController's position history because that's what the local engine
// actually replays moves against — the server-authoritative side-to-move
// fields (_authoritativeTurn on CPUStreamMode / OnlinePvPMode) lag the
// local engine by a network round trip and mark "what side may move on
// the server next", not "what side does the local engine think is next".
// Empirically, on a CPUStreamMode resume, _authoritativeTurn read 1
// (White) while the local game had already advanced past CPU's reply,
// putting the seat-fixed Black human at side-to-move; reading the local
// engine fixes that.
static int32_t inject_currentSideToMoveForRoute(kiou_route_t route) {
    (void)route;
    return inject_sideToMoveFromPosition();
}

// ---------------------------------------------------------------------------
// Read the current GameController's post-move SFEN. Mirrors the routine in
// Hook_LowLevelObserve.m (kept duplicated rather than exporting another
// symbol — it's seven lines and tied to the observed cache state).
// ---------------------------------------------------------------------------
static NSString *inject_sfenFromCachedGameCtrl(void) {
    if (!g_Position_ToSFEN) return nil;
    void *pos = inject_latestPositionFromCachedGameCtrl();
    if (!pos) return nil;
    @try {
        void *strPtr = g_Position_ToSFEN(pos);
        return il2cppStringToNSString(strPtr);
    } @catch (NSException *e) {
        return nil;
    }
}

// ---------------------------------------------------------------------------
// The main-thread side of the injection. Performs the actual il2cpp call,
// reads back the resulting SFEN, and records the outcome. Output via the
// out-pointers is for Usi_Engine.m to consume; passing NULL for any of
// them is fine. The injected move always lands in the ring buffer
// regardless.
// ---------------------------------------------------------------------------
static void inject_runOnMain(const char *usi, uint32_t move,
                             kiou_route_t route,
                             bool *outOk,
                             uint32_t *outRaw,
                             NSString **outSfen,
                             NSString **outErr) {
    bool ok = false;
    uint32_t executed = 0;
    const char *err = "";

    // Helper macro for the OnPlayerMoveAsync routes. Disassembly of
    // CPUStreamMode.<OnPlayerMoveAsync>d__87.MoveNext (RVA 0x59F8F50)
    // showed the OPM body NEVER touches _gameAdapter — it only forwards
    // the move to the server stream and waits for HandleMoveResult to come
    // back and apply it via TryMakeMove. When the server silently drops
    // the move (which is what we observe — same SFEN comes back from
    // UpdateAuthoritativeSnapshot), the local board never advances and
    // the UI is stuck.
    //
    // The fix: on top of calling OPM (so the server still gets notified
    // and the rating-side machinery isn't bypassed for online play), also
    // call ShogiGameAdapter.TryMakeMove directly to nudge the local
    // engine forward, AND call GameStateStore.NotifyPieceMoved so the
    // _currentMovePlayer ReactiveProperty flips to the opponent — without
    // that, the side-to-move UI text sticks on "your turn" forever even
    // though the engine has already advanced the position.
    //
    // STORE_OFFSET is the byte offset of `_stateStore` on the per-mode
    // class (different on every mode — see dump.cs). LOCAL_PLAYER is the
    // PlayerSide value cached at OnMatchStart, or -1 when the mode has
    // no fixed seat — we skip the notify in that case because the macro
    // call site can't tell who actually moved.
    #define CALL_OPM(SELF, ORIG, STORE_OFFSET, LOCAL_PLAYER)              \
        do {                                                              \
            void *self = (SELF);                                          \
            OnPlayerMoveAsync_t fn = (ORIG);                              \
            if (!self || !fn) { err = "no_session"; break; }              \
            file_log([NSString stringWithFormat:                          \
                      @"[INJECT-DBG] route=%s callable=%p orig=%p "       \
                      @"bypass=%p",                                      \
                      inject_routeName(route), (void *)fn,                \
                      (void *)(ORIG),                                     \
                      (void *)((ORIG) ? NULL : fn)]);                     \
            \
            (void)fn(self, move, NULL);                                   \
            ok = true;                                                    \
            executed = move;                                              \
            /* Locally apply the same move so the headless engine and */  \
            /* GameStateStore advance — disasm confirms OPM alone won't */\
            /* do it (it forwards to the server stream and waits for */   \
            /* HandleMoveResult). On binpatch orig_AdapterTryMakeMoveOut */\
            /* stays NULL by design (see Hook_MatchModeObserve.m's */     \
            /* binpatch installer) and the cave-bypass entry has to be */ \
            /* used instead. KIOU_BR_BINPATCH_ADAPTER_CALLABLE() returns */ \
            /* orig_* on JB and g_inject_entry[ADAPTER] on binpatch. */   \
            /* Failures here are benign (the move might already have */   \
            /* been applied by an earlier HandleMoveResult) — we keep */  \
            /* ok=true because the OPM call already succeeded. */         \
            {                                                             \
                Adapter_TryMakeMove_Out_t adapterFn =                     \
                    KIOU_BR_BINPATCH_ADAPTER_CALLABLE();                  \
                if (g_adapterCache && adapterFn) {                        \
                    uint32_t outMv = 0;                                   \
                    bool tryOk = adapterFn(                               \
                        (void *)g_adapterCache, move, &outMv);            \
                    file_log([NSString stringWithFormat:                  \
                              @"[INJECT-DBG] local TryMakeMove tryOk=%d " \
                              @"outMv=0x%x adapter=%p",                   \
                              (int)tryOk, (unsigned)outMv,                \
                              (void *)adapterFn]);                        \
                } else {                                                  \
                    file_log([NSString stringWithFormat:                  \
                              @"[INJECT-DBG] local TryMakeMove skipped: " \
                              @"adapterCache=%p adapterFn=%p",            \
                              g_adapterCache, (void *)adapterFn]);        \
                }                                                         \
            }                                                             \
            /* Flip the side-to-move ReactiveProperty so the "whose */    \
            /* turn" UI advances. Skipped for open-seat modes */          \
            /* (LocalPvP / RecordReplay) which pass LOCAL_PLAYER=-1. */   \
            /* */                                                          \
            /* NotifyPieceMoved alone wasn't enough — live device tests */ \
            /* showed the board (BoardPresenter) updates but the turn */  \
            /* text presenter stayed on "your turn". The MoveCount */     \
            /* presenter subscribes to GameStateStore._onStateSynced */   \
            /* (a Subject<Position> at offset 0x158) instead, and that */ \
            /* Subject only fires from NotifyStateSynced. So we call */   \
            /* both: NotifyPieceMoved to update the _lastMove side, */    \
            /* NotifyStateSynced to tick everything that's waiting */     \
            /* for "the engine just caught up here". */                   \
            if ((LOCAL_PLAYER) >= 0) {                                    \
                void *store = readPtr(self, (STORE_OFFSET));              \
                if (store) {                                              \
                    if (g_GameStateStore_NotifyPieceMoved) {              \
                        @try {                                            \
                            g_GameStateStore_NotifyPieceMoved(            \
                                store, move,                              \
                                (int32_t)(LOCAL_PLAYER));                 \
                            file_log([NSString stringWithFormat:          \
                                      @"[INJECT-DBG] NotifyPieceMoved "   \
                                      @"store=%p player=%d",              \
                                      store, (int)(LOCAL_PLAYER)]);       \
                        } @catch (NSException *e) {                       \
                            file_log([NSString stringWithFormat:          \
                                      @"[INJECT-DBG] NotifyPieceMoved "   \
                                      @"threw %@", e]);                   \
                        }                                                 \
                    }                                                     \
                    /* Pull the latest Position from the cached */        \
                    /* GameController. Adapter.TryMakeMove just */        \
                    /* appended it; reading via */                        \
                    /* inject_latestPositionFromCachedGameCtrl gets */    \
                    /* the freshest one. */                               \
                    if (g_GameStateStore_NotifyStateSynced) {             \
                        void *pos =                                       \
                            inject_latestPositionFromCachedGameCtrl();    \
                        if (pos) {                                        \
                            @try {                                        \
                                g_GameStateStore_NotifyStateSynced(       \
                                    store, pos);                          \
                                file_log([NSString stringWithFormat:      \
                                          @"[INJECT-DBG] "                \
                                          @"NotifyStateSynced store=%p "  \
                                          @"pos=%p", store, pos]);        \
                            } @catch (NSException *e) {                   \
                                file_log([NSString stringWithFormat:      \
                                          @"[INJECT-DBG] "                \
                                          @"NotifyStateSynced threw %@",  \
                                          e]);                            \
                            }                                             \
                        } else {                                          \
                            file_log(@"[INJECT-DBG] "                     \
                                     @"NotifyStateSynced skipped: no "    \
                                     @"latest pos");                      \
                        }                                                 \
                    }                                                     \
                } else {                                                  \
                    file_log(@"[INJECT-DBG] Notify* skipped: no store");  \
                }                                                         \
            }                                                             \
        } while (0)

    switch (route) {
        case KIOU_ROUTE_AI_OPM:
            CALL_OPM(g_aiMatchModeCache, KIOU_BR_BINPATCH_AI_OPM_CALLABLE(),
                     OFF_AI_STATESTORE, g_aiLocalPlayer);
            break;
        case KIOU_ROUTE_CPUSTREAM_OPM:
            CALL_OPM(g_cpuStreamModeCache, KIOU_BR_BINPATCH_CPUSTREAM_OPM_CALLABLE(),
                     OFF_CPUSTREAM_STATESTORE, g_cpuStreamLocalPlayer);
            break;
        case KIOU_ROUTE_LOCAL_OPM:
            // LocalPvP has no fixed seat — pass -1 to suppress the
            // NotifyPieceMoved call (we can't tell which side this
            // injection represents).
            CALL_OPM(g_localPvPModeCache, KIOU_BR_BINPATCH_LOCAL_OPM_CALLABLE(),
                     OFF_LOCAL_STATESTORE, -1);
            break;
        case KIOU_ROUTE_ONLINE_OPM:
            CALL_OPM(g_onlineModeCache, KIOU_BR_BINPATCH_ONLINE_OPM_CALLABLE(),
                     OFF_ONLINE_STATESTORE, g_onlineLocalPlayer);
            break;
        case KIOU_ROUTE_REPLAY_OPM:
            // RecordReplay also has no fixed seat — same treatment.
            CALL_OPM(g_recordReplayModeCache, KIOU_BR_BINPATCH_REPLAY_OPM_CALLABLE(),
                     OFF_REPLAY_STATESTORE, -1);
            break;
        case KIOU_ROUTE_ADAPTER: {
            void *self = g_adapterCache;
            Adapter_TryMakeMove_Out_t fn = KIOU_BR_BINPATCH_ADAPTER_CALLABLE();
            uint32_t outMv = 0;
            if (!self || !fn) {
                err = "no_session";
                break;
            }
            file_log([NSString stringWithFormat:
                      @"[INJECT-DBG] route=adapter callable=%p orig=%p bypass=%p",
                      (void *)fn,
                      (void *)orig_AdapterTryMakeMoveOut,
                      (void *)(orig_AdapterTryMakeMoveOut ? NULL : fn)]);
            ok = fn(self, move, &outMv);
            executed = outMv;
            if (!ok) err = "no_legal";
            break;
        }
        case KIOU_ROUTE_GAMECTRL: {
            void *self = g_gameCtrlCache;
            if (!self || !orig_GameCtrlTryMakeMove) {
                err = "no_session";
                break;
            }
            ok = orig_GameCtrlTryMakeMove(self, move);
            executed = move;
            if (!ok) err = "no_legal";
            break;
        }
        default:
            err = "no_route";
            break;
    }

    #undef CALL_OPM

    // Always read the current SFEN straight from the GameController. That's
    // the source of truth for the local board after the injection
    // (whether the injection succeeded or not), and we want the bridge to
    // see exactly what the engine sees so it can plan the next move.
    NSString *sfen = inject_sfenFromCachedGameCtrl();

    kiou_inject_record_t rec;
    memset(&rec, 0, sizeof(rec));
    rec.ts_us = inject_machTicksToUs(mach_absolute_time());
    strncpy(rec.usi_in, usi, KIOU_INJECT_USI_MAX - 1);
    strncpy(rec.route, inject_routeName(route), KIOU_INJECT_ROUTE_MAX - 1);
    rec.ok = ok;
    rec.move_raw = executed;
    if (sfen) {
        const char *cstr = [sfen UTF8String] ?: "";
        strncpy(rec.sfen_after, cstr, KIOU_INJECT_SFEN_MAX - 1);
    }
    strncpy(rec.error, err, KIOU_INJECT_ROUTE_MAX - 1);
    inject_pushRecord(&rec);

    file_log([NSString stringWithFormat:
              @"[INJECT] usi=\"%s\" route=%s ok=%d raw=0x%x err=\"%s\" "
              @"sfen=\"%@\"",
              usi, inject_routeName(route), (int)ok,
              (unsigned)executed, err, sfen ?: @""]);

    // Hand the outcome back to the Usi_Engine.m caller (or whichever
    // future caller wants it). The ring buffer / file_log entries above
    // remain regardless, so debugging still works without a consumer.
    if (outOk)   *outOk   = ok;
    if (outRaw)  *outRaw  = executed;
    if (outSfen) *outSfen = sfen;
    if (outErr)  *outErr  = (err && err[0])
                              ? [NSString stringWithUTF8String:err]
                              : nil;
}

// ---------------------------------------------------------------------------
// inject_apply — primary external entry. Called from Usi_Engine.m when
// YaneuraOu hands us a `bestmove <usi>`. Runs on whichever thread the
// caller is on; internally hops to the Unity main thread for the il2cpp
// calls. Returns true on a successful TryMakeMove, populates the out
// parameters in either case (any of them may be NULL).
// ---------------------------------------------------------------------------
bool inject_apply(NSString *usi,
                  NSString **outSfenAfter,
                  uint32_t *outRaw,
                  NSString **outErr) {
    if (outSfenAfter) *outSfenAfter = nil;
    if (outRaw)       *outRaw = 0;
    if (outErr)       *outErr = nil;
    if (usi.length == 0) {
        if (outErr) *outErr = @"empty";
        return false;
    }

    const char *usiCstr = [usi UTF8String];
    if (!usiCstr) {
        if (outErr) *outErr = @"encoding";
        return false;
    }
    size_t usiLen = strlen(usiCstr);

    char usiTok[KIOU_INJECT_USI_MAX] = {0};
    const char *skip = NULL;
    if (!inject_extractUsiToken(usiCstr, usiLen, usiTok, &skip)) {
        kiou_inject_record_t rec;
        memset(&rec, 0, sizeof(rec));
        rec.ts_us = inject_machTicksToUs(mach_absolute_time());
        strncpy(rec.route, "skip", KIOU_INJECT_ROUTE_MAX - 1);
        strncpy(rec.error, skip ?: "parse", KIOU_INJECT_ROUTE_MAX - 1);
        size_t copyN = (usiLen < KIOU_INJECT_USI_MAX - 1)
                          ? usiLen : KIOU_INJECT_USI_MAX - 1;
        memcpy(rec.usi_in, usiCstr, copyN);
        rec.usi_in[copyN] = '\0';
        inject_pushRecord(&rec);
        file_log([NSString stringWithFormat:
                  @"[INJECT] skip usi=\"%s\" reason=%s",
                  rec.usi_in, rec.error]);
        if (outErr) *outErr = [NSString stringWithUTF8String:rec.error];
        return false;
    }

    // EVERYTHING from here down has to run on the Unity main thread.
    // inject_buildMove calls Project.ShogiCore.Position.CreateFromSFEN
    // (and Position.GetPiece) via NativeFunction; calling those off the
    // main thread crashes the il2cpp runtime instantly. Box them all into
    // dispatch_sync calls.
    __block uint32_t move = 0;
    __block const char *buildErr = NULL;
    __block bool buildOk = false;
    __block kiou_route_t route = KIOU_ROUTE_NONE;
    __block int32_t currentSideOut = -1;
    __block int32_t humanSideOut = -1;

    NSString *usiBox = [[NSString alloc] initWithUTF8String:usiTok];
    dispatch_sync(dispatch_get_main_queue(), ^{
        const char *usiInner = [usiBox UTF8String];
        buildOk = inject_buildMove(usiInner, &move, &buildErr);
        if (!buildOk) return;
        route = inject_pickRoute();
        switch (route) {
            case KIOU_ROUTE_AI_OPM:        humanSideOut = g_aiLocalPlayer;        break;
            case KIOU_ROUTE_CPUSTREAM_OPM: humanSideOut = g_cpuStreamLocalPlayer; break;
            case KIOU_ROUTE_ONLINE_OPM:    humanSideOut = g_onlineLocalPlayer;    break;
            default: break;
        }
        if (humanSideOut == 0 || humanSideOut == 1) {
            currentSideOut = inject_currentSideToMoveForRoute(route);
        }
    });

    if (!buildOk) {
        __block NSString *currentSfen = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            currentSfen = inject_sfenFromCachedGameCtrl();
        });

        kiou_inject_record_t rec;
        memset(&rec, 0, sizeof(rec));
        rec.ts_us = inject_machTicksToUs(mach_absolute_time());
        strncpy(rec.usi_in, usiTok, KIOU_INJECT_USI_MAX - 1);
        strncpy(rec.route, "skip", KIOU_INJECT_ROUTE_MAX - 1);
        strncpy(rec.error, buildErr ?: "parse", KIOU_INJECT_ROUTE_MAX - 1);
        if (currentSfen) {
            const char *cstr = [currentSfen UTF8String] ?: "";
            strncpy(rec.sfen_after, cstr, KIOU_INJECT_SFEN_MAX - 1);
        }
        inject_pushRecord(&rec);
        file_log([NSString stringWithFormat:
                  @"[INJECT] parse_fail usi=\"%s\" err=%s sfen=\"%@\"",
                  usiTok, rec.error, currentSfen ?: @""]);
        if (outSfenAfter) *outSfenAfter = currentSfen;
        if (outErr) *outErr = [NSString stringWithUTF8String:rec.error];
        return false;
    }

    if ((humanSideOut == 0 || humanSideOut == 1) &&
        currentSideOut != humanSideOut) {
        kiou_inject_record_t rec;
        memset(&rec, 0, sizeof(rec));
        rec.ts_us = inject_machTicksToUs(mach_absolute_time());
        strncpy(rec.usi_in, usiTok, KIOU_INJECT_USI_MAX - 1);
        strncpy(rec.route, "skip", KIOU_INJECT_ROUTE_MAX - 1);
        strncpy(rec.error, "not_your_turn", KIOU_INJECT_ROUTE_MAX - 1);
        rec.move_raw = move;
        inject_pushRecord(&rec);
        file_log([NSString stringWithFormat:
                  @"[INJECT] not_your_turn usi=\"%s\" raw=0x%x "
                  @"current=%d human=%d route=%s",
                  usiTok, (unsigned)move,
                  (int)currentSideOut, (int)humanSideOut,
                  inject_routeName(route)]);
        if (outRaw) *outRaw = move;
        if (outErr) *outErr = @"not_your_turn";
        return false;
    }

    if (route == KIOU_ROUTE_NONE) {
        kiou_inject_record_t rec;
        memset(&rec, 0, sizeof(rec));
        rec.ts_us = inject_machTicksToUs(mach_absolute_time());
        strncpy(rec.usi_in, usiTok, KIOU_INJECT_USI_MAX - 1);
        strncpy(rec.route, "none", KIOU_INJECT_ROUTE_MAX - 1);
        strncpy(rec.error, "no_session", KIOU_INJECT_ROUTE_MAX - 1);
        rec.move_raw = move;
        inject_pushRecord(&rec);
        file_log([NSString stringWithFormat:
                  @"[INJECT] no_session usi=\"%s\" raw=0x%x",
                  usiTok, (unsigned)move]);
        if (outRaw) *outRaw = move;
        if (outErr) *outErr = @"no_session";
        return false;
    }

    // Fire the piece-movement animation BEFORE the board state advances.
    // BoardPresenter.PlayMoveAnimationAsync reads the live Position to
    // figure out the "from" square, so if we mutate first the animation
    // sees the move already applied and either does nothing or teleports.
    // We don't await the UniTask (its layout is unverified) — we just
    // sleep INJECT_ANIMATION_DELAY_SEC between the animation kick and
    // the actual mutation. Animation runs in parallel with our wait and
    // wraps up around the time we resume.
    if (g_BoardPresenter_PlayMoveAnimationAsync && g_gameOrchestratorCache) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            void *boardPresenter = readPtr((void *)g_gameOrchestratorCache,
                                           OFF_GAMEORCH_BOARD_PRESENTER);
            if (!boardPresenter) {
                file_log(@"[INJECT-DBG] PlayMoveAnimation skipped: "
                         @"no BoardPresenter on orch");
                return;
            }
            @try {
                (void)g_BoardPresenter_PlayMoveAnimationAsync(boardPresenter,
                                                              move, NULL);
                file_log([NSString stringWithFormat:
                          @"[INJECT-DBG] PlayMoveAnimation fired "
                          @"presenter=%p move=0x%x",
                          boardPresenter, (unsigned)move]);
            } @catch (NSException *e) {
                file_log([NSString stringWithFormat:
                          @"[INJECT-DBG] PlayMoveAnimation threw: %@", e]);
            }
        });
        // Sleep on the WS recv queue (NOT the main thread) so the
        // animation actually runs while we wait. usleep here is safe
        // because inject_apply is called from the WS recv queue, not
        // from a Unity callback.
        usleep((useconds_t)(INJECT_ANIMATION_DELAY_SEC * 1000000.0));
    } else {
        file_log(@"[INJECT-DBG] PlayMoveAnimation skipped: "
                 @"fn or orch cache missing");
    }

    // Second main-thread hop, this time to do the actual mutation.
    __block bool runOk = false;
    __block uint32_t runExecuted = 0;
    __block NSString *runSfen = nil;
    __block NSString *runErr = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        inject_runOnMain([usiBox UTF8String], move, route,
                         &runOk, &runExecuted, &runSfen, &runErr);
    });
    if (outSfenAfter) *outSfenAfter = runSfen;
    if (outRaw)       *outRaw = runExecuted ? runExecuted : move;
    if (outErr)       *outErr = runErr;
    return runOk;
}

// ---------------------------------------------------------------------------
// Installer. Resolves the supplementary RVAs (Move builders + Position
// factories) and loads the online server-send gate state. The WS text
// handler itself is registered by Usi_Engine.m's installer.
//
// Idempotent: if the installer is invoked twice (Tweak.m retry loop) the
// second call notices g_SunfishMoveDrop is already set and bails out.
// ---------------------------------------------------------------------------
// Public wrapper around inject_sfenFromCachedGameCtrl for callers outside
// this translation unit (Usi_Engine.m). MUST be called on the main thread.
NSString *inject_currentSfen(void) {
    return inject_sfenFromCachedGameCtrl();
}

void InstallInjectHook(uintptr_t unityBase) {
    if (g_SunfishMoveDrop) {
        file_log(@"[INJECT] install: already initialized, skipping");
        return;
    }

    g_SunfishMoveDrop =
        (SunfishMoveDrop_t)(void *)(unityBase + RVA_SUNFISH_MOVE_DROP);
    g_Position_GetPiece =
        (Position_GetPiece_t)(void *)(unityBase + RVA_POSITION_GET_PIECE);
    g_Piece_GetPieceType =
        (Piece_GetPieceType_t)(void *)(unityBase + RVA_PIECE_GET_PIECETYPE);
    g_PSCMove_Create =
        (PSCMove_Create_t)(void *)(unityBase + RVA_PSC_MOVE_CREATE);
    g_PSCMove_CreateDrop =
        (PSCMove_CreateDrop_t)(void *)(unityBase + RVA_PSC_MOVE_CREATE_DROP);
    g_Position_CreateFromSFEN =
        (Position_CreateFromSFEN_t)(void *)(unityBase + RVA_POSITION_CREATE_FROM_SFEN);
    g_Position_CreateByType =
        (Position_CreateByType_t)(void *)(unityBase + RVA_POSITION_CREATE_BY_TYPE);
    g_GameStateStore_NotifyPieceMoved =
        (GameStateStore_NotifyPieceMoved_t)(void *)
        (unityBase + RVA_GAMESTATESTORE_NOTIFY_PIECE_MOVED);
    g_GameStateStore_NotifyStateSynced =
        (GameStateStore_NotifyStateSynced_t)(void *)
        (unityBase + RVA_GAMESTATESTORE_NOTIFY_STATE_SYNCED);
    g_BoardPresenter_PlayMoveAnimationAsync =
        (BoardPresenter_PlayMoveAnimationAsync_t)(void *)
        (unityBase + RVA_BOARDPRESENTER_PLAY_MOVE_ANIMATION);

    // g_onlineServerSendAllowed is now a compile-time `true` — the env
    // var + flag-file gate was removed when online auto-play was opted
    // into. The WS text handler is owned by Usi_Engine.m in Phase 2.
    // Inject_Move is now a pure helper that Usi_Engine calls into via
    // inject_apply().

    file_log([NSString stringWithFormat:
              @"[INJECT] installed: create@0x%lx createDrop@0x%lx "
              @"getPiece@0x%lx getPieceType@0x%lx fromSFEN@0x%lx "
              @"notifyPieceMoved@0x%lx notifyStateSynced@0x%lx "
              @"playMoveAnim@0x%lx onlineServerSendGate=%d",
              (unsigned long)(unityBase + RVA_PSC_MOVE_CREATE),
              (unsigned long)(unityBase + RVA_PSC_MOVE_CREATE_DROP),
              (unsigned long)(unityBase + RVA_POSITION_GET_PIECE),
              (unsigned long)(unityBase + RVA_PIECE_GET_PIECETYPE),
              (unsigned long)(unityBase + RVA_POSITION_CREATE_FROM_SFEN),
              (unsigned long)(unityBase + RVA_GAMESTATESTORE_NOTIFY_PIECE_MOVED),
              (unsigned long)(unityBase + RVA_GAMESTATESTORE_NOTIFY_STATE_SYNCED),
              (unsigned long)(unityBase + RVA_BOARDPRESENTER_PLAY_MOVE_ANIMATION),
              (int)g_onlineServerSendAllowed]);
}
