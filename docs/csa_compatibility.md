# KIOU-KEB CSA compatibility

This document maps every command in the CSA server protocol v1.2.1 onto
KEB's behaviour. The authoritative spec is the wire-format contract in
`docs/csa_protocol.md`; if this document and that one disagree, the wire
contract wins. The authoritative protocol reference is the CSA spec:
<http://www2.computer-shogi.org/protocol/tcp_ip_server_121.html>.

Statuses:

- ✅ supported — KEB handles the command per the CSA spec.
- ⚠️ partial — KEB handles a subset of the command's semantics. Notes
  describe exactly what.
- ⛔ omitted — KEB intentionally ignores the command. Reason listed.

## Session management

| CSA concept | Wire | KEB behaviour | Status |
|---|---|---|---|
| Connect | TCP to `:4081` | Single concurrent client. New connect preempts a stale session. | ✅ |
| Login | `LOGIN <name> <pass>` | Accepted unconditionally. Reply: `LOGIN:<name> OK`. | ⚠️ no authentication |
| Logout | `LOGOUT` / `LOGOUT:completed` | Replies `LOGOUT:completed`, closes the socket. | ✅ |
| Keepalive | bare LF (≥ 30 s interval) | Logged and ignored. TCP keepalive does the actual liveness check. | ✅ |

## Match negotiation

CSA defines a strict pre-match handshake: server emits `BEGIN
Game_Summary`, engine replies `AGREE` or `REJECT`, server emits `START`.
KEB follows it exactly, with the local KIOU side filling the server role.

| CSA field | Wire | KEB behaviour | Status |
|---|---|---|---|
| Protocol version | `Protocol_Version:1.2` | Hard-coded `1.2`. | ✅ |
| Protocol mode | `Protocol_Mode:Server` | Always `Server`. | ✅ |
| Format | `Format:Shogi 1.0` | Always `Shogi 1.0`. | ✅ |
| Declaration | `Declaration:Jishogi 1.1` | Always advertised — the engine may submit `%KACHI`. | ✅ |
| Game ID | `Game_ID:<value>` | `<UTC compact timestamp>-<MatchMode>`. | ✅ |
| Black name | `Name+:<name>` | From `MatchConfig.BlackPlayer` or `GameStateStore.SetBlackPlayerInfo` (Online matchmaking). Omitted when blank. | ✅ |
| White name | `Name-:<name>` | Same as Black. | ✅ |
| Local seat | `Your_Turn:+` / `Your_Turn:-` | Mapped from KIOU's `_localPlayer`. Open-seat modes default to `+`. | ✅ |
| First to move | `To_Move:+` | Hard-coded `+` (KIOU always starts on Black's move). | ⚠️ no handicap-aware override yet |
| Max moves | `Max_Moves:<n>` | — | ⛔ KIOU does not expose a hard move cap. |
| Rematch on draw | `Rematch_On_Draw:NO` | — | ⛔ omitted. |
| Engine accept | `AGREE [<id>]` | Accepted but treated as a no-op when already PLAYING (KEB sends `START` immediately after `Game_Summary` — see note below). | ⚠️ AGREE arrives late |
| Engine reject | `REJECT [<id>]` | Sends `REJECT:<Game_ID> by engine`, drops back to LOGIN. KIOU side stays in match. | ✅ |
| Match start | `START:<Game_ID>` | Emitted immediately after `Game_Summary` without waiting for `AGREE`, because KIOU's CPU starts committing moves the moment `OnMatchStart` fires. | ⚠️ pre-emptive START |

## Time control

CSA's `BEGIN Time ... END Time` block can express far more than KIOU
surfaces. KEB writes only the fields it can faithfully fill.

| CSA field | Wire | KEB behaviour | Status |
|---|---|---|---|
| Time unit | `Time_Unit:1sec` | Always `1sec`. KIOU works in seconds. | ✅ |
| Total time | `Total_Time:<n>` | `MatchConfig.TimeControlConfig.main_seconds`. Omitted when zero / unreadable. | ✅ |
| Byoyomi | `Byoyomi:<n>` | `TimeControlConfig.byoyomi`. Omitted when zero. | ✅ |
| Increment | `Increment:<n>` | `TimeControlConfig.increment`. Omitted when zero. | ✅ |
| Delay | `Delay:<n>` | — | ⛔ KIOU does not expose Delay. |
| Min time per move | `Least_Time_Per_Move:<n>` | — | ⛔ KIOU does not expose this. |
| Time roundup | `Time_Roundup:YES` | — | ⛔ KIOU does not expose this. |

## Initial position

KEB always writes the `BEGIN Position` block in CSA's standard form,
derived from KIOU's live SFEN via `Csa/Convert::CsaPositionFromSfen`.

| Concept | KEB behaviour | Status |
|---|---|---|
| Board cells `P1`..`P9` | 9 rows, 3 chars per square (` * `, `+XX`, `-XX`). Trailing column spaces trimmed. | ✅ |
| Hand pieces `P+` / `P-` | CSA `00<PIECE>` format. Order follows the SFEN hand string. | ✅ |
| Side-to-move | `+` for black, `-` for white. | ✅ |
| `N+:<name>` / `N-:<name>` (player tags inside Position) | — | ⛔ KEB writes player names in `Name+` / `Name-` instead. |
| `AL` (all pieces) | — | ⛔ Not used. |

## Per-turn exchange

This is the core CSA loop: server notifies each engine of every move with
the consumed time, and the engine submits its own move when its turn
arrives. KEB follows the same pattern from both directions.

| CSA concept | Wire | KEB behaviour | Status |
|---|---|---|---|
| Notify move | `<sign><from><to><PIECE>,T<n>` | Emitted from `Hooks/GameStateStoreObserve::HookNotifyPieceMoved` for every KIOU move (both sides). `,T<n>` derived from the snapshot-delta on Online/CPUStream; omitted in modes without authoritative clocks. | ✅ |
| Engine submits move | `<sign><from><to><PIECE>` | Parsed via `MoveBitsFromCsaText`, translated to USI, fed into `inject_apply`. The `,T<n>` suffix is accepted but ignored (KIOU keeps its own clock). | ✅ |
| Engine resigns | `%TORYO` | Sends `#RESIGN` + `#LOSE`, calls `GameOrchestrator.RequestSurrender` for the local seat. The engine controls the local player, so `%TORYO` means the local seat surrenders. | ⚠️ surrenders the local seat |
| Engine nyugyoku win | `%KACHI` | Sends `#JISHOGI` + `#WIN`, advances to GAME_OVER. KIOU side is not signalled. | ⚠️ engine learns; KIOU stays |
| Engine pauses | `%CHUDAN` | Sends `#CHUDAN`, advances to GAME_OVER. KIOU is not signalled. | ⚠️ engine learns; KIOU stays |
| Liveness ping | bare LF | Logged and ignored. | ✅ |

## Result delivery

CSA splits the result into a reason marker followed by the outcome. KEB
cannot distinguish all reasons KIOU may have for ending a match, so it
emits the closest match plus the outcome.

| CSA reason | KEB emits | Status |
|---|---|---|
| `#RESIGN` | Win / lose: KEB sends `#RESIGN` and the outcome. | ✅ |
| `#TIME_UP` | — | ⛔ no separate signal; we fall back to `#RESIGN`. |
| `#ILLEGAL_MOVE` | — | ⛔ no separate signal; we fall back to `#RESIGN`. |
| `#SENNICHITE` | Draw: KEB sends `#SENNICHITE` + `#DRAW`. | ✅ |
| `#OUTE_SENNICHITE` | — | ⛔ no separate signal; we fall back to `#SENNICHITE`. |
| `#JISHOGI` | Sent in response to `%KACHI`. | ⚠️ engine-initiated only |
| `#TSUMI` | — | ⛔ no separate signal. |
| `#MAX_MOVES` / `#CENSORED` | — | ⛔ KIOU does not expose a move-cap end. |
| `#CHUDAN` | Sent in response to `%CHUDAN`. | ⚠️ engine-initiated only |

| CSA outcome | KEB behaviour | Status |
|---|---|---|
| `#WIN` | Sent when the local seat won. | ✅ |
| `#LOSE` | Sent when the local seat lost. | ✅ |
| `#DRAW` | Sent for sennichite. | ✅ |
| `#CENSORED` | — | ⛔ Not surfaced. |

## KIOU_* extensions

CSA does not have first-class fields for the metadata KIOU carries about
its matches (mode, handicap setup, rate, user id, wall-clock start time).
KEB ships these as `KIOU_*` lines inside `Game_Summary`; a strict CSA
parser is required to ignore unknown keys.

| Key | Value | Notes |
|---|---|---|
| `KIOU_Mode` | `VsAI` \| `LocalPvP` \| `OnlinePvP` \| `RecordReplay` \| `Spectate` | |
| `KIOU_StartPosition` | `Standard` \| `HandicapLance` \| ... \| `TsumeShogi` | |
| `KIOU_Rank+` / `KIOU_Rank-` | string | Often surfaced on Online matches. |
| `KIOU_Rate+` / `KIOU_Rate-` | integer | Omitted when zero. |
| `KIOU_UserId+` / `KIOU_UserId-` | string | Omitted when blank. |
| `KIOU_StartedAt` | ISO 8601 UTC | KEB wall-clock at OnMatchStart. |

## Scope boundary

The following CSA / Floodgate features are intentionally outside KEB's
scope as of this revision:

- **shogi-server extensions** (`CHALLENGE`, custom rating tags, lobby
  messages) — KEB only implements the v1.2 server protocol surface.
- **`%KACHI` actually ending KIOU's match** — needs a Task 7 follow-up
  once a reverse-engineered nyugyoku declaration API is found.
- **`#TIME_UP` / `#ILLEGAL_MOVE` distinct from `#RESIGN`** — KIOU does
  not expose end-reason details to the bridge.
- **Multi-client fanout** — only one engine attached at a time.
- **Encrypted transport** — CSA itself is plaintext; if you need TLS,
  terminate it externally and pass plaintext on the loopback.

## Verifying against a real engine

`shogi-server`'s reference Ruby clients (`csa.rb`, `usi.rb`) are the
easiest way to sanity-check the wire. From any host on the same network
as the KIOU device:

```sh
nc <device-ip> 4081
LOGIN test pass
... (Game_Summary lines arrive)
AGREE
... (KEB sends START + first move notification)
```

The full test loop with a real CSA engine (Apery, 技巧, YaneuraOu in CSA
mode) is captured in the migration plan's Verification section:
`docs/plans/kiou_engine_bridge_csa_migration.md`.

## Related documents

- `docs/csa_protocol.md` — wire-level contract and state machine.
- `docs/plans/kiou_engine_bridge_csa_migration.md` — migration plan.
- `docs/archive/usi_compatibility.md` — superseded USI compatibility doc.
