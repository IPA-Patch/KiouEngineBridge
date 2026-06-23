"""Recipe for KiouEngineBridge — Phase C binpatch.

Patches UnityFramework so that every observation/injection site
KiouEngineBridge cares about calls into ``KiouEngineBridge.dylib``
for the binpatch flavour.

## Multi-version support

All per-version constants (RVAs, slot addresses, cave region, AFK patch
bytes) live in ``_VERSIONS`` at the bottom of this file.  The active
version is selected by the ``KIOU_TARGET_VERSION`` environment variable::

    KIOU_TARGET_VERSION=1.0.2 make ipa

The Makefile's ``KIOU_VERSION`` variable sets this automatically, so
callers only need to pass ``KIOU_VERSION=1.0.2`` to make.  The variable
defaults to the most-recently-verified version (``1.0.1``) so existing
workflows are unaffected until 1.0.2 RVAs are filled in.

## Adding a new version

1. Run ``/dump`` to produce ``assets/<ver>/dump.cs.index.json``.
2. Run ``/verify-sites`` (or ``make verify-sites``) against the old recipe
   to find which RVAs changed.
3. Copy the ``"1.0.1"`` entry in ``_VERSIONS``, update every address, and
   set ``"build"`` to the new CFBundleVersion integer.
4. Set ``KIOU_TARGET_VERSION=<ver>`` and confirm ``make ipa`` succeeds.

See ``docs/plans/kiou_engine_bridge_binpatch.md`` for the full design.
"""

from __future__ import annotations

import os

from tools.encode import (
    add_x_imm,
    adrp,
    b_imm,
    blr_x,
    ldp_off_x,
    ldp_post_x,
    ldr_x_imm,
    mov_w0_imm_ret,
    movz_w_imm,
    ret_insn,
    stp_off_x,
    stp_pre_x,
)


# ---------------------------------------------------------------------------
# Target identification (version-independent)
# ---------------------------------------------------------------------------

TARGET_BASENAME = "UnityFramework"
DYLIB_PATH = "@executable_path/Frameworks/KiouEngineBridge.dylib"


# ---------------------------------------------------------------------------
# Info.plist additions (version-independent)
# ---------------------------------------------------------------------------

PLIST_KEYS: dict = {
    "UIFileSharingEnabled": True,
    "LSSupportsOpeningDocumentsInPlace": True,
}


# ---------------------------------------------------------------------------
# Hook ID enum — mirrors ``enum kiou_bridge_hook_id`` in Internal.h.
# Stable across versions unless new hooks are added.
# ---------------------------------------------------------------------------

_HOOK_IDS: dict[str, int] = {
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

# Entry slot indices — one per CAVE_ENTRY row, must mirror Internal.h.
_ENTRY_SLOT_INDEX_BY_HOOK: dict[str, int] = {
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
# Cave kinds
# ---------------------------------------------------------------------------

CAVE_OBSERVER = "observer"
CAVE_ENTRY    = "entry"

CAVE_PAYLOAD_SIZE = 84   # 21 arm64 instructions

_NOP = b"\x1f\x20\x03\xd5"


# ---------------------------------------------------------------------------
# Cave payload builders
# ---------------------------------------------------------------------------

def _build_bridge_cave_payload(orig_va, slot_va, displaced_insn, hook_id):
    """Observer cave: peek before orig, then run displaced prologue + B orig+4."""
    if len(displaced_insn) != 4:
        raise ValueError(f"displaced_insn must be 4 bytes; got {len(displaced_insn)}")
    if not (0 <= hook_id <= 0xFFFF):
        raise ValueError(f"hook_id out of MOVZ 16-bit range: {hook_id}")

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

        assert len(out) == CAVE_PAYLOAD_SIZE, f"observer cave wrong size: {len(out)}"
        return bytes(out)

    return build


_ENTRY_HEAD_INSNS = 7
_ENTRY_TAIL_BYTES = 8
_ENTRY_PAD_INSNS  = (CAVE_PAYLOAD_SIZE - _ENTRY_HEAD_INSNS * 4 - _ENTRY_TAIL_BYTES) // 4


def _build_entry_cave_payload(orig_va, slot_va, displaced_insn, slot_index):
    """Entry cave: replace orig — hook controls return value and calls bypass if needed."""
    if len(displaced_insn) != 4:
        raise ValueError(f"displaced_insn must be 4 bytes; got {len(displaced_insn)}")
    if not (0 <= slot_index <= 0xFFFF):
        raise ValueError(f"slot_index out of MOVZ 16-bit range: {slot_index}")

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

        assert len(out) == CAVE_PAYLOAD_SIZE, f"entry cave wrong size: {len(out)}"
        return bytes(out)

    return build


def _payload_for_row(site, prologue_bytes, hook_id_name, kind, hook_slot_rva, entry_slot_base_rva):
    if kind == CAVE_OBSERVER:
        return _build_bridge_cave_payload(
            site, hook_slot_rva, prologue_bytes, _HOOK_IDS[hook_id_name]
        )
    if kind == CAVE_ENTRY:
        slot_index = _ENTRY_SLOT_INDEX_BY_HOOK[hook_id_name]
        slot_va = entry_slot_base_rva + slot_index * 8
        return _build_entry_cave_payload(site, slot_va, prologue_bytes, slot_index)
    raise AssertionError(f"unknown cave kind {kind!r} for {hook_id_name}")


# ---------------------------------------------------------------------------
# Per-version data.
#
# Keys per version entry:
#   build                  int    CFBundleVersion integer
#   cave_region            tuple  (start_rva, end_exclusive_rva) for cave pool
#   hook_slot_rva          int    __DATA,__bss dispatcher slot (Bridge observer)
#   probed_hook_slot_rva   int    reserve_hook_slot() return value for this build
#   inject_entry_table_rva int    sibling slot table RVA (for diagnostics)
#   entry_slot_base_rva    int    base of per-hook entry slot table
#   zero_region_end_rva    int    exclusive end of verified-zero region for sanity check
#   afk_site               int    RVA of IsAfkEnabled
#   afk_orig_8             str    first 8 on-disk bytes of IsAfkEnabled (hex)
#   sites                  list   (rva, prologue_hex, hook_id_name, kind, label)
#
# To add 1.0.2:
#   1. Run ``/dump`` → assets/1.0.2/dump.cs.index.json
#   2. Run ``make verify-sites KIOU_VERSION=1.0.1`` to find drifted RVAs
#   3. Copy the "1.0.1" block, update every address, set build=12
# ---------------------------------------------------------------------------

_VERSIONS: dict[str, dict] = {
    "1.0.1": {
        "build": 11,
        "cave_region": (0x826A000, 0x826C000),
        "hook_slot_rva": 0x8F90CC0,
        "probed_hook_slot_rva": 0x8F90CD0,
        "inject_entry_table_rva": 0x8F90C00,
        "entry_slot_base_rva": 0x091E91B8,
        "zero_region_end_rva": 0x091E93B8,
        "afk_site": 0x59455D4,
        "afk_orig_8": "f44fbea9fd7b01a9",
        "sites": [
            # fmt: off
            # OnMatchEndAsync × 5
            (0x59E5958, "f657bda9", "KIOU_BR_HOOK_AI_END",        CAVE_OBSERVER, "AIMatchMode.OnMatchEndAsync"),
            (0x59EC818, "ff8301d1", "KIOU_BR_HOOK_CPUSTREAM_END", CAVE_OBSERVER, "CPUStreamMode.OnMatchEndAsync"),
            (0x59FF8F8, "f44fbea9", "KIOU_BR_HOOK_LOCAL_END",     CAVE_OBSERVER, "LocalPvPMode.OnMatchEndAsync"),
            (0x5A0139C, "ff8301d1", "KIOU_BR_HOOK_ONLINE_END",    CAVE_OBSERVER, "OnlinePvPMode.OnMatchEndAsync"),
            (0x5A2B564, "f85fbca9", "KIOU_BR_HOOK_REPLAY_END",    CAVE_OBSERVER, "RecordReplayMode.OnMatchEndAsync"),

            # InitializeAsync × 5
            (0x59E4E0C, "e923ba6d", "KIOU_BR_HOOK_AI_INIT",        CAVE_OBSERVER, "AIMatchMode.InitializeAsync"),
            (0x59E7B48, "ff8302d1", "KIOU_BR_HOOK_CPUSTREAM_INIT", CAVE_OBSERVER, "CPUStreamMode.InitializeAsync"),
            (0x59FF7B0, "f657bda9", "KIOU_BR_HOOK_LOCAL_INIT",     CAVE_OBSERVER, "LocalPvPMode.InitializeAsync"),
            (0x5A00E90, "ff8302d1", "KIOU_BR_HOOK_ONLINE_INIT",    CAVE_OBSERVER, "OnlinePvPMode.InitializeAsync"),
            (0x5A2ADD0, "ff0301d1", "KIOU_BR_HOOK_REPLAY_INIT",    CAVE_OBSERVER, "RecordReplayMode.InitializeAsync"),

            # OnPlayerMoveAsync × 5
            (0x59E5268, "ffc301d1", "KIOU_BR_HOOK_AI_OPM",        CAVE_OBSERVER, "AIMatchMode.OnPlayerMoveAsync"),
            (0x59E886C, "ffc301d1", "KIOU_BR_HOOK_CPUSTREAM_OPM", CAVE_OBSERVER, "CPUStreamMode.OnPlayerMoveAsync"),
            (0x59FF87C, "f44fbea9", "KIOU_BR_HOOK_LOCAL_OPM",     CAVE_OBSERVER, "LocalPvPMode.OnPlayerMoveAsync"),
            (0x5A012D8, "ffc301d1", "KIOU_BR_HOOK_ONLINE_OPM",    CAVE_OBSERVER, "OnlinePvPMode.OnPlayerMoveAsync"),
            (0x5A2B3EC, "ff0301d1", "KIOU_BR_HOOK_REPLAY_OPM",    CAVE_OBSERVER, "RecordReplayMode.OnPlayerMoveAsync"),

            # OnMatchStart × 5
            (0x59E5000, "f85fbca9", "KIOU_BR_HOOK_AI_START",        CAVE_OBSERVER, "AIMatchMode.OnMatchStart"),
            (0x59E7D64, "fa67bba9", "KIOU_BR_HOOK_CPUSTREAM_START", CAVE_OBSERVER, "CPUStreamMode.OnMatchStart"),
            (0x59FF878, "c0035fd6", "KIOU_BR_HOOK_LOCAL_START",     CAVE_OBSERVER, "LocalPvPMode.OnMatchStart"),
            (0x59FFE3C, "f657bda9", "KIOU_BR_HOOK_ONLINE_START",    CAVE_OBSERVER, "OnlinePvPMode.OnMatchStart"),
            (0x5A2B36C, "f657bda9", "KIOU_BR_HOOK_REPLAY_START",    CAVE_OBSERVER, "RecordReplayMode.OnMatchStart"),

            # Single-site observation hooks
            (0x59D0DFC, "ff8301d1", "KIOU_BR_HOOK_ADAPTER_TRY_MAKE_MOVE_OUT", CAVE_OBSERVER, "ShogiGameAdapter.TryMakeMove(Move,out)"),
            (0x5A0A64C, "e923bc6d", "KIOU_BR_HOOK_ONLINE_UPDATE_SNAPSHOT",    CAVE_OBSERVER, "OnlinePvPMode.UpdateAuthoritativeSnapshot"),
            (0x5A0CBD0, "ff0302d1", "KIOU_BR_HOOK_ONLINE_HANDLE_RESULT",      CAVE_OBSERVER, "OnlinePvPMode.HandleMoveResult"),
            (0x59EB0E0, "e923bc6d", "KIOU_BR_HOOK_CPUSTREAM_UPDATE_SNAPSHOT", CAVE_OBSERVER, "CPUStreamMode.UpdateAuthoritativeSnapshot"),
            (0x5944E84, "ff4302d1", "KIOU_BR_HOOK_GAMEORCH_ACTIVATE",         CAVE_OBSERVER, "GameOrchestrator.ActivateAsync"),

            # GameStateStore hooks
            (0x5A2CB64, "f44fbea9", "KIOU_BR_HOOK_GSTATE_SET_BLACK_PLAYER_INFO", CAVE_OBSERVER, "GameStateStore.SetBlackPlayerInfo"),
            (0x5A2CBA0, "f44fbea9", "KIOU_BR_HOOK_GSTATE_SET_WHITE_PLAYER_INFO", CAVE_OBSERVER, "GameStateStore.SetWhitePlayerInfo"),
            (0x5A2CD24, "ff4301d1", "KIOU_BR_HOOK_GSTATE_NOTIFY_PIECE_MOVED",    CAVE_OBSERVER, "GameStateStore.NotifyPieceMoved"),

            # Account identity — CAVE_ENTRY: hook controls bool return
            (0x591E860, "fd7bbfa9", "KIOU_BR_HOOK_ACCOUNT_EXISTS",          CAVE_ENTRY, "UserSaveDataExtensions.AccountExists"),

            # Account switching — CAVE_ENTRY: hook swaps deviceId / distinctId args
            (0x5B9899C, "f657bda9", "KIOU_BR_HOOK_LOGIN_ARGS_CREATE",         CAVE_ENTRY, "ILoginArgs.Create"),
            (0x5B98A2C, "f657bda9", "KIOU_BR_HOOK_REGISTER_USER_ARGS_CREATE", CAVE_ENTRY, "IRegisterUserArgs.Create"),

            # Matching filter — CAVE_ENTRY (seat filter needs post-orig read)
            (0x5D04E94, "ff0301d1", "KIOU_BR_HOOK_GET_VALID_MATCH_FOUND_STATUS", CAVE_ENTRY,    "GetValidMatchFoundStatus"),
            (0x5BCA664, "fc6fbaa9", "KIOU_BR_HOOK_MATCH_STREAM_ARGS_CREATE",     CAVE_ENTRY,    "IShogiMatchStreamArgs.Create"),
            (0x5D06B10, "ff0303d1", "KIOU_BR_HOOK_RECEIVE_TIMEOUT_MOVENEXT",     CAVE_OBSERVER, "MatchingHandler.ReceiveWithTimeoutAsync.MoveNext"),

            # Async MoveNext post-orig observers — CAVE_ENTRY
            (0x5812534, "ff8302d1", "KIOU_BR_HOOK_RUN_LOGIN_SEQ_MOVENEXT",    CAVE_ENTRY, "RunLoginSequenceAsync.MoveNext"),
            (0x5BB4774, "ff4302d1", "KIOU_BR_HOOK_GET_SELF_PROFILE_MOVENEXT", CAVE_ENTRY, "GetSelfUserProfileAsync.MoveNext"),

            # HttpMessageInvoker.SendAsync vtable thunk
            (0x607C974, "000840f9", "KIOU_BR_HOOK_HTTPMSGINVOKER_SEND_ASYNC", CAVE_ENTRY, "HttpMessageInvoker.SendAsync"),
            # fmt: on
        ],
    },

    # -----------------------------------------------------------------------
    # 1.0.2 (CFBundleVersion 12)
    # RVAs verified against assets/1.0.2/dump.cs.index.json on 2026-06-23.
    # Slot addresses (__bss / __common zero-fill) are identical to 1.0.1:
    #   __bss   1.0.2: 0x8E83340 .. 0x8F9D4C0  (hook/entry slots well inside)
    #   __common 1.0.2: 0x8F9D4C0 .. 0x91F5978  (entry slot base fits)
    # -----------------------------------------------------------------------
    "1.0.2": {
        "build": 12,
        "cave_region": (0x826A000, 0x826C000),
        "hook_slot_rva": 0x8F90CC0,
        "probed_hook_slot_rva": 0x8F9D4B8,
        "inject_entry_table_rva": 0x8F90C00,
        "entry_slot_base_rva": 0x091E91B8,
        "zero_region_end_rva": 0x091F5978,
        "afk_site": 0x594A034,
        "afk_orig_8": "f44fbea9fd7b01a9",
        "sites": [
            # fmt: off
            # OnMatchEndAsync × 5
            (0x59EA720, "f657bda9", "KIOU_BR_HOOK_AI_END",        CAVE_OBSERVER, "AIMatchMode.OnMatchEndAsync"),
            (0x59F15D4, "ff8301d1", "KIOU_BR_HOOK_CPUSTREAM_END", CAVE_OBSERVER, "CPUStreamMode.OnMatchEndAsync"),
            (0x5A046B4, "f44fbea9", "KIOU_BR_HOOK_LOCAL_END",     CAVE_OBSERVER, "LocalPvPMode.OnMatchEndAsync"),
            (0x5A06158, "ff8301d1", "KIOU_BR_HOOK_ONLINE_END",    CAVE_OBSERVER, "OnlinePvPMode.OnMatchEndAsync"),
            (0x5A30320, "f85fbca9", "KIOU_BR_HOOK_REPLAY_END",    CAVE_OBSERVER, "RecordReplayMode.OnMatchEndAsync"),

            # InitializeAsync × 5
            (0x59E9BD4, "e923ba6d", "KIOU_BR_HOOK_AI_INIT",        CAVE_OBSERVER, "AIMatchMode.InitializeAsync"),
            (0x59EC910, "ff8302d1", "KIOU_BR_HOOK_CPUSTREAM_INIT", CAVE_OBSERVER, "CPUStreamMode.InitializeAsync"),
            (0x5A0456C, "f657bda9", "KIOU_BR_HOOK_LOCAL_INIT",     CAVE_OBSERVER, "LocalPvPMode.InitializeAsync"),
            (0x5A05C4C, "ff8302d1", "KIOU_BR_HOOK_ONLINE_INIT",    CAVE_OBSERVER, "OnlinePvPMode.InitializeAsync"),
            (0x5A2FB8C, "ff0301d1", "KIOU_BR_HOOK_REPLAY_INIT",    CAVE_OBSERVER, "RecordReplayMode.InitializeAsync"),

            # OnPlayerMoveAsync × 5
            (0x59EA030, "ffc301d1", "KIOU_BR_HOOK_AI_OPM",        CAVE_OBSERVER, "AIMatchMode.OnPlayerMoveAsync"),
            (0x59ED634, "ffc301d1", "KIOU_BR_HOOK_CPUSTREAM_OPM", CAVE_OBSERVER, "CPUStreamMode.OnPlayerMoveAsync"),
            (0x5A04638, "f44fbea9", "KIOU_BR_HOOK_LOCAL_OPM",     CAVE_OBSERVER, "LocalPvPMode.OnPlayerMoveAsync"),
            (0x5A06094, "ffc301d1", "KIOU_BR_HOOK_ONLINE_OPM",    CAVE_OBSERVER, "OnlinePvPMode.OnPlayerMoveAsync"),
            (0x5A301A8, "ff0301d1", "KIOU_BR_HOOK_REPLAY_OPM",    CAVE_OBSERVER, "RecordReplayMode.OnPlayerMoveAsync"),

            # OnMatchStart × 5
            (0x59E9DC8, "f85fbca9", "KIOU_BR_HOOK_AI_START",        CAVE_OBSERVER, "AIMatchMode.OnMatchStart"),
            (0x59ECB2C, "fa67bba9", "KIOU_BR_HOOK_CPUSTREAM_START", CAVE_OBSERVER, "CPUStreamMode.OnMatchStart"),
            (0x5A04634, "c0035fd6", "KIOU_BR_HOOK_LOCAL_START",     CAVE_OBSERVER, "LocalPvPMode.OnMatchStart"),
            (0x5A04BF8, "f657bda9", "KIOU_BR_HOOK_ONLINE_START",    CAVE_OBSERVER, "OnlinePvPMode.OnMatchStart"),
            (0x5A30128, "f657bda9", "KIOU_BR_HOOK_REPLAY_START",    CAVE_OBSERVER, "RecordReplayMode.OnMatchStart"),

            # Single-site observation hooks
            # TryMakeMove: label uses bare method name (no arg list) so
            # verify_sites _sig_matches finds ' TryMakeMove(' in the sig.
            (0x59D5BC0, "ff8301d1", "KIOU_BR_HOOK_ADAPTER_TRY_MAKE_MOVE_OUT", CAVE_OBSERVER, "ShogiGameAdapter.TryMakeMove"),
            (0x5A0F408, "e923bc6d", "KIOU_BR_HOOK_ONLINE_UPDATE_SNAPSHOT",    CAVE_OBSERVER, "OnlinePvPMode.UpdateAuthoritativeSnapshot"),
            (0x5A1198C, "ff0302d1", "KIOU_BR_HOOK_ONLINE_HANDLE_RESULT",      CAVE_OBSERVER, "OnlinePvPMode.HandleMoveResult"),
            (0x59EFE9C, "e923bc6d", "KIOU_BR_HOOK_CPUSTREAM_UPDATE_SNAPSHOT", CAVE_OBSERVER, "CPUStreamMode.UpdateAuthoritativeSnapshot"),
            (0x59498E4, "ff4302d1", "KIOU_BR_HOOK_GAMEORCH_ACTIVATE",         CAVE_OBSERVER, "GameOrchestrator.ActivateAsync"),

            # GameStateStore hooks
            (0x5A31920, "f44fbea9", "KIOU_BR_HOOK_GSTATE_SET_BLACK_PLAYER_INFO", CAVE_OBSERVER, "GameStateStore.SetBlackPlayerInfo"),
            (0x5A3195C, "f44fbea9", "KIOU_BR_HOOK_GSTATE_SET_WHITE_PLAYER_INFO", CAVE_OBSERVER, "GameStateStore.SetWhitePlayerInfo"),
            (0x5A31AE0, "ff4301d1", "KIOU_BR_HOOK_GSTATE_NOTIFY_PIECE_MOVED",    CAVE_OBSERVER, "GameStateStore.NotifyPieceMoved"),

            # Account identity — CAVE_ENTRY
            (0x5922CD0, "fd7bbfa9", "KIOU_BR_HOOK_ACCOUNT_EXISTS",          CAVE_ENTRY, "UserSaveDataExtensions.AccountExists"),

            # Account switching — CAVE_ENTRY
            (0x5B9DC04, "f657bda9", "KIOU_BR_HOOK_LOGIN_ARGS_CREATE",         CAVE_ENTRY, "ILoginArgs.Create"),
            (0x5B9DC94, "f657bda9", "KIOU_BR_HOOK_REGISTER_USER_ARGS_CREATE", CAVE_ENTRY, "IRegisterUserArgs.Create"),

            # Matching filter — CAVE_ENTRY
            # State machine type in 1.0.2: MatchingHandler.<ReceiveWithTimeoutAsync>d__6
            # '+' marks the nested boundary for verify_sites split_label.
            (0x5D0A78C, "ff0301d1", "KIOU_BR_HOOK_GET_VALID_MATCH_FOUND_STATUS", CAVE_ENTRY,    "GetValidMatchFoundStatus"),
            (0x5BCF8CC, "fc6fbaa9", "KIOU_BR_HOOK_MATCH_STREAM_ARGS_CREATE",     CAVE_ENTRY,    "IShogiMatchStreamArgs.Create"),
            (0x5D0C408, "ff0303d1", "KIOU_BR_HOOK_RECEIVE_TIMEOUT_MOVENEXT",     CAVE_OBSERVER, "MatchingHandler+<ReceiveWithTimeoutAsync>d__6.MoveNext"),

            # Async MoveNext post-orig observers — CAVE_ENTRY
            # State machine types in 1.0.2:
            #   AuthServiceExtensions.<RunLoginSequenceAsync>d__1
            #   GameService.<GetSelfUserProfileAsync>d__36
            (0x58152BC, "ff8302d1", "KIOU_BR_HOOK_RUN_LOGIN_SEQ_MOVENEXT",    CAVE_ENTRY, "AuthServiceExtensions+<RunLoginSequenceAsync>d__1.MoveNext"),
            (0x5BB99DC, "ff4302d1", "KIOU_BR_HOOK_GET_SELF_PROFILE_MOVENEXT", CAVE_ENTRY, "GameService+<GetSelfUserProfileAsync>d__36.MoveNext"),

            # HttpMessageInvoker.SendAsync vtable thunk
            (0x6082AC0, "000840f9", "KIOU_BR_HOOK_HTTPMSGINVOKER_SEND_ASYNC", CAVE_ENTRY, "HttpMessageInvoker.SendAsync"),
            # fmt: on
        ],
    },
}

# Default: latest version whose data is complete.
_DEFAULT_VERSION = "1.0.1"


# ---------------------------------------------------------------------------
# Version selection and export
# ---------------------------------------------------------------------------

_target_version = os.environ.get("KIOU_TARGET_VERSION", _DEFAULT_VERSION)
_vdata = _VERSIONS.get(_target_version)

if _vdata is None:
    _known = [v for v, d in _VERSIONS.items() if d is not None]
    raise ImportError(
        f"KIOU version {_target_version!r} is not yet implemented in the recipe.\n"
        f"  Known versions: {_known}\n"
        f"  Set KIOU_TARGET_VERSION to one of those, or fill in the {_target_version!r} "
        "entry in recipes/kiouenginebridge.py."
    )

# Validate slot reservation fits in the zero region.
_esr = _vdata["entry_slot_base_rva"]
_zend = _vdata["zero_region_end_rva"]
assert _esr + ENTRY_SLOT_CAPACITY * 8 <= _zend, (
    f"entry slot reservation overflows verified-zero region: "
    f"0x{_esr + ENTRY_SLOT_CAPACITY * 8:X} > 0x{_zend:X}"
)
assert len(_ENTRY_SLOT_INDEX_BY_HOOK) == ENTRY_SLOT_COUNT

# Public recipe exports consumed by patch_macho / verify_sites.
CAVE_REGION          = _vdata["cave_region"]
HOOK_SLOT_RVA        = _vdata["hook_slot_rva"]
PROBED_HOOK_SLOT_RVA = _vdata["probed_hook_slot_rva"]
INJECT_ENTRY_TABLE_RVA       = _vdata["inject_entry_table_rva"]
PROBED_INJECT_ENTRY_TABLE_RVA = _vdata["inject_entry_table_rva"]
ENTRY_SLOT_BASE_RVA  = _vdata["entry_slot_base_rva"]

_afk_site    = _vdata["afk_site"]
_afk_orig_8  = bytes.fromhex(_vdata["afk_orig_8"])
_afk_new_8   = mov_w0_imm_ret(0)

PATCHES: list = [
    (
        _afk_site,
        _afk_orig_8,
        _afk_new_8,
        "IsAfkEnabled: return false (MOVZ W0,#0; RET)",
    ),
]

_bridge_sites = _vdata["sites"]

CAVE_PATCHES: list = [
    (
        site,
        bytes.fromhex(prologue_hex),
        _payload_for_row(
            site,
            bytes.fromhex(prologue_hex),
            hook_id_name,
            kind,
            HOOK_SLOT_RVA,
            ENTRY_SLOT_BASE_RVA,
        ),
        f"{label}: route to Bridge {kind} cave ({hook_id_name})",
    )
    for site, prologue_hex, hook_id_name, kind, label in _bridge_sites
]

# verify_sites-compatible view: (slot_index, site_rva, prologue_hex, label)
_SITES: list[tuple[int, int, str, str]] = [
    (_HOOK_IDS[hook_id_name], site_rva, prologue_hex, label)
    for site_rva, prologue_hex, hook_id_name, kind, label in _bridge_sites
]
