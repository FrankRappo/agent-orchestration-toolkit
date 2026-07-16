#!/bin/bash
# Supervise ONE interactive Claude REPL agent (launched via claude_agent_launcher).
# Mirror of codex_supervisor, adapted for Claude:
#   - agent is an interactive `claude` REPL in tmux (NOT `claude -p`);
#   - stall is detected by JSONL session growth (Claude-native), not stdout-log age;
#   - rate/session-limit is detected by capturing the REPL pane.
# Finish = report whose final line is STATUS: SUCCESS|FAIL|BLOCKED|PARTIAL.
# Run AS the claude user so tmux/jsonl/auth belong to that user.
#
# Required env: TASK PROJECT_DIR TASK_FILE REPORT
# Optional env: LOG_DIR STATE_DIR LAUNCHER PANE_SESSION JSONL_DIR PID_FILE
#   MAX_RESPAWN STALL_LIMIT NO_JSONL_LIMIT POLL RETRY_STATUSES
#   RATE_LIMIT_WAIT_SECONDS RATE_LIMIT_MAX_WAITS RATE_LIMIT_RE CHAT_ID
set -u
unset TMUX TMUX_PANE
export LC_ALL=C.utf8 LANG=C.utf8

TASK="${TASK:?need TASK}"
PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
TASK_FILE="${TASK_FILE:?need TASK_FILE}"
REPORT="${REPORT:?need REPORT}"

LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state}"
LAUNCHER="${LAUNCHER:-/work/settings/claude/claude_agent_launcher.template.sh}"
PANE_SESSION="${PANE_SESSION:-claude_${TASK}_repl}"
PID_FILE="${PID_FILE:-$STATE_DIR/${TASK}.pid}"
PROMPT_FILE="${PROMPT_FILE:-$STATE_DIR/${TASK}_prompt.txt}"
SUPLOG="${SUPLOG:-$LOG_DIR/${TASK}_supervisor.log}"
# claude-sessions dir of the running user for this project path.
# Claude replaces EVERY non-alphanumeric char (incl. '/' AND '_') with '-'  →  /work/vnc_rnd = -work-vnc-rnd.
JSONL_DIR="${JSONL_DIR:-$HOME/.claude/projects/$(echo "$PROJECT_DIR" | sed 's#[^a-zA-Z0-9]#-#g')}"
MAX_RESPAWN="${MAX_RESPAWN:-4}"
STALL_LIMIT="${STALL_LIMIT:-600}"
NO_JSONL_LIMIT="${NO_JSONL_LIMIT:-$STALL_LIMIT}"
POLL="${POLL:-30}"
RETRY_STATUSES="${RETRY_STATUSES:-}"
RATE_LIMIT_WAIT_SECONDS="${RATE_LIMIT_WAIT_SECONDS:-1500}"
RATE_LIMIT_MAX_WAITS="${RATE_LIMIT_MAX_WAITS:-24}"
# Narrow real 5h/session markers only (see HOW_TO_RUN §9.10.2 / 2026-07-13 fix).
RATE_LIMIT_RE="${RATE_LIMIT_RE:-hit your (session|usage|5.?hour|weekly) limit|limit will reset|resets? (at )?[0-9]{1,2}(:[0-9]{2})? ?(am|pm)|usage limit reached}"
STATUS_RE='^[[:space:]]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)[[:space:]]*$'
PAUSE_FLAG=/tmp/ram_paused
# Notification hook — set NOTIFY_CMD to a command taking ONE message arg (e.g. a Telegram sender).
# Empty by default so the template carries no project identity → single source, publishable as-is.
NOTIFY_CMD="${NOTIFY_CMD:-}"
notify(){ [ -n "$NOTIFY_CMD" ] && $NOTIFY_CMD "$*" >/dev/null 2>&1; return 0; }

mkdir -p "$LOG_DIR" "$STATE_DIR" "$(dirname "$REPORT")"
exec >> "$SUPLOG" 2>&1
log(){ echo "[$(date '+%F %T')] $*"; }

report_status(){ grep -aE "$STATUS_RE" "$REPORT" 2>/dev/null | tail -1 \
  | sed -E 's/^[[:space:]]*STATUS:[[:space:]]*//; s/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]'; }
status_in_list(){ local n="$1" i; for i in $2; do [ "$n" = "$(printf '%s' "$i"|tr '[:lower:]' '[:upper:]')" ] && return 0; done; return 1; }
archive_report_attempt(){ local st="$1" ts; ts="$(date +%Y%m%d_%H%M%S)"; mkdir -p "$STATE_DIR/report_attempts"
  mv "$REPORT" "$STATE_DIR/report_attempts/${TASK}_${ts}_${st}.md" 2>/dev/null; log "archived retryable report STATUS=$st"; }

pane_tail(){ tmux capture-pane -p -t "=$PANE_SESSION" 2>/dev/null | tail -n 40; }
rate_limit_line(){ pane_tail | grep -aiE "$RATE_LIMIT_RE" | tail -1; }
newest_jsonl(){ find "$JSONL_DIR" -maxdepth 1 -name '*.jsonl' -newermt "@$((LAUNCH_TS-5))" 2>/dev/null \
  | xargs -r ls -t 2>/dev/null | head -1; }

kill_agent(){
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$pid" ]; then
    kill -CONT "$pid" 2>/dev/null
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 15); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  fi
  tmux kill-session -t "=$PANE_SESSION" 2>/dev/null
  sleep 2
}

launch_agent(){
  rm -f "$PID_FILE"
  LAUNCH_TS=$(date +%s)
  PROJECT_DIR="$PROJECT_DIR" TASK="$TASK" TASK_FILE="$TASK_FILE" PID_FILE="$PID_FILE" \
    PANE_SESSION="$PANE_SESSION" PROMPT_FILE="$PROMPT_FILE" \
    setsid bash "$LAUNCHER" </dev/null >>"$LOG_DIR/${TASK}_launch.log" 2>&1 &
  for _ in $(seq 1 10); do sleep 3; [ -s "$PID_FILE" ] && break; done
  SUB_PID="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$SUB_PID" ] && kill -0 "$SUB_PID" 2>/dev/null; then log "launched REPL SUB_PID=$SUB_PID session=$PANE_SESSION"; return 0; fi
  log "launch failed: no live SUB_PID"; return 1
}

handle_rate_limit(){
  local rl tries=0; rl="$(rate_limit_line)"; [ -n "$rl" ] || return 1
  while :; do
    tries=$((tries+1))
    log "RATE-LIMIT «$rl» wait ${RATE_LIMIT_WAIT_SECONDS}s (${tries}/${RATE_LIMIT_MAX_WAITS})"
    notify "⏳ $TASK: лимит Claude — жду ~$((RATE_LIMIT_WAIT_SECONDS/60)) мин и перезапуск (RL #$tries)" 2>&1 | tail -1
    kill_agent
    sleep "$RATE_LIMIT_WAIT_SECONDS"
    launch_agent && return 0
    [ "$tries" -ge "$RATE_LIMIT_MAX_WAITS" ] && { log "FATAL: RL persisted"; return 2; }
  done
}

finish_on_report(){
  sleep 2; local st sz; st="$(report_status)"; sz=$(wc -c < "$REPORT" 2>/dev/null || echo 0)
  case "$st" in
    SUCCESS) log "SUCCESS report=$REPORT ${sz}b"; notify "✅ $TASK: УСПЕХ — $REPORT ($sz b)" 2>&1|tail -1; kill_agent; exit 0 ;;
    FAIL|BLOCKED|PARTIAL)
      if status_in_list "$st" "$RETRY_STATUSES"; then return 10; fi
      log "DONE-NOT-SUCCESS STATUS=$st"; notify "⚠️ $TASK: завершился STATUS=$st (не успех): $REPORT" 2>&1|tail -1; kill_agent; exit 2 ;;
    *) log "AMBIGUOUS: report without STATUS line"; notify "⚠️ $TASK: отчёт без строки STATUS — проверь вручную: $REPORT" 2>&1|tail -1; kill_agent; exit 3 ;;
  esac
}

respawns=0; LAUNCH_TS=0; SUB_PID=""
if [ -f "$REPORT" ]; then st="$(report_status)"; if [ -n "$st" ]; then
  status_in_list "$st" "$RETRY_STATUSES" && archive_report_attempt "$st" || finish_on_report; fi; fi
launch_agent || { handle_rate_limit || { notify "❌ $TASK supervisor: не смог запустить агента"; exit 1; }; }
log "supervisor start task=$TASK max_respawn=$MAX_RESPAWN stall=${STALL_LIMIT}s jsonl=$JSONL_DIR"

while true; do
  sleep "$POLL"

  if [ -f "$REPORT" ]; then
    finish_on_report; rc=$?
    if [ "$rc" -eq 10 ]; then st="$(report_status)"; archive_report_attempt "$st"; kill_agent
      respawns=$((respawns+1)); [ "$respawns" -gt "$MAX_RESPAWN" ] && { log "FATAL respawn exhausted"; exit 1; }
      log "retryable STATUS=$st; respawn $respawns/$MAX_RESPAWN"; launch_agent || exit 1; continue; fi
  fi

  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    sleep 3
    [ -f "$REPORT" ] && finish_on_report
    if handle_rate_limit; then continue; fi
    respawns=$((respawns+1)); [ "$respawns" -gt "$MAX_RESPAWN" ] && { log "FATAL respawn exhausted"; notify "❌ $TASK: respawn-лимит исчерпан"; exit 1; }
    log "agent died without report; respawn $respawns/$MAX_RESPAWN"; notify "♻️ $TASK: агент умер → respawn $respawns/$MAX_RESPAWN" 2>&1|tail -1
    launch_agent || exit 1; continue
  fi

  if [ -f "$PAUSE_FLAG" ]; then log "RAM pause — stall-детект пропущен"; continue; fi

  J="$(newest_jsonl)"
  if [ -n "$J" ] && [ -f "$J" ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$J") ))
    if [ "$AGE" -ge "$STALL_LIMIT" ]; then
      log "STALL jsonl quiet ${AGE}s ≥ $STALL_LIMIT → kill+respawn"; kill_agent
      if handle_rate_limit; then continue; fi
      respawns=$((respawns+1)); [ "$respawns" -gt "$MAX_RESPAWN" ] && { log FATAL; notify "❌ $TASK: respawn-лимит"; exit 1; }
      notify "♻️ $TASK: завис (jsonl тих ${AGE}s) → respawn $respawns/$MAX_RESPAWN" 2>&1|tail -1
      launch_agent || exit 1; continue
    fi
    log "alive PID=$SUB_PID jsonl=${J##*/} age=${AGE}s respawns=$respawns"
  else
    NA=$(( $(date +%s) - LAUNCH_TS ))
    if [ "$NA" -ge "$NO_JSONL_LIMIT" ]; then
      log "NO-JSONL ${NA}s ≥ $NO_JSONL_LIMIT → kill+respawn"; kill_agent
      if handle_rate_limit; then continue; fi
      respawns=$((respawns+1)); [ "$respawns" -gt "$MAX_RESPAWN" ] && { log FATAL; exit 1; }
      launch_agent || exit 1; continue
    fi
    log "alive PID=$SUB_PID (jsonl ещё нет ${NA}s/${NO_JSONL_LIMIT}s)"
  fi
done
