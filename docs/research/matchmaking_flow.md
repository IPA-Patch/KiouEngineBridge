# 対局マッチメイキングフロー

## 全体フロー（概略）

```mermaid
flowchart TD
    START([アプリ起動]) --> PENDING{未完了対局確認\nGetPendingMatch}
    PENDING -->|PendingMatchあり| REJOIN[既存対局へ再参加]
    PENDING -->|なし| MATCH[マッチング開始\nShogiMatchStream]
    REJOIN --> GAME[対局フェーズ\nShogiGameStream]
    MATCH --> FOUND[マッチ成立\nMatchFound]
    FOUND --> GAME
    GAME --> FINISH[対局終了\nFinishShogiMatch]
    FINISH --> END([終了])
```

---

## Phase 0：未完了対局チェック（単項 RPC）

```mermaid
sequenceDiagram
    participant C as Client
    participant S as ShogiService

    C->>S: GetPendingMatch（引数なし）
    S-->>C: GetPendingMatchReply
    note right of C: PendingMatchStatus<br/>PendingCpuMatchStatus
    C->>C: Pendingあり？
```

---

## Phase 1：マッチング（双方向ストリーミング `ShogiMatchStream`）

```mermaid
sequenceDiagram
    participant C as Client
    participant MS as MatchingService

    C->>MS: Action=Connect
    MS-->>C: Event=Connected

    C->>MS: Action=JoinQueue<br/>MatchType, RankMatchRuleType/EventMatchRuleType<br/>MstEventMatchId, EnableBeginnerSupport<br/>MatchingClientType=Searching

    loop マッチング中（定期通知）
        MS-->>C: Event=MatchingStatus<br/>State=Searching<br/>ElapsedSeconds, CurrentRateRange↑
    end

    alt マッチ失敗→再エンキュー
        MS-->>C: Event=MatchingRequeue
    end

    alt ユーザーがキャンセル
        C->>MS: Action=LeaveQueue
        MS-->>C: Event=LeaveQueueCompleted
    end

    MS-->>C: Event=MatchFound<br/>MatchRoomId, ConnectUrl, JoinToken<br/>TlsCertHash, IsFirstPlayer<br/>MatchType, RuleType

    C->>MS: Action=Heartbeat / MatchingClientType=MatchedConnecting
    note over C,MS: 接続失敗時は MatchingClientType=ConnectionFailed

    alt マッチング停止（サーバー都合）
        MS-->>C: Event=MatchingStopped
    end
```

### `MatchingStatus` のフィールド

| フィールド | 型 | 内容 |
|---|---|---|
| `State` | `ShogiMatchingState` | Idle / Searching / Matched / InGame |
| `QueueStartDate` | Timestamp | キュー開始時刻 |
| `ElapsedSeconds` | int | 経過秒数 |
| `CurrentRateRange` | int | 現在のマッチングレートレンジ（時間で拡大） |

### `MatchFound` のフィールド

| フィールド | 型 | 内容 |
|---|---|---|
| `MatchRoomId` | string | 対局ルームID |
| `ConnectUrl` | string | ゲームサーバーURL（TLS） |
| `JoinToken` | string | 入室トークン |
| `TlsCertHash` | string | TLS証明書ハッシュ |
| `IsFirstPlayer` | bool | 先手かどうか |
| `MatchType` | enum | RankMatch / EventMatch / LobbyMatch |
| `RankMatchRuleType` | enum | Beginner / Vip / Fischer / Bullet3Min |
| `EventMatchRuleType` | enum | Beginner / Vip / Short / Medium |

---

## Phase 2：対局（双方向ストリーミング `ShogiGameStream`、`ConnectUrl` へ TLS 接続）

```mermaid
sequenceDiagram
    participant C as Client
    participant GS as GameService

    C->>GS: Action=Prepare<br/>MatchRoomId, JoinToken
    note over C,GS: 両者が Prepare を送るまで待機

    GS-->>C: Event=BothPrepared
    C->>GS: Action=Ready

    GS-->>C: Event=GameStarted<br/>MatchRoomId, PlayerTurnType<br/>Timer（ShogiTimerStatus）

    loop 対局ループ（手番のたびに繰り返す）
        alt 指し手（盤上の駒を動かす）
            C->>GS: Action=Move<br/>Move（ShogiMoveSettings）<br/>ThinkingTimeMicros, HasEffect<br/>RequestToken<br/>LastKnownTurn, LastKnownMoveCount<br/>BoardPositionHash
        else 打ち（持ち駒を打つ）
            C->>GS: Action=Drop<br/>Move（ShogiMoveSettings）<br/>ThinkingTimeMicros, HasEffect<br/>RequestToken<br/>LastKnownTurn, LastKnownMoveCount<br/>BoardPositionHash
        end

        GS-->>C: Event=MoveResult<br/>IsValid, MoveUsi, MoveNum<br/>NewPositionSfen, BoardPositionHash<br/>TurnType, ThinkingTimeMicros<br/>BlackTimer, WhiteTimer<br/>LegalMoveList, IsCheck<br/>DetectedTesujiTypeList<br/>AiAnalysis（AIサポート有効時）<br/>AiSpecialSupportRemainingFreeCount<br/>IsGameOver, Result

        opt AI特殊サポート要求
            C->>GS: Action=AiSpecialSupport<br/>AiSpecialSupportState=Request<br/>AiSpecialSupportSettings
            GS-->>C: Event=AiSpecialSupportResult
        end

        opt 引き分け提案
            C->>GS: Action=OfferDraw
        end

        opt 状態同期（再接続後など）
            GS-->>C: Event=StateSync
            GS-->>C: Event=GameState（ShogiGameStatus）
        end

        opt ハートビート
            C->>GS: Action=Heartbeat
        end
    end

    alt 投了
        C->>GS: Action=Resign
    end

    GS-->>C: Event=MoveResult（IsGameOver=true, Result付き）

    opt 相手切断・復帰
        GS-->>C: Event=OpponentDisconnected
        GS-->>C: Event=OpponentReconnected
    end

    opt 対局無効化（タイムアウト・サーバー障害）
        GS-->>C: Event=MatchInvalidated<br/>Reason=ConnectionTimeout / ServerUnavailable
    end

    opt 観戦者数変化
        GS-->>C: Event=SpectatorCountChanged
    end
```

### `ShogiGameStreamArgs`（C→S）の主要フィールド

| フィールド | 型 | 内容 |
|---|---|---|
| `MatchRoomId` | string | 対局ルームID |
| `JoinToken` | string | 入室トークン |
| `Move` | ShogiMoveSettings | 移動元・先・成り判定など |
| `ThinkingTimeMicros` | long | 考慮時間（マイクロ秒） |
| `HasEffect` | bool | エフェクト有無 |
| `RequestToken` | string | 冪等性トークン |
| `LastKnownTurn` | ShogiTurnType | 直前ターン（同期用） |
| `LastKnownMoveCount` | int | 直前手数（同期用） |
| `BoardPositionHash` | ulong | 盤面ハッシュ（同期用） |
| `GamePhaseType` | ShogiGamePhaseType | クライアント側の現在フェーズ |
| `IncludeSecondBest` | bool | 次善手も含むか |

### `MoveResult`（S→C）の主要フィールド

| フィールド | 型 | 内容 |
|---|---|---|
| `IsValid` | bool | 合法手か |
| `MoveUsi` | string | USI形式の指し手 |
| `MoveNum` | int | 手数 |
| `NewPositionSfen` | string | 指し手後のSFEN |
| `BoardPositionHash` | ulong | 盤面ハッシュ |
| `TurnType` | ShogiTurnType | 次の手番（Black/White） |
| `ThinkingTimeMicros` | long | 実際の考慮時間 |
| `BlackTimer` / `WhiteTimer` | ShogiPlayerTimerStatus | 両者の残り時間 |
| `LegalMoveList` | list | 次手の合法手一覧 |
| `IsCheck` | bool | 王手かどうか |
| `IsGameOver` | bool | 終局かどうか |
| `Result` | ShogiGameResultStatus | 勝敗・理由 |
| `DetectedTesujiTypeList` | list | 検出された手筋 |
| `AiAnalysis` | ShogiAIAnalysisStatus | AI分析結果 |
| `AiSpecialSupportUsed` | bool | AIサポート使用有無 |
| `AiSpecialSupportRemainingFreeCount` | int | 無料残回数 |

---

## Phase 3：対局終了（単項 RPC）

```mermaid
sequenceDiagram
    participant C as Client
    participant S as ShogiService

    C->>S: FinishShogiMatch（MatchRoomId など）
    S-->>C: FinishShogiMatchReply（キャラ更新・報酬など）
```

---

## 再接続フロー

```mermaid
sequenceDiagram
    participant C as Client
    participant MS as MatchingService
    participant GS as GameService

    C->>MS: MatchingClientType=ConnectionFailed
    C->>MS: Action=JoinQueue（再エンキュー）
    MS-->>C: Event=MatchFound（同一MatchRoomId）

    C->>GS: Action=Reconnect<br/>MatchRoomId, JoinToken
    GS-->>C: Event=StateSync
    GS-->>C: Event=GameState（現在の盤面）
    note over C,GS: 対局ループに復帰
```

---

## CPU対局フロー（単項 RPC 系）

```mermaid
sequenceDiagram
    participant C as Client
    participant S as ShogiService

    C->>S: StartCPUMatch（難易度・ハンデなど）
    S-->>C: StartCPUMatchReply（MatchRoomId）

    note over C,S: ShogiGameStream で対局（上記 Phase 2 と同じ）

    opt 中断・復帰
        C->>S: ResumeCPUMatch（MatchRoomId）
        S-->>C: ResumeCPUMatchReply
    end

    C->>S: FinishCPUMatch（MatchRoomId）
    S-->>C: FinishCPUMatchReply
```

---

## 終局理由一覧（`ShogiMatchResultReasonType`）

| 値 | 内容 |
|---|---|
| Resign | 投了 |
| Checkmate | 詰み |
| TimeOver | 時間切れ |
| NyugyokuDeclaration | 入玉宣言 |
| ThousandYearHand | 千日手 |
| PerpetualCheck | 連続王手の千日手 |
| MaxMovesDraw | 最大手数引き分け |
| Stalemate | ステールメイト |
| Illegal | 反則 |
| Disconnect | 切断 |
| ConnectionTimeout | 接続タイムアウト |
| BothDisconnected | 両者切断 |
| ServerUnavailable | サーバー障害 |
| CpuMatchAbandoned | CPU対局放棄 |
