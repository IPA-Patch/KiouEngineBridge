#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>

// ===========================================================================
// Csa_Convert — CSA protocol coordinate / piece / move / position conversion.
//
// Pure functions, Foundation-only dependency. No il2cpp, no hooks, no
// globals — every routine is a referentially transparent helper that can be
// linked into a host test binary on macOS without any of the tweak runtime
// (`Tests/CsaConvertTests.m` does exactly that).
//
// Coordinate system:
//   KIOU's Move bits use Project.ShogiCore.Square encoding
//     SQ11 = 0, SQ19 = 8, SQ91 = 72, SQ99 = 80
//     square = (file - 1) * 9 + (rank - 1)
//   CSA writes the same square as a two-digit string "<file><rank>",
//   each digit in 1-9. e.g. square 60 → "77" (= 7七 = USI "7g").
//
// Move bit layout (mirrored from Hook_LowLevelObserve.m::moveToUsi):
//   bit[6:0]   to     — destination Square (0..80)
//   bit[13:7]  from   — origin Square (0..80), undefined when drop bit set
//   bit[14]    promote
//   bit[15]    drop
//   bit[31:16] upper16 — movingPiece et al. Drop piece type lives here,
//                        but the exact bit layout is still under reverse
//                        engineering (Task 7 of the CSA migration plan).
//
// CSA piece codes (14 PSC PieceType values mapped to CSA mnemonics):
//   1 FU (Pawn)        9  TO (Promoted Pawn)
//   2 KY (Lance)       10 NY (Promoted Lance)
//   3 KE (Knight)      11 NK (Promoted Knight)
//   4 GI (Silver)      12 NG (Promoted Silver)
//   5 KA (Bishop)      13 UM (Promoted Bishop)
//   6 HI (Rook)        14 RY (Promoted Rook)
//   7 KI (Gold)
//   8 OU (King)
//
// The promoted PieceType values (9..14) are assumed to follow the PSC enum
// declaration order; they will be verified against dump.cs in Task 7.
// ===========================================================================

// ---------------------------------------------------------------------------
// Square <-> CSA coordinate.
// ---------------------------------------------------------------------------

// Convert a Square value (0..80) into its CSA two-character coordinate
// (`"77"` for SQ77 / file 7 rank 7). Returns nil when `square` is out of
// range — callers MUST check for nil rather than assume a default.
NSString *CsaSquareFromMoveBits(uint32_t square);

// Inverse of CsaSquareFromMoveBits — parse a two-digit CSA coordinate and
// write the Square index (0..80) into *outSquare. Returns YES on success,
// NO on malformed input (wrong length, non-digit, file/rank out of 1..9).
// outSquare is left untouched on failure.
BOOL MoveBitsFromCsaSquare(NSString *csa, uint32_t *outSquare);

// ---------------------------------------------------------------------------
// CSA piece code <-> PSC PieceType.
// ---------------------------------------------------------------------------

// PSC PieceType integer (1..14) → CSA piece mnemonic. Returns nil for
// out-of-range values. The mnemonic is exactly two ASCII uppercase chars.
NSString *CsaPieceFromPscPieceType(int32_t pieceType);

// CSA piece mnemonic → PSC PieceType integer. Returns -1 when the input is
// not one of the 14 known mnemonics. Case-sensitive (CSA always uses upper
// case).
int32_t PscPieceTypeFromCsaPiece(NSString *csa);

// ---------------------------------------------------------------------------
// Move bits <-> CSA move text.
//
// CSA move text shape:
//   ±<from_file><from_rank><to_file><to_rank><PIECE>[,T<seconds>]
//     "+7776FU"          ordinary move, black side, T omitted
//     "+7776FU,T10"      same move with 10 s consumed
//     "+0055FU"          drop — from is literally "00", piece names the
//                        dropped piece type
//     "+8822UM"          promoting move — piece is the promoted type
//
// playerSide:
//   0 = Black (CSA `+`)
//   1 = White (CSA `-`)
// timeSpent:
//   seconds consumed on the move, written as `,T<n>`. Pass -1 to omit the
//   `,T<n>` suffix entirely (used when KIOU has not surfaced a clock for
//   this move, e.g. AI / Local modes before any snapshot arrives).
// ---------------------------------------------------------------------------

// Render a KIOU Move bits value as a CSA move line.
//
// For ordinary moves, the produced piece mnemonic reflects the promotion
// bit: if `bit[14]` is set we emit the promoted variant (FU → TO, KA → UM,
// etc). `pscPieceType` is the *unpromoted* PSC PieceType (1..8); upgrading
// to the promoted form is this function's job.
//
// For drops, `move`'s drop bit must be set and `pscPieceType` MUST be the
// dropped piece's PieceType (1..8, never a promoted form). The `from`
// coordinate is forced to "00" per CSA.
//
// Returns nil on any malformed input (bad squares, unknown piece type,
// drop bit + promote bit both set).
NSString *CsaTextFromMoveBits(uint32_t move,
                              int32_t pscPieceType,
                              int32_t playerSide,
                              int32_t timeSpent);

// Parse a CSA move line into its components. The leading `±` selects
// playerSide (0/1). `,T<n>` suffix is optional.
//
// Successful parse writes:
//   *outMove      — uint32 with to/from/promote/drop bits set. Upper-16
//                   piece type bits are left as zero (callers that need the
//                   piece type should consult *outPieceType).
//   *outPieceType — PSC PieceType integer (1..14). For promoting moves
//                   this is the *promoted* PieceType from the CSA text;
//                   the caller is responsible for downshifting to the
//                   unpromoted PieceType when invoking PSCMove_Create.
//   *outPlayerSide — 0 (Black) or 1 (White).
//   *outTimeSpent  — seconds parsed from `,T<n>`, or -1 if the suffix
//                    was absent.
//
// Returns YES on success, NO on any malformed input. All `out*` arguments
// must be non-NULL; on failure they are left untouched.
BOOL MoveBitsFromCsaText(NSString *csa,
                        uint32_t *outMove,
                        int32_t *outPieceType,
                        int32_t *outPlayerSide,
                        int32_t *outTimeSpent);

// ---------------------------------------------------------------------------
// SFEN -> CSA position block.
//
// Produces the multi-line representation that goes inside `BEGIN Position`
// / `END Position`. Format example for the standard opening:
//
//   P1-KY-KE-GI-KI-OU-KI-GI-KE-KY
//   P2 * -HI *  *  *  *  * -KA *
//   P3-FU-FU-FU-FU-FU-FU-FU-FU-FU
//   P4 *  *  *  *  *  *  *  *  *
//   P5 *  *  *  *  *  *  *  *  *
//   P6 *  *  *  *  *  *  *  *  *
//   P7+FU+FU+FU+FU+FU+FU+FU+FU+FU
//   P8 * +KA *  *  *  *  * +HI *
//   P9+KY+KE+GI+KI+OU+KI+GI+KE+KY
//   P+
//   P-
//   +
//
// The trailing `+` (or `-`) line is the side to move, derived from the SFEN
// side-to-move token. P+ / P- lines describe Black / White hand pieces using
// CSA's `00FU00FU` format ("00" file/rank + piece). Empty hand prints as a
// blank `P+` / `P-`.
//
// Returns nil when the SFEN is malformed (wrong number of board ranks, etc).
// The trailing newline is omitted; callers should append `\n` when slotting
// the block into the Game_Summary stream.
// ---------------------------------------------------------------------------

NSString *CsaPositionFromSfen(NSString *sfen);

// ---------------------------------------------------------------------------
// Helpers for reconstructing piece type from an SFEN snapshot.
//
// The Move bits surfaced by KIOU's NotifyPieceMoved hook carry the
// destination square but not (in any reverse-engineered form) the piece
// type that just landed there. Reading the post-move SFEN and pulling the
// letter sitting on the destination square is a robust workaround until the
// upper-16 layout is decoded (Task 7).
// ---------------------------------------------------------------------------

// Read the piece occupying `square` (0..80) in `sfen`. Returns the PSC
// PieceType integer (1..14) of the piece — promoted variants land on
// 9..14. Returns -1 if the square is empty or sfen is malformed.
int32_t PscPieceTypeAtSquare(NSString *sfen, uint32_t square);

// Find the piece type that disappeared from one player's hand between two
// SFEN snapshots. Used to recover the dropped piece type when KIOU's Move
// bits don't carry a usable upper-16 encoding for drops. Returns the PSC
// PieceType (1..7 — drops are always unpromoted) of the missing piece, or
// -1 when the hands match exactly (no drop happened) or sfen is malformed.
//
// playerSide: 0=Black (look at the uppercase hand letters), 1=White
// (lowercase hand letters).
int32_t DropPieceTypeFromHandDelta(NSString *sfenBefore,
                                   NSString *sfenAfter,
                                   int32_t playerSide);

// ---------------------------------------------------------------------------
// Move legality checks.
//
// Lightweight validators KEB runs before handing a CSA-supplied move off to
// inject_apply. They don't replicate the full shogi rule engine — KIOU is
// the authority on board state — but they catch the categories of input
// that, when fed through inject, leave KIOU's internal state inconsistent
// (the 'piece bounces back' symptom from on-device testing):
//
//   - dropping onto an occupied square
//   - moving from an empty square
//   - moving from a square whose piece doesn't match the named piece type
//   - moving onto a square already holding the same side's piece
//   - drop landing on a rank with no escape (pawn / lance on rank 1,
//     knight on ranks 1-2; from the moving side's perspective)
//   - two pawns on the same file (nifu) when dropping a pawn
//
// All four return a short ASCII reason string on rejection, or NULL when
// the move passes. `playerSide` is 0=Black, 1=White. Square indices follow
// the KIOU PSC convention (0..80).
// ---------------------------------------------------------------------------

const char *ValidateCsaDrop(NSString *sfenBefore,
                            uint32_t toSquare,
                            int32_t pscPieceType,
                            int32_t playerSide);

const char *ValidateCsaMove(NSString *sfenBefore,
                            uint32_t fromSquare,
                            uint32_t toSquare,
                            int32_t pscPieceType,
                            BOOL promote,
                            int32_t playerSide);

// Convenience: given a CSA-formatted move that's missing its `,T<n>`
// suffix, append `,T<seconds>` (or return the original unchanged when
// `seconds` < 0). Used by the engine driver when it knows the time spent
// at emit time but had to build the CSA prefix earlier.
NSString *CsaTextAppendingTime(NSString *csaMove, int32_t seconds);
