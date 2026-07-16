#!/bin/bash
# Queue orchestrator for interactive Claude REPL task agents. Mirror of codex_orchestrator.
# Runs task files one-by-one (MAX_PARALLEL, default 1 for RAM) each under claude_supervisor,
# which launches an interactive `claude` REPL in tmux. Run AS the claude user.
#
# Dynamic queue: does NOT exit when the current tasks finish — it idles and keeps picking up
# NEW task files dropped into tasks/. Kill the orchestrator tmux session to stop.
#
# Required env: PROJECT_DIR
# Optional env: TASKS TASK_DIR REPORT_DIR LOG_DIR STATE_DIR PROGRESS OLOG SUPERVISOR
#   SESSION_PREFIX MAX_PARALLEL RAM_MIN_KB RETRY_STATUSES MAX_RESPAWN STALL_LIMIT
#   POLL RATE_LIMIT_WAIT_SECONDS IDLE_EXIT
set -u
unset TMUX TMUX_PANE
export LC_ALL=C.utf8 LANG=C.utf8

PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
TASK_DIR="${TASK_DIR:-$PROJECT_DIR/tasks}"
REPORT_DIR="${REPORT_DIR:-$PROJECT_DIR/reports}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state}"
PROGRESS="${PROGRESS:-$PROJECT_DIR/orch/progress.md}"
OLOG="${OLOG:-$LOG_DIR/claude_orchestrator.log}"
SUPERVISOR="${SUPERVISOR:-/work/settings/claude/claude_supervisor.template.sh}"
SESSION_PREFIX="${SESSION_PREFIX:-claude}"
MAX_PARALLEL="${MAX_PARALLEL:-1}"
RAM_MIN_KB="${RAM_MIN_KB:-900000}"
IDLE_EXIT="${IDLE_EXIT:-0}"
# Мин. интервал между стартами ОДНОГО таска: не перезапускать раньше, чем launcher успеет поднять
# REPL — иначе новый launcher своим `tmux kill-session` добьёт REPL ещё не вставшего предыдущего
# запуска → бесконечный churn (кейс T02 2026-07-16). Ставь > (STARTUP_WAIT launcher'а + PID-wait супервизора).
START_GRACE="${START_GRACE:-90}"
TASKS="${TASKS:-}"
STATUS_RE='^[[:space:]]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)[[:space:]]*$'

mkdir -p "$TASK_DIR" "$REPORT_DIR" "$LOG_DIR" "$STATE_DIR" "$(dirname "$PROGRESS")"
exec >> "$OLOG" 2>&1
log(){ echo "[$(date '+%F %T')] $*"; }

discover_tasks(){ if [ -n "$TASKS" ]; then printf '%s\n' $TASKS; else
  find "$TASK_DIR" -maxdepth 1 -type f -name 'T*.md' -printf '%f\n' | sed 's/\.md$//' | sort; fi; }
report_path(){ echo "$REPORT_DIR/report_$1.md"; }
task_file(){ echo "$TASK_DIR/$1.md"; }
session_name(){ echo "${SESSION_PREFIX}_$1_sup"; }
report_status(){ grep -aE "$STATUS_RE" "$1" 2>/dev/null | tail -1 \
  | sed -E 's/^[[:space:]]*STATUS:[[:space:]]*//; s/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]'; }
task_lock(){ grep -aE '^[[:space:]]*Resource-Lock:[[:space:]]*' "$1" 2>/dev/null | head -1 \
  | sed -E 's/^[[:space:]]*Resource-Lock:[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]'; }
tmux_alive(){ tmux has-session -t "=$1" 2>/dev/null; }
active_count(){ local n=0 s sess; for s in "$STATE_DIR"/*.session; do [ -f "$s" ]||continue
  sess=$(cat "$s" 2>/dev/null); [ -n "$sess" ] && tmux_alive "$sess" && n=$((n+1)); done; echo "$n"; }
lock_active(){ local lock="$1" lf task sess; { [ -z "$lock" ]||[ "$lock" = none ]; } && return 1
  for lf in "$STATE_DIR"/*.lock; do [ -f "$lf" ]||continue; [ "$(cat "$lf" 2>/dev/null)" = "$lock" ]||continue
    task="$(basename "$lf" .lock)"; sess="$(cat "$STATE_DIR/$task.session" 2>/dev/null)"
    [ -n "$sess" ] && tmux_alive "$sess" && return 0; done; return 1; }
ram_ok(){ local a; a=$(awk '/MemAvailable/{print $2}' /proc/meminfo); [ "${a:-0}" -ge "$RAM_MIN_KB" ]; }
mark_progress(){ local t="$1" s="$2"; grep -qa "\\b$t\\b.*STATUS=" "$PROGRESS" 2>/dev/null && return 0
  case "$s" in SUCCESS) echo "- [x] $t STATUS=$s $(date '+%F %T')" >>"$PROGRESS";;
               *) echo "- [~] $t STATUS=$s $(date '+%F %T')" >>"$PROGRESS";; esac; }

start_task(){
  local task="$1" tf report sess lock
  sess="$(session_name "$task")"
  # идемпотентность: НИКОГДА не пересоздаём (и не kill-session) живую сессию супервизора.
  if tmux_alive "$sess"; then log "start_task: $sess уже жив — пропуск"; return 0; fi
  tf="$(task_file "$task")"; report="$(report_path "$task")"
  lock="$(task_lock "$tf")"; [ -z "$lock" ] && lock=none
  echo "$lock" > "$STATE_DIR/$task.lock"; echo "$sess" > "$STATE_DIR/$task.session"
  date +%s > "$STATE_DIR/$task.started"
  tmux kill-session -t "=$sess" 2>/dev/null
  log "starting $task session=$sess lock=$lock"
  tmux new-session -d -s "$sess" -c "$PROJECT_DIR" \
    "TASK='$task' PROJECT_DIR='$PROJECT_DIR' TASK_FILE='$tf' REPORT='$report' LOG_DIR='$LOG_DIR' STATE_DIR='$STATE_DIR' PANE_SESSION='claude_${task}_repl' RETRY_STATUSES='${RETRY_STATUSES:-}' MAX_RESPAWN='${MAX_RESPAWN:-4}' STALL_LIMIT='${STALL_LIMIT:-600}' POLL='${POLL:-30}' RATE_LIMIT_WAIT_SECONDS='${RATE_LIMIT_WAIT_SECONDS:-1500}' NOTIFY_CMD='${NOTIFY_CMD:-}' bash '$SUPERVISOR'"
}

all_done(){ local t st; for t in $(discover_tasks); do st="$(report_status "$(report_path "$t")")"; [ -n "$st" ]||return 1; done; return 0; }

[ -f "$PROGRESS" ] || echo "# Claude REPL queue progress $(date '+%F %T')" > "$PROGRESS"
log "orchestrator start project=$PROJECT_DIR max_parallel=$MAX_PARALLEL idle_exit=$IDLE_EXIT"

while true; do
  # record finished sessions
  for sf in "$STATE_DIR"/*.session; do
    [ -f "$sf" ] || continue
    task="$(basename "$sf" .session)"; sess="$(cat "$sf" 2>/dev/null)"; [ -n "$sess" ] || continue
    if ! tmux_alive "$sess"; then
      st="$(report_status "$(report_path "$task")")"
      if [ -n "$st" ]; then mark_progress "$task" "$st"; rm -f "$sf" "$STATE_DIR/$task.lock" "$STATE_DIR/$task.started"; log "finished $task STATUS=$st"; fi
    fi
  done

  if all_done; then
    if [ "$IDLE_EXIT" = "1" ]; then log "ALL DONE (idle_exit=1)"; touch "$REPORT_DIR/ALL_DONE"; exit 0; fi
    log "queue drained — idle, watching tasks/ for new files"
    sleep 30; continue
  fi

  if ram_ok; then
    for task in $(discover_tasks); do
      [ "$(active_count)" -lt "$MAX_PARALLEL" ] || break
      tf="$(task_file "$task")"; [ -f "$tf" ] || continue
      [ -n "$(report_status "$(report_path "$task")")" ] && continue
      sess="$(session_name "$task")"; tmux_alive "$sess" && continue
      # start-grace: если таск стартовали недавно — не перезапускаем, даём launcher'у поднять REPL
      # (иначе новый kill-session добьёт REPL предыдущего запуска → churn).
      started_at="$(cat "$STATE_DIR/$task.started" 2>/dev/null || echo 0)"; nows="$(date +%s)"
      [ $(( nows - started_at )) -lt "$START_GRACE" ] && { log "grace: $task стартовал $(( nows - started_at ))s назад (<${START_GRACE}s) — жду, не перезапускаю"; continue; }
      lock="$(task_lock "$tf")"; [ -z "$lock" ] && lock=none
      lock_active "$lock" && { log "waiting lock=$lock for $task"; continue; }
      start_task "$task"
    done
  else
    log "RAM gate: MemAvailable < ${RAM_MIN_KB}KB; holding new starts"
  fi
  sleep 20
done
