# KiouEngineBridge wire protocol

KiouEngineBridge is the iOS-side dylib that turns KIOU into a USI client.
It opens a WebSocket server inside the KIOU process and waits for an
external "bridge" host (the TypeScript bridge in the companion repo, in
practice) to connect. Everything the host needs to drive a match — USI
control lines plus best-effort metadata — flows over that single
connection.

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
| dylib → host | USI | one USI command, e.g. `usi\n`, `position sfen ...\n` | `Usi_Engine.m::usi_engine_send_line` |
| dylib → host | meta | `meta <json>\n` where `<json>` is one canonical JSON object | `Meta_Emitter.m::meta_emit_dict` |
| host → dylib | USI | one USI command, lines split on `\r\n` / `\n` / `\r` | `Usi_Engine.m::usi_engine_text_handler` |

There is no separate channel for control or for errors. If the dylib
needs to tell the host something the host can't act on from the existing
channels, it goes into the on-device log only (`tmp/kiouenginebridge.log`
on the jailbroken build; Documents on the binpatch build) — not over the
WebSocket.

## USI channel — state machine

The dylib is the **USI client** in USI-spec terms; the host's USI engine
(e.g. YaneuraOu) is the **engine**. The dylib never speaks `setoption`
or `go` — it only emits position lines and observes `bestmove` replies.
The host owns engine setup and the `go` cadence.

States are tracked atomically in `Usi_Engine.m::g_usiState`:

```
BOOT
  ↓  WS client finishes upgrade  →  send "usi"
HANDSHAKE
  ↓  inbound "usiok"             →  send "isready"
  ↓  inbound "readyok"           →  send "usinewgame"
READY
  ↓  observation says it is our turn  →  send "position sfen ..."
THINKING
  ↓  inbound "bestmove <usi>"    →  inject move locally
INJECTING
  ↓  next observation arrives    →  back to READY
```

Notes:

- `usinewgame` is only sent once, on `readyok`. Subsequent matches
  reuse the same engine session.
- On WebSocket disconnect the state resets to `BOOT`.
- A match start where we already know the seat and it is our turn
  triggers a 500 ms-delayed "kick" so the engine gets a `position`
  even before any opponent move fires an observation. See
  `usi_engine_try_kick_on_main`.

### dylib → host (USI)

| Line | When | Notes |
|---|---|---|
| `usi` | WS client connected, state → `HANDSHAKE` | Standard USI handshake. |
| `isready` | inbound `usiok` | |
| `usinewgame` | inbound `readyok` | One per WebSocket session, not per match. |
| `position sfen <sfen>` | observation says it is our turn AND state is `READY` | `<sfen>` is the full SFEN after the opponent's move. The dylib never appends `moves ...` — the bridge / engine treats this as the absolute position. |
| `gameover {win\|lose\|draw}` | match ends with a known result | Suppressed when the result is unknown (`USI_RESULT_UNKNOWN`, e.g. open-seat modes). |

The dylib does NOT emit `go`. The host is expected to observe
`position sfen ...` on the WebSocket and drive its engine with whatever
`go ...` it wants (`go btime ... wtime ...`, `go movetime ...`, etc).

### host → dylib (USI)

The dylib only acts on the first token of each inbound line. Lines may
be batched in a single text frame; the dylib splits on any of
`\r\n`, `\n`, `\r`.

| First token | Action |
|---|---|
| `id` | logged, otherwise ignored |
| `option` | logged, otherwise ignored |
| `usiok` | reply `isready` |
| `readyok` | reply `usinewgame`, state → `READY`, kick if it is already our turn |
| `info` | last `info string ...` is cached for debugging; everything else ignored |
| `bestmove resign` / `bestmove (none)` / `bestmove win` | no injection, state → `READY` |
| `bestmove <usi>` | state → `INJECTING`, call `inject_apply(<usi>)`, then wait for the next observation to revert to `READY` |
| anything else | logged at `[USI] ignored inbound:`, otherwise dropped |

`<usi>` for `bestmove` is a normal USI move string (`7g7f`, `8h2b+`,
`P*5e`). The dylib applies it through KIOU's own
`ShogiGameAdapter.TryMakeMove` path, so it has to be legal in the
current KIOU position.

There is no inbound `quit` handling — the host disconnects the WS to
shut the session down.

## meta channel — JSON event stream

`meta` lines are best-effort match metadata that the host uses to build
a KIF or stat surface. **They are not delivered on the binpatch build** —
the binpatch flavour links no-op stubs in `Meta_Emitter.m` lines 3-18,
so a host running against a sideloaded KIOU sees only the USI channel.
On the jailbroken build the host can rely on the events below.

Each line has the shape:

```
meta {"type":"...","...":...}\n
```

The leading literal `meta ` is the channel tag. Everything after the
first space is canonical JSON produced by `NSJSONSerialization`. There
are exactly three event types today.

### `match_start`

Emitted once per match. On Online matches a 1.5 s grace period waits
for `GameStateStore.SetBlackPlayerInfo` / `SetWhitePlayerInfo` to land
the matchmaking-resolved opponent; on CPU / LocalPvP matches it fires
from a fallback timer. Schema:

```json
{
  "type": "match_start",
  "mode": "VsAI" | "LocalPvP" | "OnlinePvP" | "RecordReplay" | "Spectate" | "Unknown(<n>)",
  "started_at": "2026-06-15T20:43:11Z",
  "local_player": "b" | "w" | null,
  "start_position": "Standard" | "HandicapLance" | "HandicapBishop" | ... | "TsumeShogi" | "Unknown(<n>)",
  "time_control": {
    "main_seconds": 600,
    "byoyomi_seconds": 30,
    "increment_seconds": 0
  },
  "black": {
    "name": "プレイヤー",
    "rank": "六段",
    "rate": 1832,
    "user_id": "abc123"
  },
  "white": {
    "name": null,
    "rank": null,
    "rate": null,
    "user_id": null
  }
}
```

- `local_player` is `null` for open-seat modes (LocalPvP, RecordReplay).
- `time_control` keys are always present; values are `null` if the
  underlying `TimeControlConfig` was unreadable.
- `black` / `white` use the same skeleton in both directions; each
  field is `null` if the source PlayerInfo did not supply it.
- `started_at` is ISO 8601 UTC.

### `move`

Emitted once per applied move, as seen by
`ShogiGameAdapter.TryMakeMove(Move, out)`. The hook deliberately runs
on the main queue after the original returns, so `sfen_after` is the
post-move authoritative SFEN.

```json
{
  "type": "move",
  "ply": 17,
  "side": "b" | "w" | null,
  "usi": "7g7f",
  "elapsed_ms": 4321,
  "sfen_after": "lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PPPPPPPPP/1B5R1/LNSGKGSNL b - 1"
}
```

- `ply` prefers the SFEN's trailing move-number (1-based, minus one for
  "just played"); falls back to an internal counter if the SFEN does
  not parse.
- `side` is the side that just moved (the opposite of the SFEN's side
  to move). `null` if the dylib can't tell.
- `elapsed_ms` is wall-clock between consecutive `move` emits, not
  engine think time.
- Remaining-time fields are intentionally NOT in the MVP schema; they
  will be added once the `ReactiveProperty<float>` layout is pinned.

### `match_end`

Emitted from `Hook_MatchModeObserve`'s `OnMatchEndAsync` after the
result has been inferred from the side-to-move of the final SFEN
versus the cached `local_player`.

```json
{
  "type": "match_end",
  "ended_at": "2026-06-15T20:51:02Z",
  "result": "win" | "lose" | "draw" | "unknown",
  "total_moves": 73,
  "final_sfen": "lnsgk...",
  "usi_text": "startpos moves 7g7f 3c3d 2g2f ..."
}
```

- `result` is `unknown` for open-seat modes and for any match where
  the dylib can't compare side-to-move against a fixed local seat.
- `usi_text` is `GameController.GetUSIText`'s raw return value. The
  host should treat it as the authoritative record and use it to
  rewrite whatever it accumulated from `move` events — `move` deltas
  can drift on jump-moves, drops, and duplicate observation fires.

## Build-flavour matrix

| Build | USI channel | meta channel | Distribution |
|---|---|---|---|
| `make package install` (JB / rootless) | available | available | jailbroken iOS 15.0 – 16.5 |
| `make binpatch` + `make ipa` | available | **no-op** (stubs in `Meta_Emitter.m`) | sideloaded iOS 15.0 – 18.x via Sideloadly / TrollStore / AltStore / Apple Developer Program |

Hosts that want KIF assembly today need the jailbroken build. The
binpatch build's USI half is enough to drive the engine end of a CPU /
Online match, but the host has to live without the structured `meta`
stream and reconstruct what it can from the on-device log file.

## Example session

Host's perspective, from connect to one engine reply, on the JB build.
Lines starting with `>` are sent by the host, `<` by the dylib.
`\n`s and the leading `meta ` prefix are shown literally.

```
< usi\n
> id name YaneuraOu NNUE 7.6.3\n
> option name USI_Hash type spin default 16\n
> usiok\n
< isready\n
> readyok\n
< usinewgame\n
< meta {"type":"match_start","mode":"VsAI","started_at":"2026-06-15T20:43:11Z","local_player":"b","start_position":"Standard","time_control":{"main_seconds":600,"byoyomi_seconds":30,"increment_seconds":0},"black":{"name":"プレイヤー","rank":null,"rate":null,"user_id":null},"white":{"name":"KIOU CPU (Normal)","rank":null,"rate":null,"user_id":null}}\n
< position sfen lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PPPPPPPPP/1B5R1/LNSGKGSNL b - 1\n
> info depth 12 score cp 32 pv 7g7f\n
> bestmove 7g7f\n
< meta {"type":"move","ply":1,"side":"b","usi":"7g7f","elapsed_ms":4321,"sfen_after":"lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PP1PPPPPP/1B5R1/LNSGKGSNL w - 2"}\n
...
< meta {"type":"match_end","ended_at":"2026-06-15T20:51:02Z","result":"win","total_moves":73,"final_sfen":"...","usi_text":"startpos moves 7g7f 3c3d ..."}\n
< gameover win\n
```

Note that the `match_start` meta line lands BEFORE the first
`position sfen ...`. The host can use that ordering as a cue that a new
KIF is starting; it doesn't have to infer it from move numbers.

## Compatibility notes

- The protocol is unversioned. New fields may be added to existing
  `meta` events without notice; the host MUST ignore unknown keys and
  MUST NOT pin on the field order.
- New `meta` event `type`s may appear in the future. The host MUST drop
  unknown types silently rather than disconnecting.
- The USI channel is whatever USI engines already speak; the dylib
  only emits the subset listed above, but the host is free to send any
  USI line — unknown first-tokens are logged and dropped, never
  errored. This means a future dylib can start handling more inbound
  tokens without coordinating a host upgrade.
