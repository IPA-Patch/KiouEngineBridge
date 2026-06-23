# Changelog

All notable changes to KiouEngineBridge are documented here.

## [Unreleased]

### Added
- Multi-version target support. RVAs, slot addresses, and the AFK patch
  for each KIOU app version live in `recipes/v<maj>_<min>_<patch>.py`;
  `recipes/__init__.py` selects the active version via the
  `TARGET_VERSION` environment variable.
- KIOU 1.0.2 (CFBundleVersion 12) is now a supported target alongside 1.0.1.
- `make ipa TARGET_VERSION=<ver>` and `python3 shared/tools/dump.py` —
  the dump tool scans `assets/<ver>/*.ipa`, downloads Il2CppDumper on
  first use, and writes `dump.cs` + `dump.cs.index.json` for the version.
- `tools.verify_sites --version <ver>` cross-checks the recipe against
  the dump index for any registered target version; `find_method`
  prefers the overload whose RVA matches the recipe entry to resolve
  same-named overloads (e.g. `TryMakeMove`).

## [0.1.3] - 2026-06-22

### Added
- Account switching support including a "Force Register" flow that lets
  the user create a new KIOU account on top of an existing device id.
- Persist the currently-active account from `AccountExists`, including
  on the chinlan (static-patch) build flavour.
- Accept Seat (sente/gote-only matching filter), Fixed Rate Range, and
  matching/account/grpc observation hooks; in-app settings panel surfaces
  the new switches.

### Fixed
- Login crash and account-switch login error on the chinlan build.
- Entry slot table moved past the KIOU bitmask data at `0x091E90B8` so
  the cave dispatcher no longer collides with runtime-written state.

### Changed
- Chinlan submodule bumped to a tip that includes log rotation and
  sandbox-log replay on TCP connect.

## [0.1.2] - 2026-06-19

### Added
- In-process settings panel to configure the CSA server port and other options without restarting the app.
- `%%TIME` extension command support: while a game is in progress, a connected CSA engine can send `%%TIME` to receive a `BEGIN Time … END Time` block with millisecond-precision remaining time for both sides (`Remaining_Time_Ms+`, `Remaining_Time_Ms-`, `Byoyomi_Ms`).

### Fixed
- CSA resign path now calls `MatchController.SurrenderAsync` instead of the deprecated `RequestSurrender`, fixing resign injection in recent KIOU builds.
- `Remaining_Time+/-` in `Game_Summary` was missing the CPU side's clock on reconnect. The live clock is now read directly from `GameStateStore` when the move-observer cache is uninitialised (`NaN`). The no-limit sentinel (`-1.0f` / ≥ 86340 s from KIOU) is reported as `86400 s` / `86400000 ms`.

## [0.1.1] - 2026-06-19

### Fixed
- Correctly call `MatchController.SurrenderAsync` instead of `RequestSurrender` when the CSA engine sends `%TORYO`.

### Changed
- Bumped Chinlan submodule to `23b028d` for iOS 18 compatibility.

## [0.1.0] - 2026-06-19

Initial release.

- CSA server on a configurable TCP port (default 4081).
- Full CSA protocol state machine: LOGIN → Game_Summary → START → PLAYING → GAME_OVER.
- Per-move `+XXYYPP,T<n>` notifications with live or wall-clock think-time fallback.
- Inbound engine move parsing, legality pre-checks, and USI injection into KIOU.
- `%TORYO` / `%KACHI` / `%CHUDAN` special command handling.
- Three build flavours: rootless `.deb` (MobileSubstrate), jailed `.dylib` (Dobby static), chinlan `.dylib` (iOS 18 `__DATA` slot table).
