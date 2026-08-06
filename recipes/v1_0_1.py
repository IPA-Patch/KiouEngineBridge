"""KiouEngineBridge patch constants for app version 1.0.1 (CFBundleVersion 11).

RVAs verified against assets/1.0.1/dump.cs.index.json on 2026-06-15.
"""

from recipes.common import CAVE_OBSERVER, CAVE_ENTRY

BUILD = 11

CAVE_REGION          = (0x826A000, 0x826C000)
# Observer dispatcher slot. The old 0x8F90CC0 sat in __DATA,__bss, which
# UnityRuntime overwrites during lazy il2cpp init — i.e. after our constructor
# publishes, so the cave's BLR X16 jumps to garbage (verified crash on 1.0.2,
# recorded in IPA-Patch/KIOU-Hook recipes/v1_0_2.py). Everything the caves
# touch now lives in __DATA,__common, which survives publish.
#
# Sections measured on the 1.0.1 UnityFramework:
#   __DATA,__bss     0x8E76B80..0x8F90CD8
#   __DATA,__common  0x8F90D00..0x091E91B8
# KIOU-Hook pins 1.0.1 at 0x091E93B8, but that address is past __common's end
# (it lands in __DATA segment padding, mapped but section-less) and our
# machoops.assert_slot_in_bss rejects it. Use the same geometry the other two
# versions use instead: table at __common end - 0xC7C0, dispatcher +0x200.
HOOK_SLOT_RVA        = 0x091DCBF8
# Canary only: the __bss tail reserve_hook_slot() probes. Kept so a layout
# shift between builds still trips the drift warning.
PROBED_HOOK_SLOT_RVA = 0x8F90CD0
INJECT_ENTRY_TABLE_RVA        = 0x8F90C00
PROBED_INJECT_ENTRY_TABLE_RVA = 0x8F90C00
ENTRY_SLOT_BASE_RVA  = 0x091DC9F8
ZERO_REGION_END_RVA  = 0x091E91B8

AFK_SITE    = 0x59455D4
AFK_ORIG_8  = "f44fbea9fd7b01a9"

# Runtime call targets — see recipes.common.CALL_RVA_KEYS.
CALLS = {
    "GAMEORCH_REQUEST_SURRENDER":          0x594A91C,
    "GAMEORCH_ON_END_SEQUENCE_COMPLETED":  0x594AE5C,
    "BOARDPRESENTER_PLAY_MOVE_ANIMATION":  0x5968894,
    "MATCHCTRL_TRY_MAKE_LOCAL_MOVE":       0x59D7908,
    "MATCHCTRL_SURRENDER_ASYNC":           0x59DDD94,
    "GAMESTATESTORE_SET_CURRENT_POSITION": 0x5A2C06C,
    "GAMESTATESTORE_NOTIFY_PIECE_MOVED":   0x5A2CD24,
    "GAMESTATESTORE_NOTIFY_STATE_SYNCED":  0x5A2CE64,
    "BACK_TO_TITLE_RUN_ASYNC":             0x5CF712C,
    "CPU_MATCH_START_FREE":                0x5D02FE8,
    "MATCHING_START_RANK":                 0x5D0478C,
    "POSITION_GET_PIECE":                  0x5D3A1C8,
    "PIECE_GET_PIECETYPE":                 0x5D3A1FC,
    "POSITION_CREATE_BY_TYPE":             0x5D423F8,
    "POSITION_CREATE_FROM_SFEN":           0x5D42650,
    "GAMECTRL_GET_USI_TEXT":               0x5D44074,
    "POSITION_TO_SFEN":                    0x5D44374,
    "PSC_MOVE_CREATE":                     0x5D4536C,
    "PSC_MOVE_CREATE_DROP":                0x5D4538C,
    "SUNFISH_MOVE_TO_STRING_SFEN":         0x5D821B0,
    "SUNFISH_MOVE_DROP":                   0x5D86AD8,
    "HTTPHEADERS_TRYADD":                  0x608886C,
    "HTTPHEADERS_REMOVE":                  0x6088D24,
}

# BoardPresenter.PlayMoveAnimationAsync(Move, CancellationToken).
BOARD_ANIM_TAKES_PLAYER_SIDE = False

# Drifting field offsets — see recipes.common.FIELD_OFFSET_KEYS.
FIELD_OFFSETS = {
    "SELF_PROFILE_RANK_LIST":          0x28,
    "SELF_PROFILE_BATTLE_RECORD_LIST": 0x48,
}

# fmt: off
SITES = [
    # OnMatchEndAsync × 5
    (0x59E5958, "f657bda9", "KIOU_BR_HOOK_AI_END",        CAVE_OBSERVER, "AIMatchMode.OnMatchEndAsync"),
    (0x59EC818, "ff8301d1", "KIOU_BR_HOOK_CPUSTREAM_END", CAVE_OBSERVER, "CPUStreamMode.OnMatchEndAsync"),
    (0x59FF8F8, "f44fbea9", "KIOU_BR_HOOK_LOCAL_END",     CAVE_OBSERVER, "LocalPvPMode.OnMatchEndAsync"),
    (0x5A0139C, "ff8301d1", "KIOU_BR_HOOK_ONLINE_END",    CAVE_OBSERVER, "OnlinePvPMode.OnMatchEndAsync"),
    (0x5A2B564, "f85fbca9", "KIOU_BR_HOOK_REPLAY_END",    CAVE_OBSERVER, "RecordReplayMode.OnMatchEndAsync"),

    # InitializeAsync × 5
    (0x59E4E0C, "e923ba6d", "KIOU_BR_HOOK_AI_INIT",        CAVE_OBSERVER, "AIMatchMode.InitializeAsync"),
    (0x59E7B48, "ff8302d1", "KIOU_BR_HOOK_CPUSTREAM_INIT", CAVE_OBSERVER, "CPUStreamMode.InitializeAsync"),
    (0x59FF7B0, "f657bda9", "KIOU_BR_HOOK_LOCAL_INIT",     CAVE_OBSERVER, "LocalPvPMode.InitializeAsync"),
    (0x5A00E90, "ff8302d1", "KIOU_BR_HOOK_ONLINE_INIT",    CAVE_OBSERVER, "OnlinePvPMode.InitializeAsync"),
    (0x5A2ADD0, "ff0301d1", "KIOU_BR_HOOK_REPLAY_INIT",    CAVE_OBSERVER, "RecordReplayMode.InitializeAsync"),

    # OnPlayerMoveAsync × 5
    (0x59E5268, "ffc301d1", "KIOU_BR_HOOK_AI_OPM",        CAVE_OBSERVER, "AIMatchMode.OnPlayerMoveAsync"),
    (0x59E886C, "ffc301d1", "KIOU_BR_HOOK_CPUSTREAM_OPM", CAVE_OBSERVER, "CPUStreamMode.OnPlayerMoveAsync"),
    (0x59FF87C, "f44fbea9", "KIOU_BR_HOOK_LOCAL_OPM",     CAVE_OBSERVER, "LocalPvPMode.OnPlayerMoveAsync"),
    (0x5A012D8, "ffc301d1", "KIOU_BR_HOOK_ONLINE_OPM",    CAVE_OBSERVER, "OnlinePvPMode.OnPlayerMoveAsync"),
    (0x5A2B3EC, "ff0301d1", "KIOU_BR_HOOK_REPLAY_OPM",    CAVE_OBSERVER, "RecordReplayMode.OnPlayerMoveAsync"),

    # OnMatchStart × 5
    (0x59E5000, "f85fbca9", "KIOU_BR_HOOK_AI_START",        CAVE_OBSERVER, "AIMatchMode.OnMatchStart"),
    (0x59E7D64, "fa67bba9", "KIOU_BR_HOOK_CPUSTREAM_START", CAVE_OBSERVER, "CPUStreamMode.OnMatchStart"),
    (0x59FF878, "c0035fd6", "KIOU_BR_HOOK_LOCAL_START",     CAVE_OBSERVER, "LocalPvPMode.OnMatchStart"),
    (0x59FFE3C, "f657bda9", "KIOU_BR_HOOK_ONLINE_START",    CAVE_OBSERVER, "OnlinePvPMode.OnMatchStart"),
    (0x5A2B36C, "f657bda9", "KIOU_BR_HOOK_REPLAY_START",    CAVE_OBSERVER, "RecordReplayMode.OnMatchStart"),

    # Single-site observation hooks
    (0x59D0DFC, "ff8301d1", "KIOU_BR_HOOK_ADAPTER_TRY_MAKE_MOVE_OUT", CAVE_OBSERVER, "ShogiGameAdapter.TryMakeMove"),
    (0x5A0A64C, "e923bc6d", "KIOU_BR_HOOK_ONLINE_UPDATE_SNAPSHOT",    CAVE_OBSERVER, "OnlinePvPMode.UpdateAuthoritativeSnapshot"),
    (0x5A0CBD0, "ff0302d1", "KIOU_BR_HOOK_ONLINE_HANDLE_RESULT",      CAVE_OBSERVER, "OnlinePvPMode.HandleMoveResult"),
    (0x59EB0E0, "e923bc6d", "KIOU_BR_HOOK_CPUSTREAM_UPDATE_SNAPSHOT", CAVE_OBSERVER, "CPUStreamMode.UpdateAuthoritativeSnapshot"),
    (0x5944E84, "ff4302d1", "KIOU_BR_HOOK_GAMEORCH_ACTIVATE",         CAVE_OBSERVER, "GameOrchestrator.ActivateAsync"),

    # GameStateStore hooks
    (0x5A2CB64, "f44fbea9", "KIOU_BR_HOOK_GSTATE_SET_BLACK_PLAYER_INFO", CAVE_OBSERVER, "GameStateStore.SetBlackPlayerInfo"),
    (0x5A2CBA0, "f44fbea9", "KIOU_BR_HOOK_GSTATE_SET_WHITE_PLAYER_INFO", CAVE_OBSERVER, "GameStateStore.SetWhitePlayerInfo"),
    (0x5A2CD24, "ff4301d1", "KIOU_BR_HOOK_GSTATE_NOTIFY_PIECE_MOVED",    CAVE_OBSERVER, "GameStateStore.NotifyPieceMoved"),

    # Account identity — CAVE_ENTRY
    (0x591E860, "fd7bbfa9", "KIOU_BR_HOOK_ACCOUNT_EXISTS",          CAVE_ENTRY, "UserSaveDataExtensions.AccountExists"),

    # Account switching — CAVE_ENTRY
    (0x5B9899C, "f657bda9", "KIOU_BR_HOOK_LOGIN_ARGS_CREATE",         CAVE_ENTRY, "ILoginArgs.Create"),
    (0x5B98A2C, "f657bda9", "KIOU_BR_HOOK_REGISTER_USER_ARGS_CREATE", CAVE_ENTRY, "IRegisterUserArgs.Create"),

    # Matching filter — CAVE_ENTRY
    (0x5D04E94, "ff0301d1", "KIOU_BR_HOOK_GET_VALID_MATCH_FOUND_STATUS", CAVE_ENTRY,    "GetValidMatchFoundStatus"),
    (0x5BCA664, "fc6fbaa9", "KIOU_BR_HOOK_MATCH_STREAM_ARGS_CREATE",     CAVE_ENTRY,    "IShogiMatchStreamArgs.Create"),
    (0x5D06B10, "ff0303d1", "KIOU_BR_HOOK_RECEIVE_TIMEOUT_MOVENEXT",     CAVE_OBSERVER, "MatchingHandler+<ReceiveWithTimeoutAsync>d__6.MoveNext"),

    # Async MoveNext — CAVE_ENTRY
    (0x5812534, "ff8302d1", "KIOU_BR_HOOK_RUN_LOGIN_SEQ_MOVENEXT",    CAVE_ENTRY, "AuthServiceExtensions+<RunLoginSequenceAsync>d__1.MoveNext"),
    (0x5BB4774, "ff4302d1", "KIOU_BR_HOOK_GET_SELF_PROFILE_MOVENEXT", CAVE_ENTRY, "GameService+<GetSelfUserProfileAsync>d__36.MoveNext"),

    # HttpMessageInvoker.SendAsync vtable thunk
    (0x607C974, "000840f9", "KIOU_BR_HOOK_HTTPMSGINVOKER_SEND_ASYNC", CAVE_ENTRY, "HttpMessageInvoker.SendAsync"),
]
# fmt: on
