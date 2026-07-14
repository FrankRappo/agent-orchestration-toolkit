#!/bin/bash
# wave_supervisor.sh — параметризованный supervisor одиночного claude -p агента.
# Параметризованный supervisor переживает смерть агента и jsonl-stall:
#   • respawn по смерти агента и по jsonl-stall (turn завис на API);
#   🔴 ВНИМАНИЕ: повторяющееся «SUB_PID DEAD без отчёта» каждые ~N мин (не OOM/не stall) =
#     чаще всего АГЕНТ САМ УСТУПАЕТ ХОД в -p (запустил фон/ScheduleWakeup и «ждёт переинвока»).
#     Респавн это НЕ лечит (новый агент так же уступит) — правится ТОЛЬКО в таск-файле:
#     длинные операции = детач на сервере + блокирующий поллинг В ТОМ ЖЕ ходе. См. README.md
#   • 🔴 5-ЧАСОВОЙ ЛИМИТ Claude: при маркере лимита НЕ тратим respawn — ждём RL_WAIT и
#     перезапускаемся сами, пока квота не вернётся;
#   • выход по строке STATUS: в отчёте (ФИНИШ != УСПЕХ; успех — только STATUS: SUCCESS).
#
# Конфиг передаётся через окружение:
#   TASK PROJ_DIR TASK_FILE PID_FILE LOG REPORT JSONL_DIR  (+ опц. MAX_RESPAWN STALL_LIMIT RL_WAIT CHAT_ID)
#
# Запуск (root, в tmux): tmux new-session -d -s <TASK>_sup -c "$PROJ_DIR" \
#   "TASK=.. PROJ_DIR=.. TASK_FILE=.. PID_FILE=.. LOG=.. REPORT=.. JSONL_DIR=.. bash /work/<project>/chat/wave_supervisor.sh"
set -u
unset TMUX TMUX_PANE TERM
export LC_ALL=C.utf8 LANG=C.utf8

# ====== конфиг из окружения ======
TASK="${TASK:?need TASK}"
PROJ_DIR="${PROJ_DIR:?need PROJ_DIR}"
TASK_FILE="${TASK_FILE:?need TASK_FILE}"
PID_FILE="${PID_FILE:?need PID_FILE}"
LOG="${LOG:?need LOG}"
REPORT="${REPORT:?need REPORT}"          # сигнал ФИНИША (внутри — строка STATUS:)
JSONL_DIR="${JSONL_DIR:?need JSONL_DIR}"  # каталог jsonl агента для stall-детекта
AGENT_USER="${AGENT_USER:-agent}"
AGENT_HOME="${AGENT_HOME:-/home/$AGENT_USER}"
LAUNCHER="${LAUNCHER:-/work/settings/wave_launcher.template.sh}"
SUPLOG="${SUPLOG:-${LOG%.log}_supervisor.log}"
CHAT_ID="${CHAT_ID:-000000000}"
MAX_RESPAWN="${MAX_RESPAWN:-12}"
STALL_LIMIT="${STALL_LIMIT:-1500}"        # 25 мин без роста jsonl = завис на API-turn
POLL="${POLL:-45}"
NO_JSONL_LIMIT="${NO_JSONL_LIMIT:-$STALL_LIMIT}"
PAUSE_FLAG=/tmp/ram_paused
STATUS_RE='^[[:space:]]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)'
# 5-часовой лимит Claude — маркеры в выводе агента:
# 🔴 Узкий RL_RE ловит только настоящий harness-формат («You've hit your session limit · resets 7:30pm»),
# без широких токенов (rate limit/429/overloaded/проза), иначе ложный RL на тексте самого агента → вечная пауза.
RL_RE='hit your (session|usage|5.?hour|weekly) limit|limit will reset|resets? (at )?[0-9]{1,2}(:[0-9]{2})? ?(am|pm)|usage limit reached'
RL_WAIT="${RL_WAIT:-1500}"                # 25 мин между попытками при лимите
rl_respawns=0
# ==================================

TG="python3 /work/tg/bot.py send $CHAT_ID"
mkdir -p "$(dirname "$LOG")" "$(dirname "$REPORT")" 2>/dev/null
exec >> "$SUPLOG" 2>&1
log(){ echo "[$(date '+%F %T')] $*"; }
respawn_count=0; LAUNCH_TS=0; SUB_PID=""

launch_agent(){
  rm -f "$PID_FILE"; : > "$LOG" 2>/dev/null
  chown "$AGENT_USER:$AGENT_USER" "$LOG" 2>/dev/null; chmod 666 "$LOG" 2>/dev/null
  LAUNCH_TS=$(date +%s)
  setsid runuser -u "$AGENT_USER" -- env -i \
    HOME="$AGENT_HOME" \
    PATH="$AGENT_HOME/.local/bin:$AGENT_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
    SHELL=/bin/bash \
    PROJECT_DIR="$PROJ_DIR" TASK_FILE="$TASK_FILE" PID_FILE="$PID_FILE" LOG="$LOG" \
    bash "$LAUNCHER" </dev/null >/dev/null 2>&1 &
  sleep 8
  SUB_PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$SUB_PID" ] && kill -0 "$SUB_PID" 2>/dev/null; then
    log "launched SUB_PID=$SUB_PID (respawn #$respawn_count)"; return 0
  fi
  log "FATAL: launch не дал живого PID"; return 1
}
newest_jsonl(){ find "$JSONL_DIR" -maxdepth 1 -name '*.jsonl' -newermt "@$((LAUNCH_TS-5))" 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1; }
kill_sub(){ kill -CONT -- -"$SUB_PID" 2>/dev/null; kill -CONT "$SUB_PID" 2>/dev/null; kill -TERM "$SUB_PID" 2>/dev/null; for i in $(seq 1 12); do kill -0 "$SUB_PID" 2>/dev/null || break; sleep 1; done; kill -0 "$SUB_PID" 2>/dev/null && kill -9 "$SUB_PID" 2>/dev/null; sleep 2; }
over_limit(){ if [ "$respawn_count" -gt "$MAX_RESPAWN" ]; then log "respawn-лимит исчерпан"; $TG "❌ $TASK: $MAX_RESPAWN respawn-ов исчерпано. $SUPLOG"; exit 1; fi }

rate_limited(){ tail -n 60 "$LOG" 2>/dev/null | grep -aiE "$RL_RE" | tail -1; }  # Сканируем только свежий хвост, чтобы избежать ложного RL.
# Лимит Claude (5ч): ждём сброса и перезапуск БЕЗ расхода respawn_count. Возврат 0 = это был лимит.
handle_rate_limit(){
  local rl; rl="$(rate_limited)"; [ -z "$rl" ] && return 1
  local tries=0
  while :; do
    rl_respawns=$((rl_respawns+1)); tries=$((tries+1))
    log "RATE-LIMIT (#$rl_respawns, try $tries): «$rl» → жду ${RL_WAIT}s и перезапуск БЕЗ счётчика respawn"
    $TG "⏳ $TASK: лимит Claude (5ч). Жду сброса, сам перезапущусь через ~$((RL_WAIT/60)) мин (попытка #$rl_respawns)." 2>&1 | tail -1
    sleep "$RL_WAIT"
    launch_agent && return 0
    rl="$(rate_limited)"
    [ -z "$rl" ] && { $TG "❌ $TASK: перезапуск после лимита не стартовал (уже не лимит)"; exit 1; }
    [ "$tries" -ge 24 ] && { $TG "❌ $TASK: лимит держится слишком долго (${tries}×${RL_WAIT}s), остановка"; exit 1; }
  done
}

report_status(){ grep -aoiE "$STATUS_RE" "$REPORT" 2>/dev/null | tail -1 | grep -aoiE 'SUCCESS|FAIL|BLOCKED|PARTIAL' | head -1 | tr '[:lower:]' '[:upper:]'; }
finish_on_report(){ sleep 2; local sz st; sz=$(wc -c < "$REPORT" 2>/dev/null); st=$(report_status); st="${st:-AMBIGUOUS}"; case "$st" in
    SUCCESS) log "SUCCESS: STATUS=SUCCESS (${sz}b). Выход 0."; $TG "✅ $TASK: УСПЕХ — отчёт готов ($sz b). $REPORT" 2>&1 | tail -1; exit 0 ;;
    FAIL|BLOCKED|PARTIAL) log "DONE-NOT-SUCCESS: STATUS=$st (${sz}b). Выход 2."; $TG "⚠️ $TASK: агент завершился, СТАТУС=$st (НЕ успех). Разбор: $REPORT" 2>&1 | tail -1; exit 2 ;;
    *) log "AMBIGUOUS: отчёт без STATUS-строки (${sz}b). Выход 3."; $TG "⚠️ $TASK: отчёт есть, но без строки 'STATUS:' — достоверность НЕ подтверждена: $REPORT" 2>&1 | tail -1; exit 3 ;;
  esac; }

# идемпотентность: если отчёт со STATUS уже есть — таск сделан, не запускаем агента
if [ -f "$REPORT" ] && [ -n "$(report_status)" ]; then
  log "REPORT уже со STATUS — $TASK уже сделан. Выход без запуска."; finish_on_report
fi

launch_agent || { $TG "❌ $TASK supervisor: не смог запустить агента"; exit 1; }
log "supervisor PID $$ tracking $TASK, max_respawn=$MAX_RESPAWN, stall=${STALL_LIMIT}s, RL_WAIT=${RL_WAIT}s"

while true; do
  sleep "$POLL"
  if [ -f "$REPORT" ]; then finish_on_report; fi
  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    sleep 4; [ -f "$REPORT" ] && finish_on_report
    if handle_rate_limit; then continue; fi   # лимит Claude — ждём сброса, без счётчика
    log "SUB_PID $SUB_PID DEAD без отчёта"; respawn_count=$((respawn_count+1)); over_limit
    $TG "♻️ $TASK: агент умер → respawn $respawn_count/$MAX_RESPAWN" 2>&1 | tail -1
    launch_agent || { $TG "❌ $TASK: respawn не стартовал"; exit 1; }; continue
  fi
  if [ -f "$PAUSE_FLAG" ]; then
    log "alive PID=$SUB_PID — RAM-сторож на ПАУЗЕ (stall-детект пропущен) respawns=$respawn_count"; continue
  fi
  J=$(newest_jsonl)
  if [ -n "$J" ] && [ -f "$J" ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$J") ))
    if [ "$AGE" -ge "$STALL_LIMIT" ]; then
      log "STALL: jsonl тих ${AGE}s → kill"; kill_sub
      if handle_rate_limit; then continue; fi   # завис на лимите — ждём сброса без счётчика
      respawn_count=$((respawn_count+1)); over_limit
      $TG "♻️ $TASK: завис (jsonl тих ${AGE}s) → respawn $respawn_count/$MAX_RESPAWN" 2>&1 | tail -1
      launch_agent || { $TG "❌ $TASK: respawn не стартовал"; exit 1; }; continue
    fi
    log "alive PID=$SUB_PID jsonl=${J##*/} age=${AGE}s respawns=$respawn_count"
  else
    NOJSONL_AGE=$(( $(date +%s) - LAUNCH_TS ))
    if [ "$NOJSONL_AGE" -ge "$NO_JSONL_LIMIT" ]; then
      log "NO-JSONL-STALL: jsonl не появился ${NOJSONL_AGE}s (≥$NO_JSONL_LIMIT) → kill"; kill_sub
      if handle_rate_limit; then continue; fi   # стартовый лимит — ждём сброса без счётчика
      respawn_count=$((respawn_count+1)); over_limit
      $TG "♻️ $TASK: jsonl не появился ${NOJSONL_AGE}s (завис на старте) → respawn $respawn_count/$MAX_RESPAWN" 2>&1 | tail -1
      launch_agent || { $TG "❌ $TASK: respawn не стартовал"; exit 1; }; continue
    fi
    log "alive PID=$SUB_PID (jsonl ещё нет, ${NOJSONL_AGE}s/${NO_JSONL_LIMIT}s) respawns=$respawn_count"
  fi
done
