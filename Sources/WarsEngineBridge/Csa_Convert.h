#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>

// ===========================================================================
// Csa_Convert — SFEN -> CSA position block for WarsEngineBridge.
//
// WarsEngineBridge does not need Move-bits parsing (ShogiWars delivers
// moves as CSA text already), so only the SFEN-to-CSA position converter
// is provided here. The implementation is shared with KEB (Csa_Convert.m
// is a copy of the same pure-function module).
// ===========================================================================

// Convert a SFEN position string into the multi-line CSA `BEGIN Position`
// body (rows P1..P9, hand lines P+/P-, side-to-move marker).
// Returns nil when the SFEN is malformed.
NSString *CsaPositionFromSfen(NSString *sfen);
