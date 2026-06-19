<h1 align="center">Wars Engine Bridge</h1>

<p align="center">
  <img src="icon.webp" alt="Wars Engine Bridge icon" width="180" />
</p>

<p align="center">
  <em>Turn <strong>ShogiWars</strong> into a CSA match server. The tweak speaks
  the standard CSA server protocol on TCP <code>:4081</code>, so any CSA
  client can connect over LAN and play against ShogiWars's live board — no extra
  proxy, no host-side wrapper.</em>
</p>

<p align="center">
  <img alt="version" src="https://img.shields.io/badge/version-v0.1.0-2f80ed?style=flat-square" />
  <img alt="targets ShogiWars" src="https://img.shields.io/badge/targets-ShogiWars%2011.0.1%20(28)-ff66a3?style=flat-square" />
  <img alt="platform" src="https://img.shields.io/badge/platform-iOS%2015.0%E2%80%9326-blue?style=flat-square" />
  <img alt="arch" src="https://img.shields.io/badge/arch-arm64%20rootless-555?style=flat-square" />
  <img alt="engine" src="https://img.shields.io/badge/engine-Unity%20%2B%20il2cpp-black?style=flat-square" />
  <img alt="protocol" src="https://img.shields.io/badge/wire-TCP%20%2B%20CSA%20v1.2-1f9d55?style=flat-square" />
  <img alt="side" src="https://img.shields.io/badge/runs-LAN%20only-1f9d55?style=flat-square" />
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" />
</p>

---

Wars Engine Bridge is the in-app half of a two-piece system: the tweak
runs inside ShogiWars and exposes a CSA TCP server on `0.0.0.0:4081`;
a CSA client on your LAN connects in, plays through the standard
`LOGIN` / `Game_Summary` / `AGREE` / `START` handshake, then
participates in the live ShogiWars match by submitting CSA-format moves
(`+7776FU`) and receiving the same notifications the in-game side does.
When the client plays its move, the tweak parses it and injects it into
ShogiWars's own move pipeline so the on-device match advances exactly as
if you had played it yourself.

No proxy server, no cloud, no third-party service — one dylib on the
phone, one TCP socket to a LAN box. See `docs/csa_protocol.md` for the
full wire contract.

WEB exposes the standard CSA v1.2 surface on the TCP link:

**WEB → client**

| Lines | Notes |
|---|---|
| `LOGIN:<name> OK`, `LOGOUT:completed` | session control |
| `BEGIN Game_Summary ... END Game_Summary` | full match preamble, includes `WARS_*` extension lines |
| `START:<Game_ID>` | after `AGREE` |
| `<sign><from><to><PIECE>,T<n>` | per-move notification, both colours |
| `#RESIGN` / `#TIME_UP` / `#TSUMI` / `#SENNICHITE` / `#OUTE_SENNICHITE` / `#JISHOGI` / `#MAX_MOVES` / `#CHUDAN` + `#WIN` / `#LOSE` / `#DRAW` | match end |

**client → WEB**

| Lines | Notes |
|---|---|
| `LOGIN <name> <pass>` | accepted unconditionally |
| `LOGOUT` | tears the session down |
| `AGREE [<id>]` / `REJECT [<id>]` | advance / decline pre-match |
| `<sign><from><to><PIECE>` | client's move; injected into ShogiWars |
| `%TORYO` | calls `ShowResignAlertDialog` |
| `%KACHI` / `%CHUDAN` | client learns; ShogiWars is not signalled |
| `%%TIME` | WEB responds with a `BEGIN Time … END Time` block containing `Remaining_Time_Ms+`, `Remaining_Time_Ms-`, `Byoyomi_Ms` (PLAYING only) |

The full mapping (every CSA field, what ShogiWars exposes, what we drop)
lives in `docs/csa_compatibility.md`. The wire-level state machine and
example session are in `docs/csa_protocol.md`.

## CSA protocol v1.2 compatibility

WEB targets the [CSA TCP/IP server protocol
v1.2.1](http://www2.computer-shogi.org/protocol/tcp_ip_server_121.html).
The table below summarises coverage at a glance; see
`docs/csa_compatibility.md` for per-field detail.

| Area | Status | Notes |
|---|---|---|
| Session (`LOGIN` / `LOGOUT` / liveness `\n`) | ✅ | Credentials accepted unconditionally. |
| `BEGIN Game_Summary` negotiation | ✅ | `AGREE` / `REJECT` handled. |
| `BEGIN Time` block | ✅ | `Total_Time`, `Byoyomi`, `Remaining_Time+/-` written. Byoyomi is per-player (`sente_byoyomi` / `gote_byoyomi`). |
| Initial position `BEGIN Position` | ✅ | Full 9×9 board + hand pieces in CSA form, derived from ShogiWars's live position. |
| Per-turn move exchange with `,T<n>` | ✅ | Both colours notified. |
| `%TORYO` (resign) | ✅ | Calls `ShowResignAlertDialog`. |
| `%KACHI` (nyugyoku win) | ⚠️ partial | WEB learns and sends `#JISHOGI`; ShogiWars side is not signalled. |
| `%CHUDAN` (abort) | ⚠️ partial | WEB sends `#CHUDAN`; ShogiWars is not notified. |
| `#WIN` / `#LOSE` / `#DRAW` result delivery | ✅ | |
| `#RESIGN` reason marker | ✅ | `TORYO` / `DISCONNECT` reasons. |
| `#TIME_UP` reason marker | ✅ | `TIMEOUT` reason. |
| `#TSUMI` reason marker | ✅ | `CHECKMATE` reason. |
| `#SENNICHITE` reason marker | ✅ | `SENNICHI` reason. |
| `#OUTE_SENNICHITE` reason marker | ✅ | `OUTE_SENNICHI` reason. |
| `#JISHOGI` reason marker | ✅ | `ENTERINGKING` reason. |
| `#MAX_MOVES` reason marker | ✅ | `PLY_LIMIT` reason. |
| Multi-client fanout | ⛔ | One client at a time; a new connect preempts the prior session. |

### WARS_* extensions

WEB inserts vendor-prefixed lines inside `Game_Summary` for data CSA has
no equivalent for. A strict CSA parser must ignore unknown keys.

| Key | Example value | Description |
|---|---|---|
| `WARS_Mode` | `Online` | Match mode: `Online`, `Practice`. |
| `WARS_Dan+` / `WARS_Dan-` | `3` | Player dan rank (integer). |
| `WARS_Points+` / `WARS_Points-` | `1450` | Player rating points. |
| `WARS_Favsenpou+` / `WARS_Favsenpou-` | `居飛車` | Player's favourite opening style. |
| `WARS_StartedAt` | `2026-06-16T09:30:03Z` | Wall-clock ISO 8601 UTC at match start. |

## Install

### Jailbroken device (rootless)

`make package install` transfers and installs the `.deb` over SSH.
Requires `openssh-server` on the device (install via Sileo/Zebra).

```sh
make package
make package install THEOS_DEVICE_IP=<device-ip>
```

The dylib lands at `/var/jb/Library/MobileSubstrate/DynamicLibraries/WarsEngineBridge.dylib`
and is loaded by ElleKit on next launch. Respring or relaunch ShogiWars, then
point your CSA client at `tcp://<device-ip>:4081`.

### Jailed dylib (TrollStore)

TrollStore is only supported on specific iOS versions. Check the
[supported versions table](https://ios.cfw.guide/installing-trollstore/)
before proceeding.

```sh
make JAILED=1
# -> packages/jailed/WarsEngineBridge.dylib
```

Stage inside the decrypted ShogiWars `.app/Frameworks/`, add an `LC_LOAD_DYLIB`,
and install via TrollStore.

### Patched IPA (Sideload)

For devices where TrollStore is unavailable. Install the patched IPA with
[Sideloadly](https://sideloadly.io/) or [AltStore](https://altstore.io/).

Requires a **decrypted** ShogiWars IPA (e.g. obtained via [palera1n](https://palera.in/) +
Filza, or [TrollDecrypt](https://github.com/donato-fiore/TrollDecrypt)). The
App Store download is FairPlay-encrypted and cannot be patched directly.

```sh
make chinlan FINALPACKAGE=1
# -> packages/chinlan/WarsEngineBridge.dylib
```

Then build the patched IPA:

```sh
shared/tools/build_patched_ipa.sh \
  --recipe warsenginebridge \
  --framework UnityFramework \
  --dylib packages/chinlan/WarsEngineBridge.dylib \
  --input ShogiWars-11.0.1.ipa
# -> ShogiWars-11.0.1-patched.ipa
```

Unlike runtime hook engines (Substrate, Dobby, frida-gum), the static
binary patch never writes to `__TEXT` at runtime and survives the iOS 18
Code Signing Monitor (CSM) — the chinlan flavour covers iOS 15.0 – 18.x.

All three build flavours ship the full CSA protocol surface — Game_Summary,
per-move notifications, resign / draw handling, `%%TIME` time queries.

## Compatibility

| | |
|---|---|
| **ShogiWars app version** | `11.0.1` (`CFBundleVersion` 28) |
| **ShogiWars bundle ID** | `jp.co.heroz.ShogiWars` |
| **ShogiWars minimum iOS** | 10.0 (`MinimumOSVersion` in app bundle) |
| **WarsEngineBridge minimum iOS** | 15.0 |
| **Tested on** | 15.0 – 26, arm64 |
| **Distribution** | Jailbroken `.deb` (rootless), TrollStore-injected jailed `.dylib`, Chinlan-patched IPA (Sideloadly / AltStore) |
| **Engine wire** | CSA server protocol v1.2 over plain TCP (`:4081`) |

All hook sites are RVA-pinned to this exact ShogiWars build. After a ShogiWars update
the RVAs will drift.

## Requirements

- [Theos](https://theos.dev/) with the standard iOS toolchain installed
  (`$THEOS` set). Wars Engine Bridge is pure Objective-C — no Orion,
  no Swift runtime.
- iOS 15.0–26, arm64.
- For the jailed (sideload) path: a decrypted copy of the ShogiWars `.ipa`.

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

The dylib writes its own diagnostic log into the ShogiWars sandbox:

```
<ShogiWars sandbox>/tmp/warsenginebridge.log
```

— which translates to `/var/mobile/Containers/Data/Application/<UUID>/tmp/warsenginebridge.log`
on a jailbroken device. Tail it over SSH to watch matches and the
CSA handshake resolve in real time:

```sh
ssh root@<device-ip> 'tail -F /var/mobile/Containers/Data/Application/*/tmp/warsenginebridge.log'
```

Each match produces `[MMODE]` lifecycle lines, `[CSA]` connection
events, and `[CSA-ENG]` engine-state transitions interleaved with the
move-injection results.

## License

Released under the [MIT License](LICENSE) — see the `LICENSE` file for the
full text.
