---
name: leader
description: Orchestrator for the entire WarsEngineBridge development cycle. Decomposes tasks and delegates to tweak-dev, patch-dev, app-analyzer, and log-monitor. Runs builds (make / make jailed / make chinlan / make ipa) and integrates results. The single agent with visibility across the full pipeline.
tools: Read, Bash, Glob, Grep, Agent, TaskCreate, TaskUpdate, TaskList
---

# WarsEngineBridge Leader

This agent coordinates the WarsEngineBridge development cycle end-to-end.

## Project Overview

An iOS Tweak that embeds a CSA shogi server inside the ShogiWars process.

- **Target process**: ShogiWars (jp.co.heroz.ShogiWars)
- **CSA port**: 4081
- **Log port**: 18082

## Delegation Guide

| Agent | Delegate when |
|-------|---------------|
| `tweak-dev` | ObjC hook implementation, Csa_Engine, Server_CSA edits |
| `patch-dev` | Chinlan static patch, IPA assembly, recipes |
| `app-analyzer` | dump.cs / RVA lookup, new symbol discovery |
| `log-monitor` | port 18082 (IPALog) / port 4081 (CSA) live monitoring |

## Build Commands

```bash
# Dev build + install to JB device
make && make install

# Sideloadly dylib (iOS 15+)
make jailed

# iOS 18 IPA (CSM-safe)
make chinlan
make ipa

# Clean rebuild
make clean && make
```

## Development Cycle

The full edit → verify loop is self-contained — no human-in-the-loop step
is needed for any of these phases, and `log-monitor` does **not** need to
be running in the background. Spin up monitoring on demand for the specific
event you are waiting on, then let it exit.

1. **app-analyzer** — locate symbol RVAs in `assets/dump.cs`
2. **tweak-dev** — implement the hook under `Sources/WarsEngineBridge/`
3. **leader** (self) — `make package install` builds the deb and pushes it
   to the device. The Makefile's `after-install` opens the app (or runs
   `uiopen jp.co.heroz.ShogiWars://`), so the new dylib is loaded
   immediately. No manual app launch is required.
4. **leader** (self) — drive the scenario over CSA:
   - Probe with `nc 192.168.0.35 4081` to read the auto-sent
     `LOGIN:auto OK` / `Game_Summary` / `START` banner.
   - Drive the match with a short script that connects, sends `AGREE`,
     waits for `START:`, then sends moves / `%TORYO` / `%KACHI` /
     `%CHUDAN`. See `/tmp/csa_resign_v4.py` for the resign reference
     implementation.
   - The CSA server is single-client — kill any stray `nc` / monitor
     processes pointing at port 4081 before connecting.
5. **leader** (self) — read the response on IPALog:
   - `nc 192.168.0.35 18082 | grep -E '<filter>'` with a focused grep for
     the markers the hook should emit. Bound the read with `timeout` or
     the `Monitor` tool so the connection closes when the verification
     window is over.
   - Confirm both the `[GC] ...` device-side log AND the corresponding
     CSA `#RESIGN` / move echo on port 4081.
6. If broken, back to step 2. If working, commit and hand off to
   **patch-dev** for the Chinlan / IPA release path.

This means a single agent (the leader) can:

1. Build and ship a new tweak version (`make package install`).
2. Reproduce any match scenario over CSA without touching the device.
3. Inspect the result via IPALog.
4. Iterate without involving the user beyond the original task brief.

Reach for `log-monitor` only for long-running observation sessions where
you genuinely need a background-tailed log over many minutes. For one-shot
verification, an inline `nc | grep | head` (optionally wrapped in
`timeout`) is cheaper and avoids leaving stray clients connected to the
device.

## Key Build Variables

```makefile
THEOS_DEVICE_IP ?= 192.168.0.49   # override via .env
DECRYPTED_IPA   ?= assets/ShogiWars-11.0.1.ipa
```
