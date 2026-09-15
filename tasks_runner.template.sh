#!/bin/bash
# Sub-agent runner wrapper — шаблон для копирования в проект.
# Версия: 2026-07-04 (+ RL-aware: пережидает 5ч/session-лимит Claude, НЕ тратя retry — §9.3bis).
#         База: 2026-05-26 (после уроков projectd, см. HOW_TO_RUN.md §9.10.1).
#
# Замени <project_dir> на путь к проекту (например /work/projectd) и положи как
# /work/<project_dir>/tasks/runner.sh — потом chmod +x.
#
# Зачем нужен (см. HOW_TO_RUN.md §9.10.1):
#   `claude -p < task.md` НЕ имеет встроенного retry на API timeout. Один blip
#   на Anthropic API → sub-agent умирает с "Request timed out" в log, даже не
#   начав работу. В кейсе projectd 2026-05-26 две sub-agent (T05+T06) синхронно
#   умерли в 07:21 из-за одной API-ямы — main orchestrator продолжал ждать
#   их Monitor-ом, watchdog видел смерть но не respawn.
#
# Что делает (в порядке):
#   1. Проверяет sentinel reports/TASK.done — если есть, exit 0 idempotent.
#   2. Проверяет live pid_file — если есть другой живой runner для этой таски,
#      exit 1 (защита от двойного запуска).
#   3. Записывает свой PID в /tmp/<project>_<TASK>.pid.
#   4. Цикл retry: до 3 попыток `claude -p < task.md`, между попытками sleep
#      экспоненциально (60s, 120s, 180s).
#   5. Если попытка завершилась без "Request timed out" в logе И с код выхода
#      0 → атомарно создаёт reports/TASK.done, exit 0.
#   6. После 3 fail-ов → атомарно создаёт reports/TASK.failed, TG-пинг, exit 1.
#
# Использование (вместо прямого `setsid claude -p`):
#   В оркестраторе вместо:
#     setsid runuser -u agentuser -- bash -c "claude -p < tasks/T05.md > logs/T05.log 2>&1" &
#   Запускать:
#     setsid runuser -u agentuser -- /work/<project>/tasks/runner.sh T05 &
#
# Wrapper сам подключит лог, задачу, sentinel.

set -u

# ====== НАСТРОЙКИ — поправь под проект ======
PROJECT_DIR='/work/<project_dir>'      # ← поправь
PROJECT_TAG='<project_tag>'            # короткий тэг, e.g. 'orv' — для имени pid-файла
CHAT_ID=YOUR_TELEGRAM_CHAT_ID                      # TG для алертов
MAX_RETRIES=3
BASE_BACKOFF=60                        # секунды до 1-го retry; следующие = i * BASE_BACKOFF
# RL-aware (5ч/session-лимит Claude, §9.3bis): при лимите ждём сброса ЦИКЛОМ, НЕ тратя retry.
# Иначе 3 быстрых ретрая сгорают об лимит → ложный .failed (кейс PROJECTA 2026-06-30, но на уровне runner).
RL_WAIT="${RL_WAIT:-1500}"             # 25 мин между попытками при лимите
RL_MAX="${RL_MAX:-24}"                 # cap ~10ч пережидания лимита
RL_RE='usage limit|session limit|hit your [a-z ]*limit|limit reached|limit will reset|resets? at|resets? [0-9]|reached your|5-hour|превыш.*лимит|лимит исчерпан'
# ============================================

TASK="${1:-}"                          # T05, T06, etc.
if [ -z "$TASK" ]; then
  echo "Usage: $0 <TASK_ID> (e.g. T05)"
  exit 2
fi

# Файлы:
TASK_FILE=$(ls "$PROJECT_DIR/tasks/${TASK}_"*.md 2>/dev/null | head -1)
LOG="$PROJECT_DIR/logs/${TASK}.log"
PID_FILE="/tmp/${PROJECT_TAG}_${TASK}.pid"
DONE_SENTINEL="$PROJECT_DIR/reports/${TASK}.done"
FAIL_SENTINEL="$PROJECT_DIR/reports/${TASK}.failed"
TG="python3 /work/tg/bot.py send $CHAT_ID"

if [ -z "$TASK_FILE" ] || [ ! -f "$TASK_FILE" ]; then
  echo "FATAL: no task file matching $PROJECT_DIR/tasks/${TASK}_*.md"
  exit 2
fi
mkdir -p "$PROJECT_DIR/logs" "$PROJECT_DIR/reports"

# 1. Idempotent: уже done?
if [ -f "$DONE_SENTINEL" ]; then
  echo "[$(date '+%F %T')] $TASK already done (sentinel $DONE_SENTINEL exists) — exit 0"
  exit 0
fi

# 2. Уже running?
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[$(date '+%F %T')] $TASK already running (PID $OLD_PID) — exit 1"
    exit 1
  else
    echo "[$(date '+%F %T')] stale pid-file $PID_FILE (PID $OLD_PID dead) — cleaning"
    rm -f "$PID_FILE"
  fi
fi

# 3. Записать свой PID
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT INT TERM

# Init log с маркером начала
{
  echo "==================================================="
  echo "$TASK runner started PID $$ at $(date '+%F %T')"
  echo "Task file: $TASK_FILE"
  echo "==================================================="
} >> "$LOG"

# 4. Retry loop
for i in $(seq 1 $MAX_RETRIES); do
  echo "[$(date '+%F %T')] $TASK attempt $i/$MAX_RETRIES" >> "$LOG"

  # Snapshot offset чтобы потом проверять только то что добавилось в этом ране
  OFFSET=$(wc -c < "$LOG" 2>/dev/null || echo 0)

  # Запуск claude -p
  # 🔴 --dangerously-skip-permissions ОБЯЗАТЕЛЬНО: без него sub-агент не имеет прав
  # на Write/Edit/Bash-сеть → не может писать отчёты/curl/деплоить (фикс 2026-06-01).
  claude --dangerously-skip-permissions -p < "$TASK_FILE" >> "$LOG" 2>&1
  RC=$?

  # Проверка: были ли API timeouts в этой попытке?
  # 🔴 НЕ `grep -c ... || echo 0` — при 0 совпадений grep печатает "0" И возвращает rc1,
  # затем `|| echo 0` добавляет ВТОРОЙ "0" → TIMEOUT_HIT="0\n0" → integer-error в [ -eq ]
  # → любой успешный ран помечается FAILED (грабля §9.8.4). Считаем строки через wc:
  TIMEOUT_HIT=$(tail -c +"$OFFSET" "$LOG" 2>/dev/null | grep -E "Request timed out|isApiErrorMessage" | wc -l | tr -d ' ')
  [ -z "$TIMEOUT_HIT" ] && TIMEOUT_HIT=0

  # RL-aware: упёрлись в 5ч/session-лимит → ждём сброса ЦИКЛОМ и перезапускаем В ТОЙ ЖЕ
  # попытке $i (retry НЕ тратим). Ловим только настоящие лимит-маркеры (не 429/blip → им обычный retry).
  NEW=$(tail -c +"$OFFSET" "$LOG" 2>/dev/null)
  rl_n=0
  while [ "$RC" -ne 0 ] && [ ! -f "$DONE_SENTINEL" ] && printf '%s' "$NEW" | grep -qiE "$RL_RE"; do
    rl_n=$((rl_n+1))
    if [ "$rl_n" -gt "$RL_MAX" ]; then
      echo "[$(date '+%F %T')] $TASK RL держится >${RL_MAX}×${RL_WAIT}s — прекращаю ждать" >> "$LOG"; break
    fi
    echo "[$(date '+%F %T')] $TASK RATE-LIMIT (#$rl_n) — жду ${RL_WAIT}s, попытка $i НЕ тратится" >> "$LOG"
    $TG "⏳ $TASK: лимит Claude (5ч) — жду сброса ~$((RL_WAIT/60)) мин (RL #$rl_n)" 2>&1 | tail -1
    sleep "$RL_WAIT"
    OFFSET=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    claude --dangerously-skip-permissions -p < "$TASK_FILE" >> "$LOG" 2>&1
    RC=$?
    NEW=$(tail -c +"$OFFSET" "$LOG" 2>/dev/null)
    TIMEOUT_HIT=$(printf '%s' "$NEW" | grep -E "Request timed out|isApiErrorMessage" | wc -l | tr -d ' '); [ -z "$TIMEOUT_HIT" ] && TIMEOUT_HIT=0
  done

  if [ "$RC" -eq 0 ] && [ "$TIMEOUT_HIT" -eq 0 ]; then
    # SUCCESS — атомарно создаём sentinel
    TMP_DONE="$PROJECT_DIR/reports/.${TASK}.done.tmp"
    {
      echo "completed: $(date '+%F %T')"
      echo "attempt: $i/$MAX_RETRIES"
      echo "exit_code: $RC"
      echo "runner_pid: $$"
    } > "$TMP_DONE"
    mv "$TMP_DONE" "$DONE_SENTINEL"
    echo "[$(date '+%F %T')] $TASK SUCCESS (attempt $i, rc=$RC)" >> "$LOG"
    $TG "✅ $TASK done (attempt $i/$MAX_RETRIES)" 2>&1 | tail -1
    exit 0
  fi

  echo "[$(date '+%F %T')] $TASK attempt $i FAILED (rc=$RC, api_timeouts=$TIMEOUT_HIT)" >> "$LOG"

  if [ "$i" -lt "$MAX_RETRIES" ]; then
    BACKOFF=$((i * BASE_BACKOFF))
    echo "[$(date '+%F %T')] sleeping $BACKOFF seconds before retry" >> "$LOG"
    sleep "$BACKOFF"
  fi
done

# 6. Все попытки исчерпаны — fail sentinel + ping
TMP_FAIL="$PROJECT_DIR/reports/.${TASK}.failed.tmp"
{
  echo "failed: $(date '+%F %T')"
  echo "attempts_used: $MAX_RETRIES"
  echo "last_rc: $RC"
  echo "runner_pid: $$"
  echo "last_log_tail:"
  tail -30 "$LOG"
} > "$TMP_FAIL"
mv "$TMP_FAIL" "$FAIL_SENTINEL"
echo "[$(date '+%F %T')] $TASK FAILED after $MAX_RETRIES attempts" >> "$LOG"
$TG "❌ $TASK FAILED после $MAX_RETRIES попыток. См. $LOG и $FAIL_SENTINEL" 2>&1 | tail -1
exit 1
