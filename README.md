<h1 align="center">Kiou Engine Bridge</h1>

<p align="center">
  <img src="icon.webp" alt="Kiou Engine Bridge icon" width="180" />
</p>

<p align="center">
  <em>Turn <strong>KIOU</strong> into a CSA match server. The tweak speaks
  the standard CSA server protocol on TCP <code>:4081</code>, so any CSA
  engine (Apery / 技巧 / YaneuraOu in CSA mode / shogi-server clients)
  can connect over LAN and play against KIOU's live board — no extra
  proxy, no host-side wrapper.</em>
</p>

<p align="center">
  <img alt="version" src="https://img.shields.io/badge/version-v0.1.0-2f80ed?style=flat-square" />
  <img alt="targets KIOU" src="https://img.shields.io/badge/targets-KIOU%201.0.1%20(11)-ff66a3?style=flat-square" />
  <img alt="platform" src="https://img.shields.io/badge/platform-iOS%2015.0%E2%80%9318.x-blue?style=flat-square" />
  <img alt="arch" src="https://img.shields.io/badge/arch-arm64%20rootless-555?style=flat-square" />
  <img alt="engine" src="https://img.shields.io/badge/engine-Unity%206%20%2B%20il2cpp-black?style=flat-square" />
  <img alt="protocol" src="https://img.shields.io/badge/wire-TCP%20%2B%20CSA%20v1.2-1f9d55?style=flat-square" />
  <img alt="side" src="https://img.shields.io/badge/runs-LAN%20only-1f9d55?style=flat-square" />
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" />
  <img alt="status" src="https://img.shields.io/badge/scope-authorized%20testing%20only-c69214?style=flat-square" />
</p>

---

Kiou Engine Bridge is the in-app half of a two-piece system: the tweak
runs inside KIOU and exposes a CSA TCP server on `0.0.0.0:4081`;
a CSA engine on your LAN connects in, plays through the standard
`LOGIN` / `Game_Summary` / `AGREE` / `START` handshake, then
participates in the live KIOU match by submitting CSA-format moves
(`+7776FU`) and receiving the same notifications the in-game side does.
When the engine plays its move, the tweak parses it and feeds it back
into KIOU's own `TryMakeMove` / `OnPlayerMoveAsync` paths so the
on-device match advances exactly as if you had played it yourself.

No proxy server, no cloud, no third-party service — one ~140 KB dylib
on the phone, one TCP socket to a LAN box, and the CSA engine of your
choice on the other end. See `docs/csa_protocol.md` for the full wire
contract.

> **Historical note.** Earlier revisions of KEB spoke a custom USI
> extension over WebSocket on port `9527`. The USI implementation lives
> in `Sources/KiouEngineBridge/{Server_WebSocket,Usi_Engine}.m` behind
> `#if 0` blocks and is excluded from every build flavour; the surviving
> wire description is in `docs/archive/usi_bridge_protocol.md`.

### Observation + scoped injection

Kiou Engine Bridge is **read-mostly with a single narrow write path**.
The observation hooks (`Hook_LowLevelObserve`, `Hook_MatchModeObserve`,
`Hook_OnlineObserve`, `Hook_GameOrchestratorObserve`,
`Hook_GameStateStoreObserve`) only read — they latch live
`GameController` / `ShogiGameAdapter` / `OnlinePvPMode` pointers,
convert `Sunfish.Move` to USI, walk `PositionHistory` to extract SFEN.
No game-state field is mutated through these.

The injection layer (`Inject_Move`) calls into KIOU's own move-commit
methods as function pointers:

- `Sunfish.Move.Create` / `Move.CreateDrop` to assemble the
  packed-uint32 move,
- `ShogiGameAdapter.TryMakeMove(out Move)` /
  `GameController.TryMakeMove(Move)` to advance the headless engine,
- `IMatchMode.OnPlayerMoveAsync(Move, CancellationToken)` so the UI
  redraws and the server (Online) sees the move.

What the injection layer is **not** allowed to do:

- Touch il2cpp object fields directly. The shared header
  `il2cpp.h` is intentionally read-only; the `writeU8` / `writeI32`
  helpers that `KiouEditor` carries in its own `Internal.h` are
  deliberately **not** included here. Any future "tweak a board field"
  regression must opt in explicitly — they don't sneak in via the
  shared header.
- Replay anything that didn't come from the engine. Only CSA move
  lines (`+7776FU` / `-3334FU` / `+0055FU`) submitted by the connected
  engine make it into the move pipeline. `%TORYO` / `%KACHI` /
  `%CHUDAN` are accepted but routed to dedicated end-of-match handlers
  rather than the inject path.

Uninstalling the dylib returns KIOU to a fully vanilla state.

## What you get

Three actors, two wires. KIOU is the game itself; Bridge is this tweak
loaded into KIOU's process; the CSA engine is the thinking part on the
other end of the LAN socket.

- **KIOU <-> Bridge** — in-process: il2cpp hook callbacks for the
  read side, function-pointer calls into `Move.Create` /
  `OnPlayerMoveAsync` / `TryMakeMove` / `GameOrchestrator.RequestSurrender`
  for the inject side.
- **Bridge <-> CSA engine** — plain TCP on `tcp://<device>:4081`,
  CSA server protocol v1.2.

```mermaid
sequenceDiagram
    autonumber
    participant K as KIOU
    participant B as Bridge (this tweak)
    participant E as CSA engine

    Note over K,B: in-process hooks
    Note over B,E: tcp://device:4081 (CSA v1.2)

    Note over B,E: Session handshake
    E->>B: LOGIN test pass
    B-->>E: LOGIN:test OK

    Note over K,E: Match start
    K-->>B: IMatchMode.InitializeAsync (latch MatchConfig / local_player)
    B-->>E: BEGIN Game_Summary ... END Game_Summary
    E->>B: AGREE
    B-->>E: START:<Game_ID>

    loop Per move
        K-->>B: NotifyPieceMoved (move bits, side)
        B-->>E: +7776FU,T10  (or -3334FU,T8 for white)
        E->>B: +2726FU
        Note over B,K: inject_apply -> Move.Create -> OnPlayerMoveAsync -> TryMakeMove
        B->>K: replay move through KIOU's move pipeline
    end

    K-->>B: IMatchMode.OnMatchEndAsync (result)
    B-->>E: #RESIGN
    B-->>E: #WIN
```

## How it works

```mermaid
flowchart TD
    obs["Hook_LowLevelObserve<br/>Hook_MatchModeObserve<br/>Hook_OnlineObserve<br/>Hook_GameStateStoreObserve"]
    state(["g_gameCtrlCache &middot; g_adapterCache<br/>g_*ModeCache &middot; g_localPlayer*<br/>g_csaMatchConfig"])
    convert["Csa_Convert<br/>(square / piece / SFEN -> CSA)"]

    obs -- "latch state / surface SFEN+move" --> state
    state --> convert
    convert --> csaout

    tcp[("TCP :4081<br/>line-oriented UTF-8")]
    csaout["Csa_Engine state machine<br/>BOOT / LOGIN / AGREE_WAIT /<br/>PLAYING / GAME_OVER"]
    csaout --> tcp
    tcp -- "+7776FU / %TORYO" --> csain
    csain["Csa_Engine inbound dispatch"]

    csain --> commit["inject_apply<br/>(Move.Create / OnPlayerMoveAsync / TryMakeMove)"]
    csain --> resign["Inject_Resign<br/>(GameOrchestrator.RequestSurrender)"]
    commit --> kiou(["KIOU board state advances"])
    resign --> kiou

    state --> gameinfo["Csa_GameInfo<br/>(Game_Summary + KIOU_* lines)"]
    gameinfo --> tcp
```

KEB exposes the standard CSA v1.2 surface on the TCP link:

| Direction | Lines | Notes |
|---|---|---|
| tweak → engine | `LOGIN:<name> OK`, `LOGOUT:completed` | session control |
| tweak → engine | `BEGIN Game_Summary ... END Game_Summary` | full match preamble, includes `KIOU_*` extension lines |
| tweak → engine | `START:<Game_ID>` | after `AGREE` |
| tweak → engine | `<sign><from><to><PIECE>,T<n>` | per-move notification, both colours |
| tweak → engine | `#RESIGN` / `#SENNICHITE` / `#JISHOGI` / `#CHUDAN` + `#WIN` / `#LOSE` / `#DRAW` | match end |
| engine → tweak | `LOGIN <name> <pass>` | accepted unconditionally |
| engine → tweak | `LOGOUT` | tears the session down |
| engine → tweak | `AGREE [<id>]` / `REJECT [<id>]` | advance / decline pre-match |
| engine → tweak | `<sign><from><to><PIECE>` | engine's move; injected via `inject_apply` |
| engine → tweak | `%TORYO` | drives `GameOrchestrator.RequestSurrender` |
| engine → tweak | `%KACHI` / `%CHUDAN` | engine learns; KIOU is not signalled |

The full mapping (every CSA field, what KIOU exposes, what we drop)
lives in `docs/csa_compatibility.md`. The wire-level state machine and
example session are in `docs/csa_protocol.md`.

## Install

Pick the row that matches how your device is signed.

### Jailbroken (rootless — Dopamine / palera1n)

```sh
make package install THEOS_DEVICE_IP=<device-ip>
```

The dylib lands at `/var/jb/Library/MobileSubstrate/DynamicLibraries/KiouEngineBridge.dylib`
and is loaded by MobileSubstrate / ElleKit on next launch. Respring or
relaunch KIOU, then point your CSA engine at `tcp://<device-ip>:4081`.

### Non-JB (Sideloadly / TrollStore / AltStore / Apple Developer Program)

```sh
make binpatch
# -> packages/binpatch/KiouEngineBridge.dylib

shared/tools/build_patched_ipa.sh \
  --recipe kiouenginebridge \
  --framework UnityFramework \
  --dylib packages/binpatch/KiouEngineBridge.dylib \
  --input Kiou-1.0.1.ipa
# -> Kiou-1.0.1-patched.ipa
```

The patched IPA can be installed via TrollStore (direct), Sideloadly /
AltStore (sign with Apple ID), or the Apple Developer Program (sign
with a paid cert). Unlike runtime hook engines (Substrate, Dobby,
frida-gum), the static binary patch never writes to `__TEXT` at
runtime and therefore survives the iOS 18 Code Signing Monitor (CSM) —
the binpatch flavour covers iOS 15.0 – 18.x.

All three build flavours (`make`, `make JAILED=1`, `make BINPATCH=1`)
ship the full CSA protocol surface — Game_Summary, per-move
notifications, resign / draw handling. See
`docs/plans/kiou_engine_bridge_binpatch.md` § 2 for the full build
matrix.

## Compatibility

| | |
|---|---|
| **KIOU app version** | `1.0.1` (`CFBundleVersion` 11) |
| **iOS (JB rootless build)** | 15.0 – 16.5, arm64, rootless |
| **iOS (non-JB binpatch build)** | 15.0 – 18.x, arm64 |
| **Engine wire** | CSA server protocol v1.2 over plain TCP (`:4081`) |

All hooks are pinned to RVAs from this exact KIOU build's
`UnityFramework`. After a KIOU update the RVAs will drift and the
tweak will silently no-op (or crash on a method whose signature
changed). **Don't install this dylib against a KIOU version other
than the one above without re-deriving every RVA first.**

## Versioning

Kiou Engine Bridge uses **its own [SemVer](https://semver.org/)** numbering,
independent of the KIOU app's version. The two never share a digit.

| Field | What it means |
|---|---|
| `MAJOR` | Bumped on a breaking change to the wire protocol, distribution shape, or hook interface (e.g. dropping a build flavor). |
| `MINOR` | New observation hook, new injection path, new wire-protocol feature. |
| `PATCH` | Bug / crash / wiring fix with no user-visible behaviour change. |

The **target KIOU app version** is pinned separately in the
[Compatibility](#compatibility) table above and in `recipes/kiouenginebridge.py`'s
RVA table. When KIOU itself updates, every hook site is re-derived against
the new `UnityFramework`, and that re-port lands as a PATCH or MINOR —
never a MAJOR just because the host bumped.

Releases are tagged `vMAJOR.MINOR.PATCH` on the repo. The dylib also
embeds the short git commit hash (read at build time into
`KIOU_ENGINE_BRIDGE_COMMIT`) so the exact build behind a sideloaded copy
is always recoverable.

## Requirements

- [Theos](https://theos.dev/) with the standard iOS toolchain installed
  (`$THEOS` set). Kiou Engine Bridge is pure Objective-C — no Orion,
  no Swift runtime.
- iOS 15.0–16.5, arm64, rootless layout.
- For the jailed (sideload) path: a decrypted copy of the KIOU `.ipa`.
- A CSA engine reachable on the LAN. Apery, 技巧, and YaneuraOu in CSA
  mode are reference setups. shogi-server's bundled `csa.rb` test
  client is enough to sanity-check the wire.

## Layout

```
Sources/KiouEngineBridge/
  Internal.h                    # tweak-private declarations
  Tweak.m                       # constructor + UnityFramework dyld walk
  Hook_LowLevelObserve.m        # TryMakeMove / SFEN / USI extraction
  Hook_MatchModeObserve.m       # IMatchMode lifecycle (5 modes, 3 methods)
  Hook_OnlineObserve.m          # OnlinePvPMode snapshot / result observer
  Hook_GameOrchestratorObserve.m# match-end auto-rematch helper
  Hook_GameStateStoreObserve.m  # Set*PlayerInfo capture for meta_emit
  Hook_AfkSuppress.m            # pin GameOrchestrator.IsAfkEnabled = false
  Inject_Move.m                 # CSA move -> Move.Create / TryMakeMove path
  Inject_Resign.m               # %TORYO -> GameOrchestrator.RequestSurrender
  Csa_Convert.{h,m}             # square / piece / move / SFEN <-> CSA conversion
  Csa_Engine.{h,m}              # CSA protocol state machine (BOOT/LOGIN/.../GAME_OVER)
  Csa_GameInfo.m                # Game_Summary + KIOU_* extension builder
  Server_CSA.m                  # 0.0.0.0:4081 listener + line-oriented recv loop
  BinpatchDispatcher.m          # binpatch-only: publishes hook dispatcher into __bss SLOT
  Usi_Engine.m                  # DEPRECATED (#if 0) — pre-CSA USI driver
  Server_WebSocket.m            # DEPRECATED (#if 0) — pre-CSA WS sink
  Meta_Emitter.m                # legacy JSON sidecar (no longer wired on the wire)
  Csa_Stubs.m                   # transitional no-op shims for USI symbols

Sources/Common/                 # IPA-Patch/Common submodule (logging, il2cpp, hookengine)
shared/                         # IPA-Patch/Shared submodule (binpatch tooling)
recipes/kiouenginebridge.py     # static-patch site table + cave payload builder
scripts/pre-commit              # recipe<->dump cross-check hook (install with `make hooks`)
```

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
USI handshake resolve in real time:

```sh
ssh root@<device-ip> 'tail -F /var/mobile/Containers/Data/Application/*/tmp/kiouenginebridge.log'
```

Each match produces `[MMODE]` lifecycle lines, `[WS]` connection
events, and `[USI]` engine-state transitions interleaved with the
move-injection results.

## Sibling tweaks

Kiou Engine Bridge shares its il2cpp helpers and logging plumbing with
two sister projects you can install side-by-side. All three can
coexist in the same KIOU process:

- [**Kiou Editor**](https://github.com/IPA-Patch/KiouEditor) — the
  client-side customization suite (item unlock, premium gating, engine
  tuning, voice unlock, etc).
- [**Kiou Kif Exporter**](https://github.com/IPA-Patch/KiouKifExporter) —
  saves every match as a standard KIF 2.0 file in the app sandbox,
  ready for Files.app / AirDrop / PiyoShogi.

Bridge and KifExporter use the same static-binpatch toolchain
(`shared/tools/patch_macho.py`) and can be applied to the same IPA —
their cave regions are partitioned
(`docs/plans/kiou_kif_exporter_binpatch.md` § 8). Stack both dylibs in
Sideloadly to ship a single patched IPA that does both jobs.

## Plan documents

- [`docs/plans/kiou_engine_bridge_binpatch.md`](docs/plans/kiou_engine_bridge_binpatch.md) —
  this project's static-binpatch migration plan.
- [`docs/plans/kiou_kif_exporter_binpatch.md`](docs/plans/kiou_kif_exporter_binpatch.md) —
  the sibling KifExporter recipe that pioneered the same approach.

## License

Released under the [MIT License](LICENSE) — see the `LICENSE` file for the
full text.

### Scope of use

Intended for **authorized penetration testing and personal research**. The
repository ships no proprietary KIOU assets and does not distribute the
IPA — sourcing a decrypted copy of KIOU for the sideload path is the
reader's responsibility. Online ranked play through this bridge can
affect your account's rating; the tweak does not gate that behavior,
so use against ranked matches only on accounts and in jurisdictions
where you have the authority to do so.
