#!/usr/bin/env python3
"""Generate Sources/KiouEngineBridge/Generated/RecipeConstants.h from the
active recipe so the dylib's compile-time RVAs always match the recipe
that ``make ipa`` will apply. Keeps the recipe (Python) as the single
source of truth — eliminates the recipe/Internal.h drift that broke 1.0.2
sideload.

Run before compile (the Makefile invokes this automatically):

    TARGET_VERSION=1.0.2 python3 tools/gen_recipe_header.py
"""

from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "shared"))

ver = os.environ.get("TARGET_VERSION", "1.0.1")
os.environ["TARGET_VERSION"] = ver

recipe = importlib.import_module("recipes")

cave_start, _ = recipe.CAVE_REGION
out = REPO_ROOT / "Sources" / "KiouEngineBridge" / "Generated" / "RecipeConstants.h"
out.parent.mkdir(parents=True, exist_ok=True)

_WIDTH = max(len(k) for k in recipe.CALLS) + len("KIOU_BR_RVA_")

calls = "\n".join(
    f"#define {'KIOU_BR_RVA_' + key:<{_WIDTH + 2}}0x{recipe.CALLS[key]:X}"
    for key in sorted(recipe.CALLS, key=lambda k: recipe.CALLS[k])
)

offsets = "\n".join(
    f"#define {'KIOU_BR_OFF_' + key:<{_WIDTH + 2}}0x{recipe.FIELD_OFFSETS[key]:X}"
    for key in sorted(recipe.FIELD_OFFSETS)
)

content = f"""\
// Auto-generated from recipes/v{ver.replace('.', '_')}.py by
// tools/gen_recipe_header.py. DO NOT EDIT — re-run `make` after
// editing the recipe.
//
// Source of truth for the slot/cave RVAs is the active recipe module.
// Internal.h includes this file so the dylib's compile-time addresses
// always match the recipe applied by `make ipa`.
#pragma once

#define KIOU_BR_HOOK_SLOT_RVA           0x{recipe.HOOK_SLOT_RVA:X}
#define KIOU_BR_ENTRY_SLOT_BASE_RVA     0x{recipe.ENTRY_SLOT_BASE_RVA:X}
#define KIOU_BR_INJECT_ENTRY_TABLE_RVA  0x{recipe.INJECT_ENTRY_TABLE_RVA:X}
#define KIOU_BR_CAVE_REGION_START       0x{cave_start:X}

// il2cpp entry points the dylib resolves as `unityBase + rva` and calls
// directly. These are not patch sites, so nothing else validates them —
// keep them in the recipe or they rot silently across app versions.
{calls}

// 1 when BoardPresenter.PlayMoveAnimationAsync takes an explicit
// PlayerSide between the Move and the CancellationToken.
#define KIOU_BR_BOARD_ANIM_TAKES_PLAYER_SIDE {int(recipe.BOARD_ANIM_TAKES_PLAYER_SIDE)}

// 1 when ILoginArgs.Create takes a third `string appsflyerId` argument.
// The entry cave hands the hook the caller's x0..x7 untouched, so a hook
// declared with too few parameters silently drops the tail arguments and
// Create stores a garbage string pointer.
#define KIOU_BR_LOGIN_ARGS_TAKES_APPSFLYER_ID {int(recipe.LOGIN_ARGS_TAKES_APPSFLYER_ID)}

// il2cpp field offsets that have moved between app versions.
{offsets}
"""

# Idempotent: only rewrite when content changes, so `make` doesn't treat
# the header as newer than every .m file on every invocation.
prev = out.read_text() if out.exists() else None
if prev != content:
    out.write_text(content)
    print(f"==> generated {out.relative_to(REPO_ROOT)} (TARGET_VERSION={ver})", file=sys.stderr)
