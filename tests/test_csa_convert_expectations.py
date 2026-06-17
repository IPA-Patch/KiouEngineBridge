"""Pinned expectations for the CSA conversion library (Csa_Convert.{h,m}).

The C/ObjC implementation lives in ``Sources/KiouEngineBridge/Csa_Convert.m``
and is exercised on-device against KIOU. We can't link Foundation against a
Linux CI runner, so this test module ports the algorithms to pure Python and
pins the expected outputs against the same inputs the ObjC code receives.

A future macOS-only test harness (``Tests/CsaConvertTests.m``) will run the
same vectors through the real implementation. Until then, this module is the
authoritative regression net for:

  - Square <-> CSA coordinate (square 60 <-> "77")
  - PSC PieceType <-> CSA piece mnemonic (FU..RY, 14 types)
  - Move bits <-> CSA move text ("+7776FU", "+0055FU", "+8822UM", ",T10")
  - SFEN -> CSA position block (P1..P9 + P+ / P- hand + side)

If the Python port and the ObjC implementation ever diverge, the diff is
the bug — both should agree on every value in this file.
"""

from __future__ import annotations

import pytest


# ---------------------------------------------------------------------------
# Python reference implementation. Mirrors Csa_Convert.m verbatim.
# ---------------------------------------------------------------------------

CSA_PIECE_NAMES = [
    "",     # 0 — unused
    "FU",   # 1
    "KY",   # 2
    "KE",   # 3
    "GI",   # 4
    "KA",   # 5
    "HI",   # 6
    "KI",   # 7
    "OU",   # 8
    "TO",   # 9
    "NY",   # 10
    "NK",   # 11
    "NG",   # 12
    "UM",   # 13
    "RY",   # 14
]

PROMOTED_PIECE_TYPE = [0, 9, 10, 11, 12, 13, 14, 0, 0, 0, 0, 0, 0, 0, 0]


def csa_square_from_move_bits(square: int) -> str | None:
    if not (0 <= square <= 80):
        return None
    f = square // 9 + 1
    r = square % 9 + 1
    return f"{f}{r}"


def move_bits_from_csa_square(csa: str) -> int | None:
    if len(csa) != 2 or not csa.isdigit():
        return None
    f, r = int(csa[0]), int(csa[1])
    if not (1 <= f <= 9 and 1 <= r <= 9):
        return None
    return (f - 1) * 9 + (r - 1)


def csa_piece_from_psc(pt: int) -> str | None:
    if not (1 <= pt <= 14):
        return None
    return CSA_PIECE_NAMES[pt]


def psc_from_csa_piece(s: str) -> int:
    if len(s) != 2:
        return -1
    for i in range(1, 15):
        if CSA_PIECE_NAMES[i] == s:
            return i
    return -1


def encode_move_bits(to: int, frm: int = 0, promote: bool = False,
                     drop: bool = False) -> int:
    return ((to & 0x7F)
            | ((frm & 0x7F) << 7)
            | ((1 if promote else 0) << 14)
            | ((1 if drop else 0) << 15))


def csa_text_from_move_bits(move: int, psc_piece_type: int, player_side: int,
                            time_spent: int) -> str | None:
    if player_side not in (0, 1):
        return None
    if not (1 <= psc_piece_type <= 14):
        return None
    to = move & 0x7F
    frm = (move >> 7) & 0x7F
    promote = bool((move >> 14) & 1)
    drop = bool((move >> 15) & 1)
    if promote and drop:
        return None
    to_str = csa_square_from_move_bits(to)
    if not to_str:
        return None
    if drop:
        if psc_piece_type > 8:
            return None
        from_str = "00"
        final = psc_piece_type
    else:
        from_str = csa_square_from_move_bits(frm)
        if not from_str:
            return None
        final = psc_piece_type
        if promote:
            promoted = PROMOTED_PIECE_TYPE[psc_piece_type]
            if promoted == 0:
                return None
            final = promoted
    piece_str = csa_piece_from_psc(final)
    if not piece_str:
        return None
    sign = "+" if player_side == 0 else "-"
    if time_spent < 0:
        return f"{sign}{from_str}{to_str}{piece_str}"
    return f"{sign}{from_str}{to_str}{piece_str},T{time_spent}"


def move_bits_from_csa_text(csa: str):
    """Return (move, piece_type, player_side, time_spent) or None."""
    if len(csa) < 7:
        return None
    sign = csa[0]
    if sign == "+":
        side = 0
    elif sign == "-":
        side = 1
    else:
        return None
    from_str = csa[1:3]
    to_str = csa[3:5]
    piece_str = csa[5:7]
    time_spent = -1
    if len(csa) > 7:
        if len(csa) < 9 or csa[7] != "," or csa[8] != "T":
            return None
        t_str = csa[9:]
        if not t_str.isdigit():
            return None
        time_spent = int(t_str)
    pt = psc_from_csa_piece(piece_str)
    if pt < 0:
        return None
    to = move_bits_from_csa_square(to_str)
    if to is None:
        return None
    is_drop = from_str == "00"
    frm = 0
    drop = False
    promote = False
    if is_drop:
        if pt > 8:
            return None
        drop = True
    else:
        frm = move_bits_from_csa_square(from_str)
        if frm is None:
            return None
        if pt > 8:
            promote = True
    move = encode_move_bits(to, frm, promote, drop)
    return move, pt, side, time_spent


def csa_text_appending_time(csa_move: str, seconds: int) -> str:
    if seconds < 0 or not csa_move:
        return csa_move
    if ",T" in csa_move:
        return csa_move
    return f"{csa_move},T{seconds}"


def sfen_piece_to_psc(letter: str, promoted: bool) -> int | None:
    base_map = {
        "p": 1, "l": 2, "n": 3, "s": 4,
        "b": 5, "r": 6, "g": 7, "k": 8,
    }
    base = base_map.get(letter.lower())
    if base is None:
        return None
    if promoted:
        promoted_type = PROMOTED_PIECE_TYPE[base]
        if promoted_type == 0:
            return None
        return promoted_type
    return base


def csa_line_from_sfen_rank(sfen_rank: str) -> str | None:
    # CSA's `P<n>` line packs each square into exactly three characters so
    # the columns align: ` *` for empty, `+XX` / `-XX` for occupied. Note
    # the empty cell uses a leading SPACE, not nothing, so each cell still
    # spans three columns when followed by a piece on the next square.
    out = []
    pending_promote = False
    filled = 0
    for ch in sfen_rank:
        if ch == "+":
            pending_promote = True
            continue
        if ch.isdigit() and ch != "0":
            empty = int(ch)
            for _ in range(empty):
                out.append(" * ")
                filled += 1
            pending_promote = False
            continue
        is_black = ch.isupper()
        pt = sfen_piece_to_psc(ch, pending_promote)
        if pt is None:
            return None
        out.append("+" if is_black else "-")
        out.append(CSA_PIECE_NAMES[pt])
        filled += 1
        pending_promote = False
    if filled != 9:
        return None
    # Collapse the trailing column padding so the line is rstripped at the
    # right edge but interior alignment survives. CSA reference outputs
    # carry a single trailing space after the last `*` when the rightmost
    # cell is empty (e.g. "P2 * -HI *  *  *  *  * -KA *"), but the canonical
    # shogi-server output trims it. Match the trimmed form.
    return "".join(out).rstrip()


def csa_position_from_sfen(sfen: str) -> str | None:
    if not sfen:
        return None
    parts = sfen.split()
    if len(parts) < 3:
        return None
    ranks = parts[0].split("/")
    if len(ranks) != 9:
        return None
    lines = []
    for i, rank in enumerate(ranks, start=1):
        body = csa_line_from_sfen_rank(rank)
        if body is None:
            return None
        lines.append(f"P{i}{body}")
    # Hand pieces.
    black = ["P+"]
    white = ["P-"]
    hand = parts[2]
    if hand != "-":
        i = 0
        while i < len(hand):
            count = 1
            if hand[i].isdigit():
                n_str = ""
                while i < len(hand) and hand[i].isdigit():
                    n_str += hand[i]
                    i += 1
                count = int(n_str)
            ch = hand[i]
            i += 1
            is_black = ch.isupper()
            pt = sfen_piece_to_psc(ch, False)
            if pt is None:
                return None
            target = black if is_black else white
            for _ in range(count):
                target.append("00")
                target.append(CSA_PIECE_NAMES[pt])
    lines.append("".join(black))
    lines.append("".join(white))
    if parts[1] == "b":
        lines.append("+")
    elif parts[1] == "w":
        lines.append("-")
    else:
        return None
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Pinned vectors.
# ---------------------------------------------------------------------------

SFEN_INITIAL = (
    "lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PPPPPPPPP/1B5R1/LNSGKGSNL b - 1"
)


# --- coordinate conversion --------------------------------------------------

class TestSquareConversion:
    @pytest.mark.parametrize("square, expected", [
        (0,  "11"),
        (8,  "19"),
        (60, "77"),
        (72, "91"),
        (80, "99"),
    ])
    def test_square_to_csa(self, square, expected):
        assert csa_square_from_move_bits(square) == expected

    def test_square_out_of_range(self):
        assert csa_square_from_move_bits(81) is None
        assert csa_square_from_move_bits(-1 & 0xFF) is None

    @pytest.mark.parametrize("csa, expected", [
        ("11",  0),
        ("19",  8),
        ("77", 60),
        ("91", 72),
        ("99", 80),
    ])
    def test_csa_to_square(self, csa, expected):
        assert move_bits_from_csa_square(csa) == expected

    @pytest.mark.parametrize("bad", ["", "1", "111", "0a", "a0", "01", "10"])
    def test_csa_square_rejects_bad_input(self, bad):
        assert move_bits_from_csa_square(bad) is None

    def test_roundtrip(self):
        for sq in range(81):
            assert move_bits_from_csa_square(
                csa_square_from_move_bits(sq)) == sq


# --- piece conversion -------------------------------------------------------

class TestPieceConversion:
    @pytest.mark.parametrize("pt, csa", [
        (1, "FU"), (2, "KY"), (3, "KE"), (4, "GI"),
        (5, "KA"), (6, "HI"), (7, "KI"), (8, "OU"),
        (9, "TO"), (10, "NY"), (11, "NK"), (12, "NG"),
        (13, "UM"), (14, "RY"),
    ])
    def test_psc_to_csa(self, pt, csa):
        assert csa_piece_from_psc(pt) == csa

    def test_psc_out_of_range(self):
        assert csa_piece_from_psc(0) is None
        assert csa_piece_from_psc(15) is None
        assert csa_piece_from_psc(-1) is None

    @pytest.mark.parametrize("csa, pt", [
        ("FU", 1), ("KY", 2), ("KE", 3), ("GI", 4),
        ("KA", 5), ("HI", 6), ("KI", 7), ("OU", 8),
        ("TO", 9), ("NY", 10), ("NK", 11), ("NG", 12),
        ("UM", 13), ("RY", 14),
    ])
    def test_csa_to_psc(self, csa, pt):
        assert psc_from_csa_piece(csa) == pt

    @pytest.mark.parametrize("bad", ["", "F", "FUU", "fu", "XX"])
    def test_csa_piece_rejects_bad_input(self, bad):
        assert psc_from_csa_piece(bad) == -1


# --- move bits <-> CSA text -------------------------------------------------

class TestMoveText:
    def test_ordinary_move_no_time(self):
        # 7g7f: SQ77 (60) -> SQ76 (59), pawn (FU)
        move = encode_move_bits(to=59, frm=60)
        assert csa_text_from_move_bits(move, 1, 0, -1) == "+7776FU"

    def test_ordinary_move_with_time(self):
        move = encode_move_bits(to=59, frm=60)
        assert csa_text_from_move_bits(move, 1, 0, 10) == "+7776FU,T10"

    def test_white_move(self):
        # 3c3d: SQ33 (20) -> SQ34 (21), pawn (downward = white)
        move = encode_move_bits(to=21, frm=20)
        assert csa_text_from_move_bits(move, 1, 1, 8) == "-3334FU,T8"

    def test_promoted_move(self):
        # 8h2b+ : KA promoting in enemy camp.
        # SQ88 = (8-1)*9 + (8-1) = 70; SQ22 = (2-1)*9 + (2-1) = 10
        move = encode_move_bits(to=10, frm=70, promote=True)
        assert csa_text_from_move_bits(move, 5, 0, -1) == "+8822UM"

    def test_drop_move(self):
        # P*5e -> drop pawn at SQ55 = (5-1)*9 + (5-1) = 40
        move = encode_move_bits(to=40, drop=True)
        assert csa_text_from_move_bits(move, 1, 0, 5) == "+0055FU,T5"

    def test_drop_promoted_rejected(self):
        # Drop of a promoted piece type is illegal in CSA.
        move = encode_move_bits(to=40, drop=True)
        assert csa_text_from_move_bits(move, 9, 0, -1) is None

    def test_invalid_side(self):
        move = encode_move_bits(to=0, frm=1)
        assert csa_text_from_move_bits(move, 1, 2, -1) is None

    def test_promote_and_drop_rejected(self):
        move = encode_move_bits(to=40, drop=True, promote=True)
        assert csa_text_from_move_bits(move, 1, 0, -1) is None

    def test_king_cannot_promote(self):
        move = encode_move_bits(to=40, frm=41, promote=True)
        assert csa_text_from_move_bits(move, 8, 0, -1) is None

    def test_gold_cannot_promote(self):
        move = encode_move_bits(to=40, frm=41, promote=True)
        assert csa_text_from_move_bits(move, 7, 0, -1) is None


# --- CSA text parsing -------------------------------------------------------

class TestMoveParse:
    def test_ordinary(self):
        result = move_bits_from_csa_text("+7776FU")
        assert result is not None
        move, pt, side, t = result
        assert side == 0
        assert pt == 1
        assert (move & 0x7F) == 59
        assert ((move >> 7) & 0x7F) == 60
        assert ((move >> 14) & 1) == 0
        assert ((move >> 15) & 1) == 0
        assert t == -1

    def test_with_time(self):
        result = move_bits_from_csa_text("-3334FU,T8")
        assert result is not None
        _, _, side, t = result
        assert side == 1
        assert t == 8

    def test_drop(self):
        result = move_bits_from_csa_text("+0055FU,T5")
        assert result is not None
        move, pt, side, t = result
        assert ((move >> 15) & 1) == 1
        assert (move & 0x7F) == 40
        assert pt == 1
        assert side == 0
        assert t == 5

    def test_promotion(self):
        # Promoted piece in CSA: piece mnemonic is the promoted form
        result = move_bits_from_csa_text("+8822UM")
        assert result is not None
        move, pt, _, _ = result
        # promote bit should be set
        assert ((move >> 14) & 1) == 1
        # piece type returned is the promoted form (UM = 13)
        assert pt == 13

    @pytest.mark.parametrize("bad", [
        "", "+7776F", "*7776FU", "+777FU", "+77a6FU", "+7776FU,",
        "+7776FU,T", "+7776FU,Tabc", "+7776XX",
    ])
    def test_rejects_bad_input(self, bad):
        assert move_bits_from_csa_text(bad) is None

    def test_drop_promoted_rejected_on_parse(self):
        # CSA "from = 00" with a promoted-form piece name should not parse.
        assert move_bits_from_csa_text("+0055TO") is None


# --- SFEN -> CSA position ---------------------------------------------------

INITIAL_CSA_POSITION = (
    "P1-KY-KE-GI-KI-OU-KI-GI-KE-KY\n"
    "P2 * -HI *  *  *  *  * -KA *\n"
    "P3-FU-FU-FU-FU-FU-FU-FU-FU-FU\n"
    "P4 *  *  *  *  *  *  *  *  *\n"
    "P5 *  *  *  *  *  *  *  *  *\n"
    "P6 *  *  *  *  *  *  *  *  *\n"
    "P7+FU+FU+FU+FU+FU+FU+FU+FU+FU\n"
    "P8 * +KA *  *  *  *  * +HI *\n"
    "P9+KY+KE+GI+KI+OU+KI+GI+KE+KY\n"
    "P+\n"
    "P-\n"
    "+"
)


class TestCsaPosition:
    def test_initial_position(self):
        assert csa_position_from_sfen(SFEN_INITIAL) == INITIAL_CSA_POSITION

    def test_white_to_move(self):
        sfen = ("lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PPPPPPPPP/1B5R1/LNSGKGSNL "
                "w - 1")
        result = csa_position_from_sfen(sfen)
        assert result is not None
        assert result.endswith("\nP-\n-")

    def test_hand_pieces(self):
        # Black holds 2 pawns and a knight, white holds a bishop.
        sfen = ("lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PPPPPPPPP/1B5R1/LNSGKGSNL "
                "b 2PNb 1")
        result = csa_position_from_sfen(sfen)
        assert result is not None
        assert "P+00FU00FU00KE" in result
        assert "P-00KA" in result

    def test_promoted_piece_in_board(self):
        # An SFEN row with +P (promoted pawn = TO) somewhere on the board.
        sfen = ("lnsgkgsnl/1r5b1/ppppppppp/9/4+P4/9/PPPP1PPPP/1B5R1/LNSGKGSNL "
                "b - 1")
        result = csa_position_from_sfen(sfen)
        assert result is not None
        # Row 5 should contain +TO at the centre square (file 5).
        assert "P5 *  *  *  * +TO *  *  *  *" in result

    def test_malformed_rejected(self):
        assert csa_position_from_sfen("") is None
        assert csa_position_from_sfen("xxx") is None
        # 8 ranks instead of 9
        assert csa_position_from_sfen("9/9/9/9/9/9/9/9 b - 1") is None


# --- helper -----------------------------------------------------------------

class TestAppendTime:
    def test_appends_when_missing(self):
        assert csa_text_appending_time("+7776FU", 10) == "+7776FU,T10"

    def test_keeps_existing(self):
        assert csa_text_appending_time("+7776FU,T5", 10) == "+7776FU,T5"

    def test_negative_passes_through(self):
        assert csa_text_appending_time("+7776FU", -1) == "+7776FU"
