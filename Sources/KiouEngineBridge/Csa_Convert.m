#import "Csa_Convert.h"

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
// The CSA cell format is two chars per square: ` *` for empty, `+XX` for
// black piece XX, `-XX` for white piece XX. Each `P<n>` row therefore is
// `P<n>` followed by 9 × 2 = 18 chars.
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
    NSMutableString *out = [NSMutableString stringWithCapacity:18];
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
                [out appendString:@" *"];
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
