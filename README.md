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
