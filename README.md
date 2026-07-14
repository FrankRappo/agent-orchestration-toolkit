# Agent Orchestration Toolkit — Claude branch

Portable Bash templates for RL-aware, three-level agent orchestration:

1. **Supervisor** keeps an orchestrator or task agent alive, detects process and
   JSONL stalls, and waits through a five-hour usage-window reset without
   consuming ordinary retries.
2. **Orchestrator / queue** selects the next task, enforces RAM and singleton
   resource gates, and starts one isolated task at a time through a runner.
3. **Runner / launcher** owns the process group, retry loop, logs, and terminal
   report contract for one agent task.

The `codex` branch contains the equivalent Codex-oriented templates.

## Reliability model

- **Idempotency:** a `STATUS: SUCCESS|FAIL|BLOCKED|PARTIAL` report or a dedicated
  sentinel determines whether work is complete; file existence alone is not
  treated as success.
- **RL-aware recovery:** usage/session-limit messages enter a bounded wait loop
  and do not consume normal crash retries.
- **Stable handoff:** sequential queue templates wait for exact tmux sessions,
  detached process tails, and RAM recovery before starting the next wave.
- **Scoped termination:** watchdogs and deadline stoppers target exact sessions,
  process groups, and project-tagged PID files rather than broad `pkill` rules.
- **Resource protection:** `ram_guard.template.sh` pauses only project-owned
  agent groups and resumes them with hysteresis.

## Templates

| File | Purpose |
| --- | --- |
| `tasks_runner.template.sh` | Idempotent single-task runner with retries and sentinels. |
| `orchestrator_watchdog.template.sh` | Persistent orchestrator health and recovery loop. |
| `single_agent_supervisor.template.sh` | Active supervisor for one long-running agent. |
| `single_agent_watchdog.template.sh` | Read-only alerting watchdog for one agent. |
| `wave_supervisor.template.sh` | Environment-driven supervisor for queued waves. |
| `wave_launcher.template.sh` | Safe stdin-based `claude -p` launcher. |
| `queue_next_orchestrator.template.sh` | Start a second orchestrator after the first becomes quiet. |
| `queue_wave_after_orchestrator.template.sh` | Run a task wave after an upstream orchestrator. |
| `queue_wave_then_resume_orchestrator.template.sh` | Run a wave, then resume an upstream orchestrator. |
| `ram_guard.template.sh` | Project-scoped OOM protection. |
| `deadline_stopper.template.sh` | Hard deadline with sentinel-first shutdown. |

## Use

1. Copy the required `*.template.sh` files into a project-owned directory.
2. Replace angle-bracket placeholders and review the settings block at the top
   of each file.
3. Set the Unix agent user and paths through the documented environment
   variables. Telegram notification IDs default to `000000000`; override
   `CHAT_ID` only in the runtime environment.
4. Run `bash -n` on each configured script before launch.
5. Use exact, project-prefixed tmux session names and PID tags.

These templates can start autonomous tools with broad permissions. Review every
copied task, sandbox setting, notification command, and shutdown scope before
running it on a shared or production host.

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
