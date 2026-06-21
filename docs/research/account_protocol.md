# KIOU アカウント認証プロトコル

実機ログで確認した認証 gRPC API の構造とサーバーの挙動。

---

## 1. 結論：本質は distinctId だけ

サーバー側でアカウントを一意に引くキーは **`distinctId`（クライアントが生成・保持する UUID）** ただ一つ。
- `DistinctId` で **1 アカウント = 1 distinctId** の関係
- `UserId` / `OpenUserId` はサーバー発行の表示・参照用
- `LoginArgs.DeviceId` は `DistinctId` と同じ値を送るだけ（冗長）
- `RegisterReply.DeviceId` は送った `DistinctId` をそのままエコーしているだけ
- JWT (`AccessToken`) の `did` クレームも `distinctId` そのもの

→ **アカウント切り替えに必要なのは「distinctId を保存・差し替える」だけ**。

---

## 2. RPC

すべて `AuthService` (`Project.Network`) の unary RPC。

| RPC | Args | Reply | 用途 |
|---|---|---|---|
| `LoginAsync` | `ILoginArgs` | `ILoginReply` | 既存アカウントログイン |
| `RegisterUserAsync` | `IRegisterUserArgs` | `IRegisterUserReply` | 新規アカウント登録 |
| `InitializeUserAsync` | `IInitializeUserArgs` | `IInitializeUserReply` | アカウント削除 |

RVA：
- `AuthService.LoginAsync`         → `0x5B93820`
- `AuthService.RegisterUserAsync`   → `0x5B93938`
- `AuthService.InitializeUserAsync` → `0x5B935F0`

---

## 3. フィールド構造

### 3.1 LoginAsync

**Args** `ILoginArgs` (factory RVA `0x5B9899C`)

| フィールド | オフセット | 内容 |
|---|---|---|
| `DeviceId` | 0x18 | distinctId と同じ値（冗長） |
| `DistinctId` | 0x20 | アカウントの一次キー |

**Reply** `ILoginReply`

| フィールド | オフセット | 内容 |
|---|---|---|
| `AccessToken` | 0x18 | HS256 JWT（後述） |
| `SessionId`   | 0x20 | 64 文字 hex |
| `DeviceId`    | 0x28 | リクエストの distinctId をエコー |
| `UserName`    | 0x30 | 表示名 |

### 3.2 RegisterUserAsync

**Args** `IRegisterUserArgs` (factory RVA `0x5B98A2C`)

| フィールド | 内容 |
|---|---|
| `UserName` | プレイヤー入力名 |
| `DistinctId` | 新アカウントの一次キー（クライアント生成 UUID） |

**Reply** `IRegisterUserReply`

| フィールド | オフセット | 内容 |
|---|---|---|
| `UserId` | 0x18 | サーバー発行 ULID（例 `019ee99c-1634-7054-...`） |
| `DeviceId` | 0x20 | リクエストの distinctId をエコー |
| `OpenUserId` | 0x28 | サーバー発行 `XXXX-YYYY-ZZZZ-WWWW`（例 `9500-9280-6694-4197`） |
| `NameValidationResult` | 0x30 | int32 enum（0 = OK） |

`AccessToken` は含まれない（直後に Login が自動的に走って取得される）。

### 3.3 InitializeUserAsync

引数なし、Reply 空。サーバー側でアカウントを無効化する。

---

## 4. AccessToken (JWT)

HS256 署名、有効期間 24 時間。

```json
{
  "sub": "<userId (ULID)>",
  "sid": "<sessionId (64文字hex)>",
  "did": "<distinctId>",
  "iat": <発行UnixTime>,
  "exp": <発行+86400>
}
```

`sub = UserId`、`sid = SessionId`、`did = DistinctId` のシンプルな構造。
アクセストークン期限切れ後の更新は再 Login で別 JWT を取得する。

---

## 5. クライアント側の永続化

### 5.1 ThinkingAnalytics
- `DistinctId` を Keychain 等のシステムストアに永続化（アプリ削除しても残る）
- `SetDistinctId` でメモリ上は書き換えられるが、`GetDistinctId` は永続化された値を返す
- → **DistinctId をクライアントから直接書き換える経路はない**。フックで `LoginArgs.Create` / `RegisterUserArgs.Create` の引数を差し替えるのが現実解。

### 5.2 UserSaveData（ローカル JSON）

| フィールド | 内容 |
|---|---|
| `UserName` | 表示名 |
| `OpenId` | 直近 Login 時の OpenUserId |
| `UserId` | 直近 Login 時の UserId |
| `DeviceId` | 直近 Login で使った distinctId |
| `ServerAssetVersion` | アセットバージョン |

`AccountExists(UserSaveData)` がこれを見て **Login / Register の分岐**を決める。フィールドが空 → Register、入っている → Login。

### 5.3 NetworkSessionData（メモリのみ）
`ServerAccessToken` / `ServerSessionId` / 各種 URL。

---

## 6. 起動シーケンス

```
TitleScene.StartTitleSequenceAsync
   ↓
UserSaveData をロード
   ↓
AccountExists(data) ?
 ├─ true  → RunLoginSequenceAsync
 │          ↓ LoginAsync(deviceId=distinctId, distinctId)
 │          ↓ LoginReply (AccessToken, SessionId, ...)
 │          ↓ NetworkSessionData にトークン保存 → ホーム画面
 │
 └─ false → RunRegisterUserSequenceAsync
              ↓ UI: 名前入力
              ↓ RegisterUserAsync(userName, distinctId)
              ↓ RegisterUserReply (UserId, OpenUserId, ...)
              ↓ UserSaveData 更新
              ↓ LoginSequence へ流れて AccessToken 取得 → ホーム画面
```

---

## 7. リセット / 削除

### 7.1 `RunResetUserDataSequenceAsync`（アカウント初期化）
- **サーバー通信なし**
- ローカル `UserSaveData` をクリアするだけ
- 次回起動時 `AccountExists==false` → Register フロー
- **DistinctId は変わらない**ので、Reset 単体だけだと同じアカウントに再ログインしてしまう
- 新規アカウント化したいなら Reset の直前に `RegisterUserArgs.distinctId` を新 UUID に差し替える必要がある

### 7.2 `RunDeleteAccountSequenceAsync`（アカウント削除）
- `InitializeUserAsync` でサーバー側のアカウントを無効化
- ローカル `UserSaveData` もクリア

---

## 8. アカウント切り替え戦略

切り替えは **保存しておいた `distinctId` を LoginArgs.Create に差し込む** だけ：

```
[切り替え時に保存しておくもの]
  - distinctId (主キー)
  - openUserId / userName (表示用)

[切り替え操作]
  1. UserSaveData をクリア（または force_register フラグ）
  2. pending_distinct_id = 切り替え先の distinctId
  3. アプリ再起動
  4. LoginArgs.Create フックで distinctId を pending 値に差し替え
  5. サーバーは distinctId をキーに該当アカウントを返す
```

サーバーは `distinctId` で全部引いている前提なので、これだけで切り替わる。

---

## 9. 観察フック（KiouEngineBridge）

| Hook | RVA | 目的 |
|---|---|---|
| `ILoginArgs.Create` | `0x5B9899C` | Login 引数の観察＋差し替え |
| `IRegisterUserArgs.Create` | `0x5B98A2C` | Register 引数の観察＋差し替え |
| `AuthService.<LoginAsync>d__3.MoveNext` | `0x5B957AC` | LoginReply キャプチャ（reply @ self+0x50） |
| `AuthService.<RegisterUserAsync>d__4.MoveNext` | `0x5B95EA8` | RegisterReply キャプチャ（reply @ self+0x50） |
| `AuthServiceExtensions.<RunLoginSequenceAsync>d__1.MoveNext` | `0x5812534` | 外側ログインシーケンス |
| `GameService.<GetSelfUserProfileAsync>d__36.MoveNext` | `0x5BB4774` | SelfProfile（rank 等） |
| `UserSaveDataExtensions.AccountExists` | `0x591E860` | Login / Register 分岐の判定 |
| `TitleMenuPopupPresenter.RunResetUserDataSequenceAsync` | `0x5DC6908` | Reset 観察 |
| `TitleMenuPopupPresenter.RunDeleteAccountSequenceAsync` | `0x5DC69B8` | Delete 観察 |
| `SystemInfo.deviceUniqueIdentifier` | `0x6BD8E80` | 端末ID 観察 |
| `TDAnalytics.{Get,Set}DistinctId` | `0x63D7{35C,078}` | DistinctId 観察 |
| `TDAnalytics.GetDeviceId` | `0x63DFDAC` | DeviceId 観察 |
