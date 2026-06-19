#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>

// ===========================================================================
// Settings_Persistence.h — KiouEngineBridge user-configurable settings.
//
// Thin NSUserDefaults accessor layer, modelled on KiouForge's Persistence.m.
// All keys are prefixed with "kiou_bridge." to avoid conflicts.
// Getters return a sane default when the key is absent so the tweak behaves
// reasonably on first launch without any user interaction.
//
// Consumers read settings at call-site time (stateless pull model — no
// observers). The UI layer (Settings_UI.m) writes through these setters.
// ===========================================================================

// ---------------------------------------------------------------------------
// Auto-rematch
// ---------------------------------------------------------------------------

// Whether to automatically start the next match after the current one ends.
// Default: true (preserves the existing always-on behaviour).
bool    KEBAutoRematchEnabled(void);
void    KEBSetAutoRematchEnabled(bool enabled);

// Seconds to wait before dismissing the result overlay (step 1 of rematch).
// The actual next-match kick fires at rematchStep1Sec + rematchStep2Sec.
// Default: 3.5s  Range: 0–30s
float   KEBRematchStep1Sec(void);
void    KEBSetRematchStep1Sec(float sec);

// Additional seconds after step 1 before calling StartCpuFreeMatchAsync /
// StartRankMatchingAsync (step 2 of rematch).
// Default: 2.0s  Range: 0–30s
float   KEBRematchStep2Sec(void);
void    KEBSetRematchStep2Sec(float sec);

// ---------------------------------------------------------------------------
// Resign
// ---------------------------------------------------------------------------

// Whether %TORYO skips the "投了しますか？" confirmation dialog.
// true  → SurrenderAsync (immediate, no dialog)   ← default
// false → RequestSurrender (shows confirmation dialog)
bool    KEBResignSkipDialog(void);
void    KEBSetResignSkipDialog(bool skip);

// ---------------------------------------------------------------------------
// CSA server
// ---------------------------------------------------------------------------

// TCP port the CSA server listens on. Applied at next app launch — changing
// this while the server is already running has no effect until restart.
// Default: 4081  Range: 1024–65535
uint16_t KEBCsaPort(void);
void     KEBSetCsaPort(uint16_t port);

