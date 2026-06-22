"""Recipe for KiouEngineBridge — Phase C binpatch.

Patches UnityFramework so that every observation/injection site
KiouEngineBridge cares about (the 5 IMatchMode methods × 4 verbs plus
the GameOrchestrator / OnlinePvP / CPUStream snapshot sites) calls into
``KiouEngineBridge.dylib`` for the binpatch flavour. The dylib is loaded
automatically via ``LC_LOAD_DYLIB``; its constructor publishes a single
dispatcher function pointer into a reserved ``__bss`` slot, and each
cave loads that pointer and calls it with a per-site ``hook_id`` in W6.

How the patch chain works (see ``docs/plans/kiou_engine_bridge_binpatch.md``
for the full design):

  1. Add an ``LC_LOAD_DYLIB`` pointing at
     ``@executable_path/Frameworks/KiouEngineBridge.dylib`` so dyld
     auto-loads the Bridge dylib on app launch.
  2. Reserve an 8-byte slot in ``__bss`` (the SLOT) that the dylib
     constructor fills with its dispatcher function pointer. Writing to
     ``__DATA`` does not trigger CSM on iOS 18.
  3. For every Bridge observation site (21 entries) replace the
     prologue's first 4 bytes with ``B <cave>``. Each cave saves
     registers, materialises the SLOT address, loads the dispatcher,
     stuffs the site's ``hook_id`` into W6, calls the dispatcher,
     restores registers, runs the displaced prologue verbatim, and
     branches to ``orig + 4``. ``W6`` is used instead of ``W2`` because
     several Bridge hook sites (``OnPlayerMoveAsync``,
     ``UpdateAuthoritativeSnapshot``, ``Adapter.TryMakeMove``) carry a
     real argument in ``X2``; routing the hook id through ``X6`` keeps
     ``X2`` available for forwarding to the dispatcher.
  4. The single inline patch is ``IsAfkEnabled``: an 8-byte
     ``MOVZ W0, #0; RET`` replacement that turns the AFK check into a
     constant ``false``. The patch clobbers the second instruction of
     the original prologue (``STP X29, X30, [SP, #0x10]``) but execution
     never reaches it because the RET fires immediately.

This recipe is consumed by ``tools.patch_macho`` together with the
generic primitives in ``tools.encode``, ``tools.machoops``, and
``tools.caves``. KiouKifExporter consumes the front half of the
``__oslogstring`` zero-fill (``0x8268024 .. 0x826A000``); Bridge takes
the back half (``0x826A000 .. 0x826C000``) so both recipes can be
applied to the same UnityFramework without colliding.
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
    mov_w0_imm_ret,
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
# Code-cave region.
#
# UnityFramework's ``__TEXT,__oslogstring`` ends with a multi-KB zero-fill
# inside the same r-x mapping as every other instruction. KiouKifExporter
# carves caves out of the front of that range (``0x8268024 .. 0x826C000``,
# 5 × 84 B = 420 B used of 16 348 B available). Bridge needs ~21 caves at
# 84 B each = 1764 B. To keep the two recipes region-disjoint so they can
# coexist on the same Mach-O, Bridge claims the **back half** of the
# zero-fill (``0x826A000 .. 0x826C000``, 8 KB) and KifExporter keeps the
# front. See docs/plans/kiou_engine_bridge_binpatch.md § 8 for the
# partition rationale.
# ---------------------------------------------------------------------------

CAVE_REGION = (0x826A000, 0x826C000)  # (start, end exclusive)


# ---------------------------------------------------------------------------
# Hook slot.
#
# The dylib constructor publishes its dispatcher function pointer into
# this 8-byte slot inside __DATA,__bss. ``reserve_hook_slot()`` against
# the freshly extracted Kiou-1.0.1 build 11 UnityFramework returns
# ``0x8F90CD0`` (the section tail) — that's the slot KifExporter pins.
# Bridge needs a different slot at least 8 bytes away; we subtract 16
# bytes to land at ``0x8F90CC0`` (validated via ``assert_slot_in_bss``).
# If a future UnityFramework changes the __bss layout, re-run
# reserve_hook_slot() and update PROBED_HOOK_SLOT_RVA plus this sibling
# constant.
# ---------------------------------------------------------------------------

INJECT_ENTRY_TABLE_RVA = 0x8F90C00
HOOK_SLOT_RVA = 0x8F90CC0
PROBED_HOOK_SLOT_RVA = 0x8F90CD0

# Entry caves (KiouForge-style) use a separate slot table — each entry hook
# gets a dedicated 8-byte slot the dylib publishes its function pointer
# into, so the cave can BLR straight into it without touching the observer
# dispatcher.
#
# UnityFramework (Kiou-1.0.1 build 11) __DATA layout:
#   __bss     0x08E76B80 .. 0x08F90CD8 (1.1 MB, zero-fill)
#   __common  0x08F90D00 .. 0x091E91B8 (2.4 MB, zero-fill)
#
# The original revision placed the entry slot table at PROBED_HOOK_SLOT_RVA
# (= 0x8F90CD0), which is the last 8 bytes of __bss — fine for a single
# slot but slot[1+] silently fell into the 40-byte padding between __bss
# and __common. Both regions are zero-fill so dyld didn't catch it, but
# the placement is technically out-of-section and only the per-slot
# assert_slot_in_bss check below would have flagged it.
#
# We move the table into the __common tail instead and reserve a generous
# 32-slot capacity (256 B), giving room to add more entry-class hooks
# without revisiting this constant. The recipe also asserts every slot in
# the table — not just the first — sits inside __bss or __common.
ENTRY_SLOT_COUNT    = 9      # currently published; bump alongside the dylib enum
ENTRY_SLOT_CAPACITY = 32     # 256 B reserved at ENTRY_SLOT_BASE_RVA
# 0x091E90B8 (former placement) turned out to hold a KIOU bitmask table
# written at runtime; frida dump confirmed 0x091E91B8..0x091E92B8 is all
# zero both before and after login. Place the slot table there instead.
ENTRY_SLOT_BASE_RVA = 0x091E91B8  # first confirmed-zero word past __common

# Static sanity bound — the region must stay zero-filled at runtime.
# Verified by frida MemoryAccessMonitor on Kiou-1.0.1 build 11:
# 0x091E91B8..0x091E93B0 read all zeros after a full login sequence.
_ZERO_REGION_END_RVA = 0x091E93B8  # conservative: 512 B past ENTRY_SLOT_BASE_RVA
assert (
    ENTRY_SLOT_BASE_RVA + ENTRY_SLOT_CAPACITY * 8 <= _ZERO_REGION_END_RVA
), (
    f"entry slot reservation overflows verified-zero region: "
    f"0x{ENTRY_SLOT_BASE_RVA + ENTRY_SLOT_CAPACITY * 8:X} > "
    f"0x{_ZERO_REGION_END_RVA:X}. Pick a lower ENTRY_SLOT_BASE_RVA or "
    "reduce ENTRY_SLOT_CAPACITY."
)
assert ENTRY_SLOT_COUNT <= ENTRY_SLOT_CAPACITY, (
    f"ENTRY_SLOT_COUNT ({ENTRY_SLOT_COUNT}) exceeds reserved capacity "
    f"({ENTRY_SLOT_CAPACITY}). Bump ENTRY_SLOT_CAPACITY *and* the recipe's "
    "_COMMON_SECTION_END_RVA check above."
)

# Must stay inside __DATA,__bss and leave room for at least 32 8-byte entries.
# Runtime code reconstructs the actual bypass entry VAs from the cave geometry,
# but we still pin and validate the sibling table RVA here so future recipe /
# dylib changes have a reviewed address reservation to target.
PROBED_INJECT_ENTRY_TABLE_RVA = INJECT_ENTRY_TABLE_RVA


# ---------------------------------------------------------------------------
# Hook ID enum — must mirror ``enum kiou_bridge_hook_id`` in
# Sources/KiouEngineBridge/Internal.h. The dispatcher in
# BinpatchDispatcher.m switches on this value, so the recipe's caves and
# the dylib's dispatcher MUST agree on the integer mapping. Phase B owns
# the enum declaration; this dict is the recipe-side mirror so the recipe
# can be authored before Phase B's header lands. If you renumber the
# enum, renumber this dict in lockstep.
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
    "KIOU_BR_HOOK_MONO_SEND_ASYNC": 37,
}


# ---------------------------------------------------------------------------
# Cave payload builder.
#
# Cave shape (21 insns = 84 bytes), see
# docs/plans/kiou_engine_bridge_binpatch.md § 6 Phase C:
#
#     STP X29, X30, [SP, #-0x90]!
#     STP X19, X20, [SP, #0x10]
#     STP X21, X22, [SP, #0x20]
#     STP X0,  X1,  [SP, #0x30]   ; save args (self, arg1)
#     STP X2,  X3,  [SP, #0x40]
#     STP X4,  X5,  [SP, #0x50]
#     STP X6,  X7,  [SP, #0x60]   ; (X6 saved before we clobber it)
#     MOV X29, SP
#     ADRP X16, page(SLOT)
#     LDR  X16, [X16, #lo12(SLOT)]
#     MOVZ W6, #hook_id           ; pass hook id via W6 (no real arg lives there)
#     BLR  X16                    ; dispatcher(x0..x5, hook_id_in_x6, x7) via SLOT
#     LDP  X6,  X7,  [SP, #0x60]  ; restore X6/X7 before resuming orig
#     LDP  X4,  X5,  [SP, #0x50]
#     LDP  X2,  X3,  [SP, #0x40]
#     LDP  X0,  X1,  [SP, #0x30]
#     LDP  X21, X22, [SP, #0x20]
#     LDP  X19, X20, [SP, #0x10]
#     LDP  X29, X30, [SP], #0x90
#     <displaced prologue insn>   ; verbatim, must be PC-independent
#     B    <orig + 4>
#
# Hook id is loaded into W6 instead of W2 because several Bridge hook
# sites carry a real argument in X2 (``OnPlayerMoveAsync(self, mv, ct)``
# uses X2 for ``ct``; ``UpdateAuthoritativeSnapshot`` uses W2 for
# ``turn``; ``Adapter.TryMakeMove(Move, out)`` uses X2 for the out
# pointer). The dispatcher needs to forward those values to the C hook
# bodies, so the cave must keep X2 holding the real call-site argument
# when ``BLR X16`` is executed. X6 is unused at entry by every site in
# this recipe — all of them take at most six integer-class arguments.
# X6/X7 are still saved/restored across the BLR so the displaced
# prologue and ``B orig+4`` resume with the original register state.
# ---------------------------------------------------------------------------

CAVE_PAYLOAD_SIZE = 84  # 21 instructions

# Cave kinds — Bridge supports two cave shapes:
#
#   "observer" : peek BEFORE orig runs (Bridge's original cave shape).
#                Routes through the dispatcher slot at HOOK_SLOT_RVA with
#                the per-site hook_id in W6. The hook's return value is
#                discarded — orig executes afterwards via the displaced
#                prologue + B orig+4. Used for all 28 existing sites.
#
#   "entry"    : REPLACE the original (KiouForge-style). The cave reads
#                the per-site hook fn ptr from its dedicated entry slot,
#                BLRs it, then RETs — orig is NOT executed by the cave.
#                The hook is responsible for invoking orig itself when it
#                wants the original behavior, via the cave-bypass entry
#                exposed at cave_va + KIOU_BR_CAVE_BYPASS_OFFSET.
#                Used for AccountExists so Force Register can flip the
#                bool return on chinlan.
#
# To add a new cave kind: write `_build_<kind>_cave_payload(...)` returning
# a `build(cave_va) -> bytes` closure, then add it to `_CAVE_BUILDERS`.
CAVE_OBSERVER = "observer"
CAVE_ENTRY    = "entry"

# Single NOP instruction (arm64 little-endian).
_NOP = b"\x1f\x20\x03\xd5"


def _build_bridge_cave_payload(
    orig_va: int, slot_va: int, displaced_insn: bytes, hook_id: int
):
    """Return a ``build_payload(cave_va) -> bytes`` closure for one site.

    Parameters
    ----------
    orig_va : int
        VA of the prologue instruction that will be replaced with
        ``B <cave_va>``. The cave trampolines back to ``orig_va + 4``
        after executing the displaced prologue insn locally.
    slot_va : int
        VA of the 8-byte __bss slot the dylib constructor publishes the
        dispatcher pointer into.
    displaced_insn : bytes
        The 4 prologue bytes about to be overwritten. Must be
        PC-independent (STP pre-index, SUB SP, or RET).
    hook_id : int
        Identifier from ``enum kiou_bridge_hook_id``. Loaded into W6
        before BLR so the dispatcher can switch on it without
        clobbering any caller-supplied argument register.
    """
    if len(displaced_insn) != 4:
        raise ValueError(
            f"displaced_insn must be exactly 4 bytes; got {len(displaced_insn)}"
        )
    if not (0 <= hook_id <= 0xFFFF):
        raise ValueError(f"hook_id out of MOVZ 16-bit range: {hook_id}")

    def build(cave_va: int) -> bytes:
        out = bytearray()
        cur = cave_va

        def emit(insn: bytes) -> None:
            nonlocal cur
            out.extend(insn)
            cur += 4

        # --- prologue: save LR, callee-saved scratch, and arg registers ---
        emit(stp_pre_x(29, 30, 31, -0x90))
        emit(stp_off_x(19, 20, 31, 0x10))
        emit(stp_off_x(21, 22, 31, 0x20))
        emit(stp_off_x(0, 1, 31, 0x30))
        emit(stp_off_x(2, 3, 31, 0x40))
        emit(stp_off_x(4, 5, 31, 0x50))
        emit(stp_off_x(6, 7, 31, 0x60))
        # MOV X29, SP. arm64 has no register-to-register MOV that touches
        # SP; the canonical encoding is `ADD X29, SP, #0`, which the
        # disassembler renders as `MOV X29, SP`.
        emit(add_x_imm(29, 31, 0))

        # --- materialize SLOT address; load the published dispatcher pointer ---
        emit(adrp(16, cur, slot_va))
        emit(ldr_x_imm(16, 16, slot_va & 0xFFF))

        # --- pass the hook id to the dispatcher via X6 ---
        emit(movz_w_imm(6, hook_id))

        emit(blr_x(16))

        # --- restore ---
        emit(ldp_off_x(6, 7, 31, 0x60))
        emit(ldp_off_x(4, 5, 31, 0x50))
        emit(ldp_off_x(2, 3, 31, 0x40))
        emit(ldp_off_x(0, 1, 31, 0x30))
        emit(ldp_off_x(21, 22, 31, 0x20))
        emit(ldp_off_x(19, 20, 31, 0x10))
        emit(ldp_post_x(29, 30, 31, 0x90))

        # --- execute the displaced prologue insn verbatim ---
        emit(displaced_insn)

        # --- branch to (orig + 4) ---
        emit(b_imm(cur, orig_va + 4))

        if len(out) != CAVE_PAYLOAD_SIZE:
            raise AssertionError(
                f"cave payload wrong size: got {len(out)}, expected {CAVE_PAYLOAD_SIZE}"
            )
        return bytes(out)

    return build


# ---------------------------------------------------------------------------
# Entry cave payload builder.
#
# Cave shape (21 insns = 84 bytes), modelled on KiouForge's entry cave:
#
#     STP X29, X30, [SP, #-0x10]!
#     ADRP X16, page(slot_va)
#     LDR  X16, [X16, #lo12(slot_va)]
#     MOVZ W9,  #slot_index             ; passed for diagnostics; hook may ignore
#     BLR  X16                          ; hook(x0..x7) — return value lives in x0
#     LDP  X29, X30, [SP], #0x10
#     RET                               ; orig is NOT invoked by the cave
#     NOP × 12                          ; padding so the bypass tail stays at +0x4C
#     <displaced prologue insn>         ; reachable only when the hook BLs
#     B    <orig + 4>                   ; the bypass entry (cave_va + 0x4C)
#
# Caller registers (x0..x7) reach the hook unchanged because nothing between
# the cave entry and BLR touches them. The hook decides:
#   * return its own value -> cave RETs straight back to the call site
#   * invoke the bypass entry (cave_va + 0x4C) as a function pointer to run
#     orig and forward its return.
# ---------------------------------------------------------------------------

# Last two instructions (displaced + B orig+4) occupy 8 bytes at the tail,
# matching the observer cave's geometry so kiou_bridge_bypass_entry_for_hook()
# stays correct (cave_va + 0x4C).
_ENTRY_HEAD_INSNS = 7  # STP, ADRP, LDR, MOVZ, BLR, LDP, RET
_ENTRY_TAIL_BYTES = 8  # displaced_insn + B orig+4
_ENTRY_PAD_INSNS  = (CAVE_PAYLOAD_SIZE - _ENTRY_HEAD_INSNS * 4 - _ENTRY_TAIL_BYTES) // 4


def _build_entry_cave_payload(
    orig_va: int, slot_va: int, displaced_insn: bytes, slot_index: int
):
    """Return a ``build_payload(cave_va) -> bytes`` closure for an entry cave."""
    if len(displaced_insn) != 4:
        raise ValueError(
            f"displaced_insn must be exactly 4 bytes; got {len(displaced_insn)}"
        )
    if not (0 <= slot_index <= 0xFFFF):
        raise ValueError(f"slot_index out of MOVZ 16-bit range: {slot_index}")

    def build(cave_va: int) -> bytes:
        out = bytearray()
        cur = cave_va

        def emit(insn: bytes) -> None:
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

        if len(out) != CAVE_PAYLOAD_SIZE:
            raise AssertionError(
                f"entry cave payload wrong size: got {len(out)}, "
                f"expected {CAVE_PAYLOAD_SIZE}"
            )
        return bytes(out)

    return build


# ---------------------------------------------------------------------------
# PATCHES — inline single-instruction (or short-multi-instruction)
# replacements.
#
# IsAfkEnabled (RVA 0x59455D4) — replace wholesale with ``MOVZ W0, #0; RET``
# so the AFK check returns false unconditionally. The original first
# 8 bytes are:
#
#     0x59455D4: f44fbea9   STP X20, X19, [SP, #-0x20]!
#     0x59455D8: fd7b01a9   STP X29, X30, [SP, #0x10]
#
# The 8-byte replacement clobbers both. That's safe: the RET at offset
# +4 fires before the clobbered STP X29/X30 could ever execute, and
# nothing else in the function reaches those four bytes (they're the
# prologue's second instruction and we've replaced the entry point with
# a return). No PC-relative instruction lives in that 4-byte slot — the
# top byte 0xA9 marks it as an STP pre/offset, which is PC-independent
# even if it did execute. Recorded here so a future reader knows what
# was clobbered.
# ---------------------------------------------------------------------------

_AFK_SITE = 0x59455D4
_AFK_ORIG_8 = bytes.fromhex("f44fbea9fd7b01a9")
_AFK_NEW_8 = mov_w0_imm_ret(0)

PATCHES: list = [
    (
        _AFK_SITE,
        _AFK_ORIG_8,
        _AFK_NEW_8,
        "IsAfkEnabled: return false (MOVZ W0,#0; RET), clobbers STP X29,X30,[SP,#0x10]",
    ),
]


# ---------------------------------------------------------------------------
# CAVE_PATCHES — each entry redirects a 4-byte site instruction to a cave.
#
# Per-site tuple: (RVA, prologue hex, hook_id name, label).
#
# Verified bytes-on-disk against the freshly extracted Kiou-1.0.1 build
# 11 UnityFramework on 2026-06-15. Every prologue listed below is
# PC-independent (top byte is 0xa9 = STP off/pre, 0x6d = STP D-reg, 0xd1
# = SUB SP/MOV imm, or 0xd6 = RET), so each can be relocated into its
# cave verbatim.
#
# The OnMatchStart row for LocalPvPMode uses prologue ``c0035fd6`` (RET).
# That's the on-disk first instruction of the method — the il2cpp
# compilation emits a synchronous void thunk that just returns. Placing
# RET inside the cave means the post-dispatcher branch back to
# ``orig + 4`` is unreachable, which is fine: the method's job is already
# done by the time RET fires, and the dispatcher captured everything it
# needs in the latch. (Caves are still 84 bytes; the trailing ``B orig+4``
# encoding is emitted but never executed.)
#
# Allocation order in this list = allocation order in the cave region.
# That ordering MUST stay stable so re-runs land cave bytes at the exact
# same addresses (the "already patched" SKIP path matches the site AND
# the cave content byte-for-byte).
#
# Branch F relies on that stability for injection bypass trampolines. The
# dylib reconstructs per-site "skip the dispatcher" entries as:
#
#     cave_va + 0x4C = unityBase + CAVE_REGION_START + i * 84 + 0x4C
#
# where i is the allocation index in this table. The cave tail's last three
# instructions are:
#
#     +0x48  LDP X29, X30, [SP], #0x90    ; epilogue's stack restore
#     +0x4C  <displaced prologue insn>    ; the original method's first 4 B
#     +0x50  B   <orig + 4>               ; branch back into the original
#
# So calling +0x4C runs only the displaced prologue and the branch back to
# orig+4, bypassing both the dispatcher and the epilogue's LDP (which would
# pop the WRONG X29/X30 pair off the inject path's stack and corrupt the
# frame pointer). If this recipe ever moves away from a uniform 84-byte
# allocator or reorders `_BRIDGE_SITES`, the dylib-side recomputation in
# BinpatchDispatcher.m / Inject_Move.m must be updated in lockstep.
# ---------------------------------------------------------------------------

_BRIDGE_SITES: list[tuple[int, str, str, str, str]] = [
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

    # OnMatchStart × 5 — prologue bytes captured on 2026-06-15 from the
    # extracted Kiou-1.0.1 build 11 UnityFramework. LocalPvPMode's
    # OnMatchStart is a synchronous void thunk that compiles to a bare
    # RET (top byte 0xd6); the other four are STP pre-index frame setups.
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

    # GameStateStore hooks — move observation (CSA) + player identity (Online)
    (0x5A2CB64, "f44fbea9", "KIOU_BR_HOOK_GSTATE_SET_BLACK_PLAYER_INFO", CAVE_OBSERVER, "GameStateStore.SetBlackPlayerInfo"),
    (0x5A2CBA0, "f44fbea9", "KIOU_BR_HOOK_GSTATE_SET_WHITE_PLAYER_INFO", CAVE_OBSERVER, "GameStateStore.SetWhitePlayerInfo"),
    (0x5A2CD24, "ff4301d1", "KIOU_BR_HOOK_GSTATE_NOTIFY_PIECE_MOVED",    CAVE_OBSERVER, "GameStateStore.NotifyPieceMoved"),

    # Account identity observation + Force Register override.
    # CAVE_ENTRY: the cave reads HookAccountExistsEntry from the dedicated
    # entry slot (ENTRY_SLOT_BASE_RVA + 0) and calls it. The hook is
    # responsible for invoking orig itself via the bypass entry when it
    # wants the original return — which lets Force Register flip the bool
    # without re-entering the cave.
    (0x591E860, "fd7bbfa9", "KIOU_BR_HOOK_ACCOUNT_EXISTS",          CAVE_ENTRY,    "UserSaveDataExtensions.AccountExists"),

    # Account switching + Register-flow distinctId pinning.
    # CAVE_ENTRY: the cave gives the hook full control of the argument
    # registers so we can swap the il2cpp `deviceId` (LoginArgs) or
    # `distinctId` (RegisterUserArgs) strings to whatever
    # KEBPendingDeviceId / KEBPendingDistinctId is armed with, then
    # forward through the bypass entry. CAVE_OBSERVER cannot do this
    # because the cave restores x0..x7 from the saved frame before
    # branching to orig+4, undoing the substitution.
    (0x5B9899C, "f657bda9", "KIOU_BR_HOOK_LOGIN_ARGS_CREATE",         CAVE_ENTRY, "ILoginArgs.Create"),
    (0x5B98A2C, "f657bda9", "KIOU_BR_HOOK_REGISTER_USER_ARGS_CREATE", CAVE_ENTRY, "IRegisterUserArgs.Create"),

    # Matching filter: Accept Seat (sente/gote-only) + Fixed Rate Range.
    # GetValidMatchFoundStatus must be CAVE_ENTRY because the seat-filter
    # side effect (firing ConnectionFailed at the matching stream) needs to
    # run AFTER orig produces the MatchFoundStatus so we can read
    # `isFirstPlayer` from it. orig's return is forwarded unchanged; the
    # observable reject signal goes through the stream, not through the
    # return value. The two supporting sites are:
    #   * ShogiMatchStreamArgs.Create — CAVE_ENTRY because the 7th C
    #     argument (enableBeginnerSupport) lands in W6, which CAVE_OBSERVER
    #     clobbers with the hook_id MOVZ. CAVE_ENTRY only touches W9, a
    #     call-clobbered scratch register that isn't an argument slot.
    #   * ReceiveWithTimeoutAsync.MoveNext — CAVE_OBSERVER. Single self
    #     pointer in x0; we just need to peek to cache the stream pointer
    #     and react to MatchingStatus replies.
    (0x5D04E94, "ff0301d1", "KIOU_BR_HOOK_GET_VALID_MATCH_FOUND_STATUS", CAVE_ENTRY,    "GetValidMatchFoundStatus"),
    (0x5BCA664, "fc6fbaa9", "KIOU_BR_HOOK_MATCH_STREAM_ARGS_CREATE",     CAVE_ENTRY,    "IShogiMatchStreamArgs.Create"),
    (0x5D06B10, "ff0303d1", "KIOU_BR_HOOK_RECEIVE_TIMEOUT_MOVENEXT",     CAVE_OBSERVER, "MatchingHandler.ReceiveWithTimeoutAsync.MoveNext"),

    # Async state-machine MoveNext post-orig observers — CAVE_ENTRY because
    # the relevant fields (LoginReply pointer, SelfUserProfileStatus rank
    # list, etc.) only land in the state machine struct *after* orig has
    # advanced state to -2. The entry hook calls bypass to run orig
    # itself, then reads the now-populated fields.
    (0x5812534, "ff8302d1", "KIOU_BR_HOOK_RUN_LOGIN_SEQ_MOVENEXT",    CAVE_ENTRY, "RunLoginSequenceAsync.MoveNext"),
    (0x5BB4774, "ff4302d1", "KIOU_BR_HOOK_GET_SELF_PROFILE_MOVENEXT", CAVE_ENTRY, "GetSelfUserProfileAsync.MoveNext"),

    # HttpMessageInvoker.SendAsync(HttpRequestMessage, CancellationToken) —
    # every outbound gRPC HTTP/2 request passes through here. CAVE_ENTRY so
    # the hook can rewrite the x-user-id header before forwarding to orig.
    # Note: Hook_GrpcLogging.m's RVA_HTTPMSGINVOKER_SEND_ASYNC (0x607C974)
    # points 12 bytes into the function; the real prologue is at 0x607C968.
    (0x607C968, "fd7bbfa9", "KIOU_BR_HOOK_HTTPMSGINVOKER_SEND_ASYNC", CAVE_ENTRY, "HttpMessageInvoker.SendAsync"),

    # MonoWebRequestHandler.SendAsync — the real HTTP transport entry point
    # that all gRPC calls go through in practice on this build. The
    # HttpMessageInvoker shim above goes through a vtable dispatch that may
    # route to a different concrete implementation; this hook covers the
    # actual path that JB verified produces →[Mono] log entries.
    (0x60789E4, "ffc304d1", "KIOU_BR_HOOK_MONO_SEND_ASYNC", CAVE_ENTRY, "MonoWebRequestHandler.SendAsync"),
]


# Entry slot indices — one per CAVE_ENTRY row in _BRIDGE_SITES, assigned in
# allocation order. Must match the enum in Sources/KiouEngineBridge/Internal.h
# (KIOU_BR_ENTRY_SLOT_*).
_ENTRY_SLOT_INDEX_BY_HOOK: dict[str, int] = {
    "KIOU_BR_HOOK_ACCOUNT_EXISTS":               0,
    "KIOU_BR_HOOK_LOGIN_ARGS_CREATE":            1,
    "KIOU_BR_HOOK_REGISTER_USER_ARGS_CREATE":    2,
    "KIOU_BR_HOOK_GET_VALID_MATCH_FOUND_STATUS": 3,
    "KIOU_BR_HOOK_MATCH_STREAM_ARGS_CREATE":     4,
    "KIOU_BR_HOOK_RUN_LOGIN_SEQ_MOVENEXT":           5,
    "KIOU_BR_HOOK_GET_SELF_PROFILE_MOVENEXT":        6,
    "KIOU_BR_HOOK_HTTPMSGINVOKER_SEND_ASYNC":        7,
    "KIOU_BR_HOOK_MONO_SEND_ASYNC":                  8,
}
assert len(_ENTRY_SLOT_INDEX_BY_HOOK) == ENTRY_SLOT_COUNT, \
    f"ENTRY_SLOT_COUNT ({ENTRY_SLOT_COUNT}) must match the entry-slot map"


def _payload_for_row(site, prologue_bytes, hook_id_name, kind):
    """Pick the cave builder for `kind` and return its closure."""
    if kind == CAVE_OBSERVER:
        return _build_bridge_cave_payload(
            site, HOOK_SLOT_RVA, prologue_bytes, _HOOK_IDS[hook_id_name]
        )
    if kind == CAVE_ENTRY:
        slot_index = _ENTRY_SLOT_INDEX_BY_HOOK[hook_id_name]
        slot_va = ENTRY_SLOT_BASE_RVA + slot_index * 8
        return _build_entry_cave_payload(
            site, slot_va, prologue_bytes, slot_index
        )
    raise AssertionError(f"unknown cave kind {kind!r} for {hook_id_name}")


CAVE_PATCHES: list = [
    (
        site,
        bytes.fromhex(prologue_hex),
        _payload_for_row(
            site, bytes.fromhex(prologue_hex), hook_id_name, kind
        ),
        f"{label}: route to Bridge {kind} cave ({hook_id_name})",
    )
    for site, prologue_hex, hook_id_name, kind, label in _BRIDGE_SITES
]


# ---------------------------------------------------------------------------
# Info.plist additions.
#
# Bridge talks to its host bridge over plain TCP on port 9527 — it does
# not use Bonjour / mDNS, so iOS 14+'s NSLocalNetworkUsageDescription
# permission gate is not triggered. The plist keys below are only for
# Files.app access to the app sandbox, so the Common logging helper can
# expose the binpatch log from Documents when IPA_LOG_TO_DOCUMENTS=1 is
# enabled by the consumer build.
#
# See docs/plans/kiou_engine_bridge_binpatch.md § 8 for the local-network
# rationale and the Phase C measurement that confirmed iOS 18 does not pop
# the local-network gate for plain ``0.0.0.0:9527`` listeners.
# ---------------------------------------------------------------------------

PLIST_KEYS: dict = {
    "UIFileSharingEnabled": True,
    "LSSupportsOpeningDocumentsInPlace": True,
}

# ---------------------------------------------------------------------------
# _SITES — verify_sites-compatible view of _BRIDGE_SITES.
#
# tools.verify_sites expects a flat iterable of
#     (slot_index, site_rva, prologue_hex_str, label)
# which matches the (rva, prologue_hex, hook_id_name, label) shape of
# _BRIDGE_SITES once we substitute the slot_index with the _HOOK_IDS value.
# Exposing this alias lets ``make hooks`` / scripts/pre-commit run the
# same cross-check gate as KiouEditor / KiouKifExporter without changing
# the upstream verify_sites contract.
# ---------------------------------------------------------------------------
_SITES: list[tuple[int, int, str, str]] = [
    (_HOOK_IDS[hook_id_name], site_rva, prologue_hex, label)
    for site_rva, prologue_hex, hook_id_name, kind, label in _BRIDGE_SITES
]
