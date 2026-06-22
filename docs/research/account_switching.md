# アカウント切り替え

## モデル

サーバーは `LoginArgs.deviceId` で account を引く。これだけ。

- account ごとに保存するのは **`deviceId`**（Register reply の deviceId、初回送信した distinctId と同値）
- 切り替え = `LoginArgs.Create(deviceId, distinctId)` の **deviceId 引数** を保存値に差し替える
- distinctId は触らない。何でもよい

## 保存するもの（NSUserDefaults `kiou_bridge.accounts`）

| キー | 内容 |
|---|---|
| `deviceId` | account の主キー |
| `userName` | 表示用 |
| `openUserId` | 表示用 |
| `savedAt` | UNIX 秒 |

`kiou_bridge.active_device_id` でアクティブを記録。

## 操作

### 新規 account 作成
1. 新 UUID を生成
2. `pending_distinct_id = 新UUID`
3. Reset → 再起動 → 名前入力
4. RegisterUserArgs.Create フックが pending を distinctId に差し込む
5. RegisterReply の deviceId（= 新 UUID）を保存

### 既存 account に切り替え
1. 保存済みリストから deviceId を選ぶ
2. `pending_device_id = 選んだ deviceId`
3. アプリ再起動
4. LoginArgs.Create フックが pending を **deviceId 引数** に差し込む（distinctId は触らない）
5. サーバーが該当 account を返す

## 実装注意

- `TDAnalytics.GetDistinctId` は Keychain から読むので Set しても無意味、無視
- LoginArgs.Create の `distinctId` 引数は差し替えない（過去にこれをやって -40004 を量産した）
- UserSaveData の deviceId は LoginReply で自動更新される
