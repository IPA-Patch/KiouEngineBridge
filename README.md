# KiouUsiProxy

KIOU (`com.neconome.shogi`) の盤面状態 (SFEN) と指し手 (USI) を観測して、
ホスト側プロセスに gRPC で流す Tweak。ホスト側は USI プロトコルの皮を
被って将棋所 / ShogiGUI などの USI クライアントに繋がる「双方向プロキシ」
として動く想定。

- iOS 15.0–16.5, arm64, rootless
- MobileSubstrate (JB) と Dobby (`make jailed`、Sideloadly 注入用) の両対応
- 観測専用 — ゲーム状態は書き換えない (書き込みヘルパーは include しない)
- 兄弟 Tweak: [`KiouEditor`](https://github.com/tkgstrator/KiouEditor)
- 共有基盤: [`kiou-shared`](https://github.com/tkgstrator/kiou-shared) (submodule)

For authorized testing only.

## ビルド

通常 (MobileSubstrate):

```bash
make
```

Jailed (Dobby 静的リンク、Sideloadly 用):

```bash
make jailed
```

実機インストール:

```bash
make package install THEOS_DEVICE_IP=<デバイス IP>
```

## 構成

```
Sources/KiouUsiProxy/
  Internal.h            # tweak-private 宣言 (空に近い stub)
  Tweak.m               # constructor + UnityFramework 検出
  Hook_*.m              # フックモジュール (今後追加)

vendor/dobby            # KiouEditor の Dobby を symlink
../_shared/             # kiou-shared submodule
```
