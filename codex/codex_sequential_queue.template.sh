#!/bin/bash
# Sequential rate-limit-resilient queue for autonomous Codex/orchestrator stages.
#
# Usage:
#   PROJECT_DIR=/work/<project> \
#   STAGES='T-A T-B T-C' \
#   STAGE_CMD_TEMPLATE='bash /work/<project>/codex/run_stage.sh {stage}' \
#   RATE_LIMIT_WAIT_SECONDS=18000 RATE_LIMIT_MAX_WAITS=24 \
#   bash /work/settings/codex/codex_sequential_queue.template.sh
#
# Contract:
# - each stage command must return 0 on success;
# - each stage should write its own state/summary/report;
# - if a stage log contains rate/session-limit markers, the queue waits and
#   retries without consuming normal retries;
# - use this as a wrapper around codex_orchestrator.template.sh or any custom
#   stage runner that may call Codex/LLM APIs.

set -u
unset TMUX TMUX_PANE
export LC_ALL=C.utf8 LANG=C.utf8

PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
STAGES="${STAGES:?need STAGES}"
STAGE_CMD_TEMPLATE="${STAGE_CMD_TEMPLATE:?need STAGE_CMD_TEMPLATE; use {stage} placeholder}"
QUEUE_TAG="${QUEUE_TAG:-codex_seq_$(date -u +%Y%m%dT%H%M%SZ)}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/codex/logs}"
STATE_DIR="${STATE_DIR:-$PROJECT_DIR/codex/state}"
QUEUE_LOG="${QUEUE_LOG:-$LOG_DIR/${QUEUE_TAG}.log}"
QUEUE_STATE="${QUEUE_STATE:-$STATE_DIR/${QUEUE_TAG}.state.json}"
RATE_LIMIT_WAIT_SECONDS="${RATE_LIMIT_WAIT_SECONDS:-18000}"
RATE_LIMIT_MAX_WAITS="${RATE_LIMIT_MAX_WAITS:-24}"
MAX_STAGE_RETRIES="${MAX_STAGE_RETRIES:-3}"
RATE_LIMIT_RE="${RATE_LIMIT_RE:-rate.?limit|usage limit|session limit|hit your [a-z ]*limit|limit reached|limit will reset|resets? at|resets? [0-9]|reached your|try again|try later|please try again|too many requests|429|overloaded|5[ -]?hour|five[ -]?hour|превыш.*лимит|лимит исчерпан}"

mkdir -p "$LOG_DIR" "$STATE_DIR"
exec >> "$QUEUE_LOG" 2>&1
log(){ echo "[$(date -u +%FT%TZ)] $*"; }
json_quote(){ python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
write_state(){
  local status="$1" stage="$2" extra="${3:-{}}"
  python3 - "$QUEUE_STATE" "$status" "$stage" "$QUEUE_TAG" "$extra" <<'PY'
import json,sys,datetime
path,status,stage,tag,extra=sys.argv[1:]
data={'status':status,'stage':stage,'queue_tag':tag,'updated_utc':datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ')}
try: data.update(json.loads(extra))
except Exception: data['extra']=extra
open(path,'w',encoding='utf-8').write(json.dumps(data,ensure_ascii=False,indent=2,sort_keys=True))
PY
}
rate_limited(){ tail -n 240 "$QUEUE_LOG" 2>/dev/null | grep -aiE "$RATE_LIMIT_RE" | tail -1; }
run_stage(){
  local stage="$1" tries=0 rl_waits=0 rc=0 cmd rl
  cmd="${STAGE_CMD_TEMPLATE//\{stage\}/$stage}"
  while true; do
    tries=$((tries+1))
    log "START stage=$stage attempt=$tries cmd=$cmd"
    write_state running "$stage" "{\"attempt\":$tries,\"cmd\":$(json_quote "$cmd")}"
    bash -lc "$cmd"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      log "DONE stage=$stage"
      write_state running "$stage" '{"stage_status":"complete"}'
      return 0
    fi
    rl="$(rate_limited || true)"
    if [ -n "$rl" ]; then
      rl_waits=$((rl_waits+1))
      if [ "$rl_waits" -gt "$RATE_LIMIT_MAX_WAITS" ]; then
        log "FATAL stage=$stage rate-limit persisted too long waits=$rl_waits line=$rl"
        write_state failed "$stage" "{\"reason\":\"rate_limit_max_waits\",\"rc\":$rc}"
        return "$rc"
      fi
      log "RATE-LIMIT stage=$stage line=[$rl] wait=${RATE_LIMIT_WAIT_SECONDS}s then retry without consuming normal retry ($rl_waits/$RATE_LIMIT_MAX_WAITS)"
      write_state waiting_rate_limit "$stage" "{\"wait_seconds\":$RATE_LIMIT_WAIT_SECONDS,\"line\":$(json_quote "$rl")}"
      sleep "$RATE_LIMIT_WAIT_SECONDS"
      continue
    fi
    if [ "$tries" -ge "$MAX_STAGE_RETRIES" ]; then
      log "FATAL stage=$stage rc=$rc retries_exhausted=$tries"
      write_state failed "$stage" "{\"reason\":\"retries_exhausted\",\"rc\":$rc,\"attempts\":$tries}"
      return "$rc"
    fi
    log "RETRY stage=$stage rc=$rc after non-rate-limit failure attempt=$tries/$MAX_STAGE_RETRIES"
    sleep 30
  done
}

log "QUEUE START tag=$QUEUE_TAG stages=$STAGES"
write_state running queue "{\"stages\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' $STAGES)}"
for stage in $STAGES; do
  run_stage "$stage" || exit $?
done
write_state complete all "{\"completed_utc\":\"$(date -u +%FT%TZ)\"}"
log "QUEUE COMPLETE tag=$QUEUE_TAG"
