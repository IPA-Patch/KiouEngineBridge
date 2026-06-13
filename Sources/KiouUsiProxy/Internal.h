#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>

#import "kiou_il2cpp.h"
#import "kiou_hookengine.h"
#import "kiou_logging.h"

// ===========================================================================
// Internal.h — KiouUsiProxy-private declarations.
//
// This tweak is observation-only with respect to the KIOU game state. It
// reads SFEN / USI strings out of il2cpp memory via the shared read helpers
// (kiou_il2cpp.h) and forwards them to a host-side process. Crucially we do
// NOT include the write-side helpers (writeU8, writeI32) — those live only
// in KiouEditor's Internal.h, so any accidental "let's tweak the board"
// regression fails to compile rather than ships.
//
// Hook installers will be added per feature module in subsequent commits:
//
//   install_BoardObserve_hook (Hook_BoardObserve.m)
//   install_MoveCommit_hook   (Hook_MoveCommit.m)
//   ... etc.
//
// Tweak.m wires them up the same way KiouEditor/Tweak.m does — scan dyld
// for UnityFramework, dispatch each installer once with the base address.
// ===========================================================================

#ifndef KIOU_USI_PROXY_COMMIT
#define KIOU_USI_PROXY_COMMIT "unknown"
#endif
