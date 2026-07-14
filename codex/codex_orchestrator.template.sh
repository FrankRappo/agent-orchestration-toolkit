#!/bin/bash
# Queue orchestrator for Codex task files.
#
# Required env:
#   PROJECT_DIR
#
# Optional env:
#   TASKS="T-A T-B"       # if empty, all codex/tasks/*.md are discovered
#   CODEX_DIR=/work/<project>/codex
#   MAX_PARALLEL=1
#   SESSION_PREFIX=codex
#   RAM_MIN_KB=700000
#   RETRY_STATUSES="PARTIAL"  # statuses archived and retried by supervisor
#   MAX_RUNTIME_SECONDS=0     # recycle agent after N seconds, 0 disables

set -u
unset TMUX TMUX_PANE
export LC_ALL=C.utf8 LANG=C.utf8

PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
CODEX_DIR="${CODEX_DIR:-$PROJECT_DIR/codex}"
TASK_DIR="${TASK_DIR:-$CODEX_DIR/tasks}"
REPORT_DIR="${REPORT_DIR:-$CODEX_DIR/reports}"
LOG_DIR="${LOG_DIR:-$CODEX_DIR/logs}"
STATE_DIR="${STATE_DIR:-$CODEX_DIR/state}"
PROGRESS="${PROGRESS:-$STATE_DIR/progress.md}"
OLOG="${OLOG:-$LOG_DIR/codex_orchestrator.log}"
SUPERVISOR="${SUPERVISOR:-/work/settings/codex/codex_supervisor.template.sh}"
SESSION_PREFIX="${SESSION_PREFIX:-codex}"
MAX_PARALLEL="${MAX_PARALLEL:-1}"
RAM_MIN_KB="${RAM_MIN_KB:-700000}"
TASKS="${TASKS:-}"
STATUS_RE='^[[:space:]]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)[[:space:]]*$'

mkdir -p "$TASK_DIR" "$REPORT_DIR" "$LOG_DIR" "$STATE_DIR"
exec >> "$OLOG" 2>&1

log(){ echo "[$(date '+%F %T')] $*"; }

discover_tasks(){
  if [ -n "$TASKS" ]; then
    printf '%s\n' $TASKS
  else
    find "$TASK_DIR" -maxdepth 1 -type f -name 'T-*.md' -printf '%f\n' \
      | sed 's/\.md$//' \
      | sort
  fi
}

report_path(){ echo "$REPORT_DIR/report_$1.md"; }
task_file(){ echo "$TASK_DIR/$1.md"; }
session_name(){ echo "${SESSION_PREFIX}_$1_sup"; }

report_status(){
  local report="$1"
  grep -aE "$STATUS_RE" "$report" 2>/dev/null \
    | tail -1 \
    | sed -E 's/^[[:space:]]*STATUS:[[:space:]]*//; s/[[:space:]]*$//' \
    | tr '[:lower:]' '[:upper:]'
}

task_lock(){
  local file="$1"
  grep -aE '^[[:space:]]*Resource-Lock:[[:space:]]*' "$file" 2>/dev/null \
    | head -1 \
    | sed -E 's/^[[:space:]]*Resource-Lock:[[:space:]]*//; s/[[:space:]]*$//' \
    | tr '[:upper:]' '[:lower:]'
}

tmux_alive(){
  tmux has-session -t "=$1" 2>/dev/null
}

active_count(){
  local n=0 s
  for s in "$STATE_DIR"/*.session; do
    [ -f "$s" ] || continue
    sess=$(cat "$s" 2>/dev/null || true)
    [ -n "$sess" ] && tmux_alive "$sess" && n=$((n + 1))
  done
  echo "$n"
}

lock_active(){
  local lock="$1" lf task sess
  [ -z "$lock" ] || [ "$lock" = "none" ] && return 1
  for lf in "$STATE_DIR"/*.lock; do
    [ -f "$lf" ] || continue
    [ "$(cat "$lf" 2>/dev/null)" = "$lock" ] || continue
    task="$(basename "$lf" .lock)"
    sess="$(cat "$STATE_DIR/$task.session" 2>/dev/null || true)"
    [ -n "$sess" ] && tmux_alive "$sess" && return 0
  done
  return 1
}

ram_ok(){
  local avail
  avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  [ "${avail:-0}" -ge "$RAM_MIN_KB" ]
}

mark_progress(){
  local task="$1" status="$2"
  grep -q "^[-*] \\[[ xX]\\] $task\\b" "$PROGRESS" 2>/dev/null && return 0
  case "$status" in
    SUCCESS) echo "- [x] $task STATUS=$status $(date '+%F %T')" >> "$PROGRESS" ;;
    *) echo "- [ ] $task STATUS=$status $(date '+%F %T')" >> "$PROGRESS" ;;
  esac
}

start_task(){
  local task="$1" tf report sess lock
  tf="$(task_file "$task")"
  report="$(report_path "$task")"
  sess="$(session_name "$task")"
  lock="$(task_lock "$tf")"
  [ -z "$lock" ] && lock="none"

  echo "$lock" > "$STATE_DIR/$task.lock"
  echo "$sess" > "$STATE_DIR/$task.session"

  tmux kill-session -t "=$sess" 2>/dev/null || true
  log "starting $task session=$sess lock=$lock"
  tmux new-session -d -s "$sess" -c "$PROJECT_DIR" \
    "TASK='$task' PROJECT_DIR='$PROJECT_DIR' CODEX_DIR='$CODEX_DIR' TASK_FILE='$tf' REPORT='$report' CODEX_SANDBOX='${CODEX_SANDBOX:-workspace-write}' CODEX_MODEL='${CODEX_MODEL:-}' CODEX_EXTRA_ARGS='${CODEX_EXTRA_ARGS:-}' RETRY_STATUSES='${RETRY_STATUSES:-}' MAX_RESPAWN='${MAX_RESPAWN:-3}' STALL_LIMIT='${STALL_LIMIT:-1800}' POLL='${POLL:-30}' MAX_RUNTIME_SECONDS='${MAX_RUNTIME_SECONDS:-0}' MAX_RUNTIME_RESTARTS='${MAX_RUNTIME_RESTARTS:-24}' RUNTIME_RESTART_WAIT_SECONDS='${RUNTIME_RESTART_WAIT_SECONDS:-0}' RATE_LIMIT_WAIT_SECONDS='${RATE_LIMIT_WAIT_SECONDS:-18000}' RATE_LIMIT_MAX_WAITS='${RATE_LIMIT_MAX_WAITS:-24}' RATE_LIMIT_RE='${RATE_LIMIT_RE:-}' bash '$SUPERVISOR'"
}

all_done(){
  local task report st
  for task in $(discover_tasks); do
    report="$(report_path "$task")"
    st="$(report_status "$report")"
    [ -n "$st" ] || return 1
  done
  return 0
}

[ -f "$PROGRESS" ] || echo "# Codex queue progress $(date '+%F %T')" > "$PROGRESS"

log "orchestrator start project=$PROJECT_DIR tasks=$(discover_tasks | tr '\n' ' ') max_parallel=$MAX_PARALLEL"

while true; do
  # Record finished sessions.
  for sf in "$STATE_DIR"/*.session; do
    [ -f "$sf" ] || continue
    task="$(basename "$sf" .session)"
    sess="$(cat "$sf" 2>/dev/null || true)"
    [ -n "$sess" ] || continue
    if ! tmux_alive "$sess"; then
      report="$(report_path "$task")"
      st="$(report_status "$report")"
      if [ -n "$st" ]; then
        mark_progress "$task" "$st"
        rm -f "$sf" "$STATE_DIR/$task.lock"
        log "finished $task STATUS=$st"
      fi
    fi
  done

  all_done && { log "ALL DONE"; exit 0; }

  if ram_ok; then
    for task in $(discover_tasks); do
      [ "$(active_count)" -lt "$MAX_PARALLEL" ] || break
      tf="$(task_file "$task")"
      report="$(report_path "$task")"
      [ -f "$tf" ] || continue
      [ -n "$(report_status "$report")" ] && continue
      sess="$(session_name "$task")"
      tmux_alive "$sess" && continue
      lock="$(task_lock "$tf")"; [ -z "$lock" ] && lock="none"
      if lock_active "$lock"; then
        log "waiting lock=$lock for $task"
        continue
      fi
      start_task "$task"
    done
  else
    log "RAM gate: MemAvailable below ${RAM_MIN_KB}KB; not starting new tasks"
  fi

  sleep 20
done
