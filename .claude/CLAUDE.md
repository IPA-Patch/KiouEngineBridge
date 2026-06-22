# KiouEngineBridge — Claude Work Guide

## Reading logs

### Jailbroken

SSH into the device and fetch the sandbox log directly.
Do not use the local `logs/` directory — it contains stale logs.

```bash
# Connect to the device
ssh root@$THEOS_DEVICE_IP

# Log path varies per container — find it each time
find /var/mobile/Containers/Data/Application -name 'kiouenginebridge*.log' 2>/dev/null

# Pull to local for analysis
ssh root@$THEOS_DEVICE_IP "cat <path>" > /home/vscode/app/logs/device_latest.log
```

### Jailed

The TCP log server listens on `0.0.0.0:18082` from process start.
On connect, the last 100 KB of the sandbox log file is replayed before switching to the live stream — so boot-time and login-time logs are never lost even if no client was open at startup.

```bash
# Find the device IP in Settings → Wi-Fi → info button
nc <device-ip> 18082
```

No AirDrop or SSH required. Not available in `FINAL_RELEASE=1` builds (compiled out).

## Development policy

- Validate new features on a **JB build first, then port to Chinlan**
- On JB, use `MSHookFunction` inside `#if !KIOU_CHINLAN` blocks
- Chinlan porting requires enum additions, dispatcher wiring, and recipe changes — treat it as a separate task
