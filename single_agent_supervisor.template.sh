#!/bin/bash
# Supervisor для ОДИНОЧНОГО claude -p агента (без tmux-оркестратора).
# Включает защиту от API-stall и от ситуации, когда первый jsonl не появился:
# раньше ветка else крутила
#   «jsonl ещё не появился» БЕЗ таймаута → агент, зависший/застопленный ДО первого
#   jsonl (напр. ram_guard SIGSTOP отдал RAM соседу), держал supervisor в вечном
#   Теперь: нет jsonl дольше NO_JSONL_LIMIT (=STALL_LIMIT) → kill+respawn.
#   + kill_sub делает SIGCONT (по группе) перед TERM, иначе на STOP-процесс TERM не дойдёт.)
#
# ЧЕМ ОТЛИЧАЕТСЯ ОТ single_agent_watchdog.template.sh:
#   watchdog = НАБЛЮДАТЕЛЬ. Только ПИНГУЕТ в TG (death / API-retry / стагнация output.log).
#             Сам НИЧЕГО не перезапускает. Стагнацию ловит по output.log, который в режиме
#             `-p` пуст до самого конца → реальный API-stall watchdog НЕ видит (output.log=0
#             и при здоровой работе, и при зависании — неразличимо). Порог 45 мин, только пинг.
#   supervisor = АКТИВНЫЙ НАДЗИРАТЕЛЬ. Детектит зависание по РОСТУ JSONL-сессии (он растёт
#             стримингом каждые секунды при живой работе; не растёт N минут = turn завис),
#             САМ убивает зависший агент по PID, переподнимает стек (если нужен) и РЕСПАВНИТ.
#   🔴 ВНИМАНИЕ: повторяющееся «SUB_PID DEAD без отчёта» каждые ~N мин (не OOM/не stall) =
#     обычно АГЕНТ САМ УСТУПАЕТ ХОД в -p (фон/ScheduleWakeup + «жду переинвока»). Респавн НЕ лечит —
#     правится в таск-файле: длинные операции = детач+блокирующий поллинг В ТОМ ЖЕ ходе. README.md
#             Выходит при успехе (появился report) или при исчерпании лимита respawn.
#
# КОГДА НУЖЕН SUPERVISOR (а не watchdog):
#   - Длинные (десятки минут) одиночные таски, где API-turn периодически виснет
#     (PID жив, jsonl не растёт, соединение к API повисло без ответа и не таймаутит).
#   - Таск с внешним стеком (VNC/CDP/headless-chromium), который может отвалиться и его
#     надо переподнять перед respawn.
#   - Любой случай, где ты НЕ хочешь сидеть в петле сам и дёргать агента руками.
# Для короткого изолированного таска (<10 мин) достаточно watchdog'а — supervisor избыточен.
#
# 🔴🔴 ЭТОТ ШАБЛОН — ДЛЯ ОДИНОЧНОГО АГЕНТА. Stall-детект ниже (newest_jsonl) следит за jsonl ОДНОЙ
#    сессии — это верно, когда агент один. ЕСЛИ supervisor стережёт ОРКЕСТРАТОР (который сам спавнит
#    саб-агентов) — НЕЛЬЗЯ следить за jsonl оркестратора: он ЛЕГИТИМНО молчит, пока ждёт долгий саб-агент,
#    и ты зря убьёшь+перезапустишь оркестратор.
#    Для оркестратора: stall = возраст НОВЕЙШЕГО jsonl во ВСЁМ каталоге (NEWEST=$(ls -t $JSONL_DIR/*.jsonl|head -1)),
#    порог 900с, и kill только PID оркестратора (потомок pane'а tmux), не pkill. Готовый —
#    /work/<project>/orch/orchestrator_supervisor.sh.
#
# ⚠️ Полноценный §9-оркестратор (интерактивный claude в tmux) для ОДНОГО таска НЕ помогает:
#    он сам подвержен тем же API-зависаниям. Supervisor — внешний (bash от root), потому надёжнее.
#
# 🔴 БЕЗОПАСНОСТЬ: убивает ТОЛЬКО свой SUB_PID из PID-файла (grace TERM→KILL).
#    НИКОГДА не делает pkill -f claude / chrome (у юзера бывают параллельные сессии).
#    Стек гасит/поднимает только через свой STACK_UP_CMD (по PID/идемпотентно).
#    🔴 Если на машине второй оркестратор (общие SOCKS/VNC/другие singleton-ресурсы) —
#    оркестратор должен поднимать стек со своим портом и ставить
#    guard перед VNC-таском (СТОП+пинг, а не клоббер чужого Xvfb/туннеля).
#
# Запускать ОТ ROOT в tmux:
#   tmux new-session -d -s <TASK_ID>_sup -c /work/<project> \
#     "bash /tmp/<TASK_ID>_supervisor.sh"
#
# ЗАВИСИМОСТИ (готовятся ДО запуска, как для watchdog — см. README.md):
#   - /tmp/<TASK_ID>_launch.sh   — launcher с PID-capture (echo $$ > pidfile; exec claude -p ...)
#   - /tmp/<TASK_ID>_prompt.txt  — prompt (preamble + таск)
#   - лог chat/<TASK_ID>_output.log  — chown для AGENT_USER, chmod 666
#   - таск-файл должен в КОНЦЕ писать report (REPORT) — это сигнал ФИНИША, и ПОСЛЕДНЕЙ
#     строкой в нём статус:  STATUS: SUCCESS | FAIL | BLOCKED | PARTIAL  (успех ≠ факт файла; см. ниже).

set -u
unset TMUX TMUX_PANE TERM
export LC_ALL=C.utf8 LANG=C.utf8   # bot.py ждёт UTF-8 (иначе TG 400)

# ====== НАСТРОЙКИ — заполнить под таск ======
TASK="T-EXAMPLE"                               # ← короткий ID таска (sed заменит на твой)
PROJECT="<project>"                             # ← замени placeholder; кавычки обязательны для <>
PROJ_DIR=/work/$PROJECT
AGENT_USER="${AGENT_USER:-agent}"
AGENT_HOME="${AGENT_HOME:-/home/$AGENT_USER}"
PID_FILE=/tmp/${TASK}.pid                       # PID-файл от launcher'а
LAUNCHER=/tmp/${TASK}_launch.sh                 # launcher с PID-capture
LOG=$PROJ_DIR/chat/${TASK}_output.log           # output -p агента
REPORT=$PROJ_DIR/chat/report_${TASK}.md         # отчёт агента = сигнал ФИНИША (НЕ успеха!)
# 🔴 ДОСТОВЕРНОСТЬ: успех определяется СТАТУС-строкой ВНУТРИ отчёта, а НЕ фактом его существования.
#    Честный отчёт о провале/блокере тоже создаёт этот файл — но это НЕ успех, и ✅ слать НЕЛЬЗЯ.
#    Таск-файл ОБЯЗАН в самом конце отчёта писать одну строку:  STATUS: SUCCESS | FAIL | BLOCKED | PARTIAL
STATUS_RE='^[[:space:]]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)'  # каноническая статус-строка отчёта
LEGACY_SUCCESS_RE='МАРКЕР УСПЕХА'   # обратная совместимость: старая конвенция (пишется ТОЛЬКО на успех). Пусто = выкл.
JSONL_DIR="$AGENT_HOME/.claude/projects/-work-$PROJECT" # Claude-сессии (слэши пути → дефисы)
SUPLOG=$PROJ_DIR/chat/${TASK}_supervisor.log    # heartbeat-лог супервизора
CHAT_ID="${CHAT_ID:-000000000}"                               # TG юзера

# Стек (VNC/CDP/headless). Если таску внешний стек НЕ нужен — оставь STACK_CHECK_URL пустым,
# тогда ensure_stack() станет no-op.
STACK_UP_CMD="bash $PROJ_DIR/scripts/vnc_admin.sh up"   # идемпотентный подъём стека от root
STACK_CHECK_URL="http://127.0.0.1:9335/json/version"     # health-check (пусто = стек не нужен)

# Лимиты (обычно норм по умолчанию):
MAX_RESPAWN=5        # максимум перезапусков агента (death + stall суммарно)
STALL_LIMIT=420      # сек без роста jsonl = завис на API-turn (7 мин; жив-но-молчит > этого → kill+respawn)
POLL=45              # период опроса супервизора
# ============================================
# Лимит ожидания ПЕРВОГО jsonl после старта (агент жив, но jsonl ещё ни разу не создан).
# Наследует STALL_LIMIT (оркестратор sed'ит только STALL_LIMIT) — отдельно можно задать в env.
NO_JSONL_LIMIT=${NO_JSONL_LIMIT:-$STALL_LIMIT}
PAUSE_FLAG=/tmp/ram_paused   # global_ram_guard держит агента в SIGSTOP → тишина jsonl ОЖИДАЕМА, не столл (§8.9/§12.4)

# 5-часовой / session-лимит Claude: при его срабатывании claude -p ВЫХОДИТ с сообщением о лимите в output-логе.
# Тогда НЕ тратим respawn — ждём сброса и сами перезапускаемся ЦИКЛОМ, пока квота не вернётся (handle_rate_limit ниже).
# 🔴 Маркеры лимита ОБЯЗАНЫ покрывать и формат «You've hit your session limit · resets 7:30pm»:
#    этот текст НЕ попал под старый RL_RE → супервизор сделал respawn вместо ожидания и умер с FATAL).
# 🔴 Узкий формат по-прежнему ловит «hit your session limit · resets 7:30pm», но БЕЗ
# широких токенов/прозы — иначе ложный RL на собственном тексте агента и вечная 25-мин пауза/перезапуск.
RL_RE='hit your (session|usage|5.?hour|weekly) limit|limit will reset|resets? (at )?[0-9]{1,2}(:[0-9]{2})? ?(am|pm)|usage limit reached'
RL_WAIT=${RL_WAIT:-1500}   # пауза между попытками при лимите (25 мин); цикл до возврата квоты (cap 24× ≈ 10ч)
rl_respawns=0

TG="python3 /work/tg/bot.py send $CHAT_ID"
exec >> "$SUPLOG" 2>&1
log(){ echo "[$(date '+%F %T')] $*"; }

respawn_count=0
LAUNCH_TS=0
SUB_PID=""

ensure_stack(){
  [ -z "$STACK_CHECK_URL" ] && return 0
  if ! curl -s -m5 "$STACK_CHECK_URL" >/dev/null 2>&1; then
    log "стек down → переподнимаю: $STACK_UP_CMD"
    $STACK_UP_CMD >/dev/null 2>&1
    for i in $(seq 1 8); do curl -s -m4 "$STACK_CHECK_URL" >/dev/null 2>&1 && break; sleep 4; done
  fi
}

launch_agent(){
  ensure_stack
  rm -f "$PID_FILE"
  : > "$LOG" 2>/dev/null
  LAUNCH_TS=$(date +%s)
  setsid runuser -u "$AGENT_USER" -- env -i \
    HOME="$AGENT_HOME" \
    PATH="$AGENT_HOME/.local/bin:$AGENT_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
    SHELL=/bin/bash \
    bash "$LAUNCHER" </dev/null >/dev/null 2>&1 &
  sleep 8
  SUB_PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$SUB_PID" ] && kill -0 "$SUB_PID" 2>/dev/null; then
    log "launched SUB_PID=$SUB_PID (respawn #$respawn_count)"
    return 0
  fi
  log "FATAL: launch не дал живого PID"
  return 1
}

# свежий jsonl этой сессии (создан/изменён после старта агента)
newest_jsonl(){
  find "$JSONL_DIR" -maxdepth 1 -name '*.jsonl' -newermt "@$((LAUNCH_TS-5))" 2>/dev/null \
    | xargs -r ls -t 2>/dev/null | head -1
}

# grace-kill ТОЛЬКО нашего SUB_PID
kill_sub(){
  # агент мог быть в SIGSTOP (ram_guard отдал RAM соседу) — будим группу, иначе TERM не дойдёт.
  # SUB_PID запущен через setsid (PID=PGID), -PID = вся группа = наша и только наша.
  kill -CONT -- -"$SUB_PID" 2>/dev/null; kill -CONT "$SUB_PID" 2>/dev/null
  kill -TERM "$SUB_PID" 2>/dev/null
  for i in $(seq 1 12); do kill -0 "$SUB_PID" 2>/dev/null || break; sleep 1; done
  kill -0 "$SUB_PID" 2>/dev/null && kill -9 "$SUB_PID" 2>/dev/null
  sleep 2
}

over_limit(){
  if [ "$respawn_count" -gt "$MAX_RESPAWN" ]; then
    log "respawn-лимит ($MAX_RESPAWN) исчерпан. Стоп."
    $TG "❌ $TASK: $MAX_RESPAWN respawn-ов исчерпано, агент не доходит до отчёта. Нужна ручная диагностика. Лог: chat/${TASK}_supervisor.log"
    exit 1
  fi
}

# Маркер лимита Claude в output-логе агента?
rate_limited(){ tail -n 60 "$LOG" 2>/dev/null | grep -aiE "$RL_RE" | tail -1; }  # Только свежий хвост, чтобы проза ранних строк не давала ложный RL.
# Упёрлись в лимит (5ч/session): ждём сброса и перезапуск БЕЗ расхода respawn_count, ЦИКЛОМ до возврата квоты
# Одного RL_WAIT может быть недостаточно для многочасового сброса. Возврат 0 = лимит обработан.
handle_rate_limit(){
  local rl; rl="$(rate_limited)"; [ -z "$rl" ] && return 1
  local tries=0
  while :; do
    rl_respawns=$((rl_respawns+1)); tries=$((tries+1))
    log "RATE-LIMIT (#$rl_respawns, try $tries): «$rl» → жду ${RL_WAIT}s и перезапуск БЕЗ счётчика respawn"
    $TG "⏳ $TASK: лимит Claude (5ч). Жду сброса, сам перезапущусь через ~$((RL_WAIT/60)) мин (попытка #$rl_respawns)."
    sleep "$RL_WAIT"
    launch_agent && return 0
    rl="$(rate_limited)"
    [ -z "$rl" ] && { $TG "❌ $TASK: перезапуск после лимита не стартовал (уже не лимит)"; exit 1; }
    [ "$tries" -ge 24 ] && { $TG "❌ $TASK: лимит держится слишком долго (${tries}×${RL_WAIT}s), остановка"; exit 1; }
  done
}

# Достоверная оценка отчёта: ФИНИШ агента ≠ УСПЕХ. Возвращает SUCCESS|FAIL|BLOCKED|PARTIAL|AMBIGUOUS.
report_status(){
  local st
  st=$(grep -aoiE "$STATUS_RE" "$REPORT" 2>/dev/null | tail -1 \
       | grep -aoiE 'SUCCESS|FAIL|BLOCKED|PARTIAL' | head -1 | tr '[:lower:]' '[:upper:]')
  if [ -z "$st" ] && [ -n "$LEGACY_SUCCESS_RE" ] && grep -qaE "$LEGACY_SUCCESS_RE" "$REPORT" 2>/dev/null; then
    st=SUCCESS
  fi
  echo "${st:-AMBIGUOUS}"
}

# Завершить supervisor по СОДЕРЖИМОМУ отчёта (вызывать, когда $REPORT уже существует).
# ✅ + exit 0 — ТОЛЬКО при STATUS=SUCCESS; иначе ⚠️ + exit 2/3 — чтобы не плодить недостоверные «успехи».
finish_on_report(){
  sleep 2   # дать агенту дописать STATUS-строку (flush-race)
  local sz st; sz=$(wc -c < "$REPORT" 2>/dev/null); st=$(report_status)
  case "$st" in
    SUCCESS)
      log "SUCCESS: отчёт есть, STATUS=SUCCESS (${sz}b). Выход 0."
      $TG "✅ $TASK: УСПЕХ — отчёт готов ($sz b). chat/report_${TASK}.md"
      exit 0 ;;
    FAIL|BLOCKED|PARTIAL)
      log "DONE-NOT-SUCCESS: отчёт есть, STATUS=$st (${sz}b) — НЕ успех, ✅ НЕ шлю. Выход 2."
      $TG "⚠️ $TASK: агент завершился, СТАТУС=$st (НЕ успех). Нужен разбор: chat/report_${TASK}.md"
      exit 2 ;;
    *)
      log "AMBIGUOUS: отчёт есть, но НЕТ строки STATUS: (${sz}b) — достоверность не подтверждена. Выход 3."
      $TG "⚠️ $TASK: отчёт есть, но без строки 'STATUS: SUCCESS|FAIL|BLOCKED' — достоверность НЕ подтверждена, проверь вручную: chat/report_${TASK}.md"
      exit 3 ;;
  esac
}

# ── первый запуск ──
launch_agent || { $TG "❌ $TASK supervisor: не смог запустить агента"; exit 1; }
log "supervisor PID $$ tracking $TASK, max_respawn=$MAX_RESPAWN, stall=${STALL_LIMIT}s"

while true; do
  sleep $POLL

  # 1. ФИНИШ — отчёт появился. УСПЕХ определяем по СТАТУС-строке внутри, а НЕ по факту файла.
  if [ -f "$REPORT" ]; then
    finish_on_report
  fi

  # 2. PID жив?
  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    sleep 4
    if [ -f "$REPORT" ]; then
      log "PID мёртв, но отчёт появился (flush-race) — оцениваю по СТАТУС-строке."
      finish_on_report
    fi
    log "SUB_PID $SUB_PID DEAD без отчёта"
    if handle_rate_limit; then continue; fi   # лимит Claude (5ч/session) — ждём сброса и сам перезапуск без счётчика respawn
    respawn_count=$((respawn_count+1)); over_limit
    $TG "♻️ $TASK: агент умер → respawn $respawn_count/$MAX_RESPAWN"
    launch_agent || { $TG "❌ $TASK: respawn не стартовал"; exit 1; }
    continue
  fi

  # 2b. RAM-сторож держит агента в SIGSTOP — тишина jsonl ОЖИДАЕМА (§8.9/§12.4). Пропускаем stall-детект,
  #     иначе убьём+перезапустим здоровый агент во время законной RAM-паузы.
  if [ -f "$PAUSE_FLAG" ]; then
    log "alive PID=$SUB_PID — RAM-сторож на ПАУЗЕ (stall-детект пропущен) respawns=$respawn_count"
    continue
  fi

  # 3. STALL-детект: растёт ли jsonl? (главная фишка supervisor'а)
  J=$(newest_jsonl)
  if [ -n "$J" ] && [ -f "$J" ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$J") ))
    if [ "$AGE" -ge "$STALL_LIMIT" ]; then
      log "STALL: jsonl ${J##*/} не растёт ${AGE}s (≥$STALL_LIMIT). PID $SUB_PID жив но завис на API-turn. Kill+respawn."
      kill_sub
      if handle_rate_limit; then continue; fi   # завис на лимите Claude — ждём сброса без счётчика respawn
      respawn_count=$((respawn_count+1))
      over_limit
      $TG "♻️ $TASK: завис на API (jsonl тих ${AGE}s) → kill+respawn $respawn_count/$MAX_RESPAWN"
      launch_agent || { $TG "❌ $TASK: respawn не стартовал"; exit 1; }
      continue
    fi
    log "alive PID=$SUB_PID jsonl=${J##*/} age=${AGE}s respawns=$respawn_count"
  else
    # jsonl так и НЕ появился. Раньше тут НЕ было таймаута → агент, зависший на старте
    # (напр. ram_guard SIGSTOP'нул его до первого jsonl), держал supervisor в вечном
    # цикле без бесконечного «jsonl ещё не появился».
    # Фикс: ограничиваем ожидание первого jsonl лимитом → нет jsonl дольше
    # NO_JSONL_LIMIT → kill+respawn. LAUNCH_TS сбрасывается в launch_agent, окно — на respawn.
    NOJSONL_AGE=$(( $(date +%s) - LAUNCH_TS ))
    if [ "$NOJSONL_AGE" -ge "$NO_JSONL_LIMIT" ]; then
      log "NO-JSONL-STALL: jsonl не появился за ${NOJSONL_AGE}s (≥$NO_JSONL_LIMIT) после старта. PID $SUB_PID завис на старте. Kill+respawn."
      kill_sub
      if handle_rate_limit; then continue; fi   # стартовый лимит Claude — ждём сброса без счётчика respawn
      respawn_count=$((respawn_count+1))
      over_limit
      $TG "♻️ $TASK: jsonl не появился ${NOJSONL_AGE}s (завис на старте) → kill+respawn $respawn_count/$MAX_RESPAWN"
      launch_agent || { $TG "❌ $TASK: respawn не стартовал"; exit 1; }
      continue
    fi
    log "alive PID=$SUB_PID (jsonl ещё не появился, ${NOJSONL_AGE}s/${NO_JSONL_LIMIT}s) respawns=$respawn_count"
  fi
done
