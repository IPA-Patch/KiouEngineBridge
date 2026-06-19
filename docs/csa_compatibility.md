# WarsEngineBridge CSA compatibility

This document maps every command in the CSA server protocol v1.2.1 onto
WEB's behaviour. The authoritative spec is the wire-format contract in
`docs/csa_protocol.md`; if this document and that one disagree, the wire
contract wins. The authoritative protocol reference is the CSA spec:
<http://www2.computer-shogi.org/protocol/tcp_ip_server_121.html>.

Statuses:

- ✅ supported — WEB handles the command per the CSA spec.
- ⚠️ partial — WEB handles a subset of the command's semantics. Notes
  describe exactly what.
- ⛔ omitted — WEB intentionally ignores the command. Reason listed.

## Session management

| CSA concept | Wire | WEB behaviour | Status |
|---|---|---|---|
| Connect | TCP to `:4081` | Single concurrent client. New connect preempts a stale session. | ✅ |
| Login | `LOGIN <name> <pass>` | Accepted unconditionally. Reply: `LOGIN:<name> OK`. | ⚠️ no authentication |
| Logout | `LOGOUT` / `LOGOUT:completed` | Replies `LOGOUT:completed`, closes the socket. | ✅ |
| Keepalive | bare LF (≥ 30 s interval) | Logged and ignored. TCP keepalive does the actual liveness check. | ✅ |

## Match negotiation

CSA defines a strict pre-match handshake: server emits `BEGIN
Game_Summary`, engine replies `AGREE` or `REJECT`, server emits `START`.
WEB follows it exactly, with the local ShogiWars side filling the server role.

| CSA field | Wire | WEB behaviour | Status |
|---|---|---|---|
| Protocol version | `Protocol_Version:1.2` | Hard-coded `1.2`. | ✅ |
| Protocol mode | `Protocol_Mode:Server` | Always `Server`. | ✅ |
| Format | `Format:Shogi 1.0` | Always `Shogi 1.0`. | ✅ |
| Declaration | `Declaration:Jishogi 1.1` | Always advertised — the engine may submit `%KACHI`. | ✅ |
| Game ID | `Game_ID:<value>` | `<UTC compact timestamp>-<Mode>`. | ✅ |
| Black name | `Name+:<name>` | From `GameStartJson.sente.name`. Omitted when blank. | ✅ |
| White name | `Name-:<name>` | From `GameStartJson.gote.name`. | ✅ |
| Local seat | `Your_Turn:+` / `Your_Turn:-` | Derived from which player is local. | ✅ |
| First to move | `To_Move:+` | Always `+` (standard opening). | ✅ |
| Max moves | `Max_Moves:<n>` | — | ⛔ ShogiWars does not expose a hard move cap over the hook surface. |
| Rematch on draw | `Rematch_On_Draw:NO` | — | ⛔ omitted. |
| Engine accept | `AGREE [<id>]` | Accepted; treated as a no-op when already PLAYING (WEB sends `START` immediately after `Game_Summary`). | ⚠️ AGREE arrives late |
| Engine reject | `REJECT [<id>]` | Sends `REJECT:<Game_ID> by engine`, drops back to LOGIN. ShogiWars side stays in match. | ✅ |
| Match start | `START:<Game_ID>` | Emitted immediately after `Game_Summary` without waiting for `AGREE`. | ⚠️ pre-emptive START |

## Time control

CSA's `BEGIN Time ... END Time` block can express far more than ShogiWars
surfaces. WEB writes only the fields it can faithfully fill.

| CSA field | Wire | WEB behaviour | Status |
|---|---|---|---|
| Time unit | `Time_Unit:1sec` | Always `1sec`. ShogiWars works in seconds. | ✅ |
| Total time | `Total_Time:<n>` | `GameStartJson.sente_time_limit` (matched to the engine's seat). Omitted when zero. | ✅ |
| Byoyomi | `Byoyomi:<n>` | `sente_byoyomi` / `gote_byoyomi` per the engine's seat. Omitted when zero. | ✅ |
| Increment | `Increment:<n>` | — | ⛔ ShogiWars does not expose increment-style time control. |
| Delay | `Delay:<n>` | — | ⛔ ShogiWars does not expose Delay. |
| Min time per move | `Least_Time_Per_Move:<n>` | — | ⛔ ShogiWars does not expose this. |
| Time roundup | `Time_Roundup:YES` | — | ⛔ ShogiWars does not expose this. |

## Initial position

WEB always writes the `BEGIN Position` block in CSA's standard form,
derived from ShogiWars's live position via `GameStartJson.init_pos` (SFEN).

| Concept | WEB behaviour | Status |
|---|---|---|
| Board cells `P1`..`P9` | 9 rows, 3 chars per square (` * `, `+XX`, `-XX`). Trailing column spaces trimmed. | ✅ |
| Hand pieces `P+` / `P-` | CSA `00<PIECE>` format. Order follows the SFEN hand string. | ✅ |
| Side-to-move | `+` for black, `-` for white. | ✅ |
| `N+:<name>` / `N-:<name>` (player tags inside Position) | — | ⛔ WEB writes player names in `Name+` / `Name-` instead. |
| `AL` (all pieces) | — | ⛔ Not used. |

## Per-turn exchange

This is the core CSA loop: server notifies each engine of every move with
the consumed time, and the engine submits its own move when its turn
arrives. WEB follows the same pattern from both directions.

| CSA concept | Wire | WEB behaviour | Status |
|---|---|---|---|
| Notify move | `<sign><from><to><PIECE>,T<n>` | Emitted for every ShogiWars move (both sides). `,T<n>` sourced from `MoveData.time`. | ✅ |
| Engine submits move | `<sign><from><to><PIECE>` | Parsed and injected into ShogiWars's move pipeline. The `,T<n>` suffix is accepted but ignored (ShogiWars keeps its own clock). | ✅ |
| Engine resigns | `%TORYO` | Sends `#RESIGN` + `#LOSE`, advances to GAME_OVER, calls `ShowResignAlertDialog` on the main thread. | ✅ |
| Engine nyugyoku win | `%KACHI` | Sends `#JISHOGI` + `#WIN`, advances to GAME_OVER. ShogiWars side is not signalled. | ⚠️ engine learns; ShogiWars stays |
| Engine pauses | `%CHUDAN` | Sends `#CHUDAN`, advances to GAME_OVER. ShogiWars is not notified. | ⚠️ engine learns; ShogiWars stays |
| Liveness ping | bare LF | Logged and ignored. | ✅ |

## Result delivery

ShogiWars surfaces a rich end-reason enum in `ReceiveCommand.FinishGame.Reason`,
which WEB maps directly to CSA reason markers.

| `ReceiveCommand.FinishGame.Reason` | CSA reason | Outcome | Status |
|---|---|---|---|
| `TORYO` | `#RESIGN` | `#WIN` / `#LOSE` | ✅ |
| `DISCONNECT` | `#RESIGN` | `#LOSE` | ✅ |
| `CHECKMATE` | `#TSUMI` | `#WIN` / `#LOSE` | ✅ |
| `TIMEOUT` | `#TIME_UP` | `#WIN` / `#LOSE` | ✅ |
| `SENNICHI` | `#SENNICHITE` | `#DRAW` | ✅ |
| `OUTE_SENNICHI` | `#OUTE_SENNICHITE` | `#LOSE` (the side giving repetition check loses) | ✅ |
| `ENTERINGKING` | `#JISHOGI` | `#WIN` / `#LOSE` | ✅ |
| `PLY_LIMIT` | `#MAX_MOVES` | `#DRAW` | ✅ |
| `MAINTENANCE` | `#CHUDAN` | (no outcome line) | ✅ |

| CSA outcome | WEB behaviour | Status |
|---|---|---|
| `#WIN` | Sent when the local seat won. | ✅ |
| `#LOSE` | Sent when the local seat lost. | ✅ |
| `#DRAW` | Sent for sennichite / ply-limit draws. | ✅ |
| `#CENSORED` | — | ⛔ Not surfaced. |

## WARS_* extensions

CSA does not have first-class fields for the metadata ShogiWars carries
about its matches. WEB ships these as `WARS_*` lines inside `Game_Summary`;
a strict CSA parser is required to ignore unknown keys.

| Key | Value | Notes |
|---|---|---|
| `WARS_Mode` | `Online` \| `Practice` | Match mode derived from `GameStartJson.opponent_type`. |
| `WARS_Dan+` / `WARS_Dan-` | integer | Player dan rank from `GamePlayerJson.game_record.dan`. |
| `WARS_Points+` / `WARS_Points-` | integer | Rating points from `GamePlayerJson.points`. Omitted when zero. |
| `WARS_Favsenpou+` / `WARS_Favsenpou-` | string | Favourite opening style from `GamePlayerJson.favsenpou`. Omitted when blank. |
| `WARS_StartedAt` | ISO 8601 UTC | WEB wall-clock at match start. |

## Scope boundary

The following CSA / Floodgate features are intentionally outside WEB's
scope as of this revision:

- **shogi-server extensions** (`CHALLENGE`, custom rating tags, lobby
  messages) — WEB only implements the v1.2 server protocol surface.
- **`%KACHI` actually ending ShogiWars's match** — no public nyugyoku
  declaration API has been surfaced yet.
- **Multi-client fanout** — only one engine attached at a time.
- **Encrypted transport** — CSA itself is plaintext; if you need TLS,
  terminate it externally and pass plaintext on the loopback.

## Verifying against a real engine

From any host on the same network as the ShogiWars device:

```sh
nc <device-ip> 4081
LOGIN test pass
... (Game_Summary lines arrive)
AGREE
... (WEB sends START + first move notification)
```

The full test loop with a real CSA engine (YaneuraOu in CSA mode) is the
recommended smoke test. The `assets/YaneuraOu` binary and `assets/nn.bin`
NNUE weights can be run directly on-device for local verification.

## Related documents

- `docs/csa_protocol.md` — wire-level contract and state machine.
