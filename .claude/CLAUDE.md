# KiouEngineBridge — Claude向け作業ガイド

## ログの読み方

「JB環境でログを見て」と言われた場合、SSH で実機に接続してサンドボックスのログを直接取得する。
ローカルの `logs/` ディレクトリは古いログなので参照しない。

```bash
# デバイスへのSSH接続
ssh ShogiWars

# ログファイルのパス（bundle IDごとにContainerが変わるので都度 find する）
find /var/mobile/Containers/Data/Application -name 'kiouenginebridge*.log' 2>/dev/null

# ローカルに取得してから解析する
ssh ShogiWars "cat <path>" > /home/vscode/app/logs/device_latest.log
```

SSH の Host 名は `ShogiWars`（`~/.ssh/config` に定義済み、IdentityFile = `~/.ssh/ios_device`）。アプリ名は KIOU だが SSH ホスト名は ShogiWars のまま。

## 開発方針

- 新機能は **JBビルドで動作検証してから Chinlan に移行**する
- JB では `MSHookFunction` が使えるので `#if !KIOU_CHINLAN` ブロックにまず実装する
- Chinlan 移行は enum 追加・dispatcher 対応・Recipe 変更が伴うため別タスクとして切り出す
