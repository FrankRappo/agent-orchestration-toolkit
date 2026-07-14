#!/bin/bash
# wave_launcher.sh — универсальный лончер одиночного `claude -p` агента.
# Запускается wave_supervisor.sh от настроенного Unix-пользователя через `env -i`.
# Конфиг приходит через окружение: PROJECT_DIR, TASK_FILE, PID_FILE, LOG.
# Промпт подаётся через stdin-redirect (-p < file) — безопасно, без двойного eval'а
# backticks/$()-фрагментов из .md (README.md one-liner launcher»).
set -u
cd "$PROJECT_DIR" || { echo "FATAL: cd $PROJECT_DIR" ; exit 1; }
echo $$ > "$PID_FILE"
exec claude --dangerously-skip-permissions -p < "$TASK_FILE" > "$LOG" 2>&1
