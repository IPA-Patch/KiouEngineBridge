"""Structural smoke test for ``recipes.kiouenginebridge``.

Asserts the recipe exports the symbols ``patch_macho`` expects and that
the table counts match the migration plan. Does NOT run
``apply_patches`` against a real binary — that's an integration step
that depends on a clean UnityFramework not shipped in this repo.
"""

from __future__ import annotations

import importlib


def _load():
    return importlib.import_module("recipes.kiouenginebridge")


def test_target_basename():
    r = _load()
    assert r.TARGET_BASENAME == "UnityFramework"


def test_dylib_path():
    r = _load()
    assert r.DYLIB_PATH == "@executable_path/Frameworks/KiouEngineBridge.dylib"


def test_hook_slot_rva_is_eight_byte_aligned():
    r = _load()
    assert r.HOOK_SLOT_RVA % 8 == 0
    # Plan § 8: Bridge slot is placed 16 bytes ahead of KifExporter's
    # 0x8F90CD0 so the two recipes can coexist on the same Mach-O.
    assert r.HOOK_SLOT_RVA == 0x8F90CC0


def test_cave_region_partition():
    r = _load()
    start, end = r.CAVE_REGION
    assert start < end
    # Plan § 8: Bridge owns the back half of __oslogstring's zero-fill,
    # KifExporter owns the front. Two recipes must be region-disjoint
    # in practice (their entries may overlap declared ranges, but
    # actual cave allocations must not collide — see § 8 caveat).
    assert start == 0x826A000
    assert end == 0x826C000


def test_inline_patch_count():
    r = _load()
    # IsAfkEnabled is the only inline byte patch in Phase 1.
    assert len(r.PATCHES) == 1


def test_cave_patch_count():
    r = _load()
    # 25 cave-routed sites (Init × 5, Start × 5, OPM × 5, End × 5, plus
    # Adapter.TryMakeMove(Move,out), Online.UpdateAuthoritativeSnapshot,
    # Online.HandleMoveResult, CPUStream.UpdateAuthoritativeSnapshot,
    # GameOrchestrator.ActivateAsync). See plan § 3.
    assert len(r.CAVE_PATCHES) == 25


def test_cave_budget_fits():
    r = _load()
    # 25 × 84 B caves = 2100 B, well below the 8 KB Bridge partition.
    cave_count = len(r.CAVE_PATCHES)
    assert cave_count * 84 <= (r.CAVE_REGION[1] - r.CAVE_REGION[0])


def test_plist_keys_empty_for_bridge():
    r = _load()
    # Bridge is TCP-only (Server_WebSocket.m on 0.0.0.0:9527), no Bonjour,
    # so no Info.plist additions are needed. KifExporter is the recipe
    # that ships UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace.
    assert r.PLIST_KEYS == {}
