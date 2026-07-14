#!/bin/bash
# Supervise one Codex exec task.
#
# Required env:
#   TASK PROJECT_DIR TASK_FILE REPORT
#
# Optional env:
#   CODEX_DIR LOG_DIR STATE_DIR LAUNCHER MAX_RESPAWN STALL_LIMIT POLL RETRY_STATUSES
#   MAX_RUNTIME_SECONDS MAX_RUNTIME_RESTARTS RUNTIME_RESTART_WAIT_SECONDS
#   RATE_LIMIT_WAIT_SECONDS RATE_LIMIT_MAX_WAITS RATE_LIMIT_RE
#   CODEX_SANDBOX CODEX_MODEL CODEX_EXTRA_ARGS

set -u
unset TMUX TMUX_PANE
export LC_ALL=C.utf8 LANG=C.utf8

TASK="${TASK:?need TASK}"
PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
TASK_FILE="${TASK_FILE:?need TASK_FILE}"
REPORT="${REPORT:?need REPORT}"

CODEX_DIR="${CODEX_DIR:-$PROJECT_DIR/codex}"
LOG_DIR="${LOG_DIR:-$CODEX_DIR/logs}"
STATE_DIR="${STATE_DIR:-$CODEX_DIR/state}"
LAUNCHER="${LAUNCHER:-/work/settings/codex/codex_agent_launcher.template.sh}"
LOG="${LOG:-$LOG_DIR/${TASK}.log}"
SUPLOG="${SUPLOG:-$LOG_DIR/${TASK}_supervisor.log}"
PID_FILE="${PID_FILE:-$STATE_DIR/${TASK}.pid}"
LAST_MESSAGE="${LAST_MESSAGE:-$STATE_DIR/${TASK}.last_message.txt}"
MAX_RESPAWN="${MAX_RESPAWN:-3}"
STALL_LIMIT="${STALL_LIMIT:-1800}"
POLL="${POLL:-30}"
RETRY_STATUSES="${RETRY_STATUSES:-}"
MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-0}"
MAX_RUNTIME_RESTARTS="${MAX_RUNTIME_RESTARTS:-24}"
RUNTIME_RESTART_WAIT_SECONDS="${RUNTIME_RESTART_WAIT_SECONDS:-0}"
RATE_LIMIT_WAIT_SECONDS="${RATE_LIMIT_WAIT_SECONDS:-18000}"
RATE_LIMIT_MAX_WAITS="${RATE_LIMIT_MAX_WAITS:-24}"
RATE_LIMIT_RE="${RATE_LIMIT_RE:-rate.?limit|usage limit|session limit|hit your [a-z ]*limit|limit reached|limit will reset|resets? at|resets? [0-9]|reached your|try again|try later|please try again|too many requests|429|overloaded|5[ -]?hour|five[ -]?hour|превыш.*лимит|лимит исчерпан}"
STATUS_RE='^[[:space:]]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)[[:space:]]*$'

mkdir -p "$LOG_DIR" "$STATE_DIR" "$(dirname "$REPORT")"
exec >> "$SUPLOG" 2>&1

log(){ echo "[$(date '+%F %T')] $*"; }

report_status(){
  grep -aE "$STATUS_RE" "$REPORT" 2>/dev/null \
    | tail -1 \
    | sed -E 's/^[[:space:]]*STATUS:[[:space:]]*//; s/[[:space:]]*$//' \
    | tr '[:lower:]' '[:upper:]'
}

status_in_list(){
  local needle="$1" item
  for item in $2; do
    [ "$needle" = "$(printf '%s' "$item" | tr '[:lower:]' '[:upper:]')" ] && return 0
  done
  return 1
}

archive_report_attempt(){
  local st="$1" ts dest
  ts="$(date '+%Y%m%d_%H%M%S')"
  mkdir -p "$STATE_DIR/report_attempts"
  dest="$STATE_DIR/report_attempts/${TASK}_${ts}_${st}.md"
  mv "$REPORT" "$dest"
  log "RETRYABLE-REPORT: archived STATUS=$st report_attempt=$dest"
}

log_has_rate_limit(){
  [ -f "$LOG" ] || return 1
  tail -n 120 "$LOG" 2>/dev/null \
    | grep -aiE "$RATE_LIMIT_RE" >/dev/null
}

rate_limit_line(){
  [ -f "$LOG" ] || return 1
  tail -n 120 "$LOG" 2>/dev/null | grep -aiE "$RATE_LIMIT_RE" | tail -1
}

wait_if_needed(){
  local reason="$1" seconds="$2"
  [ "${seconds:-0}" -gt 0 ] || return 0
  log "WAIT: reason=$reason seconds=$seconds"
  sleep "$seconds"
}

finish_on_report(){
  sleep 2
  local st sz
  st="$(report_status)"
  sz=$(wc -c < "$REPORT" 2>/dev/null || echo 0)
  case "$st" in
    SUCCESS)
      log "SUCCESS: report=$REPORT size=${sz}b"
      exit 0
      ;;
    FAIL|BLOCKED|PARTIAL)
      if status_in_list "$st" "$RETRY_STATUSES"; then
        return 10
      fi
      log "DONE-NOT-SUCCESS: STATUS=$st report=$REPORT size=${sz}b"
      exit 2
      ;;
    *)
      log "AMBIGUOUS: report exists but final STATUS is missing or invalid: $REPORT size=${sz}b"
      exit 3
      ;;
  esac
}

kill_agent(){
  local pid="$1"
  [ -z "$pid" ] && return 0
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL "$pid" 2>/dev/null || true
}

launch_agent(){
  rm -f "$PID_FILE"
  : > "$LOG"
  : > "$LAST_MESSAGE"
  LAUNCH_TS=$(date +%s)
  PROJECT_DIR="$PROJECT_DIR" TASK_FILE="$TASK_FILE" PID_FILE="$PID_FILE" \
    LOG="$LOG" LAST_MESSAGE="$LAST_MESSAGE" \
    CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}" \
    CODEX_MODEL="${CODEX_MODEL:-}" \
    CODEX_EXTRA_ARGS="${CODEX_EXTRA_ARGS:-}" \
    setsid bash "$LAUNCHER" </dev/null >/dev/null 2>&1 &
  sleep 5
  SUB_PID=$(cat "$PID_FILE" 2>/dev/null || true)
  if [ -n "$SUB_PID" ] && kill -0 "$SUB_PID" 2>/dev/null; then
    log "launched SUB_PID=$SUB_PID"
    return 0
  fi
  log "launch failed: no live SUB_PID"
  return 1
}

handle_rate_limit(){
  local rl tries
  rl="$(rate_limit_line 2>/dev/null || true)"
  [ -n "$rl" ] || return 1
  tries=0
  while true; do
    tries=$((tries + 1))
    log "RATE-LIMIT: «$rl»; wait ${RATE_LIMIT_WAIT_SECONDS}s then relaunch without consuming respawn (${tries}/${RATE_LIMIT_MAX_WAITS})"
    wait_if_needed "rate-limit-or-5-hour-window" "$RATE_LIMIT_WAIT_SECONDS"
    launch_agent && return 0
    rl="$(rate_limit_line 2>/dev/null || true)"
    if [ -z "$rl" ]; then
      log "FATAL: relaunch after rate-limit failed, but latest log no longer matches RATE_LIMIT_RE"
      return 2
    fi
    if [ "$tries" -ge "$RATE_LIMIT_MAX_WAITS" ]; then
      log "FATAL: rate-limit persisted after ${tries} waits of ${RATE_LIMIT_WAIT_SECONDS}s"
      return 2
    fi
  done
}

if [ -f "$REPORT" ]; then
  st="$(report_status)"
  if [ -n "$st" ]; then
    if status_in_list "$st" "$RETRY_STATUSES"; then
      archive_report_attempt "$st"
    else
      log "report already has STATUS=$st; no launch"
      finish_on_report
    fi
  fi
fi

respawns=0
runtime_restarts=0
LAUNCH_TS=0
SUB_PID=""
if ! launch_agent; then
  handle_rate_limit || exit 1
fi
log "supervisor start task=$TASK max_respawn=$MAX_RESPAWN stall=${STALL_LIMIT}s"

while true; do
  sleep "$POLL"

  if [ -f "$REPORT" ]; then
    finish_on_report
    rc=$?
    if [ "$rc" -eq 10 ]; then
      st="$(report_status)"
      archive_report_attempt "$st"
      kill_agent "$SUB_PID"
      respawns=$((respawns + 1))
      if [ "$respawns" -gt "$MAX_RESPAWN" ]; then
        log "FATAL: respawn limit exhausted after retryable STATUS=$st"
        exit 1
      fi
      log "retryable STATUS=$st; respawn $respawns/$MAX_RESPAWN"
      launch_agent || exit 1
      continue
    fi
  fi

  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    sleep 2
    if [ -f "$REPORT" ]; then
      finish_on_report
      rc=$?
      if [ "$rc" -eq 10 ]; then
        st="$(report_status)"
        archive_report_attempt "$st"
        respawns=$((respawns + 1))
        if [ "$respawns" -gt "$MAX_RESPAWN" ]; then
          log "FATAL: respawn limit exhausted after retryable STATUS=$st"
          exit 1
        fi
        log "retryable STATUS=$st after agent exit; respawn $respawns/$MAX_RESPAWN"
        launch_agent || exit 1
        continue
      fi
    fi
    if log_has_rate_limit; then
      handle_rate_limit || exit 1
      continue
    fi
    respawns=$((respawns + 1))
    if [ "$respawns" -gt "$MAX_RESPAWN" ]; then
      log "FATAL: respawn limit exhausted without report"
      exit 1
    fi
    log "agent died without report; respawn $respawns/$MAX_RESPAWN"
    launch_agent || exit 1
    continue
  fi

  # Codex exec --json usually streams events. Treat a long quiet log as a likely
  # stuck process, but keep the default high enough for long tool calls.
  now=$(date +%s)
  if [ -f "$LOG" ]; then
    age=$(( now - $(stat -c %Y "$LOG") ))
  else
    age=$(( now - LAUNCH_TS ))
  fi
  runtime=$(( now - LAUNCH_TS ))

  if [ "$MAX_RUNTIME_SECONDS" -gt 0 ] && [ "$runtime" -ge "$MAX_RUNTIME_SECONDS" ]; then
    log "RUNTIME-LIMIT: runtime=${runtime}s limit=${MAX_RUNTIME_SECONDS}s; recycling PID $SUB_PID"
    kill_agent "$SUB_PID"
    runtime_restarts=$((runtime_restarts + 1))
    if [ "$runtime_restarts" -gt "$MAX_RUNTIME_RESTARTS" ]; then
      log "FATAL: runtime restart limit exhausted (${MAX_RUNTIME_RESTARTS})"
      exit 1
    fi
    wait_if_needed "runtime-limit" "$RUNTIME_RESTART_WAIT_SECONDS"
    launch_agent || exit 1
    continue
  fi

  if [ "$age" -ge "$STALL_LIMIT" ]; then
    log "STALL: log quiet for ${age}s; killing PID $SUB_PID"
    kill_agent "$SUB_PID"
    if log_has_rate_limit; then
      handle_rate_limit || exit 1
      continue
    fi
    respawns=$((respawns + 1))
    if [ "$respawns" -gt "$MAX_RESPAWN" ]; then
      log "FATAL: respawn limit exhausted after stall"
      exit 1
    fi
    launch_agent || exit 1
    continue
  fi

  log "alive PID=$SUB_PID log_age=${age}s respawns=$respawns"
done
