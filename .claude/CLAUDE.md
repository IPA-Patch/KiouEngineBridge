# WarsEngineBridge — Claude Code Project Instructions

## Agent Teams

This project uses a multi-agent setup under `.claude/agents/`.
**For any Tweak development task, always route through the `leader` agent first.**
Do not handle tweak-related work directly in the main session.

### When to invoke `leader`

Invoke the `leader` agent whenever the task involves any of the following:

- Adding or modifying ObjC hooks in `Sources/WarsEngineBridge/`
- Editing the CSA state machine (`Csa_Engine.m`), TCP transport (`Server_CSA.m`), or move/resign injection
- Chinlan static patch changes (`Sources/Chinlan/`) or IPA assembly (`make chinlan` / `make ipa`)
- Looking up RVAs or class/method definitions in `assets/dump.cs`
- Running any `make` build and interpreting the output
- Monitoring device logs (port 18082) or CSA traffic (port 4081)

### Agent roster

| Agent | Role |
|-------|------|
| `leader` | Orchestrator — decomposes the task and delegates to specialists |
| `tweak-dev` | ObjC hook implementation (`Sources/WarsEngineBridge/`) |
| `patch-dev` | Chinlan static patch + IPA assembly (`Sources/Chinlan/`, `recipes/`) |
| `app-analyzer` | il2cpp analysis — symbol and RVA lookup from `assets/dump.cs` |
| `log-monitor` | Live monitoring of port 18082 (IPALog) and port 4081 (CSA) with auto-reconnect |

### Tasks the main session handles directly

- Repository-level questions (git log, branch status, CHANGELOG)
- Python test suite (`uv run pytest`)
- Documentation edits (README, docs/)
- Non-Tweak scripting under `scripts/` or `shared/`

## Environment

- `THEOS_DEVICE_IP` is set in `.env` — never hard-code the IP
- Default CSA port: 4081
- Default log port: 18082
- Target app: ShogiWars (jp.co.heroz.ShogiWars), arm64, iOS 15–26
