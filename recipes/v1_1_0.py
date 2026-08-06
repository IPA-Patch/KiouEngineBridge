"""KiouEngineBridge patch constants for app version 1.1.0 (CFBundleVersion 15).

RVAs verified against assets/1.1.0/dump.cs.index.json on 2026-08-06. SITES was
re-resolved from v1_0_2.py with ``tools.port_recipe``; every slot and cave
address below was re-measured against the 1.1.0 Mach-O, because 1.1.0 moved
every section (il2cpp code alone grew ~0xF00000).

Sections this recipe depends on, as measured on the 1.1.0 UnityFramework:
  __TEXT,__oslogstring  0x94B8000 (size 0x23)   — cave region follows it
  __DATA_CONST,__got    0x94BC000               — cave region ends here
  __DATA,__bss          0xA1ADC40 (size 0x11C878)
  __DATA,__common       0xA2CA4C0 (size 0x258568)
"""

from recipes.common import CAVE_OBSERVER, CAVE_ENTRY

BUILD = 15

# Same shape as 1.0.2: the verified-zero __TEXT tail between the end of
# __oslogstring and the start of __DATA_CONST,__got. Confirmed all-zero on
# disk over 0x94B8023..0x94BC000; 37 caves * 84 B = 0xC24, against 0x3FC0
# available.
CAVE_REGION          = (0x94B8040, 0x94BC000)
# __DATA,__bss tail. reserve_hook_slot() claims the very last 8 bytes
# (0xA2CA4B0), so take the 8 bytes below it and record the probe separately —
# that leaves the tail slot to a sibling tweak and keeps patch_macho's drift
# check comparing like with like (1.0.2 pinned PROBED to its own slot, so the
# check has been reporting a false drift there).
HOOK_SLOT_RVA        = 0xA2CA4A0
PROBED_HOOK_SLOT_RVA = 0xA2CA4B0
# Reserved sibling table (Branch F), kept 0xC0 below the hook slot exactly as
# in 1.0.1/1.0.2.
INJECT_ENTRY_TABLE_RVA        = 0xA2CA3E0
PROBED_INJECT_ENTRY_TABLE_RVA = 0xA2CA3E0
# Entry-slot table stays in __DATA,__common at the same offset into the
# section as 1.0.1/1.0.2 used (+0x24BCF8): the dylib constructor runs before
# Unity's il2cpp init and overwrites the slots with our function pointers, so
# the staged garbage never gets BLR'd. Moving the slots into __bss breaks PAC
# — iOS 18 expects function pointers in __bss/__data to be PAC-signed, and our
# plain pointer + plain BLR cave crashes on auth check at the call site.
ENTRY_SLOT_BASE_RVA  = 0x0A5161B8
ZERO_REGION_END_RVA  = 0x0A522A28

# Project.Game.Presentation.GameOrchestrator.IsAfkEnabled()
AFK_SITE    = 0x6854064
AFK_ORIG_8  = "f44fbea9fd7b01a9"

# Runtime call targets — see recipes.common.CALL_RVA_KEYS. Re-resolved by
# declaring type + signature against assets/1.1.0/dump.cs.index.json.
CALLS = {
    "GAMEORCH_REQUEST_SURRENDER":          0x68598F0,
    "GAMEORCH_ON_END_SEQUENCE_COMPLETED":  0x6859EBC,
    "BOARDPRESENTER_PLAY_MOVE_ANIMATION":  0x68761A8,
    "MATCHCTRL_TRY_MAKE_LOCAL_MOVE":       0x68E6C78,
    "MATCHCTRL_SURRENDER_ASYNC":           0x68EC4E8,
    "GAMESTATESTORE_SET_CURRENT_POSITION": 0x693E974,
    "GAMESTATESTORE_NOTIFY_PIECE_MOVED":   0x693F8F8,
    "GAMESTATESTORE_NOTIFY_STATE_SYNCED":  0x693FA38,
    "BACK_TO_TITLE_RUN_ASYNC":             0x6C1581C,
    "CPU_MATCH_START_FREE":                0x6C21D44,
    "MATCHING_START_RANK":                 0x6C234E8,
    "POSITION_GET_PIECE":                  0x6C63BC0,
    "PIECE_GET_PIECETYPE":                 0x6C63BF4,
    "POSITION_CREATE_BY_TYPE":             0x6C6BDF0,
    "POSITION_CREATE_FROM_SFEN":           0x6C6C048,
    "GAMECTRL_GET_USI_TEXT":               0x6C6DA6C,
    "POSITION_TO_SFEN":                    0x6C6DD6C,
    "PSC_MOVE_CREATE":                     0x6C6ED64,
    "PSC_MOVE_CREATE_DROP":                0x6C6ED84,
    "SUNFISH_MOVE_TO_STRING_SFEN":         0x6CAFD20,
    "SUNFISH_MOVE_DROP":                   0x6CB4648,
    "HTTPHEADERS_TRYADD":                  0x6FB1CD4,
    "HTTPHEADERS_REMOVE":                  0x6FB218C,
}

# 1.1.0 widened the signature to
# PlayMoveAnimationAsync(Move move, PlayerSide movePlayer, CancellationToken ct);
# the injector has to pass the mover explicitly instead of letting the
# presenter infer it.
BOARD_ANIM_TAKES_PLAYER_SIDE = True

# Drifting field offsets — see recipes.common.FIELD_OFFSET_KEYS.
# SelfUserProfileStatus gained userAttribute_ at 0x28, pushing every list
# reference down 8 bytes.
FIELD_OFFSETS = {
    "SELF_PROFILE_RANK_LIST":          0x30,
    "SELF_PROFILE_BATTLE_RECORD_LIST": 0x50,
}

# fmt: off
SITES = [
    # OnMatchEndAsync × 5
    (0x68F4988, "f657bda9", "KIOU_BR_HOOK_AI_END",        CAVE_OBSERVER, "AIMatchMode.OnMatchEndAsync"),
    (0x68FCD78, "ff8301d1", "KIOU_BR_HOOK_CPUSTREAM_END", CAVE_OBSERVER, "CPUStreamMode.OnMatchEndAsync"),
    (0x69103D4, "f44fbea9", "KIOU_BR_HOOK_LOCAL_END",     CAVE_OBSERVER, "LocalPvPMode.OnMatchEndAsync"),
    (0x6911E8C, "ff8301d1", "KIOU_BR_HOOK_ONLINE_END",    CAVE_OBSERVER, "OnlinePvPMode.OnMatchEndAsync"),
    (0x693DE6C, "f85fbca9", "KIOU_BR_HOOK_REPLAY_END",    CAVE_OBSERVER, "RecordReplayMode.OnMatchEndAsync"),

    # InitializeAsync × 5
    (0x68F3E3C, "e923ba6d", "KIOU_BR_HOOK_AI_INIT",        CAVE_OBSERVER, "AIMatchMode.InitializeAsync"),
    (0x68F6B8C, "ff8302d1", "KIOU_BR_HOOK_CPUSTREAM_INIT", CAVE_OBSERVER, "CPUStreamMode.InitializeAsync"),
    (0x691028C, "f657bda9", "KIOU_BR_HOOK_LOCAL_INIT",     CAVE_OBSERVER, "LocalPvPMode.InitializeAsync"),
    (0x6911980, "ff8302d1", "KIOU_BR_HOOK_ONLINE_INIT",    CAVE_OBSERVER, "OnlinePvPMode.InitializeAsync"),
    (0x693D6D8, "ff0301d1", "KIOU_BR_HOOK_REPLAY_INIT",    CAVE_OBSERVER, "RecordReplayMode.InitializeAsync"),

    # OnPlayerMoveAsync × 5
    (0x68F4298, "ffc301d1", "KIOU_BR_HOOK_AI_OPM",        CAVE_OBSERVER, "AIMatchMode.OnPlayerMoveAsync"),
    (0x68F78B4, "ffc301d1", "KIOU_BR_HOOK_CPUSTREAM_OPM", CAVE_OBSERVER, "CPUStreamMode.OnPlayerMoveAsync"),
    (0x6910358, "f44fbea9", "KIOU_BR_HOOK_LOCAL_OPM",     CAVE_OBSERVER, "LocalPvPMode.OnPlayerMoveAsync"),
    (0x6911DC8, "ffc301d1", "KIOU_BR_HOOK_ONLINE_OPM",    CAVE_OBSERVER, "OnlinePvPMode.OnPlayerMoveAsync"),
    (0x693DCF4, "ff0301d1", "KIOU_BR_HOOK_REPLAY_OPM",    CAVE_OBSERVER, "RecordReplayMode.OnPlayerMoveAsync"),

    # OnMatchStart × 5
    (0x68F4030, "f85fbca9", "KIOU_BR_HOOK_AI_START",        CAVE_OBSERVER, "AIMatchMode.OnMatchStart"),
    (0x68F6DA8, "fa67bba9", "KIOU_BR_HOOK_CPUSTREAM_START", CAVE_OBSERVER, "CPUStreamMode.OnMatchStart"),
    (0x6910354, "c0035fd6", "KIOU_BR_HOOK_LOCAL_START",     CAVE_OBSERVER, "LocalPvPMode.OnMatchStart"),
    (0x6910918, "f657bda9", "KIOU_BR_HOOK_ONLINE_START",    CAVE_OBSERVER, "OnlinePvPMode.OnMatchStart"),
    (0x693DC74, "f657bda9", "KIOU_BR_HOOK_REPLAY_START",    CAVE_OBSERVER, "RecordReplayMode.OnMatchStart"),

    # Single-site observation hooks
    (0x68DFD50, "ff8300d1", "KIOU_BR_HOOK_ADAPTER_TRY_MAKE_MOVE_OUT", CAVE_OBSERVER, "ShogiGameAdapter.TryMakeMove"),
    (0x691B5D4, "e923bc6d", "KIOU_BR_HOOK_ONLINE_UPDATE_SNAPSHOT",    CAVE_OBSERVER, "OnlinePvPMode.UpdateAuthoritativeSnapshot"),
    (0x691DB58, "ff0302d1", "KIOU_BR_HOOK_ONLINE_HANDLE_RESULT",      CAVE_OBSERVER, "OnlinePvPMode.HandleMoveResult"),
    (0x68FA4EC, "e923bc6d", "KIOU_BR_HOOK_CPUSTREAM_UPDATE_SNAPSHOT", CAVE_OBSERVER, "CPUStreamMode.UpdateAuthoritativeSnapshot"),
    (0x6853920, "ff4302d1", "KIOU_BR_HOOK_GAMEORCH_ACTIVATE",         CAVE_OBSERVER, "GameOrchestrator.ActivateAsync"),

    # GameStateStore hooks
    (0x693F674, "f44fbea9", "KIOU_BR_HOOK_GSTATE_SET_BLACK_PLAYER_INFO", CAVE_OBSERVER, "GameStateStore.SetBlackPlayerInfo"),
    (0x693F6B0, "f44fbea9", "KIOU_BR_HOOK_GSTATE_SET_WHITE_PLAYER_INFO", CAVE_OBSERVER, "GameStateStore.SetWhitePlayerInfo"),
    (0x693F8F8, "ff4301d1", "KIOU_BR_HOOK_GSTATE_NOTIFY_PIECE_MOVED",    CAVE_OBSERVER, "GameStateStore.NotifyPieceMoved"),

    # Account identity — CAVE_ENTRY
    (0x682FF8C, "fd7bbfa9", "KIOU_BR_HOOK_ACCOUNT_EXISTS",          CAVE_ENTRY, "UserSaveDataExtensions.AccountExists"),

    # Account switching — CAVE_ENTRY
    (0x6AB29B0, "f85fbca9", "KIOU_BR_HOOK_LOGIN_ARGS_CREATE",         CAVE_ENTRY, "ILoginArgs.Create"),
    (0x6AB2A5C, "f657bda9", "KIOU_BR_HOOK_REGISTER_USER_ARGS_CREATE", CAVE_ENTRY, "IRegisterUserArgs.Create"),

    # Matching filter — CAVE_ENTRY
    (0x6C23BF0, "ff0301d1", "KIOU_BR_HOOK_GET_VALID_MATCH_FOUND_STATUS", CAVE_ENTRY,    "GetValidMatchFoundStatus"),
    (0x6AE500C, "fc6fbaa9", "KIOU_BR_HOOK_MATCH_STREAM_ARGS_CREATE",     CAVE_ENTRY,    "IShogiMatchStreamArgs.Create"),
    (0x6C2586C, "ff0303d1", "KIOU_BR_HOOK_RECEIVE_TIMEOUT_MOVENEXT",     CAVE_OBSERVER, "MatchingHandler+<ReceiveWithTimeoutAsync>d__6.MoveNext"),

    # Async MoveNext — CAVE_ENTRY
    (0x66CED7C, "ff8302d1", "KIOU_BR_HOOK_RUN_LOGIN_SEQ_MOVENEXT",    CAVE_ENTRY, "AuthServiceExtensions+<RunLoginSequenceAsync>d__1.MoveNext"),
    # d__36 in 1.0.2 — the state-machine ordinal shifted with the new members
    # GameService gained in 1.1.0.
    (0x6ACF014, "ff4302d1", "KIOU_BR_HOOK_GET_SELF_PROFILE_MOVENEXT", CAVE_ENTRY, "GameService+<GetSelfUserProfileAsync>d__38.MoveNext"),

    # HttpMessageInvoker.SendAsync vtable thunk
    (0x6FA5DDC, "000840f9", "KIOU_BR_HOOK_HTTPMSGINVOKER_SEND_ASYNC", CAVE_ENTRY, "HttpMessageInvoker.SendAsync"),
]
# fmt: on
