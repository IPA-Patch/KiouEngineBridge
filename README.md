<h1 align="center">Kiou Engine Bridge</h1>

<p align="center">
  <img src="icon.webp" alt="Kiou Engine Bridge icon" width="180" />
</p>

<p align="center">
  <em>Bridge <strong>KIOU</strong> to a desktop USI shogi engine (YaneuraOu
  and friends) — observe the live board, ship the SFEN to the engine,
  replay the engine's <code>bestmove</code> back into the running match.<br/>
  Runs entirely client-side; the engine sits on a LAN box you already trust.</em>
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-iOS%2015.0%E2%80%9318.x-blue?style=flat-square" />
  <img alt="arch" src="https://img.shields.io/badge/arch-arm64%20rootless-555?style=flat-square" />
  <img alt="target" src="https://img.shields.io/badge/target-com.neconome.shogi-ff66a3?style=flat-square" />
  <img alt="engine" src="https://img.shields.io/badge/engine-Unity%206%20%2B%20il2cpp-black?style=flat-square" />
  <img alt="protocol" src="https://img.shields.io/badge/wire-WebSocket%20%2B%20USI-1f9d55?style=flat-square" />
  <img alt="side" src="https://img.shields.io/badge/runs-LAN%20only-1f9d55?style=flat-square" />
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" />
  <img alt="status" src="https://img.shields.io/badge/scope-authorized%20testing%20only-c69214?style=flat-square" />
</p>

---

Kiou Engine Bridge is the in-app half of a two-piece system: the tweak
runs inside KIOU and exposes a tiny WebSocket sink on `0.0.0.0:9527`;
a host-side bridge (your machine running YaneuraOu or any other USI
engine) connects in, speaks the standard USI protocol, and receives
`position sfen ...` / `go ...` lines built from the live KIOU board.
When the engine replies with `bestmove <usi>`, the tweak feeds that
move back into KIOU's own `TryMakeMove` / `OnPlayerMoveAsync` paths so
the on-device match advances exactly as if you had played it yourself.

No proxy server, no cloud, no third-party service — one ~120 KB dylib
on the phone, one TCP socket to a LAN box, and the engine of your choice
on the other end.

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
- Replay anything that didn't come from the engine. Only frames the
  attached WebSocket client sends as `bestmove <usi>` (after a
  matching `go`) make it into the move pipeline.

Uninstalling the dylib returns KIOU to a fully vanilla state.

## What you get

Four actors, three wires. KIOU is the game itself; Bridge is this
tweak loaded into KIOU's process; Wrapper is the host-side process
that translates between WebSocket and a vanilla USI engine's stdio;
YaneuraOu (or any other USI engine) is the thinking part.

- **KIOU <-> Bridge** — in-process: il2cpp hook callbacks for the
  read side, function-pointer calls into `Move.Create` /
  `OnPlayerMoveAsync` / `TryMakeMove` for the inject side.
- **Bridge <-> Wrapper** — WebSocket text frames on
  `ws://<device>:9527`, USI lines + sidecar `meta{...}` lines.
- **Wrapper <-> YaneuraOu** — stdio pipes (the way YaneuraOu
  already expects to be driven).

```mermaid
sequenceDiagram
    autonumber
    participant K as KIOU
    participant B as Bridge (this tweak)
    participant W as Wrapper (host)
    participant E as YaneuraOu

    Note over K,B: in-process hooks
    Note over B,W: ws://device:9527 (USI + meta)
    Note over W,E: stdio pipes

    Note over B,W: USI handshake
    W->>B: usi
    B-->>W: id name ... / id author ... / usiok
    W->>B: isready
    B-->>W: readyok
    W->>B: usinewgame

    Note over K,W: Match start — Bridge emits sidecar meta
    K-->>B: IMatchMode.InitializeAsync (latch self / local_player)
    B-->>W: meta{"type":"match_start","mode":"OnlinePvPMode","local_player":0,...}

    loop Per move while it's our turn
        K-->>B: TryMakeMove observation -> SFEN / side_to_move
        B->>W: position sfen <SFEN>
        B->>W: go btime ... wtime ...
        W->>E: position sfen <SFEN> / go ...
        E-->>W: bestmove 7g7f
        W->>B: bestmove 7g7f
        Note over B,K: inject_apply -> Move.Create -> OnPlayerMoveAsync -> TryMakeMove
        B->>K: replay move through KIOU's move pipeline
        B-->>W: meta{"type":"move","usi":"7g7f","sfen_after":"...",...}
    end

    K-->>B: IMatchMode.OnMatchEndAsync (result + final SFEN + GetUSIText)
    B-->>W: meta{"type":"match_end","result":"win","final_sfen":"...","usi_text":"..."}
```

Each `meta` frame is a single line prefixed with the literal
`meta` followed by a single JSON object, so the Wrapper can demux
it from real USI traffic without parsing JSON for every line.

## How it works

```mermaid
flowchart TD
    obs["Hook_LowLevelObserve<br/>Hook_MatchModeObserve<br/>Hook_OnlineObserve"]
    state(["g_gameCtrlCache &middot; g_adapterCache<br/>g_*ModeCache &middot; g_localPlayer*"])
    sfen["sfenFromGameController()<br/>moveToUsi()"]

    obs -- "latch self / extract SFEN+USI" --> state
    state --> sfen
    sfen --> wsout

    ws[("WebSocket :9527<br/>opcode 0x1 text frames")]
    wsout["Usi_Engine state machine<br/>BOOT / HANDSHAKE / READY /<br/>THINKING / INJECTING"]
    wsout --> ws
    ws -- "bestmove &lt;usi&gt;" --> wsin
    wsin["inject_apply(usi)"]

    wsin --> commit["Move.Create / CreateDrop<br/>OnPlayerMoveAsync<br/>Adapter.TryMakeMove"]
    commit --> kiou(["KIOU board state advances"])

    state --> meta["Meta_Emitter (sidecar)"]
    meta --> ws
```

Two protocol streams share one TCP port:

| Stream | Direction | Wire | Purpose |
|---|---|---|---|
| **USI** | bidirectional | one USI command per text frame | drive the engine, accept `bestmove` back |
| **meta** | tweak -> host | `meta{...json}\n` per frame | match lifecycle + per-move record for KIF assembly |

The USI state machine (`Usi_Engine.m`) walks the standard
`usi` -> `usiok` -> `isready` -> `readyok` -> `usinewgame` -> `position` ->
`go` -> `bestmove` cycle; on `bestmove` it hops onto the Unity main
thread and calls `inject_apply` to commit the move through KIOU's own
move pipeline.

## Install

Pick the row that matches how your device is signed.

### Jailbroken (rootless — Dopamine / palera1n)

```sh
make package install THEOS_DEVICE_IP=<device-ip>
```

The dylib lands at `/var/jb/Library/MobileSubstrate/DynamicLibraries/KiouEngineBridge.dylib`
and is loaded by MobileSubstrate / ElleKit on next launch. Respring or
relaunch KIOU, then point your host bridge at `ws://<device-ip>:9527`.

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

**Note:** the binpatch build omits the `meta` sidecar lines. KIF
assembly on the host bridge depends on `meta {…}` lines emitted by the
JB build's `GameStateStore` observation hooks. Non-JB users get USI
handshake + position/go/bestmove and can still play through YaneuraOu,
but no KIF record is assembled. See
`docs/plans/kiou_engine_bridge_binpatch.md` § 2 for the full build
matrix.

## Compatibility

| | |
|---|---|
| **KIOU app version** | `1.0.1` (`CFBundleVersion` 11) |
| **iOS (JB rootless build)** | 15.0 – 16.5, arm64, rootless |
| **iOS (non-JB binpatch build)** | 15.0 – 18.x, arm64 |
| **Engine wire** | standard USI protocol over WebSocket text frames |

All hooks are pinned to RVAs from this exact KIOU build's
`UnityFramework`. After a KIOU update the RVAs will drift and the
tweak will silently no-op (or crash on a method whose signature
changed). **Don't install this dylib against a KIOU version other
than the one above without re-deriving every RVA first.**

## Requirements

- [Theos](https://theos.dev/) with the standard iOS toolchain installed
  (`$THEOS` set). Kiou Engine Bridge is pure Objective-C — no Orion,
  no Swift runtime.
- iOS 15.0–16.5, arm64, rootless layout.
- For the jailed (sideload) path: a decrypted copy of the KIOU `.ipa`.
- A host-side bridge that speaks USI over WebSocket against
  `ws://<device-ip>:9527`. YaneuraOu wrapped in a tiny WS adapter is
  the reference setup.

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
  Inject_Move.m                 # bestmove -> Move.Create / TryMakeMove path
  Usi_Engine.m                  # USI state machine (Phase 2)
  Server_WebSocket.m            # 0.0.0.0:9527 listener + recv loop
  Meta_Emitter.m                # sidecar JSON stream for KIF assembly
  BinpatchDispatcher.m          # binpatch-only: publishes hook dispatcher into __bss SLOT

Sources/Common/                 # IPA-Patch/Common submodule (logging, il2cpp, hookengine)
shared/                         # IPA-Patch/Shared submodule (binpatch tooling)
```

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
