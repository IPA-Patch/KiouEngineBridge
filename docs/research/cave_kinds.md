# Chinlan cave kinds

Bridge supports two cave shapes today. Both are emitted at patch time by
`recipes/kiouenginebridge.py` and follow the same 84-byte fixed-allocation
contract; what changes is what the cave does between the site entry and
the return to KIOU.

## At a glance

| Capability | `CAVE_OBSERVER` | `CAVE_ENTRY` |
|---|---|---|
| Peek arguments before orig runs | ✅ | ✅ |
| Run orig automatically | ✅ (cave does it after the dispatcher returns) | ❌ (hook must call the cave-bypass entry itself) |
| Override the return value | ❌ (cave executes orig _after_ the hook) | ✅ (cave's tail is `RET`; the hook's `x0` propagates straight back) |
| Substitute argument registers | ❌ (cave restores `x0..x7` before `B orig+4`) | ✅ (cave passes pristine `x0..x7` through and never restores) |
| Hooks routed through a single shared dispatcher | ✅ (`g_kebDispatch` at `KIOU_BR_HOOK_SLOT_RVA`, identified by `W6 = hook_id`) | ❌ (each site has its own slot under `KIOU_BR_ENTRY_SLOT_BASE_RVA`) |
| `W6` (= 7th C arg) survives across the cave | ❌ (clobbered with `hook_id` for the dispatcher) | ✅ (only `W9` is touched, and `x9–x15` are AAPCS64 call-clobbered scratch — never an argument slot) |
| Cave-bypass tail at `cave_va + 0x4C` still valid | ✅ | ✅ |
| Counts against `KIOU_BR_HOOK__COUNT` (= cave allocation order) | ✅ | ✅ |

### When to pick which

Pick `CAVE_OBSERVER` for almost everything. It's the cheap, default shape —
the cave preserves orig's behavior byte-for-byte, the dispatcher only needs
to log / cache / latch state, and you don't have to think about how to call
orig back.

Reach for `CAVE_ENTRY` only when one of these is true:

- **You need to override orig's return value.** Force Register flipping
  `AccountExists` to `false`, or Accept Seat rejecting a `MatchFound`.
- **You need orig to see different argument registers than the caller sent
  in.** Account switching swapping `LoginArgs.Create`'s `deviceId`, or
  Reset → Register swapping `RegisterUserArgs.Create`'s `distinctId`.
- **The hook target takes 7+ integer-class args** and `W6` carries real
  data you can't lose. Observer caves rewrite `W6` with the dispatcher
  hook id, so a 7th-arg observer would receive garbage.

Anything else — single move observation, state machine peeks, side-effect
logging — stays on `CAVE_OBSERVER`.

## Cave layouts

Both caves are 21 instructions = 84 bytes, allocated contiguously from
`KIOU_BR_CAVE_REGION_START` in `_BRIDGE_SITES` order. The last two
instructions are identical (`displaced_insn` + `B orig+4`) so the
cave-bypass entry at `cave_va + 0x4C` works for both kinds — `Inject_Move`
and the entry hooks use that to run orig without re-entering the cave.

### `CAVE_OBSERVER` (observer.cave)

```
0x00  STP X29, X30, [SP, #-0x90]!     ; save LR + reserve 0x90 of stack
0x04  STP X19, X20, [SP, #0x10]
0x08  STP X21, X22, [SP, #0x20]
0x0C  STP X0,  X1,  [SP, #0x30]       ; save x0..x7 so orig sees them
0x10  STP X2,  X3,  [SP, #0x40]
0x14  STP X4,  X5,  [SP, #0x50]
0x18  STP X6,  X7,  [SP, #0x60]
0x1C  MOV X29, SP                     ; canonical frame setup
0x20  ADRP X16, page(HOOK_SLOT_RVA)
0x24  LDR  X16, [X16, #lo12(HOOK_SLOT_RVA)] ; load dispatcher pointer
0x28  MOVZ W6,  #hook_id               ; pass hook id via W6 (clobbers arg #7!)
0x2C  BLR  X16                         ; dispatcher(x0..x5, hook_id_in_w6, x7)
0x30  LDP  X6,  X7,  [SP, #0x60]      ; restore x0..x7 — orig must see originals
0x34  LDP  X4,  X5,  [SP, #0x50]
0x38  LDP  X2,  X3,  [SP, #0x40]
0x3C  LDP  X0,  X1,  [SP, #0x30]
0x40  LDP  X21, X22, [SP, #0x20]
0x44  LDP  X19, X20, [SP, #0x10]
0x48  LDP  X29, X30, [SP], #0x90      ; tear down frame
0x4C  <displaced prologue insn>        ; orig's first 4 bytes, run verbatim
0x50  B    <orig + 4>                  ; continue into orig body
```

Reads from the dispatcher arrive as
`void dispatch_one(void *x0, void *x1, void *x2, void *x3, void *x4,
                   void *x5, uint32_t hook_id, void *x7)` — `x6` is sacrificed
to deliver `hook_id` even though `W6` is the 7th C integer arg under AAPCS64.
Hook bodies with up to six args (everything in this repo except
`IShogiMatchStreamArgs.Create`) are safe; anything more needs `CAVE_ENTRY`.

### `CAVE_ENTRY` (entry.cave)

```
0x00  STP X29, X30, [SP, #-0x10]!     ; minimal frame — no arg saving
0x04  ADRP X16, page(entry_slot_va)
0x08  LDR  X16, [X16, #lo12(entry_slot_va)] ; load this site's hook fn ptr
0x0C  MOVZ W9,  #slot_index           ; diagnostic; hook may ignore (W9 is AAPCS64 call-clobbered scratch, not an argument slot)
0x10  BLR  X16                         ; hook(x0..x7) — return ends up in x0
0x14  LDP  X29, X30, [SP], #0x10
0x18  RET                              ; orig is NOT executed by the cave
0x1C  NOP × 12                         ; padding to keep tail at +0x4C
…
0x4C  <displaced prologue insn>        ; reachable only via the bypass entry
0x50  B    <orig + 4>                  ; (or as the cave-bypass trampoline)
```

The cave hands the hook pristine `x0..x7`. The hook is then responsible for
running orig itself when it wants the original behavior — typically by
casting `g_inject_entry[KIOU_BR_HOOK_*]` (already populated by
`KEBBridgeChinlanPublish` with `cave_va + KIOU_BR_CAVE_BYPASS_OFFSET`) and
calling it as a function pointer. Whatever `x0` the hook returns becomes the
caller's return value because the cave's tail is plain `RET`.

`MOVZ W9, #slot_index` is debug-only: it lets you tell entry caves apart in
a register dump without touching any caller-supplied argument. Hooks ignore
it.

## Adding a new cave site — walkthrough

Worked example: porting an existing JB MSHookFunction site to chinlan as a
`CAVE_ENTRY` so it can override the return value. Substitute names /
prologue / argument list for your site.

### 1. Pick the right kind

Ask:

1. Do I need to override orig's return or substitute args? → `CAVE_ENTRY`.
2. Does the C function take 7+ integer-class args? → `CAVE_ENTRY` (W6 risk).
3. Otherwise → `CAVE_OBSERVER`.

### 2. Confirm the prologue is PC-independent

Pull the site's first 4 bytes from a clean extract:

```sh
python3 -c "
with open('/tmp/unity.bin','rb') as f:
    f.seek(0xRRRRRR)
    print(f.read(4).hex())
"
```

PC-independent means the top byte is one of `a9` (STP/LDP signed off /
pre / post), `6d` (STP D-reg), `d1` (SUB SP, …), `d6` (RET). Anything
that encodes a PC-relative offset (`ADR`, `ADRP`, `B`, `BL`) cannot be
relocated verbatim; you'd have to relocate + fix-up or pick a different
site. (`BR` / `BLR` are register-indirect and therefore PC-independent
themselves, but a prologue that uses them has almost always materialised
the target register a few instructions earlier — relocating just the
branch would dereference the wrong address.)

### 3. `recipes/kiouenginebridge.py`

Add a row to `_HOOK_IDS` and `_BRIDGE_SITES`, keeping list order =
allocation order = bypass-entry index. For an entry cave also add an
entry-slot index.

```python
_HOOK_IDS: dict[str, int] = {
    ...
    "KIOU_BR_HOOK_NEW_SITE": 34,   # next free integer
}

_BRIDGE_SITES = [
    ...
    (0xRRRRRR, "PROLOGUE", "KIOU_BR_HOOK_NEW_SITE", CAVE_ENTRY, "Namespace.Method"),
]

_ENTRY_SLOT_INDEX_BY_HOOK = {
    ...
    "KIOU_BR_HOOK_NEW_SITE": 5,     # next free index; bump ENTRY_SLOT_COUNT to match
}

ENTRY_SLOT_COUNT = 6   # bump alongside the new slot
```

If you're adding an observer cave, skip the slot index and slot-count
changes — observers share `HOOK_SLOT_RVA`.

### 4. `Sources/KiouEngineBridge/Internal.h`

Mirror the enum entries:

```c
enum kiou_bridge_hook_id {
    ...
    KIOU_BR_HOOK_NEW_SITE,
    KIOU_BR_HOOK__COUNT,
};

enum kiou_bridge_entry_slot_id {
    ...
    KIOU_BR_ENTRY_SLOT_NEW_SITE,    // entry caves only
    KIOU_BR_ENTRY_SLOT__COUNT,
};
```

Declare the hook signature so other translation units (and the chinlan
dispatcher) can see it:

```c
SomeReturnType HookNewSiteEntry(SomeArg1, SomeArg2);   // for entry
void           HookNewSiteObserve(SomeArg1, ...);      // for observer
```

### 5. Hook implementation

`Hook_<feature>.m`. For an entry hook, call orig via the bypass entry:

```c
#if KIOU_CHINLAN
SomeReturnType HookNewSiteEntry(SomeArg1 a, SomeArg2 b) {
    // ... pre-orig work: log, latch state, decide on override ...

    typedef SomeReturnType (*Fn)(SomeArg1, SomeArg2);
    Fn bypass = (Fn)g_inject_entry[KIOU_BR_HOOK_NEW_SITE];
    SomeReturnType result = bypass ? bypass(a, b) : (SomeReturnType){0};

    // ... post-orig work: filter / rewrite result ...
    return result;
}
#endif
```

For an observer hook, the cave already calls orig — just do the work:

```c
void HookNewSiteObserve(void *self) {
    // peek, log, cache; no orig call needed
}
```

### 6. `Sources/KiouEngineBridge/ChinlanDispatcher.m`

Observer hooks: add a `case` to `dispatch_one`.

```c
case KIOU_BR_HOOK_NEW_SITE:
    HookNewSiteObserve(x0); break;
```

Entry hooks: publish the function pointer in `KEBBridgeChinlanPublish`.

```c
entrySlots[KIOU_BR_ENTRY_SLOT_NEW_SITE] = (void *)&HookNewSiteEntry;
```

Mention it in the publish log line so a chinlan boot log makes the wiring
obvious.

### 7. `Sources/KiouEngineBridge/Tweak.m`

If this is the first site of a brand-new feature, make sure
`Install<Feature>ObserveHook(unityBase)` is called from both the JB and
chinlan branches. The Account / Matching installers are already wired and
serve as templates.

### 8. Build and verify

```sh
make JAILED=1                        # JB / Dobby flavor
make CHINLAN=1                       # chinlan flavor
make FINALPACKAGE=1 FINAL_RELEASE=1 ipa
```

`make ipa` runs the recipe end-to-end and prints `PATCH [0xRRRRRR] …
route to Bridge entry|observer cave (…)` for every site, including the new
one. If the recipe rejects the row, the error message will name the
specific assertion (slot range, allocation overflow, etc.); fix in place.

On device, the boot log gets `[CHINLAN] entry slots base=… NewSite=0x…` so
you can confirm the publish succeeded, and the dispatcher's `[CHINLAN]
unknown hook_id=…` warning never fires unless the recipe / header / dylib
fall out of sync.
