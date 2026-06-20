---
name: tweak-dev
description: Implements Objective-C hooks for WarsEngineBridge. Reads and writes .m and .h files under Sources/WarsEngineBridge, adds or fixes MSHookFunction/Dobby hooks, and debugs hook registration. Also owns the CSA state machine (Csa_Engine.m), TCP transport (Server_CSA.m), and move/resign injection (Inject_Move.m, Inject_Resign.m).
tools: Read, Write, Edit, Glob, Grep, Bash
---

# Tweak Dev (Objective-C)

This agent specializes in ObjC hook implementation for WarsEngineBridge.

## Source Layout

```
Sources/WarsEngineBridge/
├── Tweak.m              # constructor, hook registration entry point
├── Internal.h           # shared types, RVA constants, exported declarations
├── Hook_GameController.m
├── Hook_NoLoginDialog.m
├── Inject_Move.m        # move injection
├── Inject_Resign.m      # resign injection
├── Csa_Engine.m         # CSA protocol state machine
├── Csa_GameInfo.m       # game-info message builder
├── Csa_Convert.m/.h     # USIF ↔ CSA conversion
└── Server_CSA.m         # TCP transport (port 4081)

Sources/Chinlan/         # shared hook infrastructure
├── hookengine.h         # MSHook / Dobby / Chinlan switching API
├── logging.m/.h         # IPALog() → streams to port 18082
└── logserver.m/.h       # TCP log streaming server
```

## Hook Infrastructure API

```objc
// hookengine.h selects the backend via build flags
// JB / rootless:  MSHookFunction(ptr, hook, &orig)
// JAILED=1:       DobbyHook(ptr, hook, (void **)&orig)
// CHINLAN=1:      ChinlanHook(slot, ptr, hook)

// RVA calculation (g_unityBase captured in Tweak.m constructor)
extern uintptr_t g_unityBase;
void *target = (void *)(g_unityBase + RVA_FOO);
```

## Build Mode Constraints

| Mode | Flag | Constraint |
|------|------|------------|
| rootless JB | default | none |
| jailed | `JAILED=1` | no libsubstrate; Dobby static only |
| chinlan | `CHINLAN=1` | no `__TEXT` writes; `-Wl,-undefined,error` active |

## Logging

```objc
IPALog(@"[WEB] hook name addr=%p", target);
IPALog([NSString stringWithFormat:@"[CSA] state=%d line=%@", state, line]);
```

Live output can be tailed with `nc $THEOS_DEVICE_IP 18082`.

## CSA Server Port

`WEBCsaServerStart(4081)` is called from the Tweak.m constructor.
Do not reorder calls relative to hook registration.

## RVA Constants

All hook base addresses live in `Internal.h` as `#define RVA_*`.
Use **app-analyzer** to locate new RVAs from dump.cs.
