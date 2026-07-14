#!/bin/bash
# Launch one Codex exec task.
#
# Required env:
#   PROJECT_DIR TASK_FILE PID_FILE LOG LAST_MESSAGE
#
# Optional env:
#   CODEX_SANDBOX=workspace-write
#   CODEX_MODEL=
#   CODEX_EXTRA_ARGS=

set -u

PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
TASK_FILE="${TASK_FILE:?need TASK_FILE}"
PID_FILE="${PID_FILE:?need PID_FILE}"
LOG="${LOG:?need LOG}"
LAST_MESSAGE="${LAST_MESSAGE:?need LAST_MESSAGE}"

CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_EXTRA_ARGS="${CODEX_EXTRA_ARGS:-}"

cd "$PROJECT_DIR" || exit 2
echo $$ > "$PID_FILE"

MODEL_ARGS=()
if [ -n "$CODEX_MODEL" ]; then
  MODEL_ARGS=(-m "$CODEX_MODEL")
fi

ACCESS_ARGS=()
if [ "$CODEX_SANDBOX" = "danger-full-access" ]; then
  # codex exec has no --ask-for-approval flag. This is the non-interactive
  # full-access mode for externally supervised autonomous agents.
  ACCESS_ARGS=(--dangerously-bypass-approvals-and-sandbox)
else
  ACCESS_ARGS=(--sandbox "$CODEX_SANDBOX")
fi

# Keep the standard preamble outside the task file so old tasks can be reused.
{
  cat <<'PREAMBLE'
You are a Codex autonomous task agent.

Work in the project root passed through --cd. Read the task fully before
acting. Continue until the task is complete, genuinely blocked, or safely
partial. Before exiting, write the requested report file. The final line of the
report must be exactly one of:

STATUS: SUCCESS
STATUS: FAIL
STATUS: BLOCKED
STATUS: PARTIAL

Do not claim success unless verification evidence was collected. Do not use
destructive git commands. Do not touch unrelated worktree changes.

PREAMBLE
  cat "$TASK_FILE"
} | exec codex exec \
  --cd "$PROJECT_DIR" \
  "${ACCESS_ARGS[@]}" \
  --output-last-message "$LAST_MESSAGE" \
  --json \
  "${MODEL_ARGS[@]}" \
  $CODEX_EXTRA_ARGS \
  - > "$LOG" 2>&1
