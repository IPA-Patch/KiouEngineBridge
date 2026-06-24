# KiouEngineBridge CSA protocol

KiouEngineBridge (KEB) is the iOS-side dylib that turns KIOU into a **CSA
match server** — embedded inside the KIOU process rather than running as a
standalone service, but speaking the same TCP/IP protocol Floodgate and
shogi-server use. A CSA engine connects, plays one or more matches against
the KIOU side, and disconnects when finished.

Mental model:

```
KIOU  (authoritative board state and clocks)
  ↕  in-process hooks
 KEB  (CSA match server on TCP :4081)
  ↕  CSA protocol v1.2 over plain TCP
 CSA engine  (Floodgate-grade or anything that speaks the CSA wire format)
```

KIOU decides the match conditions (time control, handicap, opponent
identity). KEB reads those conditions via observation hooks and announces
them through the standard CSA `Game_Summary` block. The engine returns
`AGREE`, plays the match through the per-move exchange (`+7776FU,T10` from
KEB, `+7776FU` or `%TORYO` from the engine), and learns the result via
`#WIN` / `#LOSE` / `#DRAW`.

This document is the wire-level contract between KEB and the connecting
engine. The authoritative spec for everything not extended here is the CSA
server protocol v1.2.1: <http://www2.computer-shogi.org/protocol/tcp_ip_server_121.html>.

Source of truth pointers:

- `Sources/KiouEngineBridge/Csa/Server.m` — TCP transport.
- `Sources/KiouEngineBridge/Csa/Engine.m` — protocol state machine.
- `Sources/KiouEngineBridge/Csa/GameInfo.m` — `Game_Summary` / result builder.
- `Sources/KiouEngineBridge/Csa/Convert.m` — coordinate / piece / move /
  position conversion. Pinned regression tests in
  `tests/test_csa_convert_expectations.py`.

## Transport

- **TCP, plaintext, port 4081.** Bound to `0.0.0.0` from
  `Sources/KiouEngineBridge/Tweak.m::init` via `KEBCsaServerStart(4081)`.
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

KEB's state machine sits in `Sources/KiouEngineBridge/Csa/Engine.m`:

```
BOOT
  ↓  TCP accept
LOGIN
  ↓  inbound "LOGIN <name> <pass>"        →  send "LOGIN:<name> OK"
  ↓  (if KIOU match already in progress)  →  send "BEGIN Game_Summary ..."
                                              + "START:<Game_ID>"
                                              (KIOU does not wait for AGREE)
PLAYING
  ↓  inbound move "+7776FU"               →  inject into KIOU
  ↓  KIOU move observed                   →  send "+7776FU,T10"
  ↓  inbound "%TORYO"                     →  GameOrchestrator.RequestSurrender
  ↓  KIOU match end                       →  send "#REASON" + "#WIN/LOSE/DRAW"
GAME_OVER
  ↓  inbound "LOGIN ..." (next match)     →  back to LOGIN
  ↓  inbound "LOGOUT"                     →  send "LOGOUT:completed", close
```

**Important deviation from the CSA spec.** KIOU's match-start event fires
its in-game CPU immediately; KEB has no way to pause KIOU until the
engine has replied with `AGREE`. To prevent the CPU's first moves from
being dropped while we sit in `AGREE_WAIT`, KEB emits `START:<Game_ID>`
*together with* `Game_Summary` and advances straight to `PLAYING`. A
later inbound `AGREE` from the engine is logged and silently dropped —
the engine sees `START:` arrive without an explicit acknowledgement of
its `AGREE`, which most CSA clients accept without complaint.

The `AGREE_WAIT` state still exists in the enum but is now reserved for
future use (e.g. a build flavour that does pause KIOU during the
handshake); in the live path the state machine goes `LOGIN → PLAYING`
directly.

## CSA commands handled

### KEB → engine (outbound)

| Line | When | Notes |
|---|---|---|
| `LOGIN:<name> OK` | inbound `LOGIN` | Any credentials are accepted. |
| `LOGOUT:completed` | inbound `LOGOUT` | KEB then closes the TCP socket. |
| `BEGIN Game_Summary ... END Game_Summary` | match start | See `Game_Summary` schema below. |
| `START:<Game_ID>` | inbound `AGREE` after Game_Summary | |
| `REJECT:<Game_ID> by engine` | inbound `REJECT` | Session stays open; engine may issue another LOGIN. |
| `<sign><from><to><PIECE>,T<n>` | KIOU NotifyPieceMoved fires | Both colors are echoed (sign + black, − white). `T<n>` is computed from the snapshot delta and is omitted in modes without authoritative clocks. |
| `#RESIGN`, `#TIME_UP`, `#ILLEGAL_MOVE`, `#SENNICHITE`, `#OUTE_SENNICHITE`, `#JISHOGI`, `#MAX_MOVES`, `#CHUDAN` | match end | KEB picks the reason marker that best matches the inferred outcome (currently `#RESIGN` for win/lose and `#SENNICHITE` for draw — see `CsaBuildMatchResult` in Csa/GameInfo.m). |
| `#WIN` / `#LOSE` / `#DRAW` / `#CENSORED` | match end | Outcome from the engine's seat perspective. |

### engine → KEB (inbound)

| Line | Action |
|---|---|
| `LOGIN <name> [<pass>]` | Reply with `LOGIN:<name> OK`. Advance to LOGIN. Push Game_Summary immediately if KIOU is mid-match. |
| `LOGOUT` | Reply with `LOGOUT:completed`, close socket, return to BOOT. |
| `AGREE [<Game_ID>]` | While in AGREE_WAIT: send `START:<Game_ID>` and advance to PLAYING. Otherwise log + drop. |
| `REJECT [<Game_ID>]` | Log; reply with `REJECT:<Game_ID> by engine`; return to LOGIN. KIOU side is not affected. |
| `<sign><from><to><PIECE>[,T<n>]` | Parse via `Csa/Convert::MoveBitsFromCsaText` → translate to USI → call `inject_apply`. The `,T<n>` suffix is logged but otherwise unused (KIOU runs its own clock). |
| `%TORYO` | Send `#RESIGN` + `#WIN`, advance to GAME_OVER, schedule `GameOrchestrator.RequestSurrender` on the main thread (see `Inject/Resign.m`). |
| `%KACHI` | Send `#JISHOGI` + `#WIN`, advance to GAME_OVER. No corresponding KIOU declaration API has been surfaced yet — see Task 7 of the migration plan. |
| `%CHUDAN` | Send `#CHUDAN`, advance to GAME_OVER. KIOU is not notified. |
| bare `\n` (CSA liveness ping) | No-op; TCP keepalive handles dead-peer detection separately. |
| anything else | Logged as `[CSA-ENG] ignoring unrecognised line: ...`, otherwise dropped. |

## `Game_Summary` schema

KEB emits the block right after a KIOU match starts (or right after the
LOGIN reply if the engine connects mid-match). All standard CSA fields are
written; KIOU-specific extensions live between the position block and
`END Game_Summary` so a strict CSA parser ignores them.

```
BEGIN Game_Summary
Protocol_Version:1.2
Protocol_Mode:Server
Format:Shogi 1.0
Declaration:Jishogi 1.1
Game_ID:20260616T093003-VsAI
Name+:プレイヤー
Name-:KIOU CPU (Normal)
Your_Turn:+
To_Move:+
BEGIN Time
Time_Unit:1sec
Total_Time:600
Byoyomi:30
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
KIOU_Mode:VsAI
KIOU_StartPosition:Standard
KIOU_Rank+:六段
KIOU_Rate+:1832
KIOU_UserId+:abc123
KIOU_StartedAt:2026-06-16T09:30:03Z
END Game_Summary
```

### KIOU_* extension lines

KEB ships data CSA has no equivalent for as `KIOU_<key>:<value>` lines.
Engines should ignore any unknown `KIOU_*` key. Defined keys:

| Key | Value | Notes |
|---|---|---|
| `KIOU_Mode` | `VsAI` \| `LocalPvP` \| `OnlinePvP` \| `RecordReplay` \| `Spectate` \| `Unknown(<n>)` | KIOU match mode (`MatchMode` enum). |
| `KIOU_StartPosition` | `Standard` \| `HandicapLance` \| ... \| `TsumeShogi` | Initial position type. |
| `KIOU_Rank+` / `KIOU_Rank-` | string | Player rank if surfaced (Online matches usually have it). |
| `KIOU_Rate+` / `KIOU_Rate-` | integer | Player rate. Omitted when zero / unknown. |
| `KIOU_UserId+` / `KIOU_UserId-` | string | Player user id. Omitted when blank. |
| `KIOU_StartedAt` | ISO 8601 UTC | KEB wall-clock at match start. |

Fields that have no value are omitted entirely rather than written as
empty strings, so a parser can rely on "key present → value valid."

### Time control

CSA's `BEGIN Time` block carries only the fields KIOU actually exposes
(`Total_Time`, `Byoyomi`, `Increment`). `Delay`, `Least_Time_Per_Move`, and
`Time_Roundup` are never written. KEB does not currently honour
`Time_Unit:1msec` either — KIOU works in seconds and that's what we ship.

The `,T<n>` field on move lines is computed from the difference between
consecutive authoritative snapshots (`Hooks/OnlineObserve::g_latestBlackTimeSec` /
`g_latestWhiteTimeSec`). VsAI and LocalPvP modes do not surface
authoritative clocks, so the suffix is omitted in those modes.

## End-of-match

KEB sends a `#REASON` line followed by `#WIN` / `#LOSE` / `#DRAW` whenever
KIOU's match-end hook fires with a resolved outcome:

| Inferred outcome | `#REASON` | Outcome |
|---|---|---|
| Local seat wins (engine resigns or times out) | `#RESIGN` | `#WIN` |
| Local seat loses | `#RESIGN` | `#LOSE` |
| Draw (sennichite or similar) | `#SENNICHITE` | `#DRAW` |
| Unknown (open-seat modes) | — | (no result block sent) |

After the block KEB transitions to `GAME_OVER`. The TCP session stays
open; a fresh LOGIN advances back to `LOGIN` and the next KIOU match's
`Game_Summary` will roll the engine into another game.

## Example session (VsAI)

Engine perspective, from connect through one move to match end. `>` is
engine→KEB, `<` is KEB→engine. Trailing `\n`s are shown for clarity.

```
> LOGIN test pass\n
< LOGIN:test OK\n
< BEGIN Game_Summary\n
< Protocol_Version:1.2\n
< Protocol_Mode:Server\n
< Format:Shogi 1.0\n
< Declaration:Jishogi 1.1\n
< Game_ID:20260616T093003-VsAI\n
< Name+:プレイヤー\n
< Name-:KIOU CPU (Normal)\n
< Your_Turn:+\n
< To_Move:+\n
< BEGIN Time\n
< Time_Unit:1sec\n
< Total_Time:600\n
< Byoyomi:30\n
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
< KIOU_Mode:VsAI\n
< KIOU_StartPosition:Standard\n
< KIOU_StartedAt:2026-06-16T09:30:03Z\n
< END Game_Summary\n
> AGREE\n
< START:20260616T093003-VsAI\n
> +7776FU\n
< +7776FU\n
< -3334FU\n
> +2726FU\n
< +2726FU\n
...
> %TORYO\n
< #RESIGN\n
< #WIN\n
> LOGOUT\n
< LOGOUT:completed\n
```

## Build-flavour matrix

Hooks responsible for the CSA wire are identical across all three build
flavours. Time control / result inference is uniform too.

| Build | Distribution | Notes |
|---|---|---|
| `make` (JB / rootless) | jailbroken iOS 15.0 – 16.5 | MobileSubstrate hooks. |
| `make JAILED=1` | sideloaded iOS 15.0 – 17.x via Sideloadly | Dobby static link. |
| `make BINPATCH=1` | iOS 15.0 – 18.x via Sideloadly / TrollStore | Static binary patch + `__DATA,__bss` SLOT dispatcher, survives iOS 18 CSM. |

## Related documents

- `docs/csa_compatibility.md` — full table of CSA commands KEB supports vs
  ignores vs cannot map to KIOU.
- `docs/plans/kiou_engine_bridge_csa_migration.md` — the migration plan
  that produced this protocol surface.
- `docs/plans/kiou_engine_bridge_binpatch.md` — binpatch build mechanics.
- `docs/archive/usi_bridge_protocol.md` — the legacy USI WebSocket
  protocol KEB spoke before this migration.
