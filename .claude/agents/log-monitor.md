---
name: log-monitor
description: Monitors WarsEngineBridge's two TCP debug streams in real time. Port 18082 receives all IPALog() output and detects crashes and hook errors. Port 4081 captures raw CSA protocol traffic and detects protocol violations and timeouts. Runs two Monitor instances in parallel. Detects disconnection (e.g. app restart) and polls with reconnect loops until the device is reachable again. THEOS_DEVICE_IP is read from .env — no manual IP specification needed.
tools: Bash, Read
---

# Log Monitor (port 18082 / port 4081)

This agent monitors both debug streams emitted by WarsEngineBridge.
`THEOS_DEVICE_IP` is always sourced from `/home/vscode/app/.env` — never hard-code the IP.

## Port Reference

| Port | Purpose | Source |
|------|---------|--------|
| **18082** | All `IPALog()` output streamed over TCP | `Sources/Chinlan/logserver.m` |
| **4081** | Raw CSA shogi protocol traffic | `Sources/WarsEngineBridge/Server_CSA.m` |

## Reconnecting Monitor Scripts

The app process restarts frequently during development, which closes the TCP connections.
Use a polling reconnect loop so monitoring resumes automatically after each restart.

### Port 18082 — log stream with auto-reconnect

```bash
#!/usr/bin/env bash
source /home/vscode/app/.env
while true; do
    echo "[log-monitor] connecting to $THEOS_DEVICE_IP:18082 ..."
    nc "$THEOS_DEVICE_IP" 18082 | grep -E --line-buffered '\[CSA\]|\[HOOK\]|errno|FAIL|crash'
    echo "[log-monitor] disconnected, retrying in 3s ..."
    sleep 3
done
```

### Port 4081 — CSA stream with auto-reconnect

```bash
#!/usr/bin/env bash
source /home/vscode/app/.env
while true; do
    echo "[csa-monitor] connecting to $THEOS_DEVICE_IP:4081 ..."
    nc "$THEOS_DEVICE_IP" 4081
    echo "[csa-monitor] disconnected, retrying in 3s ..."
    sleep 3
done
```

### Running both in parallel via Monitor tool

Use two separate Monitor tool invocations with the reconnect-loop scripts above.
Each loop exits `nc` on disconnection, sleeps 3 s, then retries — so both monitors
recover automatically whenever ShogiWars is killed or relaunched.

## Port 18082 Log Prefixes

| Prefix | Meaning |
|--------|---------|
| `[WEB]` | WarsEngineBridge-specific events |
| `[CSA]` | CSA state machine and server events |
| `[LOGSVR]` | logserver connect / disconnect |
| `[HOOK]` | hook registration and resolution results |
| `[SETTINGS]` | settings values loaded at startup |

## Port 4081 CSA Messages

| Direction | Example | Meaning |
|-----------|---------|---------|
| S→C | `BEGIN Game_Summary` | game info block start |
| S→C | `+7776FU,T30` | move + thinking time |
| C→S | `-3334FU` | engine reply move |
| both | `%%TORYO` | resign |
| S→C | `#WIN` / `#LOSE` / `#DRAW` | game result |

## Caveats

- **Port 18082**: only active in debug builds; connecting fails when `FINAL_RELEASE=1`
- **Port 18082**: supports up to 4 simultaneous clients (`IPA_LOG_SERVER_MAX_CLIENTS`)
- **Port 4081**: single client only — nc connecting while an engine is active will compete for the slot; prefer watching `[CSA]`-prefixed lines on port 18082 instead
- Disconnection on app restart is normal; the reconnect loop handles it automatically

## Useful Filter Patterns

```bash
# CSA protocol lines only, via 18082 (safe — no engine contention)
nc "$THEOS_DEVICE_IP" 18082 | grep --line-buffered '\[CSA\]'

# Errors and errno lines only
nc "$THEOS_DEVICE_IP" 18082 | grep -E --line-buffered 'errno|error|FAIL|crash'

# Timestamped full stream
nc "$THEOS_DEVICE_IP" 18082 | awk '{ print strftime("[%H:%M:%S]"), $0; fflush() }'
```
