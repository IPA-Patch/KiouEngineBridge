# WarsEngineBridge CSA protocol

WarsEngineBridge (WEB) is the iOS-side dylib that turns ShogiWars into a **CSA
match server** — embedded inside the ShogiWars process rather than running as a
standalone service, but speaking the same TCP/IP protocol Floodgate and
shogi-server use. A CSA engine connects, plays one or more matches against
the ShogiWars side, and disconnects when finished.

Mental model:

```
ShogiWars  (authoritative board state and clocks)
  ↕  in-process hooks
 WEB  (CSA match server on TCP :4081)
  ↕  CSA protocol v1.2 over plain TCP
 CSA engine  (Floodgate-grade or anything that speaks the CSA wire format)
```

ShogiWars decides the match conditions (time control, handicap, opponent
identity). WEB reads those conditions via observation hooks and announces
them through the standard CSA `Game_Summary` block. The engine returns
`AGREE`, plays the match through the per-move exchange (`+7776FU,T10` from
WEB, `+7776FU` or `%TORYO` from the engine), and learns the result via
`#WIN` / `#LOSE` / `#DRAW`.

This document is the wire-level contract between WEB and the connecting
engine. The authoritative spec for everything not extended here is the CSA
server protocol v1.2.1: <http://www2.computer-shogi.org/protocol/tcp_ip_server_121.html>.

Source of truth pointers:

- `Sources/WarsEngineBridge/Server_CSA.m` — TCP transport.
- `Sources/WarsEngineBridge/Csa_Engine.m` — protocol state machine.
- `Sources/WarsEngineBridge/Csa_GameInfo.m` — `Game_Summary` / result builder.
- `Sources/WarsEngineBridge/Csa_Convert.m` — coordinate / piece / move /
  position conversion. Pinned regression tests in
  `tests/test_csa_convert_expectations.py`.

## Transport

- **TCP, plaintext, port 4081.** Bound to `0.0.0.0` from
  `Sources/WarsEngineBridge/Tweak.m::init` via `WEBCsaServerStart(4081)`.
  No TLS, no Bonjour. CSA's wire protocol is unencrypted by design; the
  model is "tweak and engine live on the same trusted network."
- **One client at a time.** A second incoming connection preempts the
  prior session (new-client-wins): if the previous engine vanished without
  closing its socket, the next connect attempt boots it out and takes over.
- **Line-oriented UTF-8.** Lines are terminated by `\n` outbound. Inbound
  CR/LF is tolerated. Lines may be up to 64 KiB; longer buffers terminate
  the session.
- **TCP keepalive.** `SO_KEEPALIVE` on, idle 5 s, interval 3 s, count 3
  — a silently dead engine is reaped in roughly 15 s.
- **Backpressure.** Outbound lines go through a serial GCD queue. If the
  in-flight backlog exceeds 128 lines the oldest pending line is dropped
  and a `[CSA]` warning is logged.

## Protocol state machine

WEB's state machine sits in `Sources/WarsEngineBridge/Csa_Engine.m`:

```
BOOT
  ↓  TCP accept
LOGIN
  ↓  inbound "LOGIN <name> <pass>"              →  send "LOGIN:<name> OK"
  ↓  (if ShogiWars match already in progress)  →  send "BEGIN Game_Summary ..."
                                                   + "START:<Game_ID>"
PLAYING
  ↓  inbound move "+7776FU"                     →  inject into ShogiWars
  ↓  ShogiWars move observed                    →  send "+7776FU,T10"
  ↓  inbound "%TORYO"                           →  ShowResignAlertDialog
  ↓  ShogiWars match end                        →  send "#REASON" + "#WIN/LOSE/DRAW"
GAME_OVER
  ↓  inbound "LOGIN ..." (next match)           →  back to LOGIN
  ↓  inbound "LOGOUT"                           →  send "LOGOUT:completed", close
```

**Note on AGREE.** WEB emits `START:<Game_ID>` together with `Game_Summary`
and advances straight to `PLAYING`, because ShogiWars's match-start event
fires immediately with no way to pause it from outside. A later inbound
`AGREE` from the engine is logged and silently dropped — most CSA clients
accept `START:` arriving without an explicit acknowledgement of their
`AGREE`.

## CSA commands handled

### WEB → engine (outbound)

| Line | When | Notes |
|---|---|---|
| `LOGIN:<name> OK` | inbound `LOGIN` | Any credentials are accepted. |
| `LOGOUT:completed` | inbound `LOGOUT` | WEB then closes the TCP socket. |
| `BEGIN Game_Summary ... END Game_Summary` | match start | See `Game_Summary` schema below. |
| `START:<Game_ID>` | immediately after `Game_Summary` | |
| `REJECT:<Game_ID> by engine` | inbound `REJECT` | Session stays open; engine may issue another LOGIN. |
| `<sign><from><to><PIECE>,T<n>` | ShogiWars move observed | Both colors are echoed. `T<n>` sourced from `MoveData.time`. |
| `#RESIGN` / `#TIME_UP` / `#TSUMI` / `#SENNICHITE` / `#OUTE_SENNICHITE` / `#JISHOGI` / `#MAX_MOVES` / `#CHUDAN` | match end | Mapped from `ReceiveCommand.FinishGame.Reason` — see `csa_compatibility.md`. |
| `#WIN` / `#LOSE` / `#DRAW` | match end | Outcome from the engine's seat perspective. |

### engine → WEB (inbound)

| Line | Action |
|---|---|
| `LOGIN <name> [<pass>]` | Reply with `LOGIN:<name> OK`. Push Game_Summary immediately if ShogiWars is mid-match. |
| `LOGOUT` | Reply with `LOGOUT:completed`, close socket, return to BOOT. |
| `AGREE [<Game_ID>]` | Logged and dropped (WEB is already PLAYING by this point). |
| `REJECT [<Game_ID>]` | Reply with `REJECT:<Game_ID> by engine`; return to LOGIN. ShogiWars side is not affected. |
| `<sign><from><to><PIECE>[,T<n>]` | Parse via `Csa_Convert::MoveBitsFromCsaText` → translate to USI → inject. The `,T<n>` suffix is logged but otherwise unused (ShogiWars runs its own clock). |
| `%TORYO` | Send `#RESIGN` + `#LOSE`, advance to GAME_OVER, call `ShowResignAlertDialog` on the main thread. |
| `%KACHI` | Send `#JISHOGI` + `#WIN`, advance to GAME_OVER. ShogiWars side is not signalled. |
| `%CHUDAN` | Send `#CHUDAN`, advance to GAME_OVER. ShogiWars is not notified. |
| `%%TIME` | Reply with `BEGIN Time … END Time` block containing `Remaining_Time_Ms+`, `Remaining_Time_Ms-`, `Byoyomi_Ms`. Only valid while PLAYING; returns an error line otherwise. |
| bare `\n` (CSA liveness ping) | No-op; TCP keepalive handles dead-peer detection separately. |
| anything else | Logged as `[CSA-ENG] ignoring unrecognised line: ...`, otherwise dropped. |

## `Game_Summary` schema

WEB emits the block right after a ShogiWars match starts (or right after
the LOGIN reply if the engine connects mid-match). All standard CSA fields
are written; ShogiWars-specific extensions live between the position block
and `END Game_Summary` so a strict CSA parser ignores them.

```
BEGIN Game_Summary
Protocol_Version:1.2
Protocol_Mode:Server
Format:Shogi 1.0
Declaration:Jishogi 1.1
Game_ID:20260616T093003-Online
Name+:プレイヤーA
Name-:プレイヤーB
Your_Turn:+
To_Move:+
BEGIN Time
Time_Unit:1sec
Total_Time:300
Byoyomi:10
END Time
BEGIN Position
P1-KY-KE-GI-KI-OU-KI-GI-KE-KY
P2 * -HI *  *  *  *  * -KA *
P3-FU-FU-FU-FU-FU-FU-FU-FU-FU
P4 *  *  *  *  *  *  *  *  *
P5 *  *  *  *  *  *  *  *  *
P6 *  *  *  *  *  *  *  *  *
P7+FU+FU+FU+FU+FU+FU+FU+FU+FU
P8 * +KA *  *  *  *  * +HI *
P9+KY+KE+GI+KI+OU+KI+GI+KE+KY
P+
P-
+
END Position
WARS_Mode:Online
WARS_Dan+:3
WARS_Dan-:4
WARS_Points+:1450
WARS_Points-:1832
WARS_Favsenpou+:居飛車
WARS_Favsenpou-:振り飛車
WARS_StartedAt:2026-06-16T09:30:03Z
END Game_Summary
```

### WARS_* extension lines

WEB ships data CSA has no equivalent for as `WARS_<key>:<value>` lines.
Engines should ignore any unknown `WARS_*` key. Defined keys:

| Key | Value | Notes |
|---|---|---|
| `WARS_Mode` | `Online` \| `Practice` | Derived from `GameStartJson.opponent_type`. |
| `WARS_Dan+` / `WARS_Dan-` | integer | `GamePlayerJson.game_record.dan`. |
| `WARS_Points+` / `WARS_Points-` | integer | `GamePlayerJson.points`. Omitted when zero. |
| `WARS_Favsenpou+` / `WARS_Favsenpou-` | string | `GamePlayerJson.favsenpou`. Omitted when blank. |
| `WARS_StartedAt` | ISO 8601 UTC | WEB wall-clock at match start. |

Fields that have no value are omitted entirely rather than written as
empty strings, so a parser can rely on "key present → value valid."

### Time control

CSA's `BEGIN Time` block carries only the fields ShogiWars actually
exposes. `sente_time_limit` / `gote_time_limit` map to `Total_Time`, and
`sente_byoyomi` / `gote_byoyomi` map to `Byoyomi` for the engine's seat.
`Increment`, `Delay`, `Least_Time_Per_Move`, and `Time_Roundup` are never
written.

The `,T<n>` field on move lines is sourced from `MoveData.time`, which
ShogiWars populates for all game modes.

## End-of-match

WEB sends a `#REASON` line followed by `#WIN` / `#LOSE` / `#DRAW` whenever
ShogiWars's match-end hook fires. The reason marker is mapped directly from
`ReceiveCommand.FinishGame.Reason`:

| Reason | `#REASON` | Outcome |
|---|---|---|
| `TORYO` / `DISCONNECT` | `#RESIGN` | `#WIN` / `#LOSE` |
| `CHECKMATE` | `#TSUMI` | `#WIN` / `#LOSE` |
| `TIMEOUT` | `#TIME_UP` | `#WIN` / `#LOSE` |
| `SENNICHI` | `#SENNICHITE` | `#DRAW` |
| `OUTE_SENNICHI` | `#OUTE_SENNICHITE` | `#LOSE` |
| `ENTERINGKING` | `#JISHOGI` | `#WIN` / `#LOSE` |
| `PLY_LIMIT` | `#MAX_MOVES` | `#DRAW` |
| `MAINTENANCE` | `#CHUDAN` | (no outcome line) |

After the block WEB transitions to `GAME_OVER`. The TCP session stays
open; a fresh LOGIN advances back to `LOGIN` and the next ShogiWars
match's `Game_Summary` will roll the engine into another game.

## Example session (Online match)

Engine perspective, from connect through one move to match end. `>` is
engine→WEB, `<` is WEB→engine. Trailing `\n`s are shown for clarity.

```
> LOGIN test pass\n
< LOGIN:test OK\n
< BEGIN Game_Summary\n
< Protocol_Version:1.2\n
< Protocol_Mode:Server\n
< Format:Shogi 1.0\n
< Declaration:Jishogi 1.1\n
< Game_ID:20260616T093003-Online\n
< Name+:プレイヤーA\n
< Name-:プレイヤーB\n
< Your_Turn:+\n
< To_Move:+\n
< BEGIN Time\n
< Time_Unit:1sec\n
< Total_Time:300\n
< Byoyomi:10\n
< END Time\n
< BEGIN Position\n
< P1-KY-KE-GI-KI-OU-KI-GI-KE-KY\n
< P2 * -HI *  *  *  *  * -KA *\n
< P3-FU-FU-FU-FU-FU-FU-FU-FU-FU\n
< P4 *  *  *  *  *  *  *  *  *\n
< P5 *  *  *  *  *  *  *  *  *\n
< P6 *  *  *  *  *  *  *  *  *\n
< P7+FU+FU+FU+FU+FU+FU+FU+FU+FU\n
< P8 * +KA *  *  *  *  * +HI *\n
< P9+KY+KE+GI+KI+OU+KI+GI+KE+KY\n
< P+\n
< P-\n
< +\n
< END Position\n
< WARS_Mode:Online\n
< WARS_Dan+:3\n
< WARS_Dan-:4\n
< WARS_StartedAt:2026-06-16T09:30:03Z\n
< END Game_Summary\n
< START:20260616T093003-Online\n
> AGREE\n
> +7776FU\n
< +7776FU,T5\n
< -3334FU,T3\n
> +2726FU\n
< +2726FU,T8\n
...
> %TORYO\n
< #RESIGN\n
< #LOSE\n
> LOGOUT\n
< LOGOUT:completed\n
```

## Build-flavour matrix

Hooks responsible for the CSA wire are identical across all three build
flavours. Time control / result inference is uniform too.

| Build | Distribution | Notes |
|---|---|---|
| `make` (JB / rootless) | jailbroken iOS 15.0 – 16.5 | MobileSubstrate hooks. |
| `make JAILED=1` | TrollStore-injected, iOS 15.0 – 17.x | Dobby static link. |
| `make chinlan FINALPACKAGE=1` | iOS 15.0 – 18.x via Sideloadly / AltStore | Static binary patch, survives iOS 18 CSM. |

## Related documents

- `docs/csa_compatibility.md` — full table of CSA commands WEB supports vs
  ignores vs cannot map to ShogiWars.
