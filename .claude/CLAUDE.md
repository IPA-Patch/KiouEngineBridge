# KiouEngineBridge — Claude Work Guide

## Reading logs

Full procedure — env vars (`THEOS_DEVICE_IP` / `THEOS_DEVICE_PORT`), `iproxy` fallback via `host.docker.internal`, jailbroken SSH sandbox pull, jailed `nc` TCP log server — lives in the **`ios-hook:device-logs`** skill. **Load that skill before touching device logs.**

Project-specific quick reference:

- Jailbroken → SSH; log path pattern is `/var/mobile/Containers/Data/Application/<UUID>/**/kiouenginebridge*.log` (find fresh each time).
- Jailed → `nc "$THEOS_DEVICE_IP" 18082`. TCP log server replays the last 100 KB then switches to live stream. **Not available in `FINAL_RELEASE=1` builds.**
- Chinlan (`IPA_CHINLAN=1`) binds the log server to **loopback only**, so the iOS Local Network prompt can't block it. `THEOS_DEVICE_IP` won't reach it — forward the port first (`iproxy 18082 18082`) and connect to `127.0.0.1` (or `host.docker.internal` from inside the container).
- **DON'T** use the local `logs/` directory as a source — those files are stale snapshots.

## Target app versions

- Recipes live in `recipes/v<maj>_<min>_<patch>.py`; pick one with `TARGET_VERSION=<ver>` (`make ipa TARGET_VERSION=1.1.0`). Supported: 1.0.1, 1.0.2, 1.1.0.
- Anything the dylib resolves as `unityBase + rva` on a Chinlan build must come from the recipe via `KIOU_BR_RVA_*` (`Generated/RecipeConstants.h`), never a literal. Literals are only OK inside `#if !KIOU_CHINLAN` — the JB flavour targets 1.0.1 only.
- Field offsets that drift across versions go in the recipe's `FIELD_OFFSETS` → `KIOU_BR_OFF_*`.

## Development policy

- **DO:** Validate new features on a **JB build first, then port to Chinlan**.
- **DO:** On JB, use `MSHookFunction` inside `#if !KIOU_CHINLAN` blocks.
- **DO:** Treat Chinlan porting as a separate task — it requires enum additions, dispatcher wiring, and recipe changes.
