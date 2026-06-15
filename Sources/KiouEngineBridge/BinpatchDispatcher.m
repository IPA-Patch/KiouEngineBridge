#if KIOU_BINPATCH

#import "Internal.h"

kiou_bridge_dispatcher_t volatile g_kiou_bridge_hook_slot = NULL;

static void kiou_bridge_dispatcher(void *self, void *arg1, uint32_t hook_id) {
    // Stub. Phase D wires this up to the real hook_<foo> functions in the
    // respective Hook_*.m files (likely by un-`static`-ing them and adding
    // forward declarations in Internal.h).
    file_log([NSString stringWithFormat:
              @"[BINPATCH] dispatch hook_id=%u self=%p arg1=%p (stub)",
              (unsigned)hook_id, self, arg1]);
    (void)hook_id;
}

void kiou_bridge_binpatch_publish(void) {
    // arm64 8-byte aligned pointer store is atomic; the cave's ADRP+LDR will
    // see either NULL (before this fires) or a fully-formed dispatcher.
    g_kiou_bridge_hook_slot = &kiou_bridge_dispatcher;
    file_log([NSString stringWithFormat:
              @"[BINPATCH] slot=%p published dispatcher=%p",
              (void *)&g_kiou_bridge_hook_slot, &kiou_bridge_dispatcher]);
}

#endif  // KIOU_BINPATCH
