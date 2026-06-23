# /dump — il2cpp dump → assets/<version>/

`assets/` 以下の IPA を走査して、`dump.cs` または `dump.cs.index.json` が
欠けているバージョンに対して Il2CppDumper を実行し、両ファイルを
`assets/<version>/` に配置する。

## 実行手順

```bash
python3 shared/tools/dump.py
```

## 注意

- `vendor/Il2CppDumper/Il2CppDumper.dll` と `dotnet` (8.x) が必要。
- IPA は復号済みであること（FairPlay 暗号化されたままでは動かない）。
- すでに両ファイルが揃っているバージョンはスキップされる。
