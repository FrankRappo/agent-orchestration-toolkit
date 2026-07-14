#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-${1:-}}"
META="${META:-${2:-}}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ -n "$PROJECT_DIR" ] || die "set PROJECT_DIR or pass it as argument 1"
[ -d "$PROJECT_DIR" ] || die "PROJECT_DIR does not exist: $PROJECT_DIR"
PROJECT_DIR="$(realpath "$PROJECT_DIR")"

if [ -z "$META" ]; then
  META="$(python3 - "$PROJECT_DIR/.omx/run" <<'PY'
import sys
from pathlib import Path
files = list(Path(sys.argv[1]).glob("*.meta.json"))
if files:
    print(max(files, key=lambda path: path.stat().st_mtime))
PY
)"
  [ -n "$META" ] || die "no .omx/run/*.meta.json files found"
fi
[ -f "$META" ] || die "metadata file does not exist: $META"

eval "$(python3 - "$META" <<'PY'
import json, shlex, sys
obj=json.load(open(sys.argv[1], encoding='utf-8'))
for key in ('pid','log','last_message','pid_file','run_id','run_name'):
    value=obj.get(key, '')
    print(f'{key.upper()}={shlex.quote(str(value))}')
PY
)"

printf '=== metadata ===\n'
cat "$META"
printf '\n=== process ===\n'
if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
  ps -o user,pid,ppid,sid,stat,etime,%cpu,%mem,cmd -p "$PID"
else
  printf 'NOT RUNNING pid=%s\n' "${PID:-unknown}"
fi

printf '\n=== log ===\n'
if [ -f "${LOG:-}" ]; then
  stat -c '%y %s %n' "$LOG"
  wc -lc "$LOG"
  printf '\n=== log tail ===\n'
  tail -n "${TAIL_LINES:-20}" "$LOG"
else
  printf 'log not found: %s\n' "${LOG:-unset}"
fi

printf '\n=== final message ===\n'
if [ -f "${LAST_MESSAGE:-}" ]; then
  cat "$LAST_MESSAGE"
else
  printf '(not written yet)\n'
fi
