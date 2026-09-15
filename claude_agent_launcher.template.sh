#!/bin/bash
# Launch ONE interactive Claude REPL agent inside a tmux session.
# Run AS the claude user — the supervisor drops privileges before calling this.
#
# Unlike `claude -p` (one-shot headless), this keeps an interactive `claude` REPL alive
# in tmux: it persists, can be inspected/continued, and survives a single API hiccup.
# The agent reads the task, works to completion, and writes the report whose FINAL line
# is exactly one of:  STATUS: SUCCESS | FAIL | BLOCKED | PARTIAL .
#
# ROBUST START (fix 2026-07-23): the OLD launcher did a fixed `sleep 12` then pasted the
# prompt and hit Enter BLINDLY — if the REPL was not ready yet (load / cold start / RAM
# pressure) the paste+Enter were lost, the agent sat idle, jsonl never appeared, and the
# ONLY safety net was the supervisor's NO_JSONL_LIMIT (== STALL_LIMIT, often 40 min) which
# for no-respawn live tasks means FATAL + quarantine, not a retry. Root cause of PROJECTA T49
# hanging twice. Now the launcher: (1) polls the pane until the REPL input is actually
# rendered (dismissing the trust prompt if shown), (2) records the PID EARLY so the
# supervisor never thinks the launch failed, (3) submits the prompt and VERIFIES the agent
# started by watching for fresh jsonl — the same signal the supervisor uses — RE-SUBMITTING
# up to SUBMIT_TRIES times. Re-submitting into the same REPL is safe: no jsonl means the
# agent has done nothing yet. A lost paste is now a self-healing <1 min retry, not a 40 min
# silent death.
#
# Required env: PROJECT_DIR TASK TASK_FILE PID_FILE PANE_SESSION
# Optional env: PROMPT_FILE CLAUDE_BIN CLAUDE_EXTRA_ARGS JSONL_DIR
#   READY_MIN READY_MAX SUBMIT_TRIES SUBMIT_VERIFY STARTUP_WAIT(legacy alias for READY_MAX)
set -u

PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
TASK="${TASK:?need TASK}"
TASK_FILE="${TASK_FILE:?need TASK_FILE}"
PID_FILE="${PID_FILE:?need PID_FILE}"
PANE_SESSION="${PANE_SESSION:?need PANE_SESSION}"
PROMPT_FILE="${PROMPT_FILE:-/tmp/${TASK}_prompt.txt}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_EXTRA_ARGS="${CLAUDE_EXTRA_ARGS:-}"
# jsonl session dir of the running user for this project (Claude maps EVERY non-alnum char,
# incl. '/' and '_', to '-'). Same derivation as the supervisor — used to confirm the agent
# actually started processing the prompt. May be passed in by the supervisor.
JSONL_DIR="${JSONL_DIR:-$HOME/.claude/projects/$(echo "$PROJECT_DIR" | sed 's#[^a-zA-Z0-9]#-#g')}"
READY_MIN="${READY_MIN:-3}"                       # settle before polling the pane
READY_MAX="${READY_MAX:-${STARTUP_WAIT:-30}}"     # max seconds to wait for REPL readiness (cap)
SUBMIT_TRIES="${SUBMIT_TRIES:-4}"                 # prompt (re)submit attempts
SUBMIT_VERIFY="${SUBMIT_VERIFY:-14}"              # seconds to watch for jsonl per attempt
TRUST_RE='trust the files|Quick safety|Do you trust|Yes, proceed|proceed\?'
# Positive "input box is up" markers for the real claude TUI — fast-path readiness so a
# healthy REPL is detected in a couple seconds instead of waiting out READY_MAX.
READY_RE="${READY_RE:-Bypassing Permissions|for shortcuts|esc to interrupt|Welcome to Claude|╭─|│ >|> Try }"

log(){ echo "[$(date '+%F %T')] $*"; }
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

# Record agent PID EARLY (pane pid = claude via exec). The supervisor waits for this file
# to decide the launch didn't fail; write it before the (slower) readiness+submit phase so
# the supervisor never times out mid-bring-up.
tmux list-panes -t "=$PANE_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1 > "$PID_FILE"
log "launched claude REPL task=$TASK session=$PANE_SESSION pid=$(cat "$PID_FILE" 2>/dev/null) — bringing up"

# (1) Wait for the REPL to actually render its input box, instead of a blind fixed sleep.
# Accept the trust / "Quick safety check" prompt if it appears (Enter = default Yes; §9
# HOW_TO_RUN). Readiness = a non-empty pane that stops changing for 2 consecutive polls
# (version-agnostic; the submit-verify loop below is the real guarantee either way).
sleep "$READY_MIN"
ready=0; last=""; stable=0; end=$(( $(date +%s) + READY_MAX ))
while [ "$(date +%s)" -lt "$end" ]; do
  pane="$(tmux capture-pane -p -t "=$PANE_SESSION" 2>/dev/null)"
  if printf '%s' "$pane" | grep -qiE "$TRUST_RE"; then
    tmux send-keys -t "$PANE_SESSION" Enter 2>/dev/null
    log "accepted trust/safety prompt"; sleep 2; last=""; stable=0; continue
  fi
  if printf '%s' "$pane" | grep -qE "$READY_RE"; then ready=1; break; fi   # fast positive marker
  if [ -n "$(printf '%s' "$pane" | tr -d '[:space:]')" ] && [ "$pane" = "$last" ]; then
    stable=$((stable+1)); [ "$stable" -ge 2 ] && { ready=1; break; }
  else
    stable=0
  fi
  last="$pane"; sleep 1
done
[ "$ready" -eq 1 ] && log "REPL ready (input stabilized)" || log "readiness timeout ${READY_MAX}s — submitting anyway"

# (2) Submit the task prompt via paste-buffer (handles multi-line / cyrillic) and VERIFY the
# agent started (fresh jsonl). Re-submit if not — a lost paste self-heals here.
submit_prompt(){
  tmux load-buffer -b "pb_$TASK" "$PROMPT_FILE" 2>/dev/null
  tmux paste-buffer -b "pb_$TASK" -t "$PANE_SESSION" 2>/dev/null
  sleep 1
  tmux send-keys -t "$PANE_SESSION" Enter 2>/dev/null
}
VERIFY_SINCE=$(date +%s)
jsonl_live(){ find "$JSONL_DIR" -maxdepth 1 -name '*.jsonl' -newermt "@$((VERIFY_SINCE-2))" 2>/dev/null | grep -q .; }

ok=0
for attempt in $(seq 1 "$SUBMIT_TRIES"); do
  if [ "$attempt" -eq 1 ]; then
    submit_prompt
  else
    # Maybe the text is already in the box but was never submitted — try a bare Enter first.
    tmux send-keys -t "$PANE_SESSION" Enter 2>/dev/null; sleep 3
    jsonl_live && { ok=1; break; }
    submit_prompt                       # otherwise re-paste fresh + Enter
  fi
  for _ in $(seq 1 "$SUBMIT_VERIFY"); do sleep 1; jsonl_live && { ok=1; break; }; done
  [ "$ok" -eq 1 ] && break
  log "submit attempt $attempt/$SUBMIT_TRIES: agent not started (no jsonl) — retrying"
done

# Refresh PID in case the pane pid changed during bring-up, then report.
tmux list-panes -t "=$PANE_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1 > "$PID_FILE"
if [ "$ok" -eq 1 ]; then
  log "prompt accepted — agent working (jsonl live) task=$TASK pid=$(cat "$PID_FILE" 2>/dev/null)"
else
  log "WARN task=$TASK: agent did NOT start after $SUBMIT_TRIES submits (no jsonl) — supervisor will decide"
fi
