#import "Csa/Convert.h"

// ===========================================================================
// Csa_Convert — implementation.
//
// Pure routines: no globals, no il2cpp, no logging. Failure modes are
// signalled via return value (nil / NO / -1) rather than NSException — this
// is what makes the file linkable into a standalone host-side test binary.
// ===========================================================================

// ---------------------------------------------------------------------------
// CSA piece tables.
//
// Index is the PSC PieceType enum value (1..14). Index 0 is left blank so
// the table can be indexed directly by PieceType without an off-by-one.
// ---------------------------------------------------------------------------
static NSString *const kCsaPieceNames[15] = {
    @"",   // 0 — unused
    @"FU", // 1  Pawn
    @"KY", // 2  Lance
    @"KE", // 3  Knight
    @"GI", // 4  Silver
    @"KA", // 5  Bishop
    @"HI", // 6  Rook
    @"KI", // 7  Gold
    @"OU", // 8  King
    @"TO", // 9  Promoted Pawn
    @"NY", // 10 Promoted Lance
    @"NK", // 11 Promoted Knight
    @"NG", // 12 Promoted Silver
    @"UM", // 13 Promoted Bishop
    @"RY", // 14 Promoted Rook
};

// Map from base (unpromoted) PieceType to its promoted PieceType. 0 means
// "this piece cannot promote" — King and Gold land there.
static int32_t kPromotedPieceType[15] = {
    0,   //  0 unused
    9,   //  1 FU -> TO
    10,  //  2 KY -> NY
    11,  //  3 KE -> NK
    12,  //  4 GI -> NG
    13,  //  5 KA -> UM
    14,  //  6 HI -> RY
    0,   //  7 KI (cannot promote)
    0,   //  8 OU (cannot promote)
    0,   //  9..14 already promoted
    0, 0, 0, 0, 0,
};

// ---------------------------------------------------------------------------
// Square <-> CSA coordinate.
//
// PSC Square layout (matches Hook_LowLevelObserve.m:140-145):
//   square = (file - 1) * 9 + (rank - 1)
//   file_idx (1..9) = square / 9 + 1
//   rank_idx (1..9) = square % 9 + 1
// CSA writes file first, then rank. SFEN's "g" rank corresponds to rank 7.
// ---------------------------------------------------------------------------

NSString *CsaSquareFromMoveBits(uint32_t square) {
    if (square > 80) return nil;
    uint32_t file = (square / 9) + 1;
    uint32_t rank = (square % 9) + 1;
    return [NSString stringWithFormat:@"%u%u", file, rank];
}

BOOL MoveBitsFromCsaSquare(NSString *csa, uint32_t *outSquare) {
    if (csa.length != 2 || !outSquare) return NO;
    unichar fileCh = [csa characterAtIndex:0];
    unichar rankCh = [csa characterAtIndex:1];
    if (fileCh < '1' || fileCh > '9') return NO;
    if (rankCh < '1' || rankCh > '9') return NO;
    uint32_t file = (uint32_t)(fileCh - '0');
    uint32_t rank = (uint32_t)(rankCh - '0');
    *outSquare = (file - 1) * 9 + (rank - 1);
    return YES;
}

// ---------------------------------------------------------------------------
// CSA piece code <-> PSC PieceType.
// ---------------------------------------------------------------------------

NSString *CsaPieceFromPscPieceType(int32_t pieceType) {
    if (pieceType < 1 || pieceType > 14) return nil;
    return kCsaPieceNames[pieceType];
}

int32_t PscPieceTypeFromCsaPiece(NSString *csa) {
    if (csa.length != 2) return -1;
    for (int32_t i = 1; i <= 14; i++) {
        if ([csa isEqualToString:kCsaPieceNames[i]]) return i;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// Move bits <-> CSA move text.
// ---------------------------------------------------------------------------

NSString *CsaTextFromMoveBits(uint32_t move,
                              int32_t pscPieceType,
                              int32_t playerSide,
                              int32_t timeSpent) {
    if (playerSide != 0 && playerSide != 1) return nil;
    if (pscPieceType < 1 || pscPieceType > 14) return nil;

    uint32_t to       = move & 0x7F;
    uint32_t from     = (move >> 7) & 0x7F;
    uint32_t promote  = (move >> 14) & 1;
    uint32_t drop     = (move >> 15) & 1;

    // Cannot both drop and promote on the same move.
    if (promote && drop) return nil;

    NSString *toStr = CsaSquareFromMoveBits(to);
    if (!toStr) return nil;

    NSString *fromStr;
    int32_t finalPieceType = pscPieceType;
    if (drop) {
        // CSA encodes drops with from = "00". Promoted piece types are never
        // legal here — drops always introduce the unpromoted form.
        if (pscPieceType > 8) return nil;
        fromStr = @"00";
    } else {
        fromStr = CsaSquareFromMoveBits(from);
        if (!fromStr) return nil;
        if (promote) {
            int32_t promoted = kPromotedPieceType[pscPieceType];
            if (promoted == 0) return nil;  // King/Gold can't promote
            finalPieceType = promoted;
        }
    }

    NSString *pieceStr = CsaPieceFromPscPieceType(finalPieceType);
    if (!pieceStr) return nil;

    NSString *sideStr = (playerSide == 0) ? @"+" : @"-";

    if (timeSpent < 0) {
        return [NSString stringWithFormat:@"%@%@%@%@",
                sideStr, fromStr, toStr, pieceStr];
    }
    return [NSString stringWithFormat:@"%@%@%@%@,T%d",
            sideStr, fromStr, toStr, pieceStr, timeSpent];
}

BOOL MoveBitsFromCsaText(NSString *csa,
                        uint32_t *outMove,
                        int32_t *outPieceType,
                        int32_t *outPlayerSide,
                        int32_t *outTimeSpent) {
    if (!outMove || !outPieceType || !outPlayerSide || !outTimeSpent) {
        return NO;
    }
    // Minimum legal shape: "<sign><4 coord digits><2 piece chars>" = 7 chars
    if (csa.length < 7) return NO;

    unichar signCh = [csa characterAtIndex:0];
    int32_t playerSide;
    if      (signCh == '+') playerSide = 0;
    else if (signCh == '-') playerSide = 1;
    else return NO;

    NSString *fromStr  = [csa substringWithRange:NSMakeRange(1, 2)];
    NSString *toStr    = [csa substringWithRange:NSMakeRange(3, 2)];
    NSString *pieceStr = [csa substringWithRange:NSMakeRange(5, 2)];

    // Optional ",T<n>" suffix.
    int32_t timeSpent = -1;
    if (csa.length > 7) {
        // Expect ",T" immediately after the piece mnemonic; everything else
        // is malformed.
        if (csa.length < 9) return NO;
        if ([csa characterAtIndex:7] != ',') return NO;
        if ([csa characterAtIndex:8] != 'T') return NO;
        NSString *tStr = [csa substringFromIndex:9];
        if (tStr.length == 0) return NO;
        NSScanner *sc = [NSScanner scannerWithString:tStr];
        int parsed = 0;
        if (![sc scanInt:&parsed] || !sc.isAtEnd || parsed < 0) return NO;
        timeSpent = parsed;
    }

    int32_t pieceType = PscPieceTypeFromCsaPiece(pieceStr);
    if (pieceType < 0) return NO;

    uint32_t to = 0;
    if (!MoveBitsFromCsaSquare(toStr, &to)) return NO;

    // Drop case: from == "00", piece is the unpromoted dropped piece type.
    BOOL isDrop = [fromStr isEqualToString:@"00"];
    uint32_t from = 0;
    uint32_t dropBit = 0;
    uint32_t promoteBit = 0;
    if (isDrop) {
        if (pieceType > 8) return NO;  // can't drop promoted
        dropBit = 1;
        // from bits are undefined for drops; leave at 0.
    } else {
        if (!MoveBitsFromCsaSquare(fromStr, &from)) return NO;
        // Promotion is signalled implicitly: if the named piece is a
        // promoted form (9..14), the move is a promoting move.
        if (pieceType > 8) promoteBit = 1;
    }

    uint32_t move = (to & 0x7F)
                  | ((from & 0x7F) << 7)
                  | ((promoteBit & 1) << 14)
                  | ((dropBit    & 1) << 15);

    *outMove       = move;
    *outPieceType  = pieceType;
    *outPlayerSide = playerSide;
    *outTimeSpent  = timeSpent;
    return YES;
}

// ---------------------------------------------------------------------------
// SFEN -> CSA position block.
//
// SFEN reminder (from the standard USI position string):
//   <board> <side> <hand> <moveNum>
// Board ranks are separated by '/', and each rank is read from file 9 down
// to file 1 (left-to-right when looking at the board). A digit in a rank
// stands for that many empty squares. '+' before a letter promotes it.
// Lowercase = white, uppercase = black. The hand field uses the same
// letters; a count > 1 is prefixed (`2P`, `18p`, etc).
//
// CSA reverses the file order on the board: P1 starts at file 9 and ends
// at file 1, so the SFEN rank order maps onto CSA's `P<n>` rows directly.
//
// Each board cell is rendered as exactly three characters so the columns
// stay aligned (a strict CSA parser doesn't require alignment, but Floodgate
// / shogi-server reference outputs do):
//
//   ` * `  empty square (leading space + asterisk + trailing space)
//   `+XX`  black piece XX
//   `-XX`  white piece XX
//
// The trailing space on the rightmost cell is stripped so the line matches
// the canonical shogi-server format byte-for-byte.
// ---------------------------------------------------------------------------

// Translate a single SFEN piece character + promotion flag into the CSA
// two-letter mnemonic. Returns nil on unknown letter.
static NSString *csa_pieceFromSfenLetter(char letter, BOOL promoted) {
    int32_t base = -1;
    switch (letter) {
        case 'P': case 'p': base = 1;  break;
        case 'L': case 'l': base = 2;  break;
        case 'N': case 'n': base = 3;  break;
        case 'S': case 's': base = 4;  break;
        case 'B': case 'b': base = 5;  break;
        case 'R': case 'r': base = 6;  break;
        case 'G': case 'g': base = 7;  break;
        case 'K': case 'k': base = 8;  break;
        default: return nil;
    }
    if (promoted) {
        int32_t promotedType = kPromotedPieceType[base];
        if (promotedType == 0) return nil;
        base = promotedType;
    }
    return kCsaPieceNames[base];
}

// Render one SFEN board rank into a CSA `P<n>` line body (the 18 chars
// after the leading `P<n>` tag). Returns nil if the rank is malformed.
static NSString *csa_lineFromSfenRank(NSString *sfenRank) {
    NSMutableString *out = [NSMutableString stringWithCapacity:27];
    BOOL pendingPromote = NO;
    NSUInteger filled = 0;
    for (NSUInteger i = 0; i < sfenRank.length; i++) {
        unichar ch = [sfenRank characterAtIndex:i];
        if (ch == '+') {
            pendingPromote = YES;
            continue;
        }
        if (ch >= '1' && ch <= '9') {
            int empty = (int)(ch - '0');
            for (int e = 0; e < empty; e++) {
                [out appendString:@" * "];
                filled++;
            }
            pendingPromote = NO;
            continue;
        }
        BOOL isBlack = (ch >= 'A' && ch <= 'Z');
        NSString *piece = csa_pieceFromSfenLetter((char)ch, pendingPromote);
        if (!piece) return nil;
        [out appendString:isBlack ? @"+" : @"-"];
        [out appendString:piece];
        filled++;
        pendingPromote = NO;
    }
    if (filled != 9) return nil;
    // Trim only the rightmost spaces — empty cells generated by an empty
    // run at the end of the rank leave a trailing " " that needs to go,
    // but the leading space in front of the first " * " is meaningful.
    NSUInteger len = out.length;
    while (len > 0 && [out characterAtIndex:len - 1] == ' ') len--;
    if (len < out.length) {
        return [out substringToIndex:len];
    }
    return out;
}

// Render the hand-pieces section into `P+...` / `P-...` lines. Returns a
// two-element array {`P+...`, `P-...`}. `sfenHand` may be `-` (empty hand)
// or a sequence like `2Pn` meaning two black pawns and one white knight.
static NSArray<NSString *> *csa_handLinesFromSfen(NSString *sfenHand) {
    NSMutableString *black = [NSMutableString stringWithString:@"P+"];
    NSMutableString *white = [NSMutableString stringWithString:@"P-"];
    if ([sfenHand isEqualToString:@"-"]) {
        return @[black, white];
    }
    NSUInteger i = 0;
    while (i < sfenHand.length) {
        unichar ch = [sfenHand characterAtIndex:i];
        int count = 1;
        if (ch >= '0' && ch <= '9') {
            int n = 0;
            while (i < sfenHand.length) {
                unichar d = [sfenHand characterAtIndex:i];
                if (d < '0' || d > '9') break;
                n = n * 10 + (int)(d - '0');
                i++;
            }
            if (n == 0) return nil;
            count = n;
            if (i >= sfenHand.length) return nil;
            ch = [sfenHand characterAtIndex:i];
        }
        i++;
        BOOL isBlack = (ch >= 'A' && ch <= 'Z');
        NSString *piece = csa_pieceFromSfenLetter((char)ch, NO);
        if (!piece) return nil;
        NSMutableString *target = isBlack ? black : white;
        for (int c = 0; c < count; c++) {
            // CSA hand entries use "00<PIECE>" — file/rank zeros mean "no
            // square on the board," signalling a piece in hand.
            [target appendString:@"00"];
            [target appendString:piece];
        }
    }
    return @[black, white];
}

NSString *CsaPositionFromSfen(NSString *sfen) {
    if (sfen.length == 0) return nil;
    NSArray<NSString *> *parts = [sfen componentsSeparatedByString:@" "];
    if (parts.count < 3) return nil;
    NSArray<NSString *> *ranks = [parts[0] componentsSeparatedByString:@"/"];
    if (ranks.count != 9) return nil;

    NSMutableString *out = [NSMutableString stringWithCapacity:256];
    for (NSUInteger r = 0; r < 9; r++) {
        NSString *line = csa_lineFromSfenRank(ranks[r]);
        if (!line) return nil;
        [out appendFormat:@"P%lu%@\n", (unsigned long)(r + 1), line];
    }

    NSArray<NSString *> *handLines = csa_handLinesFromSfen(parts[2]);
    if (!handLines) return nil;
    [out appendFormat:@"%@\n%@\n", handLines[0], handLines[1]];

    NSString *side = parts[1];
    if ([side isEqualToString:@"b"]) {
        [out appendString:@"+"];
    } else if ([side isEqualToString:@"w"]) {
        [out appendString:@"-"];
    } else {
        return nil;
    }
    return out;
}

// ---------------------------------------------------------------------------
// SFEN-square lookup helper.
//
// Walk the SFEN board until we land on the requested square and return the
// PSC PieceType of whatever sits there. Promoted variants come back as
// 9..14. Empty cells / malformed input return -1.
// ---------------------------------------------------------------------------

int32_t PscPieceTypeAtSquare(NSString *sfen, uint32_t square) {
    if (square > 80) return -1;
    if (sfen.length == 0) return -1;
    NSArray<NSString *> *parts = [sfen componentsSeparatedByString:@" "];
    if (parts.count < 1) return -1;
    NSArray<NSString *> *ranks = [parts[0] componentsSeparatedByString:@"/"];
    if (ranks.count != 9) return -1;

    // Target rank is square % 9 (0..8 → SFEN rank a..i → board row 0..8).
    uint32_t rank = square % 9;
    uint32_t file = square / 9 + 1;  // 1..9

    NSString *rankStr = ranks[rank];
    // SFEN ranks list files from 9 down to 1 left-to-right.
    uint32_t cursorFile = 9;
    BOOL pendingPromote = NO;
    for (NSUInteger i = 0; i < rankStr.length; i++) {
        unichar ch = [rankStr characterAtIndex:i];
        if (ch == '+') {
            pendingPromote = YES;
            continue;
        }
        if (ch >= '1' && ch <= '9') {
            uint32_t skip = (uint32_t)(ch - '0');
            if (cursorFile > file && file >= cursorFile - skip + 1 &&
                file <= cursorFile) {
                // The target file lies inside an empty run.
                return -1;
            }
            cursorFile -= skip;
            pendingPromote = NO;
            continue;
        }
        if (cursorFile == file) {
            int32_t base = -1;
            switch (ch) {
                case 'P': case 'p': base = 1; break;
                case 'L': case 'l': base = 2; break;
                case 'N': case 'n': base = 3; break;
                case 'S': case 's': base = 4; break;
                case 'B': case 'b': base = 5; break;
                case 'R': case 'r': base = 6; break;
                case 'G': case 'g': base = 7; break;
                case 'K': case 'k': base = 8; break;
                default: return -1;
            }
            if (pendingPromote) {
                int32_t promoted = kPromotedPieceType[base];
                if (promoted == 0) return -1;
                base = promoted;
            }
            return base;
        }
        cursorFile--;
        pendingPromote = NO;
        if (cursorFile < 1) break;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// Hand-piece counting. SFEN hand strings look like "2P3pn" (two Black pawns,
// three white pawns, one white knight). Walk the string and accumulate per-
// PSC-PieceType counts into `outCounts[1..7]` (index 0 is unused). Returns
// NO on malformed input (unknown letter, malformed count, etc).
//
// Uppercase letters land in `outBlackCounts`, lowercase in `outWhiteCounts`.
// Empty hand ("-") returns YES with both arrays left zeroed.
// ---------------------------------------------------------------------------
static BOOL csa_parseHand(NSString *hand,
                          uint32_t outBlackCounts[8],
                          uint32_t outWhiteCounts[8]) {
    for (int i = 0; i < 8; i++) {
        outBlackCounts[i] = 0;
        outWhiteCounts[i] = 0;
    }
    if (hand.length == 0) return NO;
    if ([hand isEqualToString:@"-"]) return YES;

    NSUInteger i = 0;
    while (i < hand.length) {
        uint32_t count = 1;
        unichar ch = [hand characterAtIndex:i];
        if (ch >= '0' && ch <= '9') {
            uint32_t n = 0;
            while (i < hand.length) {
                unichar d = [hand characterAtIndex:i];
                if (d < '0' || d > '9') break;
                n = n * 10 + (uint32_t)(d - '0');
                i++;
            }
            if (n == 0) return NO;
            count = n;
            if (i >= hand.length) return NO;
            ch = [hand characterAtIndex:i];
        }
        i++;
        int32_t base = -1;
        switch (ch) {
            case 'P': case 'p': base = 1; break;
            case 'L': case 'l': base = 2; break;
            case 'N': case 'n': base = 3; break;
            case 'S': case 's': base = 4; break;
            case 'B': case 'b': base = 5; break;
            case 'R': case 'r': base = 6; break;
            case 'G': case 'g': base = 7; break;
            default: return NO;
        }
        BOOL isBlack = (ch >= 'A' && ch <= 'Z');
        if (isBlack) outBlackCounts[base] += count;
        else         outWhiteCounts[base] += count;
    }
    return YES;
}

int32_t DropPieceTypeFromHandDelta(NSString *sfenBefore,
                                   NSString *sfenAfter,
                                   int32_t playerSide) {
    if (sfenBefore.length == 0 || sfenAfter.length == 0) return -1;
    if (playerSide != 0 && playerSide != 1) return -1;

    NSArray<NSString *> *beforeParts = [sfenBefore componentsSeparatedByString:@" "];
    NSArray<NSString *> *afterParts  = [sfenAfter componentsSeparatedByString:@" "];
    if (beforeParts.count < 3 || afterParts.count < 3) return -1;

    uint32_t beforeBlack[8], beforeWhite[8];
    uint32_t afterBlack[8],  afterWhite[8];
    if (!csa_parseHand(beforeParts[2], beforeBlack, beforeWhite)) return -1;
    if (!csa_parseHand(afterParts[2],  afterBlack,  afterWhite))  return -1;

    const uint32_t *beforeCount = (playerSide == 0) ? beforeBlack : beforeWhite;
    const uint32_t *afterCount  = (playerSide == 0) ? afterBlack  : afterWhite;

    // Find the piece type whose count decreased by exactly 1.
    int32_t found = -1;
    for (int32_t pt = 1; pt <= 7; pt++) {
        if (beforeCount[pt] == afterCount[pt] + 1) {
            if (found != -1) return -1;  // ambiguous — two pieces left the hand
            found = pt;
        } else if (beforeCount[pt] != afterCount[pt]) {
            // Any other delta (count went up, or dropped by >1) is unusable.
            return -1;
        }
    }
    return found;
}

// ---------------------------------------------------------------------------
// Move legality checks. The shared IPALog() emits a single line per
// rejection so the device log captures the reason without each caller
// having to format their own message.
//
// We deliberately rely on the SFEN snapshot rather than KIOU's own legal-
// move generator (which we don't have a stable RVA for). That misses
// position-specific rules KIOU still applies (uchifuzume, double check,
// etc), but it catches the cheap "obviously bad" categories that we
// observed leaving KIOU's state inconsistent on inject.
//
// piece-type letter cache for the helpers below.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Per-piece reachability check.
//
// Square encoding: sq = (file-1)*9 + (rank-1), file 1-9 (right-to-left),
// rank 1-9 (top-to-bottom in standard board view).
//   dFile step = ±9   (one file left/right)
//   dRank step = ±1   (one rank forward/backward)
// Black moves "forward" toward rank 1, so Black's advance is dRank = -1.
//
// The movement tables below encode every (dFile, dRank) step a given piece
// can make from the playerSide perspective. Black and White tables are kept
// separate because asymmetric pieces (FU, KY, KE, and the gold-generals
// TO/NY/NK/NG) have direction relative to side.
//
// Piece types (PSC):
//   1 FU  2 KY  3 KE  4 GI  5 KA  6 HI  7 KI  8 OU
//   9 TO 10 NY 11 NK 12 NG 13 UM 14 RY
// ---------------------------------------------------------------------------

// A single move direction: (dFile, dRank) delta and whether it slides
// (can repeat until blocked).
typedef struct { int dFile; int dRank; BOOL slides; } MoveDir;

// Maximum directions per piece (8 dirs × 2 for slider flag headroom).
#define MAX_DIRS 8

// Returns the set of move directions for `pscPieceType` from `playerSide`
// (0=Black, 1=White). Writes into `dirs` and returns the count.
// Caller provides dirs[MAX_DIRS].
static int moveDirsForPiece(int32_t pscPieceType, int32_t playerSide,
                             MoveDir dirs[MAX_DIRS]) {
    // Black advances toward rank 1 (dRank=-1); White toward rank 9 (dRank=+1).
    int fwd = (playerSide == 0) ? -1 : +1;
    int n = 0;

    switch (pscPieceType) {
        case 1: // FU — one step forward
            dirs[n++] = (MoveDir){0, fwd, NO};
            break;
        case 2: // KY — slides forward only
            dirs[n++] = (MoveDir){0, fwd, YES};
            break;
        case 3: // KE — L-shape forward: 2 ranks forward, 1 file either side
            dirs[n++] = (MoveDir){-9, 2*fwd, NO};
            dirs[n++] = (MoveDir){+9, 2*fwd, NO};
            break;
        case 4: // GI — Silver: 5 diagonal + forward
            dirs[n++] = (MoveDir){  0,  fwd, NO};
            dirs[n++] = (MoveDir){ -9,  fwd, NO};
            dirs[n++] = (MoveDir){ +9,  fwd, NO};
            dirs[n++] = (MoveDir){ -9, -fwd, NO};
            dirs[n++] = (MoveDir){ +9, -fwd, NO};
            break;
        case 5: // KA — Bishop: 4 diagonal slides
            dirs[n++] = (MoveDir){ -9, -1, YES};
            dirs[n++] = (MoveDir){ -9, +1, YES};
            dirs[n++] = (MoveDir){ +9, -1, YES};
            dirs[n++] = (MoveDir){ +9, +1, YES};
            break;
        case 6: // HI — Rook: 4 orthogonal slides
            dirs[n++] = (MoveDir){  0, -1, YES};
            dirs[n++] = (MoveDir){  0, +1, YES};
            dirs[n++] = (MoveDir){ -9,  0, YES};
            dirs[n++] = (MoveDir){ +9,  0, YES};
            break;
        case 7:  // KI — Gold: forward, side, backward-orthogonal
        case 9:  // TO  — same as gold
        case 10: // NY  — same as gold
        case 11: // NK  — same as gold
        case 12: // NG  — same as gold
            dirs[n++] = (MoveDir){  0,  fwd, NO};
            dirs[n++] = (MoveDir){ -9,  fwd, NO};
            dirs[n++] = (MoveDir){ +9,  fwd, NO};
            dirs[n++] = (MoveDir){ -9,    0, NO};
            dirs[n++] = (MoveDir){ +9,    0, NO};
            dirs[n++] = (MoveDir){  0, -fwd, NO};
            break;
        case 8: // OU — King: all 8 adjacent
            dirs[n++] = (MoveDir){  0, -1, NO};
            dirs[n++] = (MoveDir){  0, +1, NO};
            dirs[n++] = (MoveDir){ -9,  0, NO};
            dirs[n++] = (MoveDir){ +9,  0, NO};
            dirs[n++] = (MoveDir){ -9, -1, NO};
            dirs[n++] = (MoveDir){ -9, +1, NO};
            dirs[n++] = (MoveDir){ +9, -1, NO};
            dirs[n++] = (MoveDir){ +9, +1, NO};
            break;
        case 13: // UM — Horse: bishop slides + 4 adjacent orthogonal
            dirs[n++] = (MoveDir){ -9, -1, YES};
            dirs[n++] = (MoveDir){ -9, +1, YES};
            dirs[n++] = (MoveDir){ +9, -1, YES};
            dirs[n++] = (MoveDir){ +9, +1, YES};
            dirs[n++] = (MoveDir){  0, -1, NO};
            dirs[n++] = (MoveDir){  0, +1, NO};
            dirs[n++] = (MoveDir){ -9,  0, NO};
            dirs[n++] = (MoveDir){ +9,  0, NO};
            break;
        case 14: // RY — Dragon: rook slides + 4 adjacent diagonal
            dirs[n++] = (MoveDir){  0, -1, YES};
            dirs[n++] = (MoveDir){  0, +1, YES};
            dirs[n++] = (MoveDir){ -9,  0, YES};
            dirs[n++] = (MoveDir){ +9,  0, YES};
            dirs[n++] = (MoveDir){ -9, -1, NO};
            dirs[n++] = (MoveDir){ -9, +1, NO};
            dirs[n++] = (MoveDir){ +9, -1, NO};
            dirs[n++] = (MoveDir){ +9, +1, NO};
            break;
        default:
            break;
    }
    return n;
}

// Board occupancy helper: given a SFEN board string (part before first ' '),
// returns YES when `square` is occupied by any piece. Returns NO if empty.
// Caller must pass only the board part of SFEN (no spaces).
static BOOL squareOccupied(NSString *boardPart, uint32_t square) {
    uint32_t file = (square / 9) + 1;  // 1..9
    uint32_t rank = (square % 9) + 1;  // 1..9
    NSArray<NSString *> *ranks = [boardPart componentsSeparatedByString:@"/"];
    if (ranks.count != 9) return NO;
    NSString *rankStr = ranks[rank - 1];
    uint32_t cursorFile = 9;
    for (NSUInteger i = 0; i < rankStr.length; i++) {
        unichar ch = [rankStr characterAtIndex:i];
        if (ch == '+') continue;
        if (ch >= '1' && ch <= '9') {
            uint32_t empties = (uint32_t)(ch - '0');
            if (cursorFile - empties < file) return NO;
            cursorFile -= empties;
            continue;
        }
        // piece letter
        if (cursorFile == file) return YES;
        cursorFile--;
        if (cursorFile < 1) break;
    }
    return NO;
}

// Returns YES when `pscPieceType` can legally reach `toSquare` from
// `fromSquare` in one move, given the board occupancy in `boardPart`
// (the part of SFEN before the first space). Slider pieces are blocked
// by any intervening piece (own or opponent — only the destination
// occupation check in ValidateCsaMove distinguishes capture vs. blocked).
static BOOL pieceCanReach(int32_t pscPieceType, int32_t playerSide,
                           uint32_t fromSquare, uint32_t toSquare,
                           NSString *boardPart) {
    if (fromSquare == toSquare) return NO;

    MoveDir dirs[MAX_DIRS];
    int nDirs = moveDirsForPiece(pscPieceType, playerSide, dirs);
    if (nDirs == 0) return NO;

    int fromFile = (int)(fromSquare / 9) + 1;  // 1..9
    int fromRank = (int)(fromSquare % 9) + 1;  // 1..9

    for (int d = 0; d < nDirs; d++) {
        int cf = fromFile;
        int cr = fromRank;
        // Walk along this direction.
        for (;;) {
            cf += dirs[d].dFile / 9;  // dFile is ±9 → ±1 file step
            cr += dirs[d].dRank;
            // Check board bounds.
            if (cf < 1 || cf > 9 || cr < 1 || cr > 9) break;
            uint32_t sq = (uint32_t)((cf - 1) * 9 + (cr - 1));
            if (sq == toSquare) return YES;  // reached destination
            if (!dirs[d].slides) break;      // non-slider: only one step
            // Slider: stop if something is in the way.
            if (squareOccupied(boardPart, sq)) break;
        }
    }
    return NO;
}

const char *ValidateCsaDrop(NSString *sfenBefore,
                            uint32_t toSquare,
                            int32_t pscPieceType,
                            int32_t playerSide) {
    if (sfenBefore.length == 0) return NULL;  // no prior snapshot → don't block
    if (toSquare > 80) return "to_oob";
    if (pscPieceType < 1 || pscPieceType > 7) return "drop_promoted";
    if (playerSide != 0 && playerSide != 1) return "bad_side";

    // 1. Target square must be empty.
    int32_t occupant = PscPieceTypeAtSquare(sfenBefore, toSquare);
    if (occupant > 0) return "drop_on_occupied";

    // 2. Nowhere-to-go: pawn / lance must not land on the deepest rank;
    //    knight must not land on the two deepest ranks. Deepest rank is
    //    rank 1 for Black (SQ?1), rank 9 for White (SQ?9).
    uint32_t rank = (toSquare % 9) + 1;  // 1..9
    uint32_t deepest = (playerSide == 0) ? 1u : 9u;
    if (pscPieceType == 1 /*FU*/ || pscPieceType == 2 /*KY*/) {
        if (rank == deepest) return "drop_deadend";
    } else if (pscPieceType == 3 /*KE*/) {
        uint32_t blocked2 = (playerSide == 0) ? 2u : 8u;
        if (rank == deepest || rank == blocked2) return "drop_deadend";
    }

    // 3. Nifu: dropping a pawn onto a file that already holds an
    //    unpromoted pawn of the same side is illegal.
    if (pscPieceType == 1) {
        uint32_t file = (toSquare / 9) + 1;
        for (uint32_t r = 1; r <= 9; r++) {
            uint32_t sq = (file - 1) * 9 + (r - 1);
            int32_t pt = PscPieceTypeAtSquare(sfenBefore, sq);
            if (pt != 1) continue;
            // Determine whether that pawn belongs to the moving side.
            // PscPieceTypeAtSquare strips colour, so we re-read the SFEN
            // letter at this square. We can shortcut by reading the
            // SFEN board and inspecting the letter's case.
            // Reuse PscPieceTypeAtSquare's parser via a tiny helper.
            NSArray<NSString *> *parts = [sfenBefore componentsSeparatedByString:@" "];
            if (parts.count < 1) break;
            NSArray<NSString *> *ranks = [parts[0] componentsSeparatedByString:@"/"];
            if (ranks.count != 9) break;
            uint32_t rIdx = r - 1;
            NSString *rankStr = ranks[rIdx];
            uint32_t cursorFile = 9;
            BOOL pendingPromote = NO;
            BOOL hit = NO;
            BOOL ourPawn = NO;
            for (NSUInteger i = 0; i < rankStr.length; i++) {
                unichar ch = [rankStr characterAtIndex:i];
                if (ch == '+') { pendingPromote = YES; continue; }
                if (ch >= '1' && ch <= '9') {
                    cursorFile -= (uint32_t)(ch - '0');
                    pendingPromote = NO;
                    continue;
                }
                if (cursorFile == file) {
                    BOOL isBlack = (ch >= 'A' && ch <= 'Z');
                    BOOL isPawn = (ch == 'P' || ch == 'p');
                    hit = YES;
                    if (isPawn && !pendingPromote) {
                        ourPawn = (isBlack == (playerSide == 0));
                    }
                    break;
                }
                cursorFile--;
                pendingPromote = NO;
                if (cursorFile < 1) break;
            }
            if (hit && ourPawn) return "nifu";
        }
    }
    return NULL;
}

const char *ValidateCsaMove(NSString *sfenBefore,
                            uint32_t fromSquare,
                            uint32_t toSquare,
                            int32_t pscPieceType,
                            BOOL promote,
                            int32_t playerSide) {
    if (sfenBefore.length == 0) return NULL;
    if (fromSquare > 80) return "from_oob";
    if (toSquare > 80) return "to_oob";
    if (pscPieceType < 1 || pscPieceType > 14) return "bad_piece";
    if (playerSide != 0 && playerSide != 1) return "bad_side";

    int32_t fromPiece = PscPieceTypeAtSquare(sfenBefore, fromSquare);
    if (fromPiece < 0) return "from_empty";

    // The CSA piece mnemonic on the wire is the moving piece's *current*
    // type (post-promotion if applicable). Allow it to match either the
    // raw on-board piece or its promoted form, since promote=true means
    // the piece is being upgraded as part of this move.
    if (fromPiece != pscPieceType) {
        // Allow promotion-in-move case: from-square holds the unpromoted
        // form, CSA names the promoted form, and the promote flag is set.
        if (!promote || fromPiece > 8) return "from_piece_mismatch";
        int32_t expectedPromoted = (fromPiece >= 1 && fromPiece <= 6)
            ? fromPiece + 8 : 0;
        if (expectedPromoted != pscPieceType) return "from_piece_mismatch";
    }

    // Promotion legality. Only six base piece types can promote
    // (FU/KY/KE/GI/KA/HI = 1..6). King (8) and Gold (7) never can. A
    // promotion is only legal when the move starts in, ends in, or
    // crosses through the enemy camp — equivalent to: from-rank or
    // to-rank is on the opponent's side of the board (Black promotes
    // when either rank ≤ 3; White when either rank ≥ 7).
    if (promote) {
        if (fromPiece > 8) return "promote_already_promoted";
        if (fromPiece == 7 /*KI*/ || fromPiece == 8 /*OU*/) {
            return "promote_unpromotable";
        }
        uint32_t fromRank = (fromSquare % 9) + 1;  // 1..9
        uint32_t toRank   = (toSquare   % 9) + 1;
        BOOL inEnemyCamp;
        if (playerSide == 0) {
            // Black's enemy camp is rank 1-3.
            inEnemyCamp = (fromRank <= 3) || (toRank <= 3);
        } else {
            // White's enemy camp is rank 7-9.
            inEnemyCamp = (fromRank >= 7) || (toRank >= 7);
        }
        if (!inEnemyCamp) return "promote_outside_enemy_camp";
    }

    // Must-promote check: FU/KY cannot be left unpromoted on rank 1 (Black)
    // or rank 9 (White); KE cannot be left unpromoted on ranks 1-2 (Black)
    // or ranks 8-9 (White). Only applies to unpromoted pieces (fromPiece 1..8)
    // making a non-promoting move.
    if (!promote && fromPiece >= 1 && fromPiece <= 8) {
        uint32_t toRank = (toSquare % 9) + 1;  // 1..9
        if (playerSide == 0) {
            // Black: rank 1 is the back rank.
            if ((fromPiece == 1 /*FU*/ || fromPiece == 2 /*KY*/) && toRank == 1)
                return "must_promote";
            if (fromPiece == 3 /*KE*/ && toRank <= 2)
                return "must_promote";
        } else {
            // White: rank 9 is the back rank.
            if ((fromPiece == 1 /*FU*/ || fromPiece == 2 /*KY*/) && toRank == 9)
                return "must_promote";
            if (fromPiece == 3 /*KE*/ && toRank >= 8)
                return "must_promote";
        }
    }

    // Per-piece reachability: does this piece type actually reach toSquare
    // from fromSquare given board occupancy? Uses the unpromoted base type
    // for pieces that just landed in the from-square still unpromoted
    // (pscPieceType 1..8), or the promoted type for already-promoted pieces
    // (9..14). The moveDirsForPiece table covers all 14 types.
    {
        NSArray<NSString *> *sfenParts = [sfenBefore componentsSeparatedByString:@" "];
        NSString *boardPart = sfenParts.count >= 1 ? sfenParts[0] : @"";
        if (boardPart.length > 0) {
            // Use the piece type that is actually on fromSquare (fromPiece),
            // not the wire piece type, so sliding piece paths are computed
            // correctly for both pre- and post-promotion pieces.
            if (!pieceCanReach(fromPiece, playerSide, fromSquare, toSquare, boardPart)) {
                return "unreachable";
            }
        }
    }

    // Can't capture your own piece.
    NSArray<NSString *> *parts = [sfenBefore componentsSeparatedByString:@" "];
    if (parts.count >= 1) {
        NSArray<NSString *> *ranks = [parts[0] componentsSeparatedByString:@"/"];
        if (ranks.count == 9) {
            uint32_t toFile = (toSquare / 9) + 1;
            uint32_t toRank = (toSquare % 9) + 1;
            NSString *rankStr = ranks[toRank - 1];
            uint32_t cursorFile = 9;
            for (NSUInteger i = 0; i < rankStr.length; i++) {
                unichar ch = [rankStr characterAtIndex:i];
                if (ch == '+') continue;  // promotion marker — colour-neutral
                if (ch >= '1' && ch <= '9') {
                    cursorFile -= (uint32_t)(ch - '0');
                    continue;
                }
                if (cursorFile == toFile) {
                    BOOL isBlack = (ch >= 'A' && ch <= 'Z');
                    if (isBlack == (playerSide == 0)) {
                        return "to_own_piece";
                    }
                    break;
                }
                cursorFile--;
                if (cursorFile < 1) break;
            }
        }
    }
    return NULL;
}

NSString *CsaTextAppendingTime(NSString *csaMove, int32_t seconds) {
    if (seconds < 0 || csaMove.length == 0) return csaMove;
    if ([csaMove rangeOfString:@",T"].location != NSNotFound) {
        // Already has a time suffix; leave it alone.
        return csaMove;
    }
    return [NSString stringWithFormat:@"%@,T%d", csaMove, seconds];
}
