#if IPA_CHINLAN

#import "Internal.h"

// ===========================================================================
// ChinlanDispatcher — chinlan flavour only.
//
// On the chinlan build every observation site is redirected by a static
// code cave to this single dispatcher. The cave preserves X0..X7, loads
// the function pointer from the reserved __DATA,__bss slot inside
// UnityFramework at `unityBase + KIOU_BR_HOOK_SLOT_RVA`, calls the
// dispatcher with the original arguments plus the per-site hook id in W6,
// then restores X0..X7 and resumes orig via the displaced prologue and
// `B orig + 4`. The dispatcher therefore implements only the pre-orig
// observation work — calling orig is the cave's job.
//
// Two pieces have to agree for the cave to ever reach this function:
//
//   1. The cave's ADRP+LDR resolves the slot at
//      `unityBase + KIOU_BR_HOOK_SLOT_RVA` (see
//      `recipes/kiouenginebridge.py`'s ``HOOK_SLOT_RVA`` /
//      ``_build_bridge_cave_payload``).
//
//   2. ``KEBBridgeChinlanPublish`` below stores `&dispatch_one`
//      into that same address. The slot lives in UnityFramework's
//      __DATA,__bss — NOT in this dylib — so the publish path needs the
//      live UnityFramework base captured in ``g_unityBase``. A previous
//      revision of this file mistakenly published into a dylib-local
//      global, leaving the framework slot at NULL; the very first cave
//      site fired ``BLR X16 == BLR 0`` and got SIGKILLed with
//      CODESIGNING / Invalid Page at match start.
// ===========================================================================

void * volatile g_inject_entry[KIOU_BR_HOOK__COUNT] = {0};

// Dispatcher body. Receives the original X0..X5/X7 arguments verbatim, plus
// the per-site hook id in W6. Each case forwards to the matching hook body
// in the Hook_*.m files, casting the registers to the body's declared
// parameter types. Unused parameter slots are silently dropped per AAPCS64
// — the hook bodies only read what they need.
static void dispatch_one(void *x0, void *x1, void *x2, void *x3, void *x4,
                         void *x5, uint32_t hook_id, void *x7) {
    (void)x4;
    (void)x5;
    (void)x7;
    switch (hook_id) {
    // InitializeAsync(self, cfg, store, adapter, ct)
    //   self=x0, cfg=x1, store=x2, adapter=x3, ct=x4 — we only need the
    //   first four; ct is dropped (passed as NULL).
    case KIOU_BR_HOOK_AI_INIT:
        (void)HookAiInit(x0, x1, x2, x3, x4); break;
    case KIOU_BR_HOOK_CPUSTREAM_INIT:
        (void)HookCpuStreamInit(x0, x1, x2, x3, x4); break;
    case KIOU_BR_HOOK_LOCAL_INIT:
        (void)HookLocalInit(x0, x1, x2, x3, x4); break;
    case KIOU_BR_HOOK_ONLINE_INIT:
        (void)HookOnlineInit(x0, x1, x2, x3, x4); break;
    case KIOU_BR_HOOK_REPLAY_INIT:
        (void)HookReplayInit(x0, x1, x2, x3, x4); break;

    // OnMatchStart(self)
    case KIOU_BR_HOOK_AI_START:        HookAiStart(x0); break;
    case KIOU_BR_HOOK_CPUSTREAM_START: HookCpuStreamStart(x0); break;
    case KIOU_BR_HOOK_LOCAL_START:     HookLocalStart(x0); break;
    case KIOU_BR_HOOK_ONLINE_START:    HookOnlineStart(x0); break;
    case KIOU_BR_HOOK_REPLAY_START:    HookReplayStart(x0); break;

    // OnPlayerMoveAsync(self, mv, ct)
    //   self=x0, mv=w1 (packed uint32), ct=x2.
    case KIOU_BR_HOOK_AI_OPM:
        (void)HookAiOpm(x0, (uint32_t)(uintptr_t)x1, x2); break;
    case KIOU_BR_HOOK_CPUSTREAM_OPM:
        (void)HookCpuStreamOpm(x0, (uint32_t)(uintptr_t)x1, x2); break;
    case KIOU_BR_HOOK_LOCAL_OPM:
        (void)HookLocalOpm(x0, (uint32_t)(uintptr_t)x1, x2); break;
    case KIOU_BR_HOOK_ONLINE_OPM:
        (void)HookOnlineOpm(x0, (uint32_t)(uintptr_t)x1, x2); break;
    case KIOU_BR_HOOK_REPLAY_OPM:
        (void)HookReplayOpm(x0, (uint32_t)(uintptr_t)x1, x2); break;

    // OnMatchEndAsync(self, ct)
    case KIOU_BR_HOOK_AI_END:        (void)HookAiEnd(x0, x1); break;
    case KIOU_BR_HOOK_CPUSTREAM_END: (void)HookCpuStreamEnd(x0, x1); break;
    case KIOU_BR_HOOK_LOCAL_END:     (void)HookLocalEnd(x0, x1); break;
    case KIOU_BR_HOOK_ONLINE_END:    (void)HookOnlineEnd(x0, x1); break;
    case KIOU_BR_HOOK_REPLAY_END:    (void)HookReplayEnd(x0, x1); break;

    // ShogiGameAdapter.TryMakeMove(Move, out Move)
    //   self=x0, move=w1, outMove=x2. Return value is ignored — the cave
    //   resumes the original method which produces the real return.
    case KIOU_BR_HOOK_ADAPTER_TRY_MAKE_MOVE_OUT:
        (void)HookAdapterTryMakeMoveOut(x0, (uint32_t)(uintptr_t)x1, x2);
        break;

    // UpdateAuthoritativeSnapshot(self, sfen, turn, blackTime, whiteTime,
    //                              moveCount).
    //   sfen=x1, turn=w2 (int32), moveCount=w3 (int32). The two float
    //   arguments arrive in s0/s1 which the cave does not save and the
    //   dispatcher cannot reach from this C signature; pass 0.0f. The
    //   floats are log-only in the hook body, so the observable cost is
    //   a less precise "[SNAPSHOT]" timing line.
    case KIOU_BR_HOOK_ONLINE_UPDATE_SNAPSHOT:
        HookUpdateAuthoritativeSnapshot(x0, x1, (int32_t)(intptr_t)x2,
                                         0.0f, 0.0f,
                                         (int32_t)(intptr_t)x3);
        break;
    case KIOU_BR_HOOK_CPUSTREAM_UPDATE_SNAPSHOT:
        HookCpuStreamUpdateSnapshot(x0, x1, (int32_t)(intptr_t)x2,
                                      0.0f, 0.0f,
                                      (int32_t)(intptr_t)x3);
        break;

    // HandleMoveResult(self, reply)
    case KIOU_BR_HOOK_ONLINE_HANDLE_RESULT:
        HookHandleMoveResult(x0, x1); break;

    // GameOrchestrator.ActivateAsync(self, setup, assetLoader, ct)
    case KIOU_BR_HOOK_GAMEORCH_ACTIVATE:
        (void)HookGameOrchActivateAsync(x0, x1, x2, x3); break;

    // GameStateStore.SetBlackPlayerInfo(self, playerInfo)
    case KIOU_BR_HOOK_GSTATE_SET_BLACK_PLAYER_INFO:
        HookGStateSetBlackPlayerInfo(x0, x1); break;

    // GameStateStore.SetWhitePlayerInfo(self, playerInfo)
    case KIOU_BR_HOOK_GSTATE_SET_WHITE_PLAYER_INFO:
        HookGStateSetWhitePlayerInfo(x0, x1); break;

    // GameStateStore.NotifyPieceMoved(self, move, playerSide)
    //   self=x0, move=w1 (uint32), playerSide=w2 (int32)
    case KIOU_BR_HOOK_GSTATE_NOTIFY_PIECE_MOVED:
        HookGStateNotifyPieceMoved(x0, (uint32_t)(uintptr_t)x1,
                                   (int32_t)(intptr_t)x2); break;

    // KIOU_BR_HOOK_ACCOUNT_EXISTS / LOGIN_ARGS_CREATE /
    // REGISTER_USER_ARGS_CREATE / GET_VALID_MATCH_FOUND_STATUS /
    // MATCH_STREAM_ARGS_CREATE all use entry caves (CAVE_ENTRY): the cave
    // calls the per-slot hook directly via the entry slot table and never
    // reaches the observer dispatcher. No case bodies needed.

    // MatchingHandler.ReceiveWithTimeoutAsync.MoveNext(self)
    //   self=x0. Observer cave — peek into the state machine to cache
    //   the IStreamHandler pointer and react to MatchingStatus rate-range
    //   replies (Fixed Rate Range filter).
    case KIOU_BR_HOOK_RECEIVE_TIMEOUT_MOVENEXT:
        HookReceiveTimeoutMoveNext(x0); break;

    default:
        // Cave fired with an id outside the recipe table. Almost certainly
        // a recipe / header skew — log it and return so we at least keep
        // the process alive instead of falling off into orig with an
        // unexpected state.
        IPALog([NSString stringWithFormat:
                  @"[CHINLAN] unknown hook_id=%u self=%p",
                  (unsigned)hook_id, x0]);
        break;
    }
}

void KEBBridgeChinlanPublish(void) {
    if (g_unityBase == 0) {
        // Tweak.m always sets g_unityBase before reaching us. Guarding
        // anyway so a mis-ordered installer call surfaces in the log
        // instead of crashing on the deref below.
        IPALog(@"[CHINLAN] publish skipped: g_unityBase is zero");
        return;
    }
    // Slot lives in UnityFramework's __DATA,__bss at the RVA the recipe
    // pinned. Writing to __DATA is allowed by iOS 18 CSM; the cave's
    // ADRP+LDR resolves to this exact address and BLRs the pointer
    // stored here. arm64 aligned 8-byte pointer stores are atomic, so
    // the cave sees either NULL (before this fires) or the fully formed
    // dispatcher.
    void * volatile *slot =
        (void * volatile *)(g_unityBase + KIOU_BR_HOOK_SLOT_RVA);
    *slot = (void *)&dispatch_one;
    for (uint32_t i = 0; i < KIOU_BR_HOOK__COUNT; i++) {
        g_inject_entry[i] = kiou_bridge_bypass_entry_for_hook(i);
    }

    // Entry slots — one per CAVE_ENTRY site. The cave reads each slot via
    // ADRP+LDR and BLRs the function pointer there, so missing publishes
    // would BLR NULL and SIGKILL. Publishing before the cave can ever fire
    // is enforced by Tweak.m's installer ordering (this function runs
    // before any of the per-feature installers).
    void * volatile *entrySlots =
        (void * volatile *)(g_unityBase + KIOU_BR_ENTRY_SLOT_BASE_RVA);
    entrySlots[KIOU_BR_ENTRY_SLOT_ACCOUNT_EXISTS] =
        (void *)&HookAccountExistsEntry;
    entrySlots[KIOU_BR_ENTRY_SLOT_LOGIN_ARGS_CREATE] =
        (void *)&HookLoginArgsCreateEntry;
    entrySlots[KIOU_BR_ENTRY_SLOT_REGISTER_USER_ARGS_CREATE] =
        (void *)&HookRegisterUserArgsCreateEntry;
    entrySlots[KIOU_BR_ENTRY_SLOT_GET_VALID_MATCH_FOUND_STATUS] =
        (void *)&HookGetValidMatchFoundStatusEntry;
    entrySlots[KIOU_BR_ENTRY_SLOT_MATCH_STREAM_ARGS_CREATE] =
        (void *)&HookArgsCreateEntry;
    entrySlots[KIOU_BR_ENTRY_SLOT_RUN_LOGIN_SEQ_MOVENEXT] =
        (void *)&HookRunLoginSeqMoveNextEntry;
    entrySlots[KIOU_BR_ENTRY_SLOT_GET_SELF_PROFILE_MOVENEXT] =
        (void *)&HookGetSelfProfileMoveNextEntry;
    entrySlots[KIOU_BR_ENTRY_SLOT_HTTPMSGINVOKER_SEND_ASYNC] =
        (void *)&HookHttpMsgInvokerSendAsyncEntry;
    entrySlots[KIOU_BR_ENTRY_SLOT_HEADER_PROVIDER_SET_OR_UPDATE_HEADER] =
        (void *)&HookHeaderProviderSetOrUpdateEntry;
    IPALog([NSString stringWithFormat:
              @"[CHINLAN] entry slots base=%p (unityBase+0x%x): "
              @"AccountExists=%p LoginArgs=%p RegisterUserArgs=%p "
              @"GetValidMatchFound=%p ArgsCreate=%p "
              @"RunLoginSeq.MoveNext=%p GetSelfProfile.MoveNext=%p "
              @"HttpMsgInvoker.SendAsync=%p HeaderProvider.SetOrUpdate=%p",
              (void *)entrySlots,
              (unsigned)KIOU_BR_ENTRY_SLOT_BASE_RVA,
              (void *)entrySlots[KIOU_BR_ENTRY_SLOT_ACCOUNT_EXISTS],
              (void *)entrySlots[KIOU_BR_ENTRY_SLOT_LOGIN_ARGS_CREATE],
              (void *)entrySlots[KIOU_BR_ENTRY_SLOT_REGISTER_USER_ARGS_CREATE],
              (void *)entrySlots[KIOU_BR_ENTRY_SLOT_GET_VALID_MATCH_FOUND_STATUS],
              (void *)entrySlots[KIOU_BR_ENTRY_SLOT_MATCH_STREAM_ARGS_CREATE],
              (void *)entrySlots[KIOU_BR_ENTRY_SLOT_RUN_LOGIN_SEQ_MOVENEXT],
              (void *)entrySlots[KIOU_BR_ENTRY_SLOT_GET_SELF_PROFILE_MOVENEXT],
              (void *)entrySlots[KIOU_BR_ENTRY_SLOT_HTTPMSGINVOKER_SEND_ASYNC],
              (void *)entrySlots[KIOU_BR_ENTRY_SLOT_HEADER_PROVIDER_SET_OR_UPDATE_HEADER]]);
    IPALog([NSString stringWithFormat:
              @"[CHINLAN] slot=%p (unityBase+0x%lx) published "
              @"dispatcher=%p inject_entry[ai_opm]=%p inject_entry[adapter]=%p "
              @"cave_start=0x%lx cave_size=%u bypass_off=0x%x count=%u",
              (void *)slot,
              (unsigned long)KIOU_BR_HOOK_SLOT_RVA,
              (void *)&dispatch_one,
              (void *)g_inject_entry[KIOU_BR_HOOK_AI_OPM],
              (void *)g_inject_entry[KIOU_BR_HOOK_ADAPTER_TRY_MAKE_MOVE_OUT],
              (unsigned long)KIOU_BR_CAVE_REGION_START,
              (unsigned)KIOU_BR_CAVE_SIZE,
              (unsigned)KIOU_BR_CAVE_BYPASS_OFFSET,
              (unsigned)KIOU_BR_HOOK__COUNT]);
}

#endif  // IPA_CHINLAN
