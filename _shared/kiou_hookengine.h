#pragma once

// ===========================================================================
// kiou_hookengine.h — MSHookFunction visibility shim.
//
// JB / rootless builds (default): MobileSubstrate's MSHookFunction is live
//                                 in libsubstrate, linked at runtime. This
//                                 header pulls in <substrate.h>.
// Binpatch builds (KIOU_BINPATCH): no runtime hook engine — every site is
//                                 redirected by a static cave to a SLOT-
//                                 published dispatcher. There are no
//                                 MSHookFunction references in the source
//                                 (every install_*_hook body is gated on
//                                 #if !KIOU_BINPATCH), so <substrate.h>
//                                 isn't required and we skip it.
//
// The legacy KIOU_JAILED / Dobby branch is gone — the binpatch build
// supersedes it for non-jailbroken distribution.
// ===========================================================================

#if !KIOU_BINPATCH
#import <substrate.h>
#endif
