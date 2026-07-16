#!/bin/bash
# Launch ONE interactive Claude REPL agent inside a tmux session.
# Run AS the claude user — the supervisor drops privileges before calling this.
#
# Unlike `claude -p` (one-shot headless), this keeps an interactive `claude` REPL alive
# in tmux: it persists, can be inspected/continued, and survives a single API hiccup.
# The agent reads the task, works to completion, and writes the report whose FINAL line
# is exactly one of:  STATUS: SUCCESS | FAIL | BLOCKED | PARTIAL .
#
# Required env: PROJECT_DIR TASK TASK_FILE PID_FILE PANE_SESSION
# Optional env: PROMPT_FILE CLAUDE_BIN CLAUDE_EXTRA_ARGS STARTUP_WAIT
set -u

PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
TASK="${TASK:?need TASK}"
TASK_FILE="${TASK_FILE:?need TASK_FILE}"
PID_FILE="${PID_FILE:?need PID_FILE}"
PANE_SESSION="${PANE_SESSION:?need PANE_SESSION}"
PROMPT_FILE="${PROMPT_FILE:-/tmp/${TASK}_prompt.txt}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_EXTRA_ARGS="${CLAUDE_EXTRA_ARGS:-}"
STARTUP_WAIT="${STARTUP_WAIT:-12}"

mkdir -p "$(dirname "$PID_FILE")" "$(dirname "$PROMPT_FILE")"

# Full prompt = standard preamble (kept OUT of the task file so old tasks stay reusable) + task.
{
  cat <<'PRE'
You are an autonomous Claude task agent running in an interactive REPL.
Read the WHOLE task before acting. Work until the task is complete, genuinely
blocked, or safely partial. Do NOT yield the turn to "wait" — drive long
operations to completion in this session (detach + blocking poll in the same turn).
Before finishing, WRITE the report file the task asks for. Its FINAL line must be
EXACTLY one of:

STATUS: SUCCESS
STATUS: FAIL
STATUS: BLOCKED
STATUS: PARTIAL

Do not claim SUCCESS without verification evidence. Do not run destructive git
commands. Do not touch unrelated worktree changes. Backup before edit/deploy.

--- TASK BELOW ---
PRE
  cat "$TASK_FILE"
} > "$PROMPT_FILE"

# Fresh REPL session. Pane command is `exec claude ...` so the pane PID IS claude.
tmux kill-session -t "=$PANE_SESSION" 2>/dev/null
tmux new-session -d -s "$PANE_SESSION" -x 220 -y 50 -c "$PROJECT_DIR" \
  "exec $CLAUDE_BIN --dangerously-skip-permissions $CLAUDE_EXTRA_ARGS"

# Startup + trust-folder prompt. Enter accepts the default "Yes" of the
# "Quick safety check" trust prompt if shown; harmless no-op otherwise (§9 HOW_TO_RUN).
sleep "$STARTUP_WAIT"
tmux send-keys -t "$PANE_SESSION" Enter
sleep 2

# Feed the task prompt via paste-buffer (handles multi-line / cyrillic), then submit.
tmux load-buffer -b "pb_$TASK" "$PROMPT_FILE"
tmux paste-buffer -b "pb_$TASK" -t "$PANE_SESSION"
sleep 1
tmux send-keys -t "$PANE_SESSION" Enter

# Record agent PID (pane pid = claude via exec).
tmux list-panes -t "=$PANE_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1 > "$PID_FILE"
echo "launched claude REPL task=$TASK session=$PANE_SESSION pid=$(cat "$PID_FILE" 2>/dev/null)"
