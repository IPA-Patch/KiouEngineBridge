"""KiouEngineBridge recipe — entry point for ``tools.patch_macho``.

Selects the active version via the ``TARGET_VERSION`` environment
variable (default: ``1.0.1``) and re-exports the patch surface that
``tools.patch_macho`` and ``tools.verify_sites`` expect:

  TARGET_BASENAME, DYLIB_PATH, PLIST_KEYS
  HOOK_SLOT_RVA, PROBED_HOOK_SLOT_RVA
  CAVE_REGION, ENTRY_SLOT_BASE_RVA
  PATCHES, CAVE_PATCHES, _SITES
  CALLS, FIELD_OFFSETS, BOARD_ANIM_TAKES_PLAYER_SIDE,
  LOGIN_ARGS_TAKES_APPSFLYER_ID
    (consumed by tools/gen_recipe_header.py, not by patch_macho)

Adding a new version:
  1. Run ``/dump`` → assets/<ver>/dump.cs + dump.cs.index.json
  2. Run ``python3 -m tools.verify_sites --recipe recipes --version <old>
       --index assets/<ver>/dump.cs.index.json --ipa assets/<ver>/<ver>.ipa``
     to find drifted RVAs.
  3. Create ``recipes/v<maj>_<min>_<patch>.py`` (copy v1_0_2.py as template).
  4. Register it in ``_VERSIONS`` below.
"""

from __future__ import annotations

import importlib
import os

from recipes.common import (
    TARGET_BASENAME,
    DYLIB_PATH,
    PLIST_KEYS,
    CALL_RVA_KEYS,
    FIELD_OFFSET_KEYS,
    ENTRY_SLOT_COUNT,
    ENTRY_SLOT_CAPACITY,
    ENTRY_SLOT_INDEX,
    build_exports,
)

# ---------------------------------------------------------------------------
# Version registry — maps CFBundleShortVersionString → recipe module name.
# Set the value to None to mark a version as "known but not yet implemented".
# ---------------------------------------------------------------------------

_VERSIONS: dict[str, str | None] = {
    "1.0.1": "recipes.v1_0_1",
    "1.0.2": "recipes.v1_0_2",
    "1.1.0": "recipes.v1_1_0",
}

_DEFAULT_VERSION = "1.0.1"

# ---------------------------------------------------------------------------
# Version selection
# ---------------------------------------------------------------------------

_target_version = os.environ.get("TARGET_VERSION", _DEFAULT_VERSION)
_module_name = _VERSIONS.get(_target_version)

if _module_name is None:
    if _target_version in _VERSIONS:
        _known = [v for v, m in _VERSIONS.items() if m is not None]
        raise ImportError(
            f"KIOU version {_target_version!r} is registered but not yet implemented.\n"
            f"  Known versions: {_known}\n"
            f"  Create recipes/v{_target_version.replace('.', '_')}.py to add it."
        )
    _known = [v for v, m in _VERSIONS.items() if m is not None]
    raise ImportError(
        f"KIOU version {_target_version!r} is not in the version registry.\n"
        f"  Known versions: {_known}\n"
        f"  Add it to _VERSIONS in recipes/__init__.py."
    )

_v = importlib.import_module(_module_name)

# Validate slot reservation fits in the verified-zero region.
assert _v.ENTRY_SLOT_BASE_RVA + ENTRY_SLOT_CAPACITY * 8 <= _v.ZERO_REGION_END_RVA, (
    f"entry slot reservation overflows verified-zero region for {_target_version}"
)
assert len(ENTRY_SLOT_INDEX) == ENTRY_SLOT_COUNT

# Every version must map the full call/offset surface — a missing key would
# otherwise silently fall back to whatever literal the .m file used to carry.
_missing_calls = [k for k in CALL_RVA_KEYS if k not in _v.CALLS]
assert not _missing_calls, f"{_module_name}.CALLS is missing {_missing_calls}"
_extra_calls = [k for k in _v.CALLS if k not in CALL_RVA_KEYS]
assert not _extra_calls, f"{_module_name}.CALLS has unknown keys {_extra_calls}"

_missing_offsets = [k for k in FIELD_OFFSET_KEYS if k not in _v.FIELD_OFFSETS]
assert not _missing_offsets, (
    f"{_module_name}.FIELD_OFFSETS is missing {_missing_offsets}"
)

# ---------------------------------------------------------------------------
# Public exports consumed by patch_macho / verify_sites
# ---------------------------------------------------------------------------

CAVE_REGION                   = _v.CAVE_REGION
HOOK_SLOT_RVA                 = _v.HOOK_SLOT_RVA
PROBED_HOOK_SLOT_RVA          = _v.PROBED_HOOK_SLOT_RVA
INJECT_ENTRY_TABLE_RVA        = _v.INJECT_ENTRY_TABLE_RVA
PROBED_INJECT_ENTRY_TABLE_RVA = _v.PROBED_INJECT_ENTRY_TABLE_RVA
ENTRY_SLOT_BASE_RVA           = _v.ENTRY_SLOT_BASE_RVA
CALLS                         = _v.CALLS
FIELD_OFFSETS                 = _v.FIELD_OFFSETS
BOARD_ANIM_TAKES_PLAYER_SIDE  = _v.BOARD_ANIM_TAKES_PLAYER_SIDE
LOGIN_ARGS_TAKES_APPSFLYER_ID = _v.LOGIN_ARGS_TAKES_APPSFLYER_ID

PATCHES, CAVE_PATCHES, _SITES = build_exports(
    _v.SITES,
    _v.AFK_SITE,
    _v.AFK_ORIG_8,
    _v.HOOK_SLOT_RVA,
    _v.ENTRY_SLOT_BASE_RVA,
)

# ---------------------------------------------------------------------------
# Diagnostic build modes — KIOU_DIAG
#
# A patched IPA that crashes at launch has two independent suspects: the
# static binary patches (caves + the AFK inline patch) and the injected
# dylib. Bisecting them by hand means hand-editing a recipe, so expose it
# as a switch instead:
#
#   KIOU_DIAG=dylib-only   drop every binary patch; only LC_LOAD_DYLIB is
#                          added. Boots => the binary patches are at fault.
#                          Crashes => the dylib is.
#   KIOU_DIAG=caves-only   keep the caves, drop the AFK inline patch.
#
# Always pair with --bundle-id-suffix so the diagnostic build installs
# next to the real one instead of replacing it.
# ---------------------------------------------------------------------------

_diag = os.environ.get("KIOU_DIAG", "").strip().lower()

if _diag == "dylib-only":
    PATCHES = []
    CAVE_PATCHES = []
    print("  DIAG  KIOU_DIAG=dylib-only — no binary patches, dylib only")
elif _diag == "caves-only":
    PATCHES = []
    print("  DIAG  KIOU_DIAG=caves-only — caves kept, AFK inline patch skipped")
elif _diag:
    raise ImportError(
        f"unknown KIOU_DIAG={_diag!r}; expected 'dylib-only' or 'caves-only'"
    )
