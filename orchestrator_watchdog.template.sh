#!/bin/bash
# Watchdog оркестратора Claude — шаблон для копирования в проект.
# Включает sub-agent respawn после подтверждённого API-timeout.
# Включает API-retry detection и pstree zombie detection.
#
# Замени <project_dir> на путь к проекту (например /work/<project>) и положи как
# /work/<project_dir>/chat/orchestrator_watchdog.sh — потом chmod +x.
#
# Запускается:
#   - cron от root каждые 15 минут (A) (см. установку ниже)
#   - bash-loop в отдельной tmux от root каждые 5 минут (B) — страховка
#
# Документация: /work/settings/README.md
#   (+ §8.7 — guard на общие машинные ресурсы (SOCKS-порт / VNC / другие singleton-ресурсы),
#    КОГДА на машине крутится второй оркестратор: свой SOCKS_PORT + уникальное имя
#    SESSION с префиксом проекта (дефолтный 'orchestrator' у двух прогонов совпадёт!).)
#
# Что проверяет (в порядке выполнения):
#   1. progress.md существует — иначе оркестратор ещё не запускался.
#   2. Все таски ✅ → снимает себя из cron, kill B-loop, удаляет state-dir.
#   3. Tmux-сессия жива → если мертва, relaunch через launcher (TG-пинг).
#   4. Claude внутри tmux жив → если нет, kill session + relaunch (TG-пинг).
#  4b. Sub-agent respawn (НОВЫЙ , см. README.md):
#      Для каждого `tasks/T*.md` без [x] в progress и без `reports/T*.done` —
#      если pid_file мёртв И log содержит "Request timed out" → spawn runner.sh.
#      Лимит 3 respawn-а на таску (state per-task в STATE_DIR).
#   5. Новые `"isApiErrorMessage":true` в jsonl за последние 6ч → TG-пинг
#      (cooldown 30 мин чтобы не спамить).
#   6. Pstree всех claude-PID-ов под agent: если ≥12 тиков подряд (≥60 мин)
#      ни один не имеет non-thread-children (Bash/ssh/curl) → TG-пинг
#      «возможно завис» (один раз за инцидент).
#  5b. IDLE/RATE-LIMIT RECOVERY (НОВЫЙ ): интерактивный tmux-оркестратор при
#      5ч-лимите Claude НЕ возобновляется сам (лимит печатается в панель, не в лог →
#      grep нечего, в отличие от claude -p + wave_supervisor). Раньше он висел часами.
#      Теперь: нет non-thread-детей И свежий jsonl не рос ≥IDLE_RECOVER_SECS (20 мин) И
#      ни один саб-агент не жив → kill session + relaunch (launcher перевставит resume-
#      промпт, оркестратор продолжит по progress.md). Cooldown 20 мин, максимум
#      RECOVER_MAX подъёмов (иначе только TG). RL-маркер в jsonl различает «лимит» vs «hang».
#
# Установка:
#   chmod +x /work/<project_dir>/chat/orchestrator_watchdog.sh
#   ( crontab -l 2>/dev/null | grep -v orchestrator_watchdog;
#     echo "*/15 * * * * /work/<project_dir>/chat/orchestrator_watchdog.sh" ) | crontab -
#   tmux new-session -d -s orch_watchdog_loop -c /work/<project_dir> \
#     "bash -c 'while true; do /work/<project_dir>/chat/orchestrator_watchdog.sh; sleep 300; done'"
#
# Self-cleanup (с версии ):
#   - Когда все таски в progress.md → [x]:
#     * A-watchdog: `crontab -e` авто-удаление записи.
#     * B-watchdog: `tmux kill-session orch_watchdog_loop`.
#     * State-dir в /tmp удаляется.
#
# WSL2: убедись что cron-демон поднят (`service cron status`); systemd-free WSL не
# запускает его сам, и без `service cron start` крон-задачи не отработают.

# КРИТИЧНО: если скрипт вызван из tmux-сессии (B-watchdog), он наследует
# TMUX env и `runuser -u "$ORCHESTRATOR_USER" -- tmux has-session` уйдёт в чужой сокет →
# false-DEAD + Permission denied. Чистим:
unset TMUX TMUX_PANE TERM

# ====== НАСТРОЙКИ — поправь под проект ======
PROJECT_DIR='/work/<project_dir>'      # ← поправь на свой путь, например /work/<project>
PROJECT_TAG='<project_tag>'            # короткий тэг для pid-файлов sub-agent'ов (см. tasks_runner.template.sh)
ORCHESTRATOR_USER="${ORCHESTRATOR_USER:-agent}"
SESSION=orchestrator
LAUNCHER=/tmp/launch_orchestrator_tmux.sh
RUNNER="$PROJECT_DIR/tasks/runner.sh"  # sub-agent wrapper (см. tasks_runner.template.sh)
LOG=$PROJECT_DIR/chat/orchestrator_watchdog.log
PROMPT_FILE=$PROJECT_DIR/chat/orchestrator_resume_prompt.md
PROGRESS=$PROJECT_DIR/chat/orchestrator_progress.md
JSONL_DIR="/home/${ORCHESTRATOR_USER}/.claude/projects/-work-<project_dir>"   # слэши пути → дефисы (см. README.md)
TOTAL_TASKS=15      # сколько тасков всего у этого оркестратора
CHAT_ID="${CHAT_ID:-000000000}"   # TG юзера для алертов
SUBAGENT_RESPAWN_LIMIT=3   # максимум respawn-ов на одну sub-agent таску (см. шаг 4b)

# State-dir для счётчиков между тиками (уникальный per-wave, если у тебя
# параллельно несколько оркестраторов — добавь wave-tag в имя).
STATE_DIR=/tmp/orch_watchdog_state
S_API_COUNT="$STATE_DIR/api_retries"
S_ZOMBIE_TICKS="$STATE_DIR/zombie_ticks"
S_ZOMBIE_ALERTED="$STATE_DIR/zombie_alerted"
S_API_ALERT_TS="$STATE_DIR/api_last_alert_ts"
S_RECOVER_TS="$STATE_DIR/recover_ts"        # 🔴 NEW : время последнего авто-подъёма
S_RECOVER_COUNT="$STATE_DIR/recover_count"  # 🔴 NEW : счётчик авто-подъёмов (предохранитель)

# Лимиты (обычно не менять):
ZOMBIE_TICK_LIMIT=12          # ≥12 тиков × 5 мин = 60 мин без non-thread активности → пинг
API_ALERT_COOLDOWN=1800       # не чаще раза в 30 мин — иначе спам при длинной серии ретраев
JSONL_LOOKBACK_HOURS=6        # сканировать только свежие jsonl, иначе ловим артефакты прошлых волн
# 🔴 NEW  — IDLE/RATE-LIMIT RECOVERY (шаг 5b). Закрывает дыру: RL-защита в
# /work/settings есть ТОЛЬКО у claude -p (wave_supervisor/single_agent_supervisor/runner),
# а у ИНТЕРАКТИВНОГО tmux-оркестратора её не было. При 5ч-лимите интерактивный REPL
# печатает лимит в панель (не в лог → grep нечего) и НЕ возобновляется сам → висит часами.
# Роль лога у интерактивного = jsonl. Сигнал застоя = нет non-thread детей И jsonl не рос
# ≥ IDLE_RECOVER_SECS И ни один саб-агент не жив → kill session + relaunch (launcher
# перевставит resume-промпт, оркестратор продолжит по progress.md).
IDLE_RECOVER_SECS=1200        # jsonl тих ≥20 мин при простое → поднять заново (модель-turn столько не длится; ожидание саб-агента идёт через bash-sleep = non-thread child → сюда не попадёт)
RECOVER_COOLDOWN=1200         # не поднимать чаще раза в 20 мин (анти-шторм)
RECOVER_MAX=8                 # предохранитель: больше — только TG, ручная проверка (в сутки реально ≤5 RL)
# 🔴 ФИКС : узкий RL_RE (только настоящий harness-формат), не проза агента про лимит.
RL_RE='hit your (session|usage|5.?hour|weekly) limit|limit will reset|resets? (at )?[0-9]{1,2}(:[0-9]{2})? ?(am|pm)|usage limit reached'
# ============================================

mkdir -p "$STATE_DIR"
TG="python3 /work/tg/bot.py send $CHAT_ID"

exec >> "$LOG" 2>&1
echo "[$(date '+%F %T')] watchdog tick (caller=${USER:-root}, tmux_env=${TMUX:-none})"

# -1. ДЕДЛАЙН-СТОП (см. README.md + deadline_stopper.template.sh): если юзер
# заказал жёсткий стоп по времени, deadline_stopper.sh ставит сентинел-файл — после
# него watchdog обязан САМОЛИКВИДИРОВАТЬСЯ (cron + B-loop), а не воскрешать сборку.
if [ -f "$PROJECT_DIR/chat/DEADLINE_STOP" ]; then
  echo "[$(date '+%F %T')] DEADLINE_STOP sentinel — uninstalling watchdog (cron + B-loop), exit"
  crontab -l 2>/dev/null | grep -v orchestrator_watchdog | crontab -
  tmux kill-session -t orch_watchdog_loop 2>/dev/null || true
  rm -rf "$STATE_DIR"
  exit 0
fi

# 0. Прогресс не существует — оркестратор ещё ни разу не запускался, выходим
if [ ! -f "$PROGRESS" ]; then
  echo "[$(date '+%F %T')] no progress file at $PROGRESS — orchestrator not initialized"
  exit 0
fi

# 1. Все таски ✅? (учитываем `[ ]` И `[~]` как незавершённые — `[~]` это «partial,
#    ожидает решения юзера», волна не завершена пока есть такие). Снимаем себя.
if ! grep -qE '^- \[( |~)\]' "$PROGRESS"; then
  echo "[$(date '+%F %T')] all tasks done — uninstalling watchdog from cron + killing B-loop"
  crontab -l 2>/dev/null | grep -v orchestrator_watchdog | crontab -

  # Self-kill B-loop. TMUX env уже unset в начале скрипта.
  if tmux has-session -t orch_watchdog_loop 2>/dev/null; then
    echo "[$(date '+%F %T')] B-loop self-kill: tmux kill-session orch_watchdog_loop"
    tmux kill-session -t orch_watchdog_loop 2>/dev/null || true
  fi

  rm -rf "$STATE_DIR"
  exit 0
fi

# 2. Tmux-сессия оркестратора жива?
if ! runuser -u "$ORCHESTRATOR_USER" -- tmux has-session -t $SESSION 2>/dev/null; then
  echo "[$(date '+%F %T')] tmux session '$SESSION' DEAD. Relaunching via $LAUNCHER..."
  $TG "♻️ Orchestrator tmux DEAD → relaunch через $LAUNCHER" 2>&1 | tail -1
  if [ ! -x "$LAUNCHER" ]; then
    echo "[$(date '+%F %T')] FATAL: launcher $LAUNCHER missing or not executable"
    $TG "❌ Orchestrator: launcher $LAUNCHER не найден или не исполняем — restore вручную"
    exit 1
  fi
  "$LAUNCHER"
  exit 0
fi

# 3. Tmux жив — claude внутри жив?
CLAUDE_PIDS=$(ps -u "$ORCHESTRATOR_USER" -o pid=,comm= | awk '$2 == "claude" {print $1}')
if [ -z "$CLAUDE_PIDS" ]; then
  echo "[$(date '+%F %T')] tmux alive but no claude process. Killing session and relaunching..."
  $TG "♻️ Orchestrator no claude → kill session + relaunch" 2>&1 | tail -1
  runuser -u "$ORCHESTRATOR_USER" -- tmux kill-session -t $SESSION 2>/dev/null || true
  sleep 2
  "$LAUNCHER"
  exit 0
fi

# 4b. Sub-agent respawn (НОВЫЙ  — см. README.md).
# Для каждой tasks/T*.md без [x] в progress и без reports/T*.done:
# если pid-file указывает на мёртвый PID И log хвост содержит "Request timed out" →
# spawn runner.sh с retry-счётчиком (лимит SUBAGENT_RESPAWN_LIMIT).
if [ -d "$PROJECT_DIR/tasks" ] && [ -x "$RUNNER" ]; then
  for tf in "$PROJECT_DIR/tasks/"T*.md; do
    [ -f "$tf" ] || continue
    # Extract task id (T05 from "T05_routes_skeletons.md")
    bn=$(basename "$tf")
    TASK_ID=$(echo "$bn" | grep -oE '^T[0-9]+')
    [ -z "$TASK_ID" ] && continue

    # Уже [x] в progress? skip
    if grep -qE "^- \[x\].*\b${TASK_ID}\b" "$PROGRESS" 2>/dev/null; then
      continue
    fi

    # Уже есть done-sentinel? skip (orchestrator должен сам поставить [x] но не успел)
    [ -f "$PROJECT_DIR/reports/${TASK_ID}.done" ] && continue
    # Failed-sentinel? skip (без TG спама — fail уже зарепортил runner)
    [ -f "$PROJECT_DIR/reports/${TASK_ID}.failed" ] && continue

    # Pid жив? skip (runner работает)
    PF="/tmp/${PROJECT_TAG}_${TASK_ID}.pid"
    if [ -f "$PF" ]; then
      OLD_PID=$(cat "$PF" 2>/dev/null)
      [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null && continue
    fi

    # Pid мёртв ИЛИ файла нет — проверяем что log намекает на API-timeout fail
    TASK_LOG="$PROJECT_DIR/logs/${TASK_ID}.log"
    # Лога НЕТ = таск ещё НИ РАЗУ не
    # стартовал — запуск по порядку волн это работа ОРКЕСТРАТОРА, watchdog НЕ должен
    # его спавнить. Без этой проверки ПЕРВЫЙ тик B-loop'а (срабатывает через 0 сек
    # после установки) спавнит ВСЕ таски разом ДО старта оркестратора — ломая порядок
    # волн и RAM-лимит.
    [ -f "$TASK_LOG" ] || continue
    LAST_TAIL=$(tail -c 4000 "$TASK_LOG" 2>/dev/null)
    if ! echo "$LAST_TAIL" | grep -qE "Request timed out|isApiErrorMessage"; then
      # log есть, но не timeout — возможно sub-agent работает в фоне без pid-update;
      # не пытаемся respawn-нуть, оставляем оркестратору
      continue
    fi
    # в логе timeout — кандидат на respawn

    # Лимит respawn-ов
    RESPAWN_FILE="$STATE_DIR/respawn_${TASK_ID}"
    RC=$(cat "$RESPAWN_FILE" 2>/dev/null)
    [ -z "$RC" ] && RC=0
    if [ "$RC" -ge "$SUBAGENT_RESPAWN_LIMIT" ]; then
      # Лимит достигнут — TG раз и оставляем
      ALERTED="$STATE_DIR/respawn_alerted_${TASK_ID}"
      if [ ! -f "$ALERTED" ]; then
        echo "[$(date '+%F %T')] $TASK_ID respawn limit reached ($RC), giving up"
        $TG "❌ $TASK_ID: $SUBAGENT_RESPAWN_LIMIT respawn-ов исчерпано. Проверь $TASK_LOG и решай вручную" 2>&1 | tail -1
        touch "$ALERTED"
      fi
      continue
    fi

    # Respawn через runner (от ORCHESTRATOR_USER в новой сессии)
    RC=$((RC + 1))
    echo "$RC" > "$RESPAWN_FILE"
    echo "[$(date '+%F %T')] respawning $TASK_ID via $RUNNER (attempt $RC/$SUBAGENT_RESPAWN_LIMIT)"
    $TG "♻️ $TASK_ID: respawn $RC/$SUBAGENT_RESPAWN_LIMIT (предыдущий run упал на API timeout)" 2>&1 | tail -1
    setsid runuser -u "$ORCHESTRATOR_USER" -- "$RUNNER" "$TASK_ID" </dev/null >>"$LOG" 2>&1 &
    disown
  done
fi

# 4. Скан API-ретраев в jsonl (главный «звоночек»)
# Считаем `"isApiErrorMessage":true` только в jsonl, обновлённых за последние
# JSONL_LOOKBACK_HOURS — иначе попадают артефакты предыдущих волн.
CUTOFF_TS=$(date -d "$JSONL_LOOKBACK_HOURS hours ago" +%s 2>/dev/null || echo 0)
NEW_API_COUNT=0
if [ -d "$JSONL_DIR" ]; then
  for j in $(find "$JSONL_DIR" -maxdepth 1 -name '*.jsonl' -newermt "@$CUTOFF_TS" 2>/dev/null); do
    c=$(grep -c '"isApiErrorMessage":true' "$j" 2>/dev/null)
    [ -z "$c" ] && c=0
    NEW_API_COUNT=$((NEW_API_COUNT + c))
  done
fi
OLD_API_COUNT=$(cat "$S_API_COUNT" 2>/dev/null)
[ -z "$OLD_API_COUNT" ] && OLD_API_COUNT=0
echo "$NEW_API_COUNT" > "$S_API_COUNT"

if [ "$NEW_API_COUNT" -gt "$OLD_API_COUNT" ]; then
  DELTA=$((NEW_API_COUNT - OLD_API_COUNT))
  NOW_TS=$(date +%s)
  LAST_ALERT=$(cat "$S_API_ALERT_TS" 2>/dev/null)
  [ -z "$LAST_ALERT" ] && LAST_ALERT=0
  SINCE=$((NOW_TS - LAST_ALERT))
  if [ "$SINCE" -ge "$API_ALERT_COOLDOWN" ]; then
    echo "[$(date '+%F %T')] API retries grew +$DELTA (total $NEW_API_COUNT). Pinging."
    $TG "WARN Orchestrator: API retries +$DELTA total $NEW_API_COUNT за последние ${JSONL_LOOKBACK_HOURS}ч. Проверь: runuser -u $ORCHESTRATOR_USER -- tmux capture-pane -t $SESSION -p | tail" 2>&1 | tail -1
    echo "$NOW_TS" > "$S_API_ALERT_TS"
  else
    echo "[$(date '+%F %T')] API retries grew +$DELTA, но cooldown $SINCE/$API_ALERT_COOLDOWN — skip ping"
  fi
fi

# 5. Pstree-based zombie detection.
# Проверяем КАЖДЫЙ claude-PID под $ORCHESTRATOR_USER: имеет ли non-thread children?
# Если хотя бы один имеет (bash/ssh/curl/sshpass/ffmpeg/...) — волна жива, ресет.
# Если все только с {claude}-threads ≥ZOMBIE_TICK_LIMIT тиков подряд → пинг.
HAS_ACTIVITY=0
for pid in $CLAUDE_PIDS; do
  # pstree формат: claude(PID)─┬─{claude}(THREAD)
  #                            └─bash(CHILD)───sshpass(...)
  # grep -oE counts (PID) occurrences; \K и lookaround не работают с -E (PCRE-only).
  CHILDREN=$(pstree -p "$pid" 2>/dev/null | grep -oE '\([0-9]+\)' | wc -l)
  THREADS=$(pstree -p "$pid" 2>/dev/null | grep -oE '\{[^}]+\}\([0-9]+\)' | wc -l)
  # Все_процессы = 1 (главный) + THREADS + NON_THREAD_CHILDREN
  NON_THREAD=$((CHILDREN - 1 - THREADS))
  if [ "$NON_THREAD" -gt 0 ]; then
    HAS_ACTIVITY=1
    break
  fi
done

# 5b. Хелперы IDLE/RL-recovery (NEW ).
jsonl_age(){ # секунд с mtime самого свежего jsonl (999999 если нет)
  local j; j=$(find "$JSONL_DIR" -maxdepth 1 -name '*.jsonl' 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1)
  [ -z "$j" ] && { echo 999999; return; }
  echo $(( $(date +%s) - $(stat -c %Y "$j" 2>/dev/null || echo 0) ))
}
subagent_alive(){ # 0 если хоть один саб-агент этого проекта жив (тогда простой оркестратора легитимен)
  local pf p
  for pf in /tmp/${PROJECT_TAG}_T*.pid; do
    [ -f "$pf" ] || continue
    p=$(cat "$pf" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
  done
  return 1
}
jsonl_has_rl(){ # 0 если в хвосте свежего jsonl есть маркер 5ч-лимита
  local j; j=$(find "$JSONL_DIR" -maxdepth 1 -name '*.jsonl' 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1)
  [ -z "$j" ] && return 1
  tail -c 30000 "$j" 2>/dev/null | grep -qiE "$RL_RE"
}
recover_orchestrator(){ # kill session + relaunch, с cooldown и предохранителем
  local reason="$1" now last cnt
  now=$(date +%s); last=$(cat "$S_RECOVER_TS" 2>/dev/null); [ -z "$last" ] && last=0
  if [ $((now - last)) -lt "$RECOVER_COOLDOWN" ]; then
    echo "[$(date '+%F %T')] idle-recover на cooldown ($((now-last))/$RECOVER_COOLDOWN) — skip"; return
  fi
  cnt=$(cat "$S_RECOVER_COUNT" 2>/dev/null); [ -z "$cnt" ] && cnt=0; cnt=$((cnt + 1))
  echo "$cnt" > "$S_RECOVER_COUNT"; echo "$now" > "$S_RECOVER_TS"
  if [ "$cnt" -gt "$RECOVER_MAX" ]; then
    echo "[$(date '+%F %T')] idle-recover: лимит $RECOVER_MAX исчерпан — только TG"
    $TG "❌ Orchestrator: $RECOVER_MAX авто-подъёмов исчерпано ($reason) — нужна ручная проверка $SESSION" 2>&1 | tail -1
    return
  fi
  echo "[$(date '+%F %T')] IDLE-RECOVER ($reason): kill session $SESSION + relaunch (#$cnt/$RECOVER_MAX)"
  $TG "♻️ Orchestrator простаивал ($reason) → авто-подъём #$cnt/$RECOVER_MAX через $LAUNCHER" 2>&1 | tail -1
  runuser -u "$ORCHESTRATOR_USER" -- tmux kill-session -t "=$SESSION" 2>/dev/null || true
  sleep 3
  if [ -x "$LAUNCHER" ]; then "$LAUNCHER"; else $TG "❌ Orchestrator: launcher $LAUNCHER не исполняем — restore вручную"; fi
  echo "0" > "$S_ZOMBIE_TICKS"; echo "0" > "$S_ZOMBIE_ALERTED"
}

if [ "$HAS_ACTIVITY" -eq 1 ]; then
  echo "0" > "$S_ZOMBIE_TICKS"
  echo "0" > "$S_ZOMBIE_ALERTED"
  echo "0" > "$S_RECOVER_COUNT"   # оркестратор снова работает — сброс счётчика авто-подъёмов
else
  TICKS=$(cat "$S_ZOMBIE_TICKS" 2>/dev/null)
  [ -z "$TICKS" ] && TICKS=0
  TICKS=$((TICKS + 1))
  echo "$TICKS" > "$S_ZOMBIE_TICKS"
  if [ "$TICKS" -ge "$ZOMBIE_TICK_LIMIT" ]; then
    ALERTED=$(cat "$S_ZOMBIE_ALERTED" 2>/dev/null)
    [ -z "$ALERTED" ] && ALERTED=0
    if [ "$ALERTED" -eq 0 ]; then
      MIN=$((TICKS * 5))
      DONE=$(grep -c '^- \[x\]' "$PROGRESS" 2>/dev/null)
      [ -z "$DONE" ] && DONE=0
      echo "[$(date '+%F %T')] ZOMBIE: all claude only-threads ${MIN}min. Pinging."
      $TG "ALERT Orchestrator возможно завис: все claude (PIDs $CLAUDE_PIDS) без активных подпроцессов ${MIN} мин. Progress $DONE/$TOTAL_TASKS. Проверь: pstree -p <pid> и runuser -u $ORCHESTRATOR_USER -- tmux capture-pane -t $SESSION -p | tail" 2>&1 | tail -1
      echo "1" > "$S_ZOMBIE_ALERTED"
    fi
  fi
  # 🔴 5b. АВТО-ВОССТАНОВЛЕНИЕ: простой подтверждён jsonl-mtime И нет живого саб-агента.
  # Это ловит 5ч-лимит интерактивного оркестратора (висит после лимита) и настоящие hang'и.
  AGE=$(jsonl_age)
  if [ "$AGE" -ge "$IDLE_RECOVER_SECS" ] && ! subagent_alive; then
    if jsonl_has_rl; then recover_orchestrator "5ч-лимит/RL, jsonl тих ${AGE}s"
    else recover_orchestrator "завис, jsonl тих ${AGE}s"; fi
  fi
fi

# 6. Heartbeat
DONE=$(grep -c '^- \[x\]' "$PROGRESS" 2>/dev/null)
[ -z "$DONE" ] && DONE=0
PARTIAL=$(grep -c '^- \[~\]' "$PROGRESS" 2>/dev/null)
[ -z "$PARTIAL" ] && PARTIAL=0
ZTICKS=$(cat "$S_ZOMBIE_TICKS" 2>/dev/null || echo 0)
echo "[$(date '+%F %T')] alive (claude PIDs: $(echo $CLAUDE_PIDS | tr '\n' ' ')), progress: ${DONE}✓/${PARTIAL}~/$TOTAL_TASKS, api_retries=$NEW_API_COUNT, zombie_ticks=$ZTICKS"

exit 0
