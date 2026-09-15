#!/bin/bash
# ============================================================================
# DEADLINE STOPPER — жёсткий стоп всей оркестратор-сборки по таймеру.
# Шаблон по кейсу projecte 2026-06-10 (юзер: «тормоз — через 5 часов прекратить»).
# Подробно: HOW_TO_RUN.md §9.11.
#
# ЗАПУСК (от ROOT, в своём tmux, ДО или сразу после launcher'а оркестратора):
#   cp /work/settings/claude/deadline_stopper.template.sh /work/<proj>/chat/deadline_stopper.sh
#   # заполнить НАСТРОЙКИ ниже, затем:
#   chmod +x /work/<proj>/chat/deadline_stopper.sh
#   tmux new-session -d -s <TAG>_deadline '/work/<proj>/chat/deadline_stopper.sh'
#
# ЧТО ДЕЛАЕТ в момент дедлайна (порядок важен — сначала обезглавить воскрешателей!):
#   1) сентинел chat/DEADLINE_STOP — launcher и watchdog после него отказываются
#      перезапускать ЧТО-ЛИБО (оба должны иметь проверку сентинела, см. §9.11);
#   2) снимает A-watchdog из cron, убивает B-loop и ram_guard (свои tmux-сессии);
#   3) грейс-килл СВОИХ саб-агентов по /tmp/<TAG>_*.pid — по группе процессов
#      (runner стартует через setsid → PID=PGID): TERM, ждать ≤30с, потом KILL;
#   4) убивает tmux-сессию оркестратора (от agentuser);
#   5) TG-пинг юзеру с честным статусом.
#
# 🔴 ЧУЖОЕ НЕ ТРОГАТЬ: на машине могут жить соседние оркестраторы (orv_* и т.п.).
# Все kill'ы — ТОЛЬКО по своим <TAG>_* сущностям (tmux-имена с '=' exact-match,
# pid-файлы только своего тэга). Никаких pkill claude / kill по имени процесса!
#
# САМОСНЯТИЕ: если до дедлайна все таски в progress.md уже [x] — сборка финишировала
# сама, стоппер выходит без действий.
unset TMUX TMUX_PANE TERM
export LC_ALL=C.utf8 LANG=C.utf8

# ====== НАСТРОЙКИ — поправь под проект ======
DEADLINE_TS='<unix_ts>'            # момент стопа: `date -d '+5 hours' +%s`. В комменте — человекочитаемо!
PROJECT_DIR='/work/<project_dir>'
TAG='<project_tag>'                # тот же тэг, что в runner.sh / pid-файлах, e.g. 'insc'
ORCH_SESSION='<orchestrator_tmux>' # e.g. insc_orchestrator
ORCH_USER=agentuser
CHAT_ID=YOUR_TELEGRAM_CHAT_ID
# ============================================

SENTINEL=$PROJECT_DIR/chat/DEADLINE_STOP
LOG=$PROJECT_DIR/chat/deadline_stopper.log
TG="python3 /work/tg/bot.py send $CHAT_ID"

exec >> "$LOG" 2>&1
echo "[$(date '+%F %T')] deadline stopper armed: fire at $(date -d @$DEADLINE_TS '+%F %T')"

# Ждём дедлайн. Просыпаемся раз в минуту и сравниваем С АБСОЛЮТНЫМ timestamp'ом —
# один длинный `sleep 18000` НЕЛЬЗЯ: гибернация WSL замораживает sleep и стоппер
# сработал бы на часы позже.
while [ "$(date +%s)" -lt "$DEADLINE_TS" ]; do
  if ! grep -qE '^- \[( |~)\]' "$PROJECT_DIR/chat/orchestrator_progress.md" 2>/dev/null; then
    echo "[$(date '+%F %T')] все таски [x] до дедлайна — стоппер снимается без действий"
    exit 0
  fi
  sleep 60
done

echo "[$(date '+%F %T')] DEADLINE — останавливаю сборку $TAG"
date '+%F %T' > "$SENTINEL"

# 1. Обезглавить воскрешателей: cron-A, B-loop, ram_guard
crontab -l 2>/dev/null | grep -v orchestrator_watchdog | crontab -
tmux kill-session -t "=${TAG}_watchdog_loop" 2>/dev/null
tmux kill-session -t "=${TAG}_ram_guard" 2>/dev/null
rm -rf /tmp/${TAG}_watchdog_state

# 2. Грейс-килл своих саб-агентов (группы по pid-файлам своего тэга)
for pf in /tmp/${TAG}_*.pid; do
  [ -f "$pf" ] || continue
  p=$(cat "$pf" 2>/dev/null)
  [ -n "$p" ] || continue
  if kill -0 "$p" 2>/dev/null; then
    echo "[$(date '+%F %T')] TERM group -$p ($pf)"
    kill -TERM -- -"$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
  fi
done
for i in $(seq 1 30); do
  alive=0
  for pf in /tmp/${TAG}_*.pid; do
    [ -f "$pf" ] || continue
    p=$(cat "$pf" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive=1
  done
  [ "$alive" -eq 0 ] && break
  sleep 1
done
for pf in /tmp/${TAG}_*.pid; do
  [ -f "$pf" ] || continue
  p=$(cat "$pf" 2>/dev/null)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { echo "KILL group -$p"; kill -9 -- -"$p" 2>/dev/null || kill -9 "$p" 2>/dev/null; }
done

# 3. Убить оркестратор-tmux (он живёт на сокете agentuser)
runuser -u "$ORCH_USER" -- tmux kill-session -t "=${ORCH_SESSION}" 2>/dev/null

# 4. Итоговый пинг (поправь grep-паттерн под ID тасков своей волны)
DONE_N=$(grep -cE '^- \[x\]' "$PROJECT_DIR/chat/orchestrator_progress.md" 2>/dev/null)
[ -z "$DONE_N" ] && DONE_N=0
$TG "⏰ $TAG: дедлайн — сборка остановлена стоппером. Тасков [x]: ${DONE_N}. Прогресс: chat/orchestrator_progress.md." 2>&1 | tail -1
echo "[$(date '+%F %T')] стоп выполнен. Выход."
exit 0
