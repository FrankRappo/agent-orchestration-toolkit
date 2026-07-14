#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-${1:-}}"
PROMPT_FILE="${PROMPT_FILE:-${2:-}}"
RUN_NAME="${RUN_NAME:-omx-autopilot}"
OMX_REASONING="${OMX_REASONING:-high}"
OMX_FULL_ACCESS="${OMX_FULL_ACCESS:-0}"
OMX_ADD_DIR="${OMX_ADD_DIR:-}"
OMX_MODEL="${OMX_MODEL:-}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v omx >/dev/null 2>&1 || die "omx is not installed"
command -v setsid >/dev/null 2>&1 || die "setsid is not installed"
[ -n "$PROJECT_DIR" ] || die "set PROJECT_DIR or pass it as argument 1"
[ -d "$PROJECT_DIR" ] || die "PROJECT_DIR does not exist: $PROJECT_DIR"
[ -n "$PROMPT_FILE" ] || die "set PROMPT_FILE or pass it as argument 2"
[ -f "$PROMPT_FILE" ] || die "PROMPT_FILE does not exist: $PROMPT_FILE"

case "$OMX_REASONING" in
  low|medium|high|xhigh) ;;
  *) die "OMX_REASONING must be low, medium, high, or xhigh" ;;
esac
case "$OMX_FULL_ACCESS" in
  0|1) ;;
  *) die "OMX_FULL_ACCESS must be 0 or 1" ;;
esac
case "$RUN_NAME" in
  ''|*[!A-Za-z0-9._-]*) die "RUN_NAME may contain only A-Z, a-z, 0-9, dot, underscore, dash" ;;
esac

PROJECT_DIR="$(realpath "$PROJECT_DIR")"
PROMPT_FILE="$(realpath "$PROMPT_FILE")"
LOG_DIR="${OMX_LOG_DIR:-$PROJECT_DIR/.omx/logs}"
RUN_DIR="${OMX_RUN_DIR:-$PROJECT_DIR/.omx/run}"
mkdir -p "$LOG_DIR" "$RUN_DIR"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
BASE="${RUN_NAME}-${RUN_ID}"
LOG="$LOG_DIR/$BASE.jsonl"
LAST="$LOG_DIR/$BASE.last.md"
PIDFILE="$RUN_DIR/$BASE.pid"
META="$RUN_DIR/$BASE.meta.json"

cmd=(
  omx exec --json
  -c "model_reasoning_effort=\"$OMX_REASONING\""
  -o "$LAST"
)
if [ "$OMX_FULL_ACCESS" = 1 ]; then
  cmd+=(--dangerously-bypass-approvals-and-sandbox)
else
  cmd+=(--sandbox workspace-write)
fi
[ -n "$OMX_ADD_DIR" ] && cmd+=(--add-dir "$OMX_ADD_DIR")
[ -n "$OMX_MODEL" ] && cmd+=(--model "$OMX_MODEL")
cmd+=(-)

# Logs can contain tool output; keep new files private by default.
umask 077
(
  cd "$PROJECT_DIR"
  exec nohup setsid env -u OMX_SESSION_ID -u OMX_ACTIVE_SESSION_ID \
    "${cmd[@]}" < "$PROMPT_FILE" > "$LOG" 2>&1
) &
PID=$!
printf '%s\n' "$PID" > "$PIDFILE"

python3 - "$RUN_ID" "$RUN_NAME" "$PID" "$PROJECT_DIR" "$PROMPT_FILE" \
  "$LOG" "$LAST" "$PIDFILE" "$META" "$OMX_REASONING" "$OMX_FULL_ACCESS" "$OMX_ADD_DIR" <<'PY'
import json, sys
(
    run_id, run_name, pid, project_dir, prompt_file, log, last_message,
    pid_file, meta, reasoning, full_access, add_dir,
) = sys.argv[1:]
payload = {
    "schema_version": 1,
    "run_id": run_id,
    "run_name": run_name,
    "pid": int(pid),
    "status": "launched",
    "project_dir": project_dir,
    "prompt_file": prompt_file,
    "log": log,
    "last_message": last_message,
    "pid_file": pid_file,
    "reasoning": reasoning,
    "full_access": full_access == "1",
    "add_dir": add_dir or None,
}
with open(meta, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
PY

sleep 2
if ! kill -0 "$PID" 2>/dev/null; then
  printf 'ERROR: orchestrator exited during startup; inspect %s\n' "$LOG" >&2
  exit 1
fi
printf 'RUNNING pid=%s meta=%s log=%s\n' "$PID" "$META" "$LOG"
