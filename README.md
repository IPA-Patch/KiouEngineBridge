<h1 align="center">Kiou Engine Bridge</h1>

<p align="center">
  <img src="icon.webp" alt="Kiou Engine Bridge icon" width="180" />
</p>

<p align="center">
  <em>Turn <strong>KIOU</strong> into a CSA match server. The tweak speaks
  the standard CSA server protocol on TCP <code>:4081</code>, so any CSA
  client can connect over LAN and play against KIOU's live board — no extra
  proxy, no host-side wrapper.</em>
</p>

<p align="center">
  <img alt="version" src="https://img.shields.io/badge/version-v0.1.0-2f80ed?style=flat-square" />
  <img alt="targets KIOU" src="https://img.shields.io/badge/targets-KIOU%201.0.1%20(11)-ff66a3?style=flat-square" />
  <img alt="platform" src="https://img.shields.io/badge/platform-iOS%2015.0%E2%80%9326-blue?style=flat-square" />
  <img alt="arch" src="https://img.shields.io/badge/arch-arm64%20rootless-555?style=flat-square" />
  <img alt="engine" src="https://img.shields.io/badge/engine-Unity%206%20%2B%20il2cpp-black?style=flat-square" />
  <img alt="protocol" src="https://img.shields.io/badge/wire-TCP%20%2B%20CSA%20v1.2-1f9d55?style=flat-square" />
  <img alt="side" src="https://img.shields.io/badge/runs-LAN%20only-1f9d55?style=flat-square" />
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" />
</p>

---

Kiou Engine Bridge is the in-app half of a two-piece system: the tweak
runs inside KIOU and exposes a CSA TCP server on `0.0.0.0:4081`;
a CSA client on your LAN connects in, plays through the standard
`LOGIN` / `Game_Summary` / `AGREE` / `START` handshake, then
participates in the live KIOU match by submitting CSA-format moves
(`+7776FU`) and receiving the same notifications the in-game side does.
When the client plays its move, the tweak parses it and feeds it back
into KIOU's own `TryMakeMove` / `OnPlayerMoveAsync` paths so the
on-device match advances exactly as if you had played it yourself.

No proxy server, no cloud, no third-party service — one ~140 KB dylib
on the phone, one TCP socket to a LAN box. See `docs/csa_protocol.md`
for the full wire contract.

KEB exposes the standard CSA v1.2 surface on the TCP link:

**KEB → client**

| Lines | Notes |
|---|---|
| `LOGIN:<name> OK`, `LOGOUT:completed` | session control |
| `BEGIN Game_Summary ... END Game_Summary` | full match preamble, includes `KIOU_*` extension lines |
| `START:<Game_ID>` | after `AGREE` |
| `<sign><from><to><PIECE>,T<n>` | per-move notification, both colours |
| `#RESIGN` / `#SENNICHITE` / `#JISHOGI` / `#CHUDAN` + `#WIN` / `#LOSE` / `#DRAW` | match end |

**client → KEB**

| Lines | Notes |
|---|---|
| `LOGIN <name> <pass>` | accepted unconditionally |
| `LOGOUT` | tears the session down |
| `AGREE [<id>]` / `REJECT [<id>]` | advance / decline pre-match |
| `<sign><from><to><PIECE>` | client's move; injected into KIOU |
| `%TORYO` | drives `GameOrchestrator.RequestSurrender` |
| `%KACHI` / `%CHUDAN` | client learns; KIOU is not signalled |

The full mapping (every CSA field, what KIOU exposes, what we drop)
lives in `docs/csa_compatibility.md`. The wire-level state machine and
example session are in `docs/csa_protocol.md`.

## CSA protocol v1.2 compatibility

KEB targets the [CSA TCP/IP server protocol
v1.2.1](http://www2.computer-shogi.org/protocol/tcp_ip_server_121.html).
The table below summarises coverage at a glance; see
`docs/csa_compatibility.md` for per-field detail.

| Area | Status | Notes |
|---|---|---|
| Session (`LOGIN` / `LOGOUT` / liveness `\n`) | ✅ | Credentials accepted unconditionally. |
| `BEGIN Game_Summary` negotiation | ✅ | `AGREE` / `REJECT` handled; see deviation note below. |
| `BEGIN Time` block | ⚠️ partial | `Total_Time`, `Byoyomi`, `Increment` written. `Delay`, `Least_Time_Per_Move`, `Time_Roundup` omitted (KIOU does not expose them). |
| Initial position `BEGIN Position` | ✅ | Full 9×9 board + hand pieces in CSA form, derived from KIOU's live SFEN. |
| Per-turn move exchange with `,T<n>` | ✅ | Both colours notified. `T<n>` omitted in modes without authoritative clocks (VsAI / LocalPvP). |
| `%TORYO` (resign) | ✅ | Calls `GameOrchestrator.RequestSurrender`. |
| `%KACHI` (nyugyoku win) | ⚠️ partial | KEB learns and sends `#JISHOGI`; KIOU side is not signalled (no public declaration API yet). |
| `%CHUDAN` (abort) | ⚠️ partial | KEB sends `#CHUDAN`; KIOU is not notified. |
| `#WIN` / `#LOSE` / `#DRAW` result delivery | ✅ | |
| `#RESIGN` / `#SENNICHITE` reason markers | ✅ | |
| `#TIME_UP` / `#ILLEGAL_MOVE` reason markers | ⛔ | Emitted as `#RESIGN` — KIOU does not expose end-reason detail. |
| `To_Move` in handicap games | ⚠️ | Derived from KIOU_Sfen side-to-move; older builds hard-coded `+`. |
| Multi-client fanout | ⛔ | One client at a time; a new connect preempts the prior session. |

**Key deviation from the spec.** KIOU's CPU starts moving as soon as the
match begins, before the client can reply with `AGREE`. KEB therefore
emits `START:<Game_ID>` immediately alongside `Game_Summary` and skips
the `AGREE_WAIT` barrier — clients receive `START:` before their `AGREE`
is acknowledged, which Floodgate-grade clients accept silently.

### KIOU_* extensions

KEB inserts vendor-prefixed lines inside `Game_Summary` for data CSA has
no equivalent for. A strict CSA parser must ignore unknown keys.

| Key | Example value | Description |
|---|---|---|
| `KIOU_Mode` | `VsAI` | Match mode: `VsAI`, `LocalPvP`, `OnlinePvP`, `RecordReplay`, `Spectate`. |
| `KIOU_StartPosition` | `Standard` | Initial position type (e.g. `HandicapLance`, `TsumeShogi`). |
| `KIOU_Sfen` | `lnsgk…` | Full SFEN of the starting position; used to set the board for non-standard starts. |
| `KIOU_Rank+` / `KIOU_Rank-` | `六段` | Player rank (Online matches). |
| `KIOU_Rate+` / `KIOU_Rate-` | `1832` | Player rate; omitted when zero. |
| `KIOU_UserId+` / `KIOU_UserId-` | `550e8400-e29b-41d4-a716-446655440000` | Player user id (UUID format); omitted when blank. |
| `KIOU_StartedAt` | `2026-06-16T09:30:03Z` | Wall-clock ISO 8601 UTC at match start. |

## Install

### Jailbroken device (rootless)

`make package install` transfers and installs the `.deb` over SSH.
Requires `openssh-server` on the device (install via Sileo/Zebra).

```sh
make package
make package install THEOS_DEVICE_IP=<device-ip>
```

The dylib lands at `/var/jb/Library/MobileSubstrate/DynamicLibraries/KiouEngineBridge.dylib`
and is loaded by ElleKit on next launch. Respring or relaunch KIOU, then
point your CSA client at `tcp://<device-ip>:4081`.

### Jailed dylib (TrollStore)

TrollStore is only supported on specific iOS versions. Check the
[supported versions table](https://ios.cfw.guide/installing-trollstore/)
before proceeding.

```sh
make JAILED=1
# -> packages/jailed/KiouEngineBridge.dylib
```

Stage inside the decrypted KIOU `.app/Frameworks/`, add an `LC_LOAD_DYLIB`,
and install via TrollStore.

### Patched IPA (Sideload)

For devices where TrollStore is unavailable. Install the patched IPA with
[Sideloadly](https://sideloadly.io/) or [AltStore](https://altstore.io/).

Requires a **decrypted** KIOU IPA (e.g. obtained via [palera1n](https://palera.in/) +
Filza, or [TrollDecrypt](https://github.com/donato-fiore/TrollDecrypt)). The
App Store download is FairPlay-encrypted and cannot be patched directly.

```sh
make BINPATCH=1
# -> packages/binpatch/KiouEngineBridge.dylib
```

Then build the patched IPA:

```sh
shared/tools/build_patched_ipa.sh \
  --recipe kiouenginebridge \
  --framework UnityFramework \
  --dylib packages/binpatch/KiouEngineBridge.dylib \
  --input Kiou-1.0.1.ipa
# -> Kiou-1.0.1-patched.ipa
```

Unlike runtime hook engines (Substrate, Dobby, frida-gum), the static
binary patch never writes to `__TEXT` at runtime and survives the iOS 18
Code Signing Monitor (CSM) — the binpatch flavour covers iOS 15.0 – 18.x.

All three build flavours ship the full CSA protocol surface — Game_Summary,
per-move notifications, resign / draw handling. See
`docs/plans/kiou_engine_bridge_binpatch.md` § 2 for the full build matrix.

## Compatibility

| | |
|---|---|
| **KIOU app version** | `1.0.1` (`CFBundleVersion` 11) |
| **KIOU minimum iOS** | 10.0 (`MinimumOSVersion` in app bundle) |
| **KiouEngineBridge minimum iOS** | 15.0 |
| **Tested on** | 15.0 – 26, arm64 |
| **Distribution** | Jailbroken `.deb`, TrollStore-injected jailed `.dylib`, Patched IPA (Sideloadly / AltStore) |
| **Engine wire** | CSA server protocol v1.2 over plain TCP (`:4081`) |

All hook sites are RVA-pinned to this exact KIOU build. After a KIOU update
the RVAs will drift.

## Requirements

- [Theos](https://theos.dev/) with the standard iOS toolchain installed
  (`$THEOS` set). Kiou Engine Bridge is pure Objective-C — no Orion,
  no Swift runtime.
- iOS 15.0–26, arm64.
- For the jailed (sideload) path: a decrypted copy of the KIOU `.ipa`.

### Developer hooks

```sh
make hooks
```

Registers `scripts/` as the git hooks path so `scripts/pre-commit` fires
before every commit. When a commit touches `recipes/*.py` or
`shared/tools/`, the hook runs `tools.verify_sites` to cross-check every
`_SITES` row against `assets/dump.cs.index.json`. If the dump index is
absent (not committed to the repo) the hook exits 0 and prints a heads-up —
it is a local-only gate, not a CI requirement.

## Where the logs go

The dylib writes its own diagnostic log into the KIOU sandbox:

```
<KIOU sandbox>/tmp/kiouenginebridge.log
```

— which translates to `/var/mobile/Containers/Data/Application/<UUID>/tmp/kiouenginebridge.log`
on a jailbroken device. Tail it over SSH to watch matches and the
CSA handshake resolve in real time:

```sh
ssh root@<device-ip> 'tail -F /var/mobile/Containers/Data/Application/*/tmp/kiouenginebridge.log'
```

Each match produces `[MMODE]` lifecycle lines, `[CSA]` connection
events, and `[CSA-ENG]` engine-state transitions interleaved with the
move-injection results.

## License

Released under the [MIT License](LICENSE) — see the `LICENSE` file for the
full text.
