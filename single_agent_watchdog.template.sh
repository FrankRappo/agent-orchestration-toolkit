#!/bin/bash
# Watchdog для ОДНОГО sub-агента в режиме `claude -p` (без tmux-оркестратора).
#
# Зачем: даже одиночный sub-агент страдает от API-таймаутов так же, как
# оркестратор. Если API timeout'ит ≥10 ретраев —
# claude CLI умирает с `isApiErrorMessage:true`, sub-агент тихо вылетает.
# Без watchdog'а юзер узнаёт об этом только когда зайдёт проверить лог.
#
# Что делает: пингует юзера в TG на: API retry / process death /
# стагнацию лога (≥45 мин без роста) / success-маркер в логе.
#
# Запускать ОТ ROOT в tmux 'agent_watch' (или другое имя):
#   tmux new-session -d -s agent_watch -c /work/<project> \
#     "bash /work/settings/single_agent_watchdog.template.sh"
#
# НАСТРОЙКИ (заполнить под конкретный таск):

TASK_ID="T-EXAMPLE"                                                    # короткое имя для TG-сообщений
PROJECT_DIR="${PROJECT_DIR:-/work/<project>}"
AGENT_USER="${AGENT_USER:-agent}"
LOG="$PROJECT_DIR/chat/${TASK_ID}_output.log"                          # output sub-агента
PID_FILE=/tmp/${TASK_ID}.pid                                           # PID-файл от launcher'а
JSONL_DIR="${JSONL_DIR:-/home/$AGENT_USER/.claude/projects/-work-<project>}" # каталог Claude session jsonl
WATCHDOG_LOG="$PROJECT_DIR/chat/${TASK_ID}_watchdog.log"               # heartbeat-лог watchdog'а
STATE=/tmp/${TASK_ID}_watchdog_state                                   # internal state prefix
CHAT_ID="${CHAT_ID:-000000000}"                                                      # ID юзера в TG
# Любой из паттернов в логе → считаем финал успешным. ERE-regex, '|' между альтернативами.
# Дефолт ловит: «✅ <TASK_ID>», «<TASK_ID> готов[о]», «<TASK_ID> done», «Merge: <hash>».
SUCCESS_REGEX="✅ ${TASK_ID}|${TASK_ID}[^\n]{0,80}готов(о)?|${TASK_ID}[^\n]{0,80}done|Merge: [0-9a-f]{7,}"

# Опционально: при success watchdog автоматически отправит до SUCCESS_PHOTOS_MAX скринов в TG.
# Пример: SUCCESS_PHOTOS_GLOB="/work/<project>/chat/Скрин/${TASK_ID}_*/thumbs/AFTER_*.png"
# Bash glob, без кавычек при ls — раскрывается shell'ом. Пусто = ничего не шлём.
SUCCESS_PHOTOS_GLOB=""
SUCCESS_PHOTOS_MAX=3

# Лимиты (обычно НЕ менять)
SILENCE_LIMIT=2700   # 45 мин в секундах
TICK=90              # период опроса

# WATCHDOG_START — для фильтрации false-positive API retries:
# watchdog считает только ОШИБКИ, появившиеся в jsonl ПОСЛЕ его старта.
# Без этого фильтра watchdog при старте видит isApiErrorMessage из старого
# jsonl мёртвого предыдущего агента и шлёт ложный пинг.
WATCHDOG_START_TS=$(date +%s)

# ====================== код ниже трогать не нужно ============================

unset TMUX TMUX_PANE TERM
export LC_ALL=C.utf8 LANG=C.utf8   # bot.py expects UTF-8; without this TG send dies on "Bad Request: text must be encoded in UTF-8"
TG="python3 /work/tg/bot.py send $CHAT_ID"

exec >> "$WATCHDOG_LOG" 2>&1
echo "[$(date '+%F %T')] $TASK_ID watchdog start (PID $$)"

# Ждём появления PID-файла (launcher может ещё не отработать)
for i in $(seq 1 30); do
  [ -f "$PID_FILE" ] && break
  sleep 2
done
if [ ! -f "$PID_FILE" ]; then
  echo "[$(date '+%F %T')] FATAL: $PID_FILE не появился за 60с"
  $TG "❌ $TASK_ID watchdog: PID-файл не создан за 60с — sub-агент не стартовал."
  exit 1
fi

SUB_PID=$(cat "$PID_FILE")
echo "[$(date '+%F %T')] tracking SUB_PID=$SUB_PID"

echo "0" > "$STATE.api_retries"
date +%s > "$STATE.last_growth"
wc -c < "$LOG" > "$STATE.last_size"
echo "0" > "$STATE.silence_alerted"

while true; do
  # 1. Жив ли sub-агент?
  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    SIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    TAIL=$(tail -c 2000 "$LOG" 2>/dev/null | tr -d '\000' | head -c 1500)
    echo "[$(date '+%F %T')] SUB_PID=$SUB_PID DEAD. log size=$SIZE"

    if grep -qE "$SUCCESS_REGEX" "$LOG" 2>/dev/null; then
      $TG "✅ $TASK_ID sub-агент завершился (success-маркер в логе). Лог: $LOG (${SIZE}b). Watchdog снимается."
      # Опциональный auto-send финальных скринов (если задан SUCCESS_PHOTOS_GLOB).
      if [ -n "$SUCCESS_PHOTOS_GLOB" ]; then
        N=0
        for p in $SUCCESS_PHOTOS_GLOB; do
          [ -f "$p" ] || continue
          N=$((N+1))
          [ "$N" -gt "${SUCCESS_PHOTOS_MAX:-3}" ] && break
          python3 /work/tg/bot.py sendphoto "$CHAT_ID" "$p" "$TASK_ID: $(basename "$p")" 2>&1 \
            | head -1
        done
        echo "[$(date '+%F %T')] auto-sent $N photos via SUCCESS_PHOTOS_GLOB"
      fi
    else
      # TAIL может содержать Markdown-метасимволы (отчёты часто пишут с **bold** / `code`)
      # bot.py сам делает retry-без-parse_mode если Markdown-парс упал — оставляем TAIL как есть.
      $TG "ℹ️ $TASK_ID sub-агент завершился без success-маркера. Лог: $LOG (${SIZE}b). Хвост:
$TAIL"
    fi
    echo "[$(date '+%F %T')] watchdog exiting (sub-agent dead)"
    tmux kill-session -t "$(tmux display-message -p '#S' 2>/dev/null)" 2>/dev/null
    exit 0
  fi

  # 2. API-ретраи в jsonl (главная защита — ради этого вся затея)
  # Берём ТОЛЬКО jsonl-файлы изменённые ПОСЛЕ старта watchdog'а,
  # иначе ловим false-positive из старого jsonl мёртвого предыдущего агента.
  JSONL=$(find "$JSONL_DIR" -maxdepth 1 -name '*.jsonl' -newermt "@$WATCHDOG_START_TS" 2>/dev/null \
          | xargs -r ls -t 2>/dev/null | head -1)
  if [ -n "$JSONL" ] && [ -f "$JSONL" ]; then
    NEW_RETRIES=$(grep -c '"isApiErrorMessage":true' "$JSONL" 2>/dev/null)
    [ -z "$NEW_RETRIES" ] && NEW_RETRIES=0
    OLD_RETRIES=$(cat "$STATE.api_retries" 2>/dev/null)
    [ -z "$OLD_RETRIES" ] && OLD_RETRIES=0
    if [ "$NEW_RETRIES" -gt "$OLD_RETRIES" ]; then
      DELTA=$((NEW_RETRIES - OLD_RETRIES))
      LAST_ERR=$(grep '"isApiErrorMessage":true' "$JSONL" | tail -1 \
        | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); m=d.get('message',{}); c=m.get('content',[{}]); print(c[0].get('text','?')[:200] if c else '?')" 2>/dev/null || echo "?")
      # Экранируем Markdown-конфликтные символы для bot.py parse_mode=Markdown.
      LAST_ERR_SAFE=$(echo "$LAST_ERR" | tr -d '*_[]`<>')
      $TG "WARN $TASK_ID API retry +$DELTA total $NEW_RETRIES. Last: $LAST_ERR_SAFE"
      echo "$NEW_RETRIES" > "$STATE.api_retries"
    fi
  fi

  # 3. Стагнация лога (≥45 мин без роста)
  CUR_SIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  LAST_SIZE=$(cat "$STATE.last_size" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  LAST_GROWTH=$(cat "$STATE.last_growth" 2>/dev/null || echo "$NOW")
  if [ "$CUR_SIZE" -gt "$LAST_SIZE" ]; then
    echo "$CUR_SIZE" > "$STATE.last_size"
    echo "$NOW" > "$STATE.last_growth"
    echo "0" > "$STATE.silence_alerted"
  else
    SILENCE=$((NOW - LAST_GROWTH))
    ALERTED=$(cat "$STATE.silence_alerted" 2>/dev/null || echo 0)
    if [ "$SILENCE" -ge "$SILENCE_LIMIT" ] && [ "$ALERTED" -eq 0 ]; then
      MIN=$((SILENCE / 60))
      $TG "ℹ️ $TASK_ID лог не растёт ${MIN}мин. PID=$SUB_PID жив. Возможно длинный API-turn или завис. Проверь pstree -p $SUB_PID."
      echo "1" > "$STATE.silence_alerted"
    fi
  fi

  echo "[$(date '+%F %T')] alive PID=$SUB_PID log=${CUR_SIZE}b retries=$(cat $STATE.api_retries 2>/dev/null) silence=$((NOW - LAST_GROWTH))s"

  sleep $TICK
done
