#!/bin/bash
# RAM-сторож (OOM-защита) — шаблон для копирования в проект.
# Версия: 2026-06-06 (новый — после projecte: два оркестратора делили 5.8Gi RAM,
#   пики проседали до ~800Mi свободно → риск что Linux OOM-killer прибьёт ЧУЖОЙ
#   оркестратор/процесс).
#
# ЗАЧЕМ: когда на машине крутятся НЕСКОЛЬКО оркестраторов (или твой + чужой важный
# процесс), и суммарная RAM впритык — этот сторож при низкой памяти СТАВИТ НА ПАУЗУ
# (SIGSTOP) ТОЛЬКО СВОИ sub-агенты (по pid-файлам <project_tag>_T*.pid), отдавая RAM
# остальным. Когда память восстановилась — SIGCONT. Своя сборка лишь притормаживает на
# время крунча, НИЧЕГО не теряя; чужая важная работа защищена от OOM.
#
# Почему именно sub-агенты, а не orchestrator-claude: orchestrator idle-ждёт (лёгкий,
# ~300MB), а тяжёлые — sub-агенты (особенно таски с внутренними subagent'ами / циклами,
# дёргающими claude). Останавливаем самых прожорливых, оставляя оркестратор отзывчивым.
# orchestrator `while kill -0 SUB_PID` переживёт паузу sub-агента: kill -0 на
# остановленном процессе = 0 (жив), оркестратор просто продолжит ждать.
#
# Замени <project_dir>/<project_tag> и положи как /work/<project_dir>/chat/ram_guard.sh,
# chmod +x. Запуск — tmux-loop каждые ~20с (cron'а мало: RAM скачет быстрее минуты):
#   tmux new-session -d -s <tag>_ram_guard \
#     "bash -c 'while true; do /work/<project_dir>/chat/ram_guard.sh; sleep 20; done'"
# Снять после финала сборки: tmux kill-session -t <tag>_ram_guard
#
# Документация: /work/settings/docs/HOW_TO_RUN.md §8.9

# ====== НАСТРОЙКИ ======
PROJECT_DIR='/work/<project_dir>'
PROJECT_TAG='<project_tag>'        # префикс pid-файлов sub-агентов: /tmp/<tag>_T*.pid
PAUSE_KB=400000                    # MemAvailable (KB) ниже → пауза своих sub-агентов
RESUME_KB=800000                   # выше → возобновить (гистерезис, чтоб не дёргать)
# =======================

LOG="$PROJECT_DIR/chat/ram_guard.log"
STATE="/tmp/${PROJECT_TAG}_ram_paused"

avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)

# собрать свои живые sub-агент-ГРУППЫ (pid-файл = PID runner'а = PGID, запущен через setsid)
pgids=""
for pf in /tmp/${PROJECT_TAG}_T*.pid; do
  [ -f "$pf" ] || continue
  p=$(cat "$pf" 2>/dev/null)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && pgids="$pgids $p"
done
[ -z "$pgids" ] && { rm -f "$STATE"; exit 0; }

if [ "$avail" -lt "$PAUSE_KB" ] && [ ! -f "$STATE" ]; then
  for g in $pgids; do kill -STOP -- -"$g" 2>/dev/null; done
  touch "$STATE"
  echo "[$(date '+%F %T')] LOW avail=${avail}KB → STOP my sub-agents:$pgids" >> "$LOG"
elif [ "$avail" -gt "$RESUME_KB" ] && [ -f "$STATE" ]; then
  for g in $pgids; do kill -CONT -- -"$g" 2>/dev/null; done
  rm -f "$STATE"
  echo "[$(date '+%F %T')] OK  avail=${avail}KB → CONT my sub-agents:$pgids" >> "$LOG"
fi
exit 0
