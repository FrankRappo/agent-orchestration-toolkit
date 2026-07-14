# T-EXAMPLE - short task title

Resource-Lock: none
Report: codex/reports/report_T-EXAMPLE.md

## Goal

State the concrete outcome. The agent must work until this outcome is complete,
blocked by a real external condition, or safely reported as partial.

For tasks where partial completion is not acceptable, launch the orchestrator
with:

```bash
RETRY_STATUSES=PARTIAL
```

Then a report ending in `STATUS: PARTIAL` is archived as an attempt and the
supervisor relaunches the task until success, a non-retryable terminal status,
or the respawn limit.

## Scope

- Project root: `/work/<project>`
- Allowed write area: describe exact files/directories.
- Do not touch unrelated files.

## Context

List the files the agent must read first.

- `README.md`
- `workflow.md`

## Steps

1. Inspect the current state.
2. Make the smallest safe change.
3. Verify with the relevant command or UI check.
4. Write the report listed above.

## Verification

List objective checks. Examples:

- `git diff --check`
- project-specific tests
- project-specific UI smoke tests for browser or desktop tasks

For GUI tasks:

- Screenshot before risky actions.
- Verify after every click/edit.
- If a click misses, recalculate with `find`/`map`/`bbox`/`cclick`/`mclick`
  and click again instead of continuing from the wrong UI state.
- If the VNC/CDP tool itself is wrong, back it up before editing and document
  the tool fix.

## Red lines

- Do not run destructive git commands.
- Do not touch production unless this task explicitly says so.
- Do not change credentials, keys, or payment/delivery settings without an
  explicit task instruction.
- Do not leave interactive sessions open or persistent test data behind unless
  the task explicitly requires it.

## Report format

Write `codex/reports/report_T-EXAMPLE.md` with:

```markdown
# T-EXAMPLE Report

## Outcome

## Evidence

## Changed files

## Risks / follow-up

STATUS: SUCCESS
```

The final line must be exactly one of:

```text
STATUS: SUCCESS
STATUS: FAIL
STATUS: BLOCKED
STATUS: PARTIAL
```
