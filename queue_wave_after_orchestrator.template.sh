#!/bin/bash
# ============================================================================
# queue_wave_after_orchestrator.template.sh
# ПАТТЕРН 1 — «волна B ПОСЛЕ оркестратора A» (последовательно, автономно).
# Сторож ждёт ФИНАЛА оркестратора A, затем по одному прогоняет таски волны B под
# RL-aware супервизором (5ч-лимит сам пережидает; stall→respawn; выход по STATUS-отчёту).
#
# Сигнал финала A = смерть его supervisor-сессии(й) (НЕ progress/pid — они врут) + затихшие
# хвосты (detached-агент мог пережить супервизор) + RAM-гейт.
#
# Обратный паттерн описан в queue_wave_then_resume_orchestrator.template.sh.
#
# ЗАПУСК (ОТ ROOT, ПОСЛЕ старта A, ДО ручного старта B):
#   tmux new-session -d -s wave_qwait "bash <этот файл>"
#   sleep 3 && tail -3 <LOG>          # verify: "armed"
# ОТМЕНА до старта B:  tmux kill-session -t =wave_qwait
set -u
unset TMUX TMUX_PANE TERM
export LC_ALL=C.utf8 LANG=C.utf8

# ===================== НАСТРОЙКИ (ЗАПОЛНИТЬ) =====================
A_SUP_RE='^<project_tag>_[A-Za-z0-9_]*_sup:'         # regex имён tmux-сессий супервизора(ов) A (ждём, пока ВСЕ исчезнут)
A_PID_FILE='/tmp/UPSTREAM.pid'          # pid-файл агента A (хвост); пусто '' = не проверять
A_CWD_PREFIX='/work/<project>'                    # cwd живого Claude-агента = «хвост A»; пусто '' = не проверять
AGENT_USER="${AGENT_USER:-agent}"
TAIL_CAP_TICKS=240                          # cap ожидания хвостов A (×60с = 4ч)
RAM_MIN_KB=1500000                          # гейт MemAvailable перед каждым таском B
SUPERVISOR='/work/settings/wave_supervisor.template.sh'
LOG='/work/<project>/chat/queue_wait.log'       # лог сторожа
CHAT_ID="${CHAT_ID:-000000000}"
# Волна B — по одной строке на таск, В ПОРЯДКЕ выполнения:
#   TAG|PROJ_DIR|TASK_FILE|REPORT|JSONL_DIR|SESSION
TASKS=(
  "TB1|/work/<project>|/work/<project>/tasks/TB1_x.md|/work/<project>/reports/TB1_report.md|/home/$AGENT_USER/.claude/projects/-work-<project>|waveB_TB1_sup"
  "TB2|/work/<project>|/work/<project>/tasks/TB2_x.md|/work/<project>/reports/TB2_report.md|/home/$AGENT_USER/.claude/projects/-work-<project>|waveB_TB2_sup"
)
# ================================================================

TG="python3 /work/tg/bot.py send $CHAT_ID"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec >> "$LOG" 2>&1
log(){ echo "[$(date '+%F %T')] $*"; }
a_alive(){ tmux ls 2>/dev/null | grep -qE "$A_SUP_RE"; }
status_of(){ grep -aoiE '^[[:space:]]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)' "$1" 2>/dev/null | tail -1 | grep -aoiE 'SUCCESS|FAIL|BLOCKED|PARTIAL' | head -1 | tr '[:lower:]' '[:upper:]'; }
ram_gate(){ while :; do a=$(awk '/MemAvailable/{print $2}' /proc/meminfo); [ "${a:-0}" -ge "$RAM_MIN_KB" ] && break; log "RAM ${a}KB<${RAM_MIN_KB} — жду 120с"; sleep 120; done; sleep 20; }

log "=== wave_qwait PID $$ armed: жду финала A ($A_SUP_RE), потом волна B ==="
[ -x "$SUPERVISOR" ] || { log "FATAL: нет $SUPERVISOR"; $TG "❌ wave_qwait: нет супервизора"; exit 1; }
for row in "${TASKS[@]}"; do IFS='|' read -r tag pd tf rep jd ses <<<"$row"; tf=$(ls $tf 2>/dev/null | head -1); [ -f "$tf" ] || { log "FATAL: нет таск-файла ($tag): $tf"; $TG "❌ wave_qwait: нет таск-файла $tag"; exit 1; }; done

# 1. Финал A: исчезли все его supervisor-сессии.
if ! a_alive; then log "ВНИМАНИЕ: A не виден уже сейчас — считаю завершённым"; fi
while a_alive; do sleep 120; done
log "supervisor-сессии A завершились"

# 2. Хвосты A (detached-агент мог пережить супервизор).
for i in $(seq 1 "$TAIL_CAP_TICKS"); do
  ALIVE=0
  if [ -n "$A_PID_FILE" ] && [ -f "$A_PID_FILE" ]; then p=$(cat "$A_PID_FILE" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && ALIVE=1; fi
  if [ -n "$A_CWD_PREFIX" ]; then
    for pid in $(ps -u "$AGENT_USER" -o pid=,comm= 2>/dev/null | awk '$2=="claude"{print $1}'); do
      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null); case "$cwd" in "$A_CWD_PREFIX"|"$A_CWD_PREFIX"/*) ALIVE=1 ;; esac
    done
  fi
  [ "$ALIVE" -eq 0 ] && break
  log "хвосты A ещё живы — жду"; sleep 60
done
log "A полностью затих (или cap)"
$TG "⏱️ A завершился → запускаю волну B (по очереди, RL-aware)." 2>&1 | tail -1

# 3. Последовательный прогон B.
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
  $TG "▫️ Очередь B: $TAG завершён, STATUS=$ST. Отчёт: $REPORT" 2>&1 | tail -1
done
log "wave_qwait: волна B отработана, выход"
$TG "🏁 Волна B (после A) отработана. Статусы — выше + в отчётах." 2>&1 | tail -1
exit 0
