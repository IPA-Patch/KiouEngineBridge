"""Version-independent recipe constants and cave payload builders.

Shared by all per-version modules (v1_0_1.py, v1_0_2.py, …).
"""

from __future__ import annotations

from tools.encode import (
    add_x_imm,
    adrp,
    b_imm,
    blr_x,
    ldp_off_x,
    ldp_post_x,
    ldr_x_imm,
    movz_w_imm,
    ret_insn,
    stp_off_x,
    stp_pre_x,
)

# ---------------------------------------------------------------------------
# Target identification
# ---------------------------------------------------------------------------

TARGET_BASENAME = "UnityFramework"
DYLIB_PATH = "@executable_path/Frameworks/KiouEngineBridge.dylib"

# ---------------------------------------------------------------------------
# Info.plist additions
# ---------------------------------------------------------------------------

PLIST_KEYS: dict = {
    "UIFileSharingEnabled": True,
    "LSSupportsOpeningDocumentsInPlace": True,
}

# ---------------------------------------------------------------------------
# Cave kinds
# ---------------------------------------------------------------------------

CAVE_OBSERVER = "observer"
CAVE_ENTRY    = "entry"

CAVE_PAYLOAD_SIZE = 84   # 21 arm64 instructions

_NOP = b"\x1f\x20\x03\xd5"

# ---------------------------------------------------------------------------
# Hook ID enum — mirrors ``enum kiou_bridge_hook_id`` in Internal.h.
# ---------------------------------------------------------------------------

HOOK_IDS: dict[str, int] = {
    "KIOU_BR_HOOK_AI_INIT": 0,
    "KIOU_BR_HOOK_CPUSTREAM_INIT": 1,
    "KIOU_BR_HOOK_LOCAL_INIT": 2,
    "KIOU_BR_HOOK_ONLINE_INIT": 3,
    "KIOU_BR_HOOK_REPLAY_INIT": 4,
    "KIOU_BR_HOOK_AI_START": 5,
    "KIOU_BR_HOOK_CPUSTREAM_START": 6,
    "KIOU_BR_HOOK_LOCAL_START": 7,
    "KIOU_BR_HOOK_ONLINE_START": 8,
    "KIOU_BR_HOOK_REPLAY_START": 9,
    "KIOU_BR_HOOK_AI_OPM": 10,
    "KIOU_BR_HOOK_CPUSTREAM_OPM": 11,
    "KIOU_BR_HOOK_LOCAL_OPM": 12,
    "KIOU_BR_HOOK_ONLINE_OPM": 13,
    "KIOU_BR_HOOK_REPLAY_OPM": 14,
    "KIOU_BR_HOOK_AI_END": 15,
    "KIOU_BR_HOOK_CPUSTREAM_END": 16,
    "KIOU_BR_HOOK_LOCAL_END": 17,
    "KIOU_BR_HOOK_ONLINE_END": 18,
    "KIOU_BR_HOOK_REPLAY_END": 19,
    "KIOU_BR_HOOK_ADAPTER_TRY_MAKE_MOVE_OUT": 20,
    "KIOU_BR_HOOK_ONLINE_UPDATE_SNAPSHOT": 21,
    "KIOU_BR_HOOK_ONLINE_HANDLE_RESULT": 22,
    "KIOU_BR_HOOK_CPUSTREAM_UPDATE_SNAPSHOT": 23,
    "KIOU_BR_HOOK_GAMEORCH_ACTIVATE": 24,
    "KIOU_BR_HOOK_GSTATE_SET_BLACK_PLAYER_INFO": 25,
    "KIOU_BR_HOOK_GSTATE_SET_WHITE_PLAYER_INFO": 26,
    "KIOU_BR_HOOK_GSTATE_NOTIFY_PIECE_MOVED": 27,
    "KIOU_BR_HOOK_ACCOUNT_EXISTS": 28,
    "KIOU_BR_HOOK_LOGIN_ARGS_CREATE": 29,
    "KIOU_BR_HOOK_REGISTER_USER_ARGS_CREATE": 30,
    "KIOU_BR_HOOK_GET_VALID_MATCH_FOUND_STATUS": 31,
    "KIOU_BR_HOOK_MATCH_STREAM_ARGS_CREATE": 32,
    "KIOU_BR_HOOK_RECEIVE_TIMEOUT_MOVENEXT": 33,
    "KIOU_BR_HOOK_RUN_LOGIN_SEQ_MOVENEXT": 34,
    "KIOU_BR_HOOK_GET_SELF_PROFILE_MOVENEXT": 35,
    "KIOU_BR_HOOK_HTTPMSGINVOKER_SEND_ASYNC": 36,
}

# Entry slot indices — one per CAVE_ENTRY site, must mirror Internal.h.
ENTRY_SLOT_INDEX: dict[str, int] = {
    "KIOU_BR_HOOK_ACCOUNT_EXISTS":               0,
    "KIOU_BR_HOOK_LOGIN_ARGS_CREATE":            1,
    "KIOU_BR_HOOK_REGISTER_USER_ARGS_CREATE":    2,
    "KIOU_BR_HOOK_GET_VALID_MATCH_FOUND_STATUS": 3,
    "KIOU_BR_HOOK_MATCH_STREAM_ARGS_CREATE":     4,
    "KIOU_BR_HOOK_RUN_LOGIN_SEQ_MOVENEXT":       5,
    "KIOU_BR_HOOK_GET_SELF_PROFILE_MOVENEXT":    6,
    "KIOU_BR_HOOK_HTTPMSGINVOKER_SEND_ASYNC":    7,
}

ENTRY_SLOT_COUNT    = 8
ENTRY_SLOT_CAPACITY = 32

# ---------------------------------------------------------------------------
# Cave payload builders
# ---------------------------------------------------------------------------

def build_observer_cave(orig_va, slot_va, displaced_insn, hook_id):
    """Return a ``build(cave_va) -> bytes`` closure for an observer cave."""
    if len(displaced_insn) != 4:
        raise ValueError(f"displaced_insn must be 4 bytes; got {len(displaced_insn)}")
    if not (0 <= hook_id <= 0xFFFF):
        raise ValueError(f"hook_id out of MOVZ range: {hook_id}")

    def build(cave_va):
        out = bytearray()
        cur = cave_va

        def emit(insn):
            nonlocal cur
            out.extend(insn)
            cur += 4

        emit(stp_pre_x(29, 30, 31, -0x90))
        emit(stp_off_x(19, 20, 31, 0x10))
        emit(stp_off_x(21, 22, 31, 0x20))
        emit(stp_off_x(0, 1, 31, 0x30))
        emit(stp_off_x(2, 3, 31, 0x40))
        emit(stp_off_x(4, 5, 31, 0x50))
        emit(stp_off_x(6, 7, 31, 0x60))
        emit(add_x_imm(29, 31, 0))
        emit(adrp(16, cur, slot_va))
        emit(ldr_x_imm(16, 16, slot_va & 0xFFF))
        emit(movz_w_imm(6, hook_id))
        emit(blr_x(16))
        emit(ldp_off_x(6, 7, 31, 0x60))
        emit(ldp_off_x(4, 5, 31, 0x50))
        emit(ldp_off_x(2, 3, 31, 0x40))
        emit(ldp_off_x(0, 1, 31, 0x30))
        emit(ldp_off_x(21, 22, 31, 0x20))
        emit(ldp_off_x(19, 20, 31, 0x10))
        emit(ldp_post_x(29, 30, 31, 0x90))
        emit(displaced_insn)
        emit(b_imm(cur, orig_va + 4))

        assert len(out) == CAVE_PAYLOAD_SIZE
        return bytes(out)

    return build


_ENTRY_HEAD_INSNS = 7
_ENTRY_TAIL_BYTES = 8
_ENTRY_PAD_INSNS  = (CAVE_PAYLOAD_SIZE - _ENTRY_HEAD_INSNS * 4 - _ENTRY_TAIL_BYTES) // 4


def build_entry_cave(orig_va, slot_va, displaced_insn, slot_index):
    """Return a ``build(cave_va) -> bytes`` closure for an entry cave."""
    if len(displaced_insn) != 4:
        raise ValueError(f"displaced_insn must be 4 bytes; got {len(displaced_insn)}")
    if not (0 <= slot_index <= 0xFFFF):
        raise ValueError(f"slot_index out of MOVZ range: {slot_index}")

    def build(cave_va):
        out = bytearray()
        cur = cave_va

        def emit(insn):
            nonlocal cur
            out.extend(insn)
            cur += 4

        emit(stp_pre_x(29, 30, 31, -0x10))
        emit(adrp(16, cur, slot_va))
        emit(ldr_x_imm(16, 16, slot_va & 0xFFF))
        emit(movz_w_imm(9, slot_index))
        emit(blr_x(16))
        emit(ldp_post_x(29, 30, 31, 0x10))
        emit(ret_insn())
        for _ in range(_ENTRY_PAD_INSNS):
            emit(_NOP)
        emit(displaced_insn)
        emit(b_imm(cur, orig_va + 4))

        assert len(out) == CAVE_PAYLOAD_SIZE
        return bytes(out)

    return build


def payload_for_site(site, prologue_bytes, hook_id_name, kind, hook_slot_rva, entry_slot_base_rva):
    """Return the appropriate cave builder closure for a site row."""
    if kind == CAVE_OBSERVER:
        return build_observer_cave(
            site, hook_slot_rva, prologue_bytes, HOOK_IDS[hook_id_name]
        )
    if kind == CAVE_ENTRY:
        idx = ENTRY_SLOT_INDEX[hook_id_name]
        return build_entry_cave(site, entry_slot_base_rva + idx * 8, prologue_bytes, idx)
    raise AssertionError(f"unknown cave kind {kind!r}")


def build_exports(sites, afk_site, afk_orig_8, hook_slot_rva, entry_slot_base_rva):
    """Build PATCHES, CAVE_PATCHES, and _SITES from per-version data."""
    from tools.encode import mov_w0_imm_ret

    patches = [
        (
            afk_site,
            bytes.fromhex(afk_orig_8),
            mov_w0_imm_ret(0),
            "IsAfkEnabled: return false (MOVZ W0,#0; RET)",
        ),
    ]

    cave_patches = [
        (
            site,
            bytes.fromhex(prologue_hex),
            payload_for_site(
                site, bytes.fromhex(prologue_hex), hook_id_name, kind,
                hook_slot_rva, entry_slot_base_rva,
            ),
            f"{label}: route to Bridge {kind} cave ({hook_id_name})",
        )
        for site, prologue_hex, hook_id_name, kind, label in sites
    ]

    sites_index = [
        (HOOK_IDS[hook_id_name], site_rva, prologue_hex, label)
        for site_rva, prologue_hex, hook_id_name, kind, label in sites
    ]

    return patches, cave_patches, sites_index
