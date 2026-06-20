#pragma once

#import <Foundation/Foundation.h>
#import <stdbool.h>

// ===========================================================================
// Settings_Persistence.h — WarsEngineBridge user-configurable settings.
//
// Mirrors KiouEngineBridge's persistence layer. NSUserDefaults-backed,
// stateless pull model. Keys are prefixed "wars_bridge." to avoid conflicts.
// ===========================================================================

// Whether the next match is auto-started after the current one ends.
// Default: false (no auto-rematch until the user opts in).
bool WEBAutoRematchEnabled(void);
void WEBSetAutoRematchEnabled(bool enabled);

// Whether the "play again?" iOS dialog (OnRevengeMenu) is suppressed.
// Default: true (the dialog is hidden — user explicitly asked for this).
bool WEBSkipRevengeDialog(void);
void WEBSetSkipRevengeDialog(bool skip);

// Whether the resign confirmation dialog ("To resign?") is suppressed.
// When true, the dialog never appears and the OK action is invoked
// immediately, so the user resigns as soon as they tap the toryo button.
// Default: false (preserve the original confirmation step).
bool WEBSkipResignDialog(void);
void WEBSetSkipResignDialog(bool skip);

// Whether the app auto-navigates from the title screen straight into a
// practice match on launch. Default: true (so `make package install`
// boots the user directly into a match).
bool WEBAutoLaunchEnabled(void);
void WEBSetAutoLaunchEnabled(bool enabled);
