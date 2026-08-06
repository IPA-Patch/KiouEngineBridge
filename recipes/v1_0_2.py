"""KiouEngineBridge patch constants for app version 1.0.2 (CFBundleVersion 12).

RVAs verified against assets/1.0.2/dump.cs.index.json on 2026-06-23.
Slot addresses are identical to 1.0.1 (__bss/__common are zero-fill sections
whose layout is stable across these builds).
"""

from recipes.common import CAVE_OBSERVER, CAVE_ENTRY

BUILD = 12

# 1.0.1's CAVE_REGION at 0x826A000 was a __TEXT zero-fill area, but in 1.0.2
# __TEXT,__eh_frame grew to 0x81ACE58..0x826F5E8 and now covers that range —
# writing caves there corrupts DWARF CFI. Relocate to the verified-zero tail
# after __oslogstring (sibling tweak KiouForge uses the same window). 37 caves
# * 84 B = 0xC24, fits comfortably in the 0x3FC0 of trailing zeros.
CAVE_REGION          = (0x8270040, 0x8274000)
# Observer dispatcher slot. 0x8F90CC0 landed in __DATA,__bss, which
# UnityRuntime overwrites during lazy il2cpp init — after our publish, so the
# cave's BLR X16 jumped to garbage (verified crash, recorded in
# IPA-Patch/KIOU-Hook recipes/v1_0_2.py). Moved into __common just past the
# entry-slot table, where publishes survive.
# __DATA,__bss is 0x8E83340..0x8F9D4C0, __DATA,__common 0x8F9D4C0..0x091F5978.
HOOK_SLOT_RVA        = 0x091E93B8
# Canary only: the __bss tail reserve_hook_slot() probes.
PROBED_HOOK_SLOT_RVA = 0x8F9D4B8
INJECT_ENTRY_TABLE_RVA        = 0x8F90C00
PROBED_INJECT_ENTRY_TABLE_RVA = 0x8F90C00
# Keep the entry-slot table in __DATA,__common at the same RVA as 1.0.1 even
# though that region carries live data on disk: the dylib constructor runs
# before Unity's il2cpp init and overwrites the slots with our function
# pointers, so the staged garbage never gets BLR'd. Moving the slots into
# __bss (the previous attempt) breaks PAC: iOS 18 expects function pointers
# in __bss/__data to be PAC-signed, and our plain pointer + plain BLR cave
# crashes on auth check at the call site.
ENTRY_SLOT_BASE_RVA  = 0x091E91B8
ZERO_REGION_END_RVA  = 0x091F5978

AFK_SITE    = 0x594A034
AFK_ORIG_8  = "f44fbea9fd7b01a9"

# Runtime call targets — see recipes.common.CALL_RVA_KEYS. Until these moved
# into the recipe the dylib carried 1.0.1 literals, so every 1.0.2 build was
# calling il2cpp at addresses ~0x4C00-0x5F00 short of the real entry points.
CALLS = {
    "GAMEORCH_REQUEST_SURRENDER":          0x594F5F8,
    "GAMEORCH_ON_END_SEQUENCE_COMPLETED":  0x594FBCC,
    "BOARDPRESENTER_PLAY_MOVE_ANIMATION":  0x596CD2C,
    "MATCHCTRL_TRY_MAKE_LOCAL_MOVE":       0x59DC724,
    "MATCHCTRL_SURRENDER_ASYNC":           0x59E2BB0,
    "GAMESTATESTORE_SET_CURRENT_POSITION": 0x5A30E28,
    "GAMESTATESTORE_NOTIFY_PIECE_MOVED":   0x5A31AE0,
    "GAMESTATESTORE_NOTIFY_STATE_SYNCED":  0x5A31C20,
    "BACK_TO_TITLE_RUN_ASYNC":             0x5CFC394,
    "CPU_MATCH_START_FREE":                0x5D088E0,
    "MATCHING_START_RANK":                 0x5D0A084,
    "POSITION_GET_PIECE":                  0x5D3FAC4,
    "PIECE_GET_PIECETYPE":                 0x5D3FAF8,
    "POSITION_CREATE_BY_TYPE":             0x5D47CF4,
    "POSITION_CREATE_FROM_SFEN":           0x5D47F4C,
    "GAMECTRL_GET_USI_TEXT":               0x5D49970,
    "POSITION_TO_SFEN":                    0x5D49C70,
    "PSC_MOVE_CREATE":                     0x5D4AC68,
    "PSC_MOVE_CREATE_DROP":                0x5D4AC88,
    "SUNFISH_MOVE_TO_STRING_SFEN":         0x5D87AAC,
    "SUNFISH_MOVE_DROP":                   0x5D8C3D4,
    "HTTPHEADERS_TRYADD":                  0x608E9B8,
    "HTTPHEADERS_REMOVE":                  0x608EE70,
}

# BoardPresenter.PlayMoveAnimationAsync(Move, CancellationToken).
BOARD_ANIM_TAKES_PLAYER_SIDE = False

# ILoginArgs.Create(string deviceId, string distinctId) — appsflyerId arrived
# in 1.1.0.
LOGIN_ARGS_TAKES_APPSFLYER_ID = False

# Drifting field offsets — see recipes.common.FIELD_OFFSET_KEYS. Identical to
# 1.0.1; SelfUserProfileStatus first moved in 1.1.0.
FIELD_OFFSETS = {
    "SELF_PROFILE_RANK_LIST":          0x28,
    "SELF_PROFILE_BATTLE_RECORD_LIST": 0x48,
}

# fmt: off
SITES = [
    # OnMatchEndAsync × 5
    (0x59EA720, "f657bda9", "KIOU_BR_HOOK_AI_END",        CAVE_OBSERVER, "AIMatchMode.OnMatchEndAsync"),
    (0x59F15D4, "ff8301d1", "KIOU_BR_HOOK_CPUSTREAM_END", CAVE_OBSERVER, "CPUStreamMode.OnMatchEndAsync"),
    (0x5A046B4, "f44fbea9", "KIOU_BR_HOOK_LOCAL_END",     CAVE_OBSERVER, "LocalPvPMode.OnMatchEndAsync"),
    (0x5A06158, "ff8301d1", "KIOU_BR_HOOK_ONLINE_END",    CAVE_OBSERVER, "OnlinePvPMode.OnMatchEndAsync"),
    (0x5A30320, "f85fbca9", "KIOU_BR_HOOK_REPLAY_END",    CAVE_OBSERVER, "RecordReplayMode.OnMatchEndAsync"),

    # InitializeAsync × 5
    (0x59E9BD4, "e923ba6d", "KIOU_BR_HOOK_AI_INIT",        CAVE_OBSERVER, "AIMatchMode.InitializeAsync"),
    (0x59EC910, "ff8302d1", "KIOU_BR_HOOK_CPUSTREAM_INIT", CAVE_OBSERVER, "CPUStreamMode.InitializeAsync"),
    (0x5A0456C, "f657bda9", "KIOU_BR_HOOK_LOCAL_INIT",     CAVE_OBSERVER, "LocalPvPMode.InitializeAsync"),
    (0x5A05C4C, "ff8302d1", "KIOU_BR_HOOK_ONLINE_INIT",    CAVE_OBSERVER, "OnlinePvPMode.InitializeAsync"),
    (0x5A2FB8C, "ff0301d1", "KIOU_BR_HOOK_REPLAY_INIT",    CAVE_OBSERVER, "RecordReplayMode.InitializeAsync"),

    # OnPlayerMoveAsync × 5
    (0x59EA030, "ffc301d1", "KIOU_BR_HOOK_AI_OPM",        CAVE_OBSERVER, "AIMatchMode.OnPlayerMoveAsync"),
    (0x59ED634, "ffc301d1", "KIOU_BR_HOOK_CPUSTREAM_OPM", CAVE_OBSERVER, "CPUStreamMode.OnPlayerMoveAsync"),
    (0x5A04638, "f44fbea9", "KIOU_BR_HOOK_LOCAL_OPM",     CAVE_OBSERVER, "LocalPvPMode.OnPlayerMoveAsync"),
    (0x5A06094, "ffc301d1", "KIOU_BR_HOOK_ONLINE_OPM",    CAVE_OBSERVER, "OnlinePvPMode.OnPlayerMoveAsync"),
    (0x5A301A8, "ff0301d1", "KIOU_BR_HOOK_REPLAY_OPM",    CAVE_OBSERVER, "RecordReplayMode.OnPlayerMoveAsync"),

    # OnMatchStart × 5
    (0x59E9DC8, "f85fbca9", "KIOU_BR_HOOK_AI_START",        CAVE_OBSERVER, "AIMatchMode.OnMatchStart"),
    (0x59ECB2C, "fa67bba9", "KIOU_BR_HOOK_CPUSTREAM_START", CAVE_OBSERVER, "CPUStreamMode.OnMatchStart"),
    (0x5A04634, "c0035fd6", "KIOU_BR_HOOK_LOCAL_START",     CAVE_OBSERVER, "LocalPvPMode.OnMatchStart"),
    (0x5A04BF8, "f657bda9", "KIOU_BR_HOOK_ONLINE_START",    CAVE_OBSERVER, "OnlinePvPMode.OnMatchStart"),
    (0x5A30128, "f657bda9", "KIOU_BR_HOOK_REPLAY_START",    CAVE_OBSERVER, "RecordReplayMode.OnMatchStart"),

    # Single-site observation hooks
    (0x59D5BC0, "ff8301d1", "KIOU_BR_HOOK_ADAPTER_TRY_MAKE_MOVE_OUT", CAVE_OBSERVER, "ShogiGameAdapter.TryMakeMove"),
    (0x5A0F408, "e923bc6d", "KIOU_BR_HOOK_ONLINE_UPDATE_SNAPSHOT",    CAVE_OBSERVER, "OnlinePvPMode.UpdateAuthoritativeSnapshot"),
    (0x5A1198C, "ff0302d1", "KIOU_BR_HOOK_ONLINE_HANDLE_RESULT",      CAVE_OBSERVER, "OnlinePvPMode.HandleMoveResult"),
    (0x59EFE9C, "e923bc6d", "KIOU_BR_HOOK_CPUSTREAM_UPDATE_SNAPSHOT", CAVE_OBSERVER, "CPUStreamMode.UpdateAuthoritativeSnapshot"),
    (0x59498E4, "ff4302d1", "KIOU_BR_HOOK_GAMEORCH_ACTIVATE",         CAVE_OBSERVER, "GameOrchestrator.ActivateAsync"),

    # GameStateStore hooks
    (0x5A31920, "f44fbea9", "KIOU_BR_HOOK_GSTATE_SET_BLACK_PLAYER_INFO", CAVE_OBSERVER, "GameStateStore.SetBlackPlayerInfo"),
    (0x5A3195C, "f44fbea9", "KIOU_BR_HOOK_GSTATE_SET_WHITE_PLAYER_INFO", CAVE_OBSERVER, "GameStateStore.SetWhitePlayerInfo"),
    (0x5A31AE0, "ff4301d1", "KIOU_BR_HOOK_GSTATE_NOTIFY_PIECE_MOVED",    CAVE_OBSERVER, "GameStateStore.NotifyPieceMoved"),

    # Account identity — CAVE_ENTRY
    (0x5922CD0, "fd7bbfa9", "KIOU_BR_HOOK_ACCOUNT_EXISTS",          CAVE_ENTRY, "UserSaveDataExtensions.AccountExists"),

    # Account switching — CAVE_ENTRY
    (0x5B9DC04, "f657bda9", "KIOU_BR_HOOK_LOGIN_ARGS_CREATE",         CAVE_ENTRY, "ILoginArgs.Create"),
    (0x5B9DC94, "f657bda9", "KIOU_BR_HOOK_REGISTER_USER_ARGS_CREATE", CAVE_ENTRY, "IRegisterUserArgs.Create"),

    # Matching filter — CAVE_ENTRY
    (0x5D0A78C, "ff0301d1", "KIOU_BR_HOOK_GET_VALID_MATCH_FOUND_STATUS", CAVE_ENTRY,    "GetValidMatchFoundStatus"),
    (0x5BCF8CC, "fc6fbaa9", "KIOU_BR_HOOK_MATCH_STREAM_ARGS_CREATE",     CAVE_ENTRY,    "IShogiMatchStreamArgs.Create"),
    (0x5D0C408, "ff0303d1", "KIOU_BR_HOOK_RECEIVE_TIMEOUT_MOVENEXT",     CAVE_OBSERVER, "MatchingHandler+<ReceiveWithTimeoutAsync>d__6.MoveNext"),

    # Async MoveNext — CAVE_ENTRY
    (0x58152BC, "ff8302d1", "KIOU_BR_HOOK_RUN_LOGIN_SEQ_MOVENEXT",    CAVE_ENTRY, "AuthServiceExtensions+<RunLoginSequenceAsync>d__1.MoveNext"),
    (0x5BB99DC, "ff4302d1", "KIOU_BR_HOOK_GET_SELF_PROFILE_MOVENEXT", CAVE_ENTRY, "GameService+<GetSelfUserProfileAsync>d__36.MoveNext"),

    # HttpMessageInvoker.SendAsync vtable thunk
    (0x6082AC0, "000840f9", "KIOU_BR_HOOK_HTTPMSGINVOKER_SEND_ASYNC", CAVE_ENTRY, "HttpMessageInvoker.SendAsync"),
]
# fmt: on
