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
// Auto-start
// ---------------------------------------------------------------------------

// Auto-start match kind — encodes both match type and its parameter in one
// value. KEBAutoStartKind_None (= -1) means "do not auto-start"; any other
// value means auto-start with that match type on the first
// GameOrchestrator.ActivateAsync after launch.
//
//   KEBAutoStartKind_None         = -1  do not auto-start              ← default
//   KEBAutoStartKind_CpuEasy      =  0  CPU Easy   (CPUStrengthType=2)
//   KEBAutoStartKind_CpuNormal    =  1  CPU Normal (CPUStrengthType=3)
//   KEBAutoStartKind_CpuHard      =  2  CPU Hard   (CPUStrengthType=4)
//   KEBAutoStartKind_RankBeginner =  3  Rank Beginner (RankMatchRuleType=2)
//   KEBAutoStartKind_RankVip      =  4  Rank VIP      (RankMatchRuleType=3)
//   KEBAutoStartKind_RankFischer  =  5  Rank Fischer  (RankMatchRuleType=4)
//   KEBAutoStartKind_RankBullet   =  6  Rank 3min Bullet (RankMatchRuleType=5)
//
typedef NS_ENUM(int32_t, KEBAutoStartKind) {
    KEBAutoStartKind_None         = -1,
    KEBAutoStartKind_CpuEasy      =  0,
    KEBAutoStartKind_CpuNormal    =  1,
    KEBAutoStartKind_CpuHard      =  2,
    KEBAutoStartKind_RankBeginner =  3,
    KEBAutoStartKind_RankVip      =  4,
    KEBAutoStartKind_RankFischer  =  5,
    KEBAutoStartKind_RankBullet   =  6,
};

// Default: KEBAutoStartKind_None (no auto-start)
KEBAutoStartKind KEBAutoStartKind_(void);
void             KEBSetAutoStartKind(KEBAutoStartKind kind);

// Convenience: returns true when KEBAutoStartKind_() != KEBAutoStartKind_None.
bool             KEBAutoStartEnabled(void);

// ---------------------------------------------------------------------------
// CSA server
// ---------------------------------------------------------------------------

// TCP port the CSA server listens on. Applied at next app launch — changing
// this while the server is already running has no effect until restart.
// Default: 4081  Range: 1024–65535
uint16_t KEBCsaPort(void);
void     KEBSetCsaPort(uint16_t port);

// ---------------------------------------------------------------------------
// Display overlay
// ---------------------------------------------------------------------------

// Whether to show an evaluation score overlay on the game screen.
// The overlay itself is not yet implemented; this flag is a placeholder so
// the setting can be toggled in preparation for the feature.
// Default: false
bool    KEBEvalOverlayEnabled(void);
void    KEBSetEvalOverlayEnabled(bool enabled);
