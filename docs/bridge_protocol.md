# KiouEngineBridge wire protocol

KiouEngineBridge (KEB) is the iOS-side dylib that turns KIOU into a
**USI match server** — analogous in role to Floodgate or shogi-server,
but embedded inside the KIOU process rather than running as a standalone
service.

The mental model:

```
KIOU  (authoritative source of board state and clocks)
  ↕  in-process hooks
 KEB  (USI match server — negotiates the match, delivers position + clocks)
  ↕  USI over WebSocket :9527
 Engine  (connects when ready to play; just needs to return bestmove)
```

KIOU decides the match conditions (time control, handicap, opponents).
KEB reads those conditions via hooks and opens a WebSocket server that
announces them through the standard USI protocol. An engine that wants
to play connects, exchanges the USI handshake, and from that point
receives `position sfen ...` and `go btime/wtime/byoyomi` on every
turn — exactly the same two pieces of information Floodgate delivers to
each engine in a CSA match. The engine returns `bestmove`; KEB feeds
that move back into KIOU via the injection path.

Because KIOU is the authority on both board state and clocks, KEB has
no way to offer the engine a pre-negotiated time control before the
match starts — the engine learns the time budget from the first `go`
line of the first turn, not from `setoption` or a pre-game declaration.
A wrapper that wants to translate this into engine-specific search limits
(`go depth`, `go nodes`, custom byoyomi policy) can sit between KEB and
the raw engine process; KEB makes no distinction.

This document is the contract between the dylib and the connecting
engine (or wrapper). It is the authoritative description of what bytes
go on the wire; if the C source and this file disagree, the C source
wins and this file is the bug.

This document is the contract between the dylib and the host. It is the
authoritative description of what bytes go on the wire; if the C source
and this file disagree, the C source wins and this file is the bug.

Source of truth pointers:

- `Sources/KiouEngineBridge/Server_WebSocket.m` — RFC 6455 server.
- `Sources/KiouEngineBridge/Usi_Engine.m` — USI half of the protocol.
- `Sources/KiouEngineBridge/Meta_Emitter.m` — `meta` JSON half (JB build
  only; the binpatch build links the empty stubs at the top of the same
  file).

## Transport

- **TCP, plaintext, port 9527.** Bound to `0.0.0.0` from
  `Sources/KiouEngineBridge/Tweak.m:113` via
  `kiou_ws_server_start(9527)`. No TLS, no auth, no Bonjour /
  `NSLocalNetworkUsageDescription`. The model is "tweak and host live on
  the same trusted LAN."
- **WebSocket, RFC 6455 minimal subset.** Client sends a normal
  `HTTP/1.1 Upgrade: websocket` with a `Sec-WebSocket-Key`; server
  replies with the standard SHA-1 + base64 accept token. Sub-protocols
  and extensions are ignored if offered.
- **One client at a time.** A second incoming TCP connection is accepted
  only to be immediately closed with `HTTP/1.1 409 Conflict` so the
  kernel stops half-opening the handshake. The current client must
  close (or be detected dead via TCP keepalive) before a new one can
  attach.
- **Frame types used.**
  - Outbound (dylib → host): `0x1` text frames, FIN=1, unmasked. Two-
    and eight-byte extended payload-length forms are both supported.
  - Inbound (host → dylib): `0x1` text frames, FIN=1, masked per spec.
    `0x9` Ping → server replies with `0xA` Pong. `0x8` Close → server
    tears the client down. Anything else is logged at `[WS-DBG]` and
    dropped.
- **TCP keepalive.** `SO_KEEPALIVE` on, idle 5 s, interval 3 s, count 3
  — a silently dead host is reaped in roughly 15 s so the next connect
  attempt is not refused with 409.
- **Backpressure.** Outbound frames go through a serial GCD queue. If
  the in-flight backlog exceeds 128 frames the oldest pending frame is
  dropped and a `[WS]` warning is logged. The protocol is best-effort —
  the host MUST be able to recover state from observation lines alone
  and MUST NOT assume the dylib will retransmit anything.

## Logical channels

Every text frame is exactly one line. The dylib classifies its
**outbound** traffic into two channels by the first token of the line;
the **inbound** side only carries USI lines.

| Direction | Channel | Frame shape | Defined in |
|---|---|---|---|
| dylib → host | USI | one USI command per line, e.g. `usi\n`, `position sfen ...\n` | `Usi_Engine.m::usi_engine_send_line` |
| dylib → host | meta (extended USI) | `meta <subcommand> [<value>]\n` — one line per field, block-structured | `Meta_Emitter.m` (JB build only) |
| host → dylib | USI | one USI command, lines split on `\r\n` / `\n` / `\r` | `Usi_Engine.m::usi_engine_text_handler` |

Both channels use the same line-oriented format: first token is the
command or `meta`, remaining tokens are the payload. The `meta` prefix
is the channel tag; the engine parser can skip any line starting with
`meta` without breaking the USI state machine.

There is no separate channel for control or for errors. If the dylib
needs to tell the host something the host can't act on from the existing
channels, it goes into the on-device log only (`tmp/kiouenginebridge.log`
on the jailbroken build; Documents on the binpatch build) — not over the
WebSocket.

## USI channel — state machine

KEB acts as the **match-server side** of the USI protocol. The
connecting peer is a USI engine. KEB drives the full game loop — it
emits `usi`, `isready`, `usinewgame`, `position sfen ...`, `go ...`,
`stop`, `gameover`, and `quit`. The engine is expected to respond
according to the standard USI engine protocol.

`setoption` is not emitted by KEB. Match conditions are set by KIOU
before KEB is even aware of them; there is no opportunity for KEB to
pre-negotiate engine options before the match starts. If the engine
requires option configuration, a wrapper should handle that (see §
Wrapper-mediated deployment).

States are tracked atomically in `Usi_Engine.m::g_usiState`:

```
BOOT
  ↓  WS client finishes upgrade       →  send "usi"
HANDSHAKE
  ↓  inbound "usiok"                  →  send "isready"
  ↓  inbound "readyok"                →  (no usinewgame here — see Notes)
READY
  ↓  usi_engine_on_match_start fires  →  send "usinewgame"
  ↓  observation says it is our turn  →  send "position sfen ..."
                                          send "go ..."
THINKING
  ↓  inbound "bestmove <usi>"         →  inject move locally
INJECTING
  ↓  next observation arrives         →  back to READY
```

Notes:

- `usinewgame` is sent once per match start (`usi_engine_on_match_start`),
  not once per WebSocket session. On `readyok` KEB does NOT send
  `usinewgame` — it waits for the first match-start event. This avoids a
  double send on the first match while still priming the engine at each
  subsequent match.
- On WebSocket disconnect the state resets to `BOOT`.
- A match start where KEB already knows the seat and it is our turn
  triggers a 500 ms-delayed "kick" so the engine gets a `position` + `go`
  even before any opponent move fires an observation. See
  `usi_engine_try_kick_on_main`.

### dylib → peer (USI)

| Line | When | Notes |
|---|---|---|
| `usi` | WS client connected, state → `HANDSHAKE` | Standard USI handshake opener. |
| `isready` | inbound `usiok` | |
| `usinewgame` | `usi_engine_on_match_start` fires AND state is `READY` | One per match, not per WebSocket session. |
| `position sfen <sfen>` | observation says it is our turn AND state is `READY` | `<sfen>` is the full SFEN after the opponent's move. KEB never appends `moves ...` — the engine treats this as an absolute position. |
| `go ...` | immediately after each `position sfen ...` | See § `go` command detail below. |
| `stop` | (reserved) | Not yet emitted by KEB in this version; see § `stop`. |
| `gameover {win\|lose\|draw}` | match ends with a known result | Suppressed when the result is unknown (`USI_RESULT_UNKNOWN`, e.g. open-seat modes). |
| `quit` | (reserved) | See § `quit`. |

#### `go` command detail

KEB emits `go` immediately after each `position sfen ...`, in the same
turn decision that triggered the `position` line.

The exact form of `go` depends on what clock information is available
from KIOU at the time the line is sent:

**Clock-aware form** — used when KIOU has emitted at least one
authoritative snapshot this match (Online and CPUStream modes via
`UpdateAuthoritativeSnapshot`):

```
go btime <ms> wtime <ms> [byoyomi <ms>] [binc <ms>] [winc <ms>]
```

- `btime` / `wtime` come from `g_latestBlackTimeSec` /
  `g_latestWhiteTimeSec` (floats, converted to milliseconds).
- `byoyomi` is included when `time_control.byoyomi_seconds` from the
  cached `MatchConfig.TimeControlConfig` is non-zero.
- `binc` / `winc` are included when
  `time_control.increment_seconds` is non-zero.
- Parameters whose value is zero are omitted.

**Fallback form** — used when no authoritative snapshot has arrived
yet (VsAI / LocalPvP / RecordReplay modes, or the first turn in Online
before the first snapshot lands):

```
go movetime <ms>
```

The movetime value defaults to `30000` (30 seconds) and is not yet
runtime-configurable.

The peer must handle both forms. A wrapper that wants to translate to
engine-specific time management may do so transparently.

#### `stop` (outbound, reserved)

KEB does not yet emit `stop` spontaneously. The command is reserved for
a future version where KEB needs to abort an in-flight engine search
before injecting a result (e.g. on sudden match end or operator resign).

A peer that handles `stop` correctly (answering with `bestmove`)
is forward-compatible with this planned addition.

#### `quit` (outbound, reserved)

KEB does not yet emit `quit` spontaneously. The command is reserved so
that a future teardown path can signal clean session end before closing
the WebSocket. Peers SHOULD handle `quit` by closing their engine
process and disconnecting.

### peer → dylib (USI)

KEB only acts on the first token of each inbound line. Lines may be
batched in a single text frame; the dylib splits on any of `\r\n`,
`\n`, `\r`.

| First token | Action |
|---|---|
| `id` | logged, otherwise ignored |
| `option` | logged, otherwise ignored |
| `usiok` | reply `isready` |
| `readyok` | state → `READY`; kick if it is already our turn (does NOT send `usinewgame` — that waits for match start) |
| `info` | last `info string ...` is cached for debugging; everything else logged and ignored |
| `bestmove resign` / `bestmove (none)` / `bestmove win` | no injection, state → `READY` |
| `bestmove <usi>` | state → `INJECTING`, call `inject_apply(<usi>)`, then wait for the next observation to revert to `READY` |
| `bestmove <usi> ponder <usi2>` | same as above; ponder token is discarded |
| `stop` | if state is `THINKING`: logged (KEB waits for `bestmove` as normal — the peer is expected to reply with `bestmove` after receiving `stop`); otherwise logged and ignored |
| `quit` | KEB closes the WebSocket connection and resets state to `BOOT` |
| anything else | logged at `[USI] ignored inbound:`, otherwise dropped |

`<usi>` for `bestmove` is a normal USI move string (`7g7f`, `8h2b+`,
`P*5e`). The dylib applies it through KIOU's own
`ShogiGameAdapter.TryMakeMove` path, so it has to be legal in the
current KIOU position.

#### `setoption` (inbound — not handled)

KEB does not process `setoption`. If the peer is a wrapper that forwards
engine options, it should send them to the engine directly rather than
over the WebSocket connection to KEB. Unrecognised first tokens
(including `setoption`) are logged and dropped.

## Extended USI lines (JB build only)

KEB emits two kinds of extended USI lines that are not part of the
standard USI spec. **They are not delivered on the binpatch build** —
the binpatch flavour links no-op stubs in `Meta_Emitter.m` lines 3-18.

Both use the same line-oriented format as standard USI (one command per
line, space-separated tokens). A parser that does not recognise the
first token MUST skip the line silently — this keeps the extended lines
transparent to standard USI engine parsers.

### `meta` lines — match metadata

`meta` lines carry per-match information that has no equivalent in
standard USI. They are emitted as a flat sequence before `usinewgame`;
`usinewgame` itself signals the end of the metadata block. Values may
contain spaces (e.g. player names); the parser MUST treat everything
after the subcommand token as the value.

```
meta protocol_version 1.0
meta game_id 20260615T204311-VsAI
meta mode VsAI
meta started_at 2026-06-15T20:43:11Z
meta start_position Standard
meta your_turn b
meta name+ プレイヤー
meta name- KIOU CPU (Normal)
meta time_unit 1sec
meta total_time 600
meta byoyomi 30
usinewgame
```

| Subcommand | Value | Notes |
|---|---|---|
| `protocol_version` | `1.0` | KEB extended USI protocol version. |
| `game_id` | `<started_at_iso>-<mode>` | Unique per match. |
| `mode` | `VsAI` \| `LocalPvP` \| `OnlinePvP` \| `RecordReplay` \| `Spectate` | KIOU match mode. |
| `started_at` | ISO 8601 UTC | |
| `start_position` | `Standard` \| `HandicapLance` \| … \| `TsumeShogi` | Initial position type. |
| `your_turn` | `b` \| `w` \| `-` | Local player's seat. `-` for open-seat modes. |
| `name+` | string (rest of line) | Black player name. Omitted if unknown. |
| `name-` | string (rest of line) | White player name. Omitted if unknown. |
| `rank+` | string | Black player rank. Omitted if unknown. |
| `rank-` | string | White player rank. Omitted if unknown. |
| `rate+` | integer | Black player rate. Omitted if unknown. |
| `rate-` | integer | White player rate. Omitted if unknown. |
| `user_id+` | string | Black player user ID. Omitted if unknown. |
| `user_id-` | string | White player user ID. Omitted if unknown. |
| `time_unit` | `1sec` | Always seconds; `go` uses milliseconds. |
| `total_time` | integer (seconds) | Initial main time per player. Omitted if unlimited or unreadable. |
| `byoyomi` | integer (seconds) | Byoyomi per move. Omitted if zero. |
| `increment` | integer (seconds) | Increment per move. Omitted if zero. |

### `move` lines — per-move notification

`move` lines notify the peer of each committed move. Modelled directly
on the CSA per-move notification (`+7776FU,T10`).

```
move +7g7f T10
```

| Token | Value | Notes |
|---|---|---|
| `+` \| `-` | side | `+` = black just moved, `-` = white just moved. |
| USI move | e.g. `7g7f`, `8h2b+`, `P*5e` | The move that was applied. |
| `T<n>` | integer (seconds) | Time spent on this move, derived from the difference between consecutive authoritative snapshots. Omitted in AI / Local modes where KIOU does not issue snapshots. |

The receiver can compute remaining time as `total_time - Σ T` (summing
only the moves for that side), exactly as in the CSA protocol. The
`go btime/wtime` line KEB sends on the next turn carries the same
remaining time directly for engines that prefer not to track it.

Match end is signalled by `gameover` on the USI channel.

## Build-flavour matrix

| Build | USI channel | meta channel | Distribution |
|---|---|---|---|
| `make package install` (JB / rootless) | available | available | jailbroken iOS 15.0 – 16.5 |
| `make binpatch` + `make ipa` | available | **no-op** (stubs in `Meta_Emitter.m`) | sideloaded iOS 15.0 – 18.x via Sideloadly / TrollStore / AltStore / Apple Developer Program |

Hosts that want KIF assembly today need the jailbroken build. The
binpatch build's USI half is enough to drive the engine end of a CPU /
Online match, but the host has to live without the structured `meta`
stream and reconstruct what it can from the on-device log file.

## Wrapper-mediated deployment

A wrapper is an optional process that sits between KEB and a raw USI
engine. KEB makes no distinction — from its perspective the peer is
always a USI engine, whether or not a wrapper is in the path.

Typical wrapper responsibilities:

- Launching the engine as a child process and bridging stdio ↔ WebSocket.
- Injecting `setoption` lines at startup (KEB does not do this).
- Translating KEB's `go btime/wtime/...` into engine-specific variants
  (`go depth`, `go nodes`, custom byoyomi policies).
- Logging or recording raw engine I/O.

```
KEB  ←—— WebSocket (USI) ——→  Wrapper  ←—— stdio ——→  USI engine
```

A wrapper is NOT required if the peer is already a conforming USI
engine that can accept `go btime/wtime/byoyomi` directly.

## Example session

Peer's perspective (peer = wrapper or raw engine), from connect to one
engine reply, on the JB build. Lines starting with `>` are sent by the
peer, `<` by KEB. `\n`s and the leading `meta ` prefix are shown
literally.

```
< usi
> id name YaneuraOu NNUE 7.6.3
> option name USI_Hash type spin default 16
> usiok
< isready
> readyok
(state = READY; no usinewgame yet — KEB waits for match start)
< meta protocol_version 1.0
< meta game_id 20260615T204311-VsAI
< meta mode VsAI
< meta started_at 2026-06-15T20:43:11Z
< meta start_position Standard
< meta your_turn b
< meta name+ プレイヤー
< meta name- KIOU CPU (Normal)
< meta time_unit 1sec
< meta total_time 600
< meta byoyomi 30
< usinewgame
< position sfen lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PPPPPPPPP/1B5R1/LNSGKGSNL b - 1
< go movetime 30000
> info depth 12 score cp 32 pv 7g7f
> bestmove 7g7f
< move +7g7f T10
...
< gameover win
```

The VsAI example above shows the `go movetime` fallback because KIOU
does not send authoritative clock snapshots in that mode. `black_time_sec`
/ `white_time_sec` are also omitted from `BEGIN_MOVE` for the same reason.

For an Online match the `go` line and move block carry live clock values:

```
...
> readyok
(state = READY)
< meta protocol_version 1.0
< meta game_id 20260615T204311-OnlinePvP
< meta mode OnlinePvP
< meta your_turn b
< meta name+ プレイヤー
< meta name- 対戦相手
< meta time_unit 1sec
< meta total_time 600
< meta byoyomi 30
< usinewgame
< position sfen lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PPPPPPPPP/1B5R1/LNSGKGSNL b - 1
< go btime 600000 wtime 600000 byoyomi 30000
> bestmove 7g7f
< move +7g7f T10
...
< gameover win
```

Note that `meta` lines always arrive before `usinewgame` and the first
`position sfen`. The engine can use `usinewgame` as the cue that a new
game is starting and that the metadata block is complete.

## Compatibility notes

- The `meta` protocol version is carried in `meta protocol_version`
  inside each `BEGIN_GAME` block. Parsers MUST ignore unknown
  subcommands within a block and MUST NOT error on unrecognised
  `BEGIN_<block>` / `END_<block>` pairs — both will appear in future
  versions.
- Fields within a block may be added in future versions without a
  version bump. Parsers MUST NOT require all fields to be present.
- The USI channel is standard USI. KEB only emits the subset listed
  above, but the host is free to send any USI line — unknown
  first-tokens are logged and dropped, never errored. A future KEB
  version can handle more inbound tokens without requiring a host
  upgrade.
