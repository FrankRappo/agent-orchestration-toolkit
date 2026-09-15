#!/bin/bash
# ============================================================================
# QUEUE-СТОРОЖ — запуск ВТОРОГО оркестратора после ФИНАЛА первого.
# Шаблон по кейсу projectd FBX за projectb projectb2_queue (2026-06-12).
# Боевой пример: /work/projectc/orch/scripts/queue_after_projectb.sh
# Подробно: HOW_TO_RUN.md §12.
#
# ЗАЧЕМ: на машине нельзя два оркестратора разом (RAM/синглтоны, §8.7/8.9), а
# юзер хочет «волна B стартует, когда волна A закончится». Дописать это в промпт
# оркестратора A НЕЛЬЗЯ (он чужой/уже бежит), cron — груб. Нужен внешний
# сторож-скрипт от root в СВОЁМ tmux, который наблюдает финал A и стартует B.
#
# СИГНАЛ ФИНАЛА ПЕРВОГО = смерть его tmux-сессии (очередь/оркестратор умирает
# вместе с pane-командой). НЕ progress.md (оркестратор мог не дописать),
# НЕ pid-файлы (бывают stale/отсутствуют при живом процессе, §9.10.2).
#
# ЗАПУСК (от ROOT, ПОСЛЕ того как все артефакты волны B созданы, но НИЧЕГО из B
# ещё не запущено):
#   cp /work/settings/claude/queue_next_orchestrator.template.sh /work/<PROJECT_B>/orch/scripts/queue_after_<A>.sh
#   # заполнить НАСТРОЙКИ, chmod +x, затем:
#   tmux new-session -d -s <TAG_B>_qwait "bash /work/<PROJECT_B>/orch/scripts/queue_after_<A>.sh"
#   sleep 3 && tail -2 <LOG>   # verify: строка "armed"
#
# 🔴 ЧУЖОЕ НЕ ТРОГАТЬ: сторож ТОЛЬКО наблюдает сессии/процессы волны A.
#    Никаких kill/pkill по чужим сущностям. Все свои имена — с тэгом волны B,
#    и НЕ префиксы друг друга (§8.8; tmux -t без '=' матчит по префиксу!).
set -u
unset TMUX TMUX_PANE TERM
export LC_ALL=C.utf8 LANG=C.utf8

# ====== НАСТРОЙКИ — поправь под свои волны ======
FIRST_SESSION='projectb2_queue'        # tmux-сессия первого оркестратора/очереди (EXACT имя)
FIRST_TAIL_SESSIONS='^T-.*_sup:'   # ERE: per-task supervisor'ы волны A в `tmux ls` (пусто = не ждать)
FIRST_AGENT_MARK='projectb'       # подстрока argv claude-агентов волны A (пусто = не ждать)
TAIL_CAP_TICKS=240                 # cap ожидания хвостов, тиков по 60с (240 = 4ч), потом идём дальше
RAM_MIN_KB=1500000                 # гейт MemAvailable перед стартом B
LOG='/work/<PROJECT_B>/orch/logs/<TAG_B>_queue_wait.log'            # кавычки: голые <> = bash-редирект
ALL_DONE_B='/work/<PROJECT_B>/orch/reports/ALL_DONE_<WAVE_B>'      # сентинел готовности B (RE-check)
SUP_SESSION_B='<TAG_B>_sup'         # tmux supervisor'а волны B
SUP_B='/work/<PROJECT_B>/orch/orchestrator_supervisor_<waveB>.sh'
RAM_GUARD_SESSION_B='<TAG_B>_ram_guard'   # пусто = без RAM-сторожа
RAM_GUARD_B='/work/<PROJECT_B>/orch/scripts/ram_guard_<waveB>.sh'
CHAT_ID=YOUR_TELEGRAM_CHAT_ID
START_MSG='⏱️ Волна A финишировала → стартую волну B.'
# ================================================

TG="python3 /work/tg/bot.py send $CHAT_ID"
mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1
log(){ echo "[$(date '+%F %T')] $*"; }

log "=== qwait PID $$ armed: жду конца tmux =$FIRST_SESSION (тик 120с) ==="

# 1. Конец первого: его tmux-сессия умерла (exact-match '=', НЕ префикс!).
#    Тики, не один длинный sleep — гибернация WSL замораживает sleep (§9.11).
while tmux has-session -t "=$FIRST_SESSION" 2>/dev/null; do sleep 120; done
log "$FIRST_SESSION завершилась"

# 2. Хвосты волны A: per-task supervisor'ы могли пережить очередь (respawn'ят
#    агентов!) + сами claude-агенты A могли быть setsid-detached. Ждём с cap'ом.
#    pgrep self-match (§8.5) тут не грозит: наш argv не содержит 'claude'.
for i in $(seq 1 "$TAIL_CAP_TICKS"); do
  LEFT=0; AGENTS=0
  [ -n "$FIRST_TAIL_SESSIONS" ] && LEFT=$(tmux ls 2>/dev/null | grep -cE "$FIRST_TAIL_SESSIONS")
  [ -n "$FIRST_AGENT_MARK" ] && AGENTS=$(pgrep -af 'claude' 2>/dev/null | grep -c "$FIRST_AGENT_MARK")
  [ "$LEFT" -eq 0 ] && [ "$AGENTS" -eq 0 ] && break
  log "хвосты A: sup-сессий=$LEFT агентов=$AGENTS — жду"
  sleep 60
done
log "волна A полностью затихла (или cap)"

# 3. RAM-гейт
while :; do
  avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  [ "$avail" -ge "$RAM_MIN_KB" ] && break
  log "RAM available=${avail}KB < ${RAM_MIN_KB}KB — жду 120с"
  sleep 120
done
sleep 30   # дать системе осесть

# 4. RE-check идемпотентности (сторож могли перезапустить / B уже стартовала иначе)
if [ -f "$ALL_DONE_B" ]; then log "ALL_DONE B уже есть — нечего запускать"; exit 0; fi
if tmux has-session -t "=$SUP_SESSION_B" 2>/dev/null; then log "$SUP_SESSION_B уже жив — не дублирую"; exit 0; fi

# 5. Старт волны B: supervisor (он сам поднимет оркестратор через свой launcher) + RAM-сторож
log "стартую B: tmux $SUP_SESSION_B${RAM_GUARD_SESSION_B:+ + $RAM_GUARD_SESSION_B}"
tmux new-session -d -s "$SUP_SESSION_B" -c "$(dirname "$(dirname "$SUP_B")")" "bash $SUP_B"
if [ -n "$RAM_GUARD_SESSION_B" ]; then
  tmux has-session -t "=$RAM_GUARD_SESSION_B" 2>/dev/null || \
    tmux new-session -d -s "$RAM_GUARD_SESSION_B" "bash -c 'while true; do bash $RAM_GUARD_B; sleep 20; done'"
fi
$TG "$START_MSG" 2>&1 | tail -1
log "qwait выходит"
exit 0
