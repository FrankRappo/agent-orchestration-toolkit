#!/bin/bash
# ============================================================================
# queue_wave_then_resume_orchestrator.template.sh
# ПАТТЕРН 2 — «оркестратор A ПОСЛЕ волны B» (последовательно, автономно).
# Сначала по одному прогоняет таски волны B под RL-aware супервизором, затем по окончании
# АВТОНОМНО снимает оркестратор A с паузы (resume-команда).
#
# Обратный паттерн описан в queue_wave_after_orchestrator.template.sh.
#
# ЗАПУСК (ОТ ROOT):  tmux new-session -d -s wave_qrun "bash <этот файл>"; sleep 3 && tail -3 <LOG>
# ОТМЕНА (до старта след. таска): tmux kill-session -t =wave_qrun  (уже идущий таск гасить: tmux kill-session -t =<SESSION>)
set -u
unset TMUX TMUX_PANE TERM
export LC_ALL=C.utf8 LANG=C.utf8

# ===================== НАСТРОЙКИ (ЗАПОЛНИТЬ) =====================
RAM_MIN_KB=1500000
SUPERVISOR='/work/settings/wave_supervisor.template.sh'
LOG='/work/<project>/chat/wave_run.log'
CHAT_ID="${CHAT_ID:-000000000}"
AGENT_USER="${AGENT_USER:-agent}"
# Волна B — по одной строке на таск, В ПОРЯДКЕ выполнения:  TAG|PROJ_DIR|TASK_FILE|REPORT|JSONL_DIR|SESSION
TASKS=(
  "TB1|/work/<project>|/work/<project>/tasks/TB1_x.md|/work/<project>/reports/TB1_report.md|/home/$AGENT_USER/.claude/projects/-work-<project>|waveB_TB1_sup"
  "TB2|/work/<project>|/work/<project>/tasks/TB2_x.md|/work/<project>/reports/TB2_report.md|/home/$AGENT_USER/.claude/projects/-work-<project>|waveB_TB2_sup"
)
# Оркестратор A — как возобновить ПОСЛЕ волны B (resume-команда обычно лежит в его progress.md):
A_SESSION='<project_tag>_upstream_sup'                              # tmux-сессия супервизора A (для идемпотентности)
A_RESUME_CMD='bash /work/<project>/orch/supervisor_upstream.sh' # что запустить в этой сессии (cwd = A_CWD)
A_CWD='/work/<project>'
# ================================================================

TG="python3 /work/tg/bot.py send $CHAT_ID"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec >> "$LOG" 2>&1
log(){ echo "[$(date '+%F %T')] $*"; }
status_of(){ grep -aoiE '^[[:space:]]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)' "$1" 2>/dev/null | tail -1 | grep -aoiE 'SUCCESS|FAIL|BLOCKED|PARTIAL' | head -1 | tr '[:lower:]' '[:upper:]'; }
ram_gate(){ while :; do a=$(awk '/MemAvailable/{print $2}' /proc/meminfo); [ "${a:-0}" -ge "$RAM_MIN_KB" ] && break; log "RAM ${a}KB<${RAM_MIN_KB} — жду 120с"; sleep 120; done; sleep 20; }

log "=== wave_qrun PID $$ старт: волна B, затем resume A ($A_SESSION) ==="
[ -x "$SUPERVISOR" ] || { log "FATAL: нет $SUPERVISOR"; $TG "❌ wave_qrun: нет супервизора"; exit 1; }
for row in "${TASKS[@]}"; do IFS='|' read -r tag pd tf rep jd ses <<<"$row"; tf=$(ls $tf 2>/dev/null | head -1); [ -f "$tf" ] || { log "FATAL: нет таск-файла ($tag): $tf"; $TG "❌ wave_qrun: нет таск-файла $tag"; exit 1; }; done
$TG "▶️ Старт волны B (по очереди). По окончании сам возобновлю оркестратор A." 2>&1 | tail -1

# 1. Последовательный прогон B.
for row in "${TASKS[@]}"; do
  IFS='|' read -r TAG PROJ_DIR TASK_FILE REPORT JSONL_DIR SESSION <<<"$row"
  TASK_FILE=$(ls $TASK_FILE 2>/dev/null | head -1)
  PID_FILE="/tmp/wave_${TAG}.pid"; WLOG="$(dirname "$LOG")/${TAG}_output.log"; SUPLOG="$(dirname "$LOG")/${TAG}_supervisor.log"
  if [ -f "$REPORT" ] && [ -n "$(status_of "$REPORT")" ]; then log "$TAG: отчёт уже со STATUS=$(status_of "$REPORT") — пропуск"; continue; fi
  if ! tmux has-session -t "=$SESSION" 2>/dev/null; then
    ram_gate; log "$TAG: старт супервизора (tmux $SESSION)"
    tmux new-session -d -s "$SESSION" -c "$PROJ_DIR" \
      "TASK='$TAG' PROJ_DIR='$PROJ_DIR' TASK_FILE='$TASK_FILE' PID_FILE='$PID_FILE' LOG='$WLOG' SUPLOG='$SUPLOG' REPORT='$REPORT' JSONL_DIR='$JSONL_DIR' bash '$SUPERVISOR'"
    sleep 5; tmux has-session -t "=$SESSION" 2>/dev/null || { log "$TAG: супервизор не поднялся"; $TG "❌ wave: $TAG не стартовал, пропуск"; continue; }
  fi
  while tmux has-session -t "=$SESSION" 2>/dev/null; do sleep 60; done
  ST=$(status_of "$REPORT"); ST="${ST:-NO_REPORT}"; log "$TAG завершён, STATUS=$ST"
  $TG "▫️ Волна B: $TAG завершён, STATUS=$ST. Отчёт: $REPORT" 2>&1 | tail -1
done
log "волна B отработана — резюмлю A"

# 2. RESUME оркестратора A (в любом случае по окончании B).
ram_gate
if tmux has-session -t "=$A_SESSION" 2>/dev/null; then
  log "A ($A_SESSION) уже жив — не дублирую"; $TG "🏁 Волна B отработана. A ($A_SESSION) уже запущен — ок." 2>&1 | tail -1
else
  log "resume A: tmux $A_SESSION"
  tmux new-session -d -s "$A_SESSION" -c "$A_CWD" "$A_RESUME_CMD"
  sleep 5
  if tmux has-session -t "=$A_SESSION" 2>/dev/null; then
    $TG "🏁 Волна B отработана → снял оркестратор A с паузы ($A_SESSION)." 2>&1 | tail -1; log "A возобновлён"
  else
    $TG "🏁 Волна B отработана, но ❌ A-сессия не поднялась — резюмни вручную: tmux new-session -d -s $A_SESSION -c $A_CWD \"$A_RESUME_CMD\"" 2>&1 | tail -1; log "FATAL: A не поднялась"
  fi
fi
log "wave_qrun выход"; exit 0
