# Changelog

All notable changes to KiouEngineBridge are documented here.

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
