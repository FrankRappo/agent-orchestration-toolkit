# Agent Orchestration Toolkit — Codex branch

Portable Bash templates for RL-aware, three-level Codex orchestration:

1. **Supervisor** keeps one `codex exec` task alive, detects quiet/stalled
   processes, archives retryable terminal reports, and waits through long
   usage-window resets without consuming normal retries.
2. **Orchestrator** discovers tasks, honors per-task resource locks and a RAM
   gate, and starts bounded work through isolated tmux supervisor sessions.
3. **Agent launcher** supplies a stable task/report preamble, selects the sandbox
   mode, captures structured output, and owns the agent PID.

The `claude` branch contains the Claude-oriented supervisor, runner, watchdog,
and sequential handoff templates.

## Reliability model

- Reports end with exactly one terminal status: `SUCCESS`, `FAIL`, `BLOCKED`, or
  `PARTIAL`; completion is based on report content rather than file existence.
- Rate/session-limit output enters a bounded wait-and-relaunch loop without
  spending ordinary respawn attempts.
- Optional maximum runtime recycling handles agents that remain active but do
  not converge.
- The orchestrator defaults to one task at a time, supports explicit resource
  locks, and gates launches on available memory.
- Sequential stages persist JSON state and retry without silently skipping a
  failed stage.

## Templates

| File | Purpose |
| --- | --- |
| `codex/codex_agent_launcher.template.sh` | Launch one non-interactive Codex task. |
| `codex/codex_supervisor.template.sh` | Supervise, retry, and classify one task. |
| `codex/codex_orchestrator.template.sh` | Discover and schedule a task queue. |
| `codex/codex_sequential_queue.template.sh` | Run ordered, rate-limit-resilient stages. |
| `codex/task.template.md` | Generic task and report contract. |
| `codex/omx_autopilot_launcher.template.sh` | Start one detached OMX/Codex autonomous run with durable metadata. |
| `codex/omx_autopilot_status.template.sh` | Inspect the newest run metadata, process, log, and final message. |
| `codex/OMX_AUTONOMOUS_ORCHESTRATOR.md` | Runbook for launching, observing, resuming, and stopping detached runs. |
| `codex/AGENTS.autonomous.md` | Reusable autonomous-agent policy snapshot. |
| `codex/hooks.autonomous.json` | Reusable hook configuration snapshot. |
| `codex/autopilot.prompt.template.md` | Project-neutral prompt contract for an autonomous run. |
| `codex/omx_autonomous.config.template.toml` | Minimal project-scoped Codex/OMX configuration example. |
| `codex/omx_autonomous.sha256` | Integrity manifest for the autonomous profile. |

## Use

1. Copy `codex/` into a project-owned toolkit directory.
2. Replace angle-bracket placeholders and review sandbox, task, report, state,
   RAM, retry, and runtime settings.
3. Keep `MAX_PARALLEL=1` until tasks have explicit, non-overlapping resource
   locks and write scopes.
4. Run `bash -n codex/*.template.sh` before launch.
5. Start the orchestrator only after task files define objective verification
   and an exact report path.

The launcher can select a full-access Codex mode. Use that mode only when the
reviewed task genuinely needs it; prefer the narrowest working sandbox.

## Detached OMX autopilot

The autonomous profile keeps the reusable policy separate from project state.
Copy the profile files into a controlled settings directory, customize the
prompt and TOML copies, then launch from the target project:

```bash
PROJECT_DIR=/path/to/project \
PROMPT_FILE=/path/to/project/.omx/prompts/autopilot.md \
OMX_SETTINGS_DIR=/path/to/settings/codex \
  /path/to/settings/codex/omx_autopilot_launcher.template.sh
```

The safe default is `workspace-write`. Full access is an explicit opt-in with
`OMX_FULL_ACCESS=1` and should be used only in a reviewed, isolated workspace.
The launcher uses `nohup` plus `setsid`, records PID/log/metadata files beneath
the project `.omx/` directory, and unsets an inherited `OMX_SESSION_ID` so a
detached run receives its own session identity.

Inspect the newest recorded run without attaching to it:

```bash
/path/to/settings/codex/omx_autopilot_status.template.sh /path/to/project
```

Validate the copied profile before use:

```bash
(cd /path/to/settings/codex && sha256sum -c omx_autonomous.sha256)
bash -n /path/to/settings/codex/omx_autopilot_launcher.template.sh
bash -n /path/to/settings/codex/omx_autopilot_status.template.sh
```

Project-specific names, credentials, prompts, run IDs, and generated state must
remain outside this public toolkit.

## Safe updates

This branch uses a whitelist `.gitignore`. From the clean publication checkout:

```bash
./push_public.sh "Describe the safe template update"
```

The helper requires a local, gitignored `.forbidden-patterns` file with one
case-insensitive literal per line. It fails closed if that policy is missing,
stages only allowed paths, reports only affected filenames, scans generic
credential/host shapes, checks the staged diff, commits, and pushes the current
branch.

## License

MIT
