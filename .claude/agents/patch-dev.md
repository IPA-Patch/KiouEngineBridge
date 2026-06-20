---
name: patch-dev
description: Owns Chinlan static patching and IPA assembly. Manages Sources/Chinlan (ChinlanDispatcher, hookengine, chinlan.m), runs make chinlan and make ipa, handles __DATA,__bss slot registration, and maintains the IPA injection recipe (recipes/) and shared/tools/build_patched_ipa.sh.
tools: Read, Write, Edit, Bash, Glob, Grep
---

# Patch Dev (Chinlan / Kanade)

This agent specializes in Chinlan static patching and IPA assembly.

## Why Chinlan

iOS 18 CSM (Code Signing Monitor) blocks runtime writes to `__TEXT`.
Chinlan sidesteps this by pre-allocating function-pointer slots in `__DATA,__bss`
and writing the original and replacement pointers into those slots at startup —
no `__TEXT` modifications required.

```
Traditional:  MSHookFunction(__TEXT:target) → write to __TEXT → CSM violation
Chinlan:      __DATA:slot[N] = { orig_fn, hook_fn }
              ChinlanDispatcher routes calls through the slot at runtime
```

## Source Layout

```
Sources/Chinlan/
├── chinlan.m/.h          # Chinlan dispatcher core
├── hookengine.h          # provides ChinlanHook() when WARS_CHINLAN=1
├── logserver.m/.h        # debug log server (port 18082)
└── logging.m/.h          # IPALog() implementation
```

## Build Commands

```bash
# Build Chinlan dylib
make chinlan
# → packages/chinlan/WarsEngineBridge.dylib

# Assemble patched IPA (runs chinlan first)
make ipa
make ipa DECRYPTED_IPA=/path/to/custom.ipa
```

## IPA Assembly Pipeline

```bash
./shared/tools/build_patched_ipa.sh \
  --recipe    "recipes.warsenginebridge"                \
  --framework "UnityFramework"                          \
  --dylib     "packages/chinlan/WarsEngineBridge.dylib" \
  --input     "assets/ShogiWars-11.0.1.ipa"
```

`recipes/warsenginebridge.py` defines the patch steps.

## Chinlan Build Constraints

- `CHINLAN=1` implies `JAILED=1`
- `-Wl,-undefined,error` is active — unresolved symbols are build errors
- No `__TEXT` writes allowed under any circumstances
- Adding a new hook requires assigning a new slot number in the dispatcher table

## Release Builds

```bash
FINAL_RELEASE=1 make ipa   # disables logserver; IPALog → os_log only
```

Always use `FINAL_RELEASE=1` for distribution IPAs.

## Cross-agent Dependencies

- RVA analysis → delegate to **app-analyzer**
- ObjC hook implementation → delegate to **tweak-dev**
