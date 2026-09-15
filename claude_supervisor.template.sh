#!/bin/bash
# Supervise ONE interactive Claude REPL agent (launched via claude_agent_launcher).
# Mirror of codex_supervisor, adapted for Claude:
#   - agent is an interactive `claude` REPL in tmux (NOT `claude -p`);
#   - stall is detected by JSONL session growth (Claude-native), not stdout-log age;
#   - rate/session-limit is detected by capturing the REPL pane.
# Finish = report whose final line is STATUS: SUCCESS|FAIL|BLOCKED|PARTIAL.
# Run AS the claude user so tmux/jsonl/auth belong to that user.
#
# Required env: TASK PROJECT_DIR TASK_FILE REPORT
# Optional env: LOG_DIR STATE_DIR LAUNCHER PANE_SESSION JSONL_DIR PID_FILE
#   MAX_RESPAWN STALL_LIMIT NO_JSONL_LIMIT POLL RETRY_STATUSES
#   RATE_LIMIT_WAIT_SECONDS RATE_LIMIT_MAX_WAITS RATE_LIMIT_RE CHAT_ID
#   API_ERROR_RE API_ERROR_QUIET API_ERROR_GRACE API_ERROR_TRIES
#   API_ERROR_NIGHT_TZ API_ERROR_NIGHT_FROM API_ERROR_NIGHT_TO PAUSE_FLAG
# Прогон детекторов без агента: SUPERVISOR_SELFTEST=1 — файл только определяет функции
# (см. supervisor_api_error_selftest.sh).
set -u
unset TMUX TMUX_PANE
export LC_ALL=C.utf8 LANG=C.utf8

TASK="${TASK:?need TASK}"
PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
TASK_FILE="${TASK_FILE:?need TASK_FILE}"
REPORT="${REPORT:?need REPORT}"

LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state}"
LAUNCHER="${LAUNCHER:-/work/settings/claude/claude_agent_launcher.template.sh}"
PANE_SESSION="${PANE_SESSION:-claude_${TASK}_repl}"
PID_FILE="${PID_FILE:-$STATE_DIR/${TASK}.pid}"
PROMPT_FILE="${PROMPT_FILE:-$STATE_DIR/${TASK}_prompt.txt}"
SUPLOG="${SUPLOG:-$LOG_DIR/${TASK}_supervisor.log}"
# claude-sessions dir of the running user for this project path.
# Claude replaces EVERY non-alphanumeric char (incl. '/' AND '_') with '-'  →  /work/remote_tools = -work-vnc-rnd.
JSONL_DIR="${JSONL_DIR:-$HOME/.claude/projects/$(echo "$PROJECT_DIR" | sed 's#[^a-zA-Z0-9]#-#g')}"
MAX_RESPAWN="${MAX_RESPAWN:-4}"
STALL_LIMIT="${STALL_LIMIT:-600}"
NO_JSONL_LIMIT="${NO_JSONL_LIMIT:-$STALL_LIMIT}"
POLL="${POLL:-10}"   # 2026-07-30: было 30 — очередь заметно быстрее подхватывает следующий таск
RETRY_STATUSES="${RETRY_STATUSES:-}"
RATE_LIMIT_WAIT_SECONDS="${RATE_LIMIT_WAIT_SECONDS:-1500}"
RATE_LIMIT_MAX_WAITS="${RATE_LIMIT_MAX_WAITS:-24}"
# ============================================================================
# 🔴 ЖДЁМ ДО ВРЕМЕНИ СБРОСА, А НЕ ФИКСИРОВАННЫЕ 25 МИНУТ (добавлено 20.08.2026).
# Было: на любой лимит супервизор спал ровно RATE_LIMIT_WAIT_SECONDS и будил агента заново.
# Для пятичасового лимита это десятки лишних побудок подряд, а недельный выедал все 24 попытки
# и задача уходила в карантин с «FATAL: RL persisted» — хотя ждать надо было просто дольше.
# Сообщение Claude при этом САМО называет время сброса: «Your limit will reset at 4:30pm
# (Europe/Moscow)», «resets 3pm», иногда абсолютной датой.
# Стало: время читается из строки, пауза считается до него плюс запас. Строку не разобрали —
# берём прежнюю фиксированную паузу, то есть хуже прежнего не будет никогда.
# Потолок одной паузы нужен недельному лимиту: спать сутками одним sleep нельзя (не увидим,
# что лимит сняли раньше), поэтому ждём кусками и каждый раз перечитываем панель.
RATE_LIMIT_MARGIN_SECONDS="${RATE_LIMIT_MARGIN_SECONDS:-90}"
RATE_LIMIT_WAIT_MIN_SECONDS="${RATE_LIMIT_WAIT_MIN_SECONDS:-60}"
RATE_LIMIT_WAIT_MAX_SECONDS="${RATE_LIMIT_WAIT_MAX_SECONDS:-21600}"
# Narrow real 5h/session markers only (see HOW_TO_RUN §9.10.2 / 2026-07-13 fix).
# 🔴 УМОЛЧАНИЕ ЗАДАЁТСЯ ОТДЕЛЬНОЙ ПЕРЕМЕННОЙ, а не внутри ${VAR:-…} (найдено 15.08.2026, T263).
# Bash завершает подстановку ${VAR:-…} на ПЕРВОЙ же закрывающей скобке `}` — а в регулярке она
# стоит внутри квантификатора `{1,2}`. Прежняя однострочная запись молча превращалась в
#   …resets? (at )?[0-9]{1,2(:[0-9]{2})? ?(am|pm)|usage limit reached}
# то есть в шаблон с НЕЗАКРЫТЫМ `{1,2`: GNU grep (его и видит скрипт) такой `{` считает обычным
# символом и ошибки не даёт — просто эта альтернатива («resets at 4:30pm») не совпадала НИКОГДА,
# а под ugrep (он стоит функцией в интерактивной оболочке) весь шаблон вообще невалиден.
# Отказ был бесшумным вдвойне: и regexp молчит, и pane_tail до T263 всегда возвращал пусто.
RATE_LIMIT_RE_DEFAULT='hit your (session|usage|5.?hour|weekly) limit|limit will reset|resets? (at )?[0-9]{1,2}(:[0-9]{2})? ?(am|pm)|usage limit reached'
RATE_LIMIT_RE="${RATE_LIMIT_RE:-$RATE_LIMIT_RE_DEFAULT}"
# ============================================================================
# 🔴 ОШИБКА СВЯЗИ С API ≠ «АГЕНТ ДУМАЕТ» (добавлено 15.08.2026, T263; GOTCHAS #20).
# 15.08 дважды за сутки исполнитель ВСТАЛ, а конвейер этого не понял. У T259 в панели висело
# «API Error: Unable to connect to API (ENOTIMP)», агент простоял 1 ч 12 мин, транскрипт молчал,
# и до снятия по STALL_LIMIT оставалось ещё полчаса; разбудил человек одним сообщением. Тот же
# текст 04.08 унёс T165 вместе с ненаписанным отчётом.
# Для супервизора «агент думает над длинной командой» и «агент стоит на ошибке связи» выглядят
# ОДИНАКОВО — тишиной транскрипта. В первом случае ждать правильно, во втором бессмысленно: сам
# он не оживёт, а ночное окно уходит целиком.
# 🔴 Сработка ТОЛЬКО по ДВУМ признакам сразу: строка ошибки в хвосте панели И тишина транскрипта
# дольше API_ERROR_QUIET. По одной строке в панели срабатывать нельзя — эти же слова печатает в
# СВОЁМ выводе сам агент: в этом репозитории «fetch failed» — штатная строка лога моста киоска
# (orch/srvmove/logs/T01.log), а «Internal server error» прилетает от HTTP-сервиса 1С. Поэтому
# в умолчании их голых форм НЕТ: в реальной ошибке REPL они приходят как «API Error: fetch failed»
# и покрываются префиPROJECTAм. Набор собран по фактическим строкам из логов проекта (T165/T259 —
# ENOTIMP, ZF-PAY/ZFISCAL — «API Error: 529 Overloaded»), а не придуман.
# 🔴 Лимит сессии (RATE_LIMIT_RE) — НЕ ошибка связи: у него своя логика ожидания, и он первый по
# приоритету. Классификатор отдаёт RATE_LIMIT раньше, чем вообще смотрит на API-строки.
# Умолчание — отдельной переменной по той же причине, что и у RATE_LIMIT_RE выше.
API_ERROR_RE_DEFAULT='API Error|Unable to connect to (the )?API|Unable to connect to Anthropic|ENOTIMP|EAI_AGAIN|ECONNREFUSED|ECONNRESET'
API_ERROR_RE="${API_ERROR_RE:-$API_ERROR_RE_DEFAULT}"
API_ERROR_QUIET="${API_ERROR_QUIET:-180}"   # тишина транскрипта, с которой ошибка = «стоит», а не «думает»
API_ERROR_GRACE="${API_ERROR_GRACE:-180}"   # сколько ждём после побудки, прежде чем будить снова
API_ERROR_TRIES="${API_ERROR_TRIES:-3}"     # сколько раз будим, прежде чем закрывать как зависшего
# Ночью владелец спит: ошибка связи идёт в ЛОГ, а не в Telegram (правило 15.08, оно же правило 3
# из wait_conditions_and_launch — «пинг это журнал, а не план»). В TG уходит только финальное
# закрытие задачи — как и раньше. Владелец называет время по МСК, поэтому окно считается в МСК.
API_ERROR_NIGHT_TZ="${API_ERROR_NIGHT_TZ:-Europe/Moscow}"
API_ERROR_NIGHT_FROM="${API_ERROR_NIGHT_FROM:-23}"   # час начала тишины (включительно)
API_ERROR_NIGHT_TO="${API_ERROR_NIGHT_TO:-8}"        # час конца тишины (не включая); FROM=TO — тишины нет
api_tries=0; api_wake_ts=0; api_rl_noted=0
# ============================================================================
STATUS_RE='^[[:space:]]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)[[:space:]]*$'
# 🔴 Отчёт БЕЗ строки STATUS у ЖИВОГО агента — это черновик, а не сбой (фикс 2026-08-10, кейс T302).
# Было: как только файл отчёта появлялся, finish_on_report видел отсутствие STATUS → AMBIGUOUS →
# kill_agent + карантин. Агент при этом писал отчёт и был полностью жив (jsonl age 0-60 с) — работа
# 45 минут потеряна на финише, прод остался на feature-ветке, merge не выполнен.
# Стало: AMBIGUOUS выносится только когда агент МЁРТВ либо когда и отчёт, и транскрипт не менялись
# REPORT_GRACE секунд (агент реально бросил задачу, а не пишет её прямо сейчас).
# 🔴 ПОПРАВКА 24.08.2026, кейс T313. Жёсткие 300 с противоречили заголовку `Stall-Limit:` в
# таск-файле: задача честно объявила порог зависания 1800, агент запустил заказанный ею замер
# (тысяча запросов к площадке) и ждал его одним длинным вызовом — тринадцать минут молчания.
# Порог зависания это разрешал, а здешние 300 с — нет, и живого агента убили на середине замера.
# Стало: молчание допускается ровно столько, сколько задача сама объявила порогом зависания.
# Мёртвый процесс это не защищает — выше стоит alive_pid, и он ловит смерть независимо от порога.
REPORT_GRACE="${REPORT_GRACE:-${STALL_LIMIT:-300}}"
# ============================================================================
# 🔴 ГЕЙТ КОММИТА (добавлен 12.08.2026, GOTCHAS #16). Корень пяти подряд «работа сделана,
# а в git её нет» — НЕ лень исполнителей, а гонка в этом самом файле:
#   * каждый таск-файл требует «строку STATUS писать ТОЛЬКО последним действием»;
#   * finish_on_report при появлении валидного STATUS немедленно делает kill_agent и выходит.
# Агент, планировавший «отчёт → STATUS → коммит», физически не успевает: его снимают на
# втором шаге. Требование «коммит — часть работы» в шапке таска при таком порядке недостижимо.
# Кейсы 11-12.08: T233, T234, T237, T244, T246 — все закрылись без своего коммита, за них
# коммитили следующие задачи и человек.
# Лечение здесь: перед закрытием проверяем, доведена ли работа до git. Не доведена и агент ЖИВ —
# один раз пишем ему в его же REPL, что осталось, и даём COMMIT_GRACE секунд. По истечении
# закрываем задачу как есть (висеть вечно нельзя), но громко — в лог и в TG.
# 🔴 Правильный порядок для таск-файлов: КОММИТ И ПУШ, потом хеш в отчёт, и лишь ПОТОМ STATUS.
COMMIT_GATE="${COMMIT_GATE:-1}"          # 0 — выключить (проекты вне git)
COMMIT_GRACE="${COMMIT_GRACE:-900}"      # сколько ждать после напоминания
COMMIT_PLACEHOLDER_RE="${COMMIT_PLACEHOLDER_RE:-@@COMMIT@@|__COMMIT__|__COMMIT_[A-Za-z0-9]+__|<хеш>|<hash>}"
COMMIT_NUDGE_TS="$STATE_DIR/${TASK}_commit_nudge"
# 🔴 Агент закончил, но своего report_<TASK>.md не создал (фикс 2026-08-10, кейс T303: отчёт был
# дописан в файл предыдущей задачи). Интерактивный REPL не умирает после ответа — процесс жив, jsonl
# тих, и STALL-ветка отправляла его на respawn ПЕРЕДЕЛЫВАТЬ уже сделанную работу. Стало: перед
# respawn'ом агенту отправляется напоминание в его же REPL — обычно он просто создаёт файл.
REMIND_LIMIT="${REMIND_LIMIT:-1}"
# 15.08.2026 (T263): значение то же, но теперь его можно переопределить — иначе харнесс нельзя
# прогнать герметично (существующий /tmp/ram_paused глушил бы stall-детект во время теста).
PAUSE_FLAG="${PAUSE_FLAG:-/tmp/ram_paused}"
# Notification hook — set NOTIFY_CMD to a command taking ONE message arg (e.g. a Telegram sender).
# Empty by default so the template carries no project identity → single source, publishable as-is.
NOTIFY_CMD="${NOTIFY_CMD:-}"
notify(){ [ -n "$NOTIFY_CMD" ] && $NOTIFY_CMD "$*" >/dev/null 2>&1; return 0; }

mkdir -p "$LOG_DIR" "$STATE_DIR" "$(dirname "$REPORT")"
# 🔴 В режиме харнесса (SUPERVISOR_SELFTEST=1) лог НЕ перехватываем: иначе вывод самого харнесса
# уедет в файл супервизора и проверять будет нечего.
[ "${SUPERVISOR_SELFTEST:-0}" = 1 ] || exec >> "$SUPLOG" 2>&1
log(){ echo "[$(date '+%F %T')] $*"; }

report_status(){ grep -aE "$STATUS_RE" "$REPORT" 2>/dev/null | tail -1 \
  | sed -E 's/^[[:space:]]*STATUS:[[:space:]]*//; s/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]'; }

# 🔴 Отчёт под ДРУГИМ именем (фикс 2026-07-30). Очередь ждёт report_<ПОЛНОЕ_ИМЯ_ТАСКА>.md, а агент
# нередко называет файл короче (кейс T121: ждали report_T121_honest_pay_screen_and_standard_register.md,
# получили report_T121_honest_screen_and_register.md) → супервизор не видел отчёт, вечно писал "alive",
# таск не закрывался и ДЕРЖАЛ ЛОК — вся очередь стояла. Фолбэк: если ожидаемого файла нет, ищем в том же
# каталоге report_<номер таска>_*.md со строкой STATUS и переключаемся на него.
resolve_report(){
  [ -f "$REPORT" ] && return 0
  local dir num cand
  dir="$(dirname "$REPORT")"; num="$(printf '%s' "$TASK" | grep -oE '^T[0-9]+')"
  [ -z "$num" ] && return 1
  cand="$(find "$dir" -maxdepth 1 -name "report_${num}_*.md" -newermt "@$((LAUNCH_TS-5))" 2>/dev/null \
    | xargs -r grep -alE "$STATUS_RE" 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1)"
  # Второй заход (2026-08-10, кейс T303): агент мог дописать отчёт ПРЕДЫДУЩЕЙ задачи, если так велел
  # таск-файл. Берём любой свежий report_*.md, где есть И строка STATUS, И имя нашей задачи.
  #
  # 🔴 ДВУХ ПРИЗНАКОВ ОКАЗАЛОСЬ НЕДОСТАТОЧНО (авария 10.09.2026, T366+T367 параллельно). Отчёт
  # соседа по очереди упоминал имя нашей задачи ОДИН раз — в разделе «чужого не трогал». Супервизор
  # T366 принял чужой отчёт за свой, закрыл задачу чужим STATUS: PARTIAL и снял живого исполнителя
  # на 18-й минуте посреди установки расширения в боевую базу. Работа при этом была сделана, а
  # отчёта не осталось вовсе.
  # Фикс: отчёт, ИМЯ которого несёт ЧУЖОЙ номер задачи (report_T<другой номер>_*), не берём никогда,
  # сколько бы раз он ни упоминал нас в тексте. Имя файла — признак владения, текст — нет.
  if [ -z "$cand" ]; then
    local f fnum
    for f in $(find "$dir" -maxdepth 1 -name 'report_*.md' -newermt "@$((LAUNCH_TS-5))" 2>/dev/null \
      | xargs -r grep -alE "$STATUS_RE" 2>/dev/null | xargs -r grep -al -- "$TASK" 2>/dev/null \
      | xargs -r ls -t 2>/dev/null); do
      fnum="$(basename "$f" | grep -oE '^report_T[0-9]+' | grep -oE 'T[0-9]+')"
      if [ -n "$fnum" ] && [ "$fnum" != "$num" ]; then
        log "REPORT-ALIAS: пропускаю ${f##*/} — это отчёт задачи $fnum, а не $num (упоминание имени в тексте владением не считается)"
        continue
      fi
      cand="$f"; break
    done
  fi
  [ -z "$cand" ] && return 1
  log "REPORT-ALIAS: ожидали ${REPORT##*/}, нашли ${cand##*/} со строкой STATUS → работаем по нему"
  REPORT="$cand"; return 0
}

# 🔴 Зомби — это МЁРТВЫЙ процесс (фикс 2026-07-30). `kill -0` на зомби возвращает успех, поэтому
# супервизор считал завершившегося агента живым (кейс T121: состояние Zs, "alive" бесконечно).
alive_pid(){
  local pid="$1" st
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  st="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)"
  [ "$st" = "Z" ] && return 1
  return 0
}
status_in_list(){ local n="$1" i; for i in $2; do [ "$n" = "$(printf '%s' "$i"|tr '[:lower:]' '[:upper:]')" ] && return 0; done; return 1; }
archive_report_attempt(){ local st="$1" ts; ts="$(date +%Y%m%d_%H%M%S)"; mkdir -p "$STATE_DIR/report_attempts"
  mv "$REPORT" "$STATE_DIR/report_attempts/${TASK}_${ts}_${st}.md" 2>/dev/null; log "archived retryable report STATUS=$st"; }

# 🔴🔴 ЦЕЛЬ ПАНЕЛИ: "=имя:" С ДВОЕТОЧИЕМ, а не "=имя" (найдено и замерено 15.08.2026, T263).
# В tmux 3.4 префикс "=" (точное совпадение имени) понимают ТОЛЬКО таргеты сессии и окна.
# Команды, которым нужен таргет ПАНЕЛИ — capture-pane, send-keys, paste-buffer — на "=имя"
# отвечают «can't find pane» и возвращают 1. Замер на живой сессии:
#   tmux capture-pane -p -t "=t263probe"   -> can't find pane: =t263probe   (пусто)
#   tmux capture-pane -p -t "=t263probe:"  -> содержимое панели             (работает)
#   tmux send-keys    -t "=t263probe"      -> rc=1, ничего не доставлено
#   tmux send-keys    -t "=t263probe:"     -> rc=0, текст в панели
# Последствия, которые из-за `2>/dev/null` были БЕСШУМНЫМИ:
#   * pane_tail всегда возвращал ПУСТО -> rate_limit_line никогда не совпадал -> ветка
#     RATE-LIMIT у этого супервизора не могла сработать НИ РАЗУ;
#   * remind_commit и remind_report «отправляли» напоминание в никуда, а в лог писали, что
#     отправили (лончер спасался тем, что шлёт промпт БЕЗ "=" — строки 112-114 его шаблона).
# Это же делало невозможной саму задачу T263: детектор ошибки связи читает ту же панель.
# kill-session ниже трогать не нужно — там таргет СЕССИИ, и "=" для него законен (проверено).
pane_tail(){ tmux capture-pane -p -t "=$PANE_SESSION:" 2>/dev/null | tail -n 40; }
rate_limit_line(){ pane_tail | grep -aiE "$RATE_LIMIT_RE" | tail -1; }
# Из строки лимита достаёт время сброса и печатает, сколько секунд до него спать.
# Печатает пусто и возвращает 1, когда времени в строке нет или разобрать не вышло —
# вызывающий тогда берёт фиксированную паузу RATE_LIMIT_WAIT_SECONDS (прежнее поведение).
# Разбираются три записи, в порядке надёжности:
#   1) абсолютная  «... reset at 2026-08-21 03:00», «2026-08-21T03:00»
#   2) 12-часовая  «resets at 4:30pm», «resets 3pm», «will reset at 11 am»
#   3) 24-часовая  «resets at 15:00»
# Часовой пояс берётся из скобок, если он там есть: «(Europe/Moscow)», «(UTC)». Нет скобок —
# считаем в поясе машины: у Claude Code время в сообщении местное, и это верное умолчание.
# 🔴 Время без даты, которое уже прошло, означает сброс завтра — иначе получили бы отрицательную
# паузу и мгновенную побудку в закрытый лимит.
rate_limit_reset_wait(){
  local line="$1" tz spec now target wait
  tz="$(printf '%s\n' "$line" | grep -aoE '\((UTC|GMT|[A-Za-z]+/[A-Za-z_+-]+)\)' | head -1 | tr -d '()')"

  spec="$(printf '%s\n' "$line" | grep -aoE '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{1,2}:[0-9]{2}' | head -1 | tr 'T' ' ')"
  [ -n "$spec" ] || spec="$(printf '%s\n' "$line" \
    | grep -aoiE 'reset[a-z]*[[:space:]]+(at[[:space:]]+)?[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)' \
    | head -1 | grep -aoiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)$' | tr -d '[:space:]')"
  [ -n "$spec" ] || spec="$(printf '%s\n' "$line" \
    | grep -aoiE 'reset[a-z]*[[:space:]]+(at[[:space:]]+)?[0-9]{1,2}:[0-9]{2}' \
    | head -1 | grep -aoE '[0-9]{1,2}:[0-9]{2}$')"
  [ -n "$spec" ] || return 1

  now=$(date +%s)
  if [ -n "$tz" ]; then target="$(TZ="$tz" date -d "$spec" +%s 2>/dev/null || true)"
  else                 target="$(date -d "$spec" +%s 2>/dev/null || true)"; fi
  [ -n "$target" ] || return 1

  if [ "$target" -le "$now" ]; then
    if [ -n "$tz" ]; then target="$(TZ="$tz" date -d "tomorrow $spec" +%s 2>/dev/null || true)"
    else                 target="$(date -d "tomorrow $spec" +%s 2>/dev/null || true)"; fi
    [ -n "$target" ] || return 1
  fi

  wait=$(( target - now + RATE_LIMIT_MARGIN_SECONDS ))
  [ "$wait" -lt "$RATE_LIMIT_WAIT_MIN_SECONDS" ] && wait="$RATE_LIMIT_WAIT_MIN_SECONDS"
  [ "$wait" -gt "$RATE_LIMIT_WAIT_MAX_SECONDS" ] && wait="$RATE_LIMIT_WAIT_MAX_SECONDS"
  echo "$wait"
}
api_error_line(){ pane_tail | grep -aiE "$API_ERROR_RE" | tail -1; }
# Классификация хвоста панели: RATE_LIMIT | API_ERROR | NONE.
# Текст панели читается со stdin, ВТОРОЙ признак (возраст транскрипта в секундах) — аргументом.
# 🔴 Вынесено отдельной функцией специально: её можно прогнать на образцах панели харнессом
# (supervisor_api_error_selftest.sh), не поднимая ни агента, ни tmux, ни очередь.
# Порядок веток = приоритет: лимит сессии решается раньше и в API-ветку не попадает никогда.
classify_pane(){
  local quiet txt
  quiet="${1:-0}"
  txt="$(cat)"
  if printf '%s\n' "$txt" | grep -aqiE "$RATE_LIMIT_RE"; then printf 'RATE_LIMIT\n'; return 0; fi
  if [ "$quiet" -ge "$API_ERROR_QUIET" ] && printf '%s\n' "$txt" | grep -aqiE "$API_ERROR_RE"; then
    printf 'API_ERROR\n'; return 0
  fi
  printf 'NONE\n'; return 0
}
# Ночной час владельца (по МСК) — пинги не шлём, причина остаётся в логе. 0 = сейчас ночь.
api_night_now(){
  local h from to
  h="$(TZ="$API_ERROR_NIGHT_TZ" date +%H 2>/dev/null || date +%H)"
  h="${h#0}"; [ -n "$h" ] || h=0
  from="$API_ERROR_NIGHT_FROM"; to="$API_ERROR_NIGHT_TO"
  [ "$from" = "$to" ] && return 1
  if [ "$from" -lt "$to" ]; then
    [ "$h" -ge "$from" ] && [ "$h" -lt "$to" ] && return 0
    return 1
  fi
  { [ "$h" -ge "$from" ] || [ "$h" -lt "$to" ]; } && return 0
  return 1
}
notify_daytime(){
  if api_night_now; then log "NIGHT: пинг не шлю (владелец спит), причина только в логе — $*"; return 0; fi
  notify "$@"
}
# 🔴 jsonl СВОЕЙ сессии (фикс 2026-07-30, ПЕРЕДЕЛАН 2026-08-03 после потери T161).
# Было: файл «прилипал» к сессии через переменную SUB_JSONL. Прилипание НЕ РАБОТАЛО — функция
# зовётся как J="$(newest_jsonl)", то есть в ПОДОБОЛОЧКЕ, и присваивание умирало вместе с ней.
# Каждый опрос заново брал первый по АЛФАВИТУ новый файл. Пока исполнитель был один, это совпадало
# с его собственным транскриптом и дефекта не было видно. При параллели (разрешена 02.08) сосед с
# «младшим» UUID забирал слежение себе: 03.08 супервизор живого T161 следил за транскриптом умершего
# T159 и через 1800 с убил бы здорового исполнителя по ложному STALL.
# Стало: выбор запоминается в ФАЙЛЕ (переживает подоболочку), а сам выбор делается по СОДЕРЖИМОМУ —
# берём транскрипт, в котором упомянут наш TASK. Совпадения по алфавиту и по времени больше не решают.
SUB_JSONL=""; PRE_JSONL=""
JSONL_PIN="${JSONL_PIN:-$STATE_DIR/${TASK}.jsonlpin}"
snapshot_jsonl(){ PRE_JSONL="$(find "$JSONL_DIR" -maxdepth 1 -name '*.jsonl' 2>/dev/null | sort)"; rm -f "$JSONL_PIN" 2>/dev/null; }
newest_jsonl(){
  local pinned f cand=""
  pinned="$(cat "$JSONL_PIN" 2>/dev/null)"
  if [ -n "$pinned" ] && [ -f "$pinned" ]; then printf '%s' "$pinned"; return 0; fi
  # Кандидаты = файлы, которых не было до запуска (чужие старые сессии отсеиваются снимком).
  for f in $(find "$JSONL_DIR" -maxdepth 1 -name '*.jsonl' -newermt "@$LAUNCH_TS" 2>/dev/null | sort); do
    case "$PRE_JSONL" in *"$f"*) continue ;; esac
    # Свой транскрипт узнаём по имени задачи в промпте — единственный надёжный признак.
    if grep -qa -- "$TASK" "$f" 2>/dev/null; then printf '%s' "$f" > "$JSONL_PIN"; printf '%s' "$f"; return 0; fi
    [ -z "$cand" ] && cand="$f"
  done
  # Имя задачи ещё не долетело до транскрипта (первые секунды) — отвечаем кандидатом, но НЕ
  # закрепляем его: на следующем опросе снова попробуем найти свой по содержимому.
  printf '%s' "$cand"
}

kill_agent(){
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$pid" ]; then
    kill -CONT "$pid" 2>/dev/null
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 15); do alive_pid "$pid" || break; sleep 1; done
    alive_pid "$pid" && kill -KILL "$pid" 2>/dev/null
  fi
  tmux kill-session -t "=$PANE_SESSION" 2>/dev/null
  sleep 2
}

# --- RAM-гейт перед запуском агента (12.08.2026) -------------------------------
# RAM-сторож v3 при EMERG убивает дерево-жертву, и агент может умереть НЕ по своей вине.
# Раньше respawn шёл мгновенно: сторож убил -> супервизор тут же поднял -> снова упёрлись в
# память -> сожгли квоту MAX_RESPAWN и в итоге ушли в карантин на ровном месте. Теперь перед
# КАЖДЫМ запуском агента ждём, пока памяти реально хватит и пока снят флаг паузы сторожа.
# Память есть — стартуем сразу, ничего не замедляя.
RAM_RESPAWN_MIN_KB="${RAM_RESPAWN_MIN_KB:-1100000}"   # ниже этого MemAvailable агента не поднимаем
RAM_WAIT_MAX="${RAM_WAIT_MAX:-2700}"                  # предел ожидания; дальше стартуем всё равно
RAM_PAUSE_FLAG="${RAM_PAUSE_FLAG:-/tmp/ram_paused}"
ram_avail_kb(){ awk '/MemAvailable/{print $2}' /proc/meminfo; }
wait_for_ram(){
  local waited=0 avail paused
  while :; do
    avail="$(ram_avail_kb)"
    paused=no; [ -f "$RAM_PAUSE_FLAG" ] && paused=yes
    if [ "${avail:-0}" -ge "$RAM_RESPAWN_MIN_KB" ] && [ "$paused" = no ]; then
      [ "$waited" -gt 0 ] && log "RAM ок (avail=${avail}KB) после ожидания ${waited}s — запускаю агента"
      return 0
    fi
    if [ "$waited" -ge "$RAM_WAIT_MAX" ]; then
      log "RAM ждал ${waited}s (avail=${avail}KB, pause=$paused) — запускаю всё равно"
      notify "RAM: $TASK стартует после ${waited}s ожидания памяти (avail=${avail}KB)" 2>&1 | tail -1
      return 0
    fi
    [ "$waited" -eq 0 ] && log "RAM низкая (avail=${avail}KB < ${RAM_RESPAWN_MIN_KB}KB, pause=$paused) — жду перед запуском агента"
    sleep 15; waited=$((waited+15))
  done
}
# ------------------------------------------------------------------------------
launch_agent(){
  wait_for_ram
  rm -f "$PID_FILE"
  reminded=0            # новый агент — своя квота напоминаний про отчёт
  SUB_JSONL=""          # 2026-07-30: новая сессия — заново прилипаем к её jsonl
  snapshot_jsonl        # снимок ДО старта: чужие файлы в него попадут и будут отсеяны
  LAUNCH_TS=$(date +%s)
  PROJECT_DIR="$PROJECT_DIR" TASK="$TASK" TASK_FILE="$TASK_FILE" PID_FILE="$PID_FILE" \
    PANE_SESSION="$PANE_SESSION" PROMPT_FILE="$PROMPT_FILE" JSONL_DIR="$JSONL_DIR" \
    CLAUDE_EXTRA_ARGS="${CLAUDE_EXTRA_ARGS:-}" \
    setsid bash "$LAUNCHER" </dev/null >>"$LOG_DIR/${TASK}_launch.log" 2>&1 &
  for _ in $(seq 1 10); do sleep 3; [ -s "$PID_FILE" ] && break; done
  SUB_PID="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$SUB_PID" ] && alive_pid "$SUB_PID"; then log "launched REPL SUB_PID=$SUB_PID session=$PANE_SESSION"; return 0; fi
  log "launch failed: no live SUB_PID"; return 1
}

handle_rate_limit(){
  local rl tries=0 wait src upto
  rl="$(rate_limit_line)"; [ -n "$rl" ] || return 1
  while :; do
    tries=$((tries+1))
    if wait="$(rate_limit_reset_wait "$rl")"; then
      upto="$(date -d "+${wait} seconds" '+%F %T' 2>/dev/null || echo '?')"
      src="до сброса из сообщения, проснусь $upto"
    else
      wait="$RATE_LIMIT_WAIT_SECONDS"
      src="фиксированная пауза: времени сброса в строке нет"
    fi
    log "RATE-LIMIT «$rl» wait ${wait}s — $src (${tries}/${RATE_LIMIT_MAX_WAITS})"
    notify "⏳ $TASK: лимит Claude — жду ~$((wait/60)) мин ($src), потом перезапуск (RL #$tries)" 2>&1 | tail -1
    kill_agent
    sleep "$wait"
    launch_agent && return 0
    [ "$tries" -ge "$RATE_LIMIT_MAX_WAITS" ] && { log "FATAL: RL persisted"; return 2; }
    # Панель перечитываем: за время сна сообщение могло смениться на другое время сброса.
    rl="$(rate_limit_line)"; [ -n "$rl" ] || rl="лимит (строка ушла из панели)"
  done
}

# Отчёт есть, но строки STATUS в нём нет. Пишет ли его агент прямо сейчас?
# «Да» = процесс жив И (файл отчёта ИЛИ транскрипт менялись за последние REPORT_GRACE секунд).
report_is_draft(){
  local now rage jage J
  alive_pid "$SUB_PID" || return 1
  now=$(date +%s)
  rage=$(( now - $(stat -c %Y "$REPORT" 2>/dev/null || echo 0) ))
  jage=999999; J="$(newest_jsonl)"
  [ -n "$J" ] && [ -f "$J" ] && jage=$(( now - $(stat -c %Y "$J") ))
  if [ "$rage" -lt "$REPORT_GRACE" ] || [ "$jage" -lt "$REPORT_GRACE" ]; then
    log "report без STATUS, но агент ЖИВ и пишет (отчёт ${rage}s, jsonl ${jage}s < ${REPORT_GRACE}s) — ждём, не трогаем"
    return 0
  fi
  return 1
}

# Доведена ли работа до git? Признаки, любой = «не доведена»:
# 1) в отчёте плейсхолдер вместо хеша коммита; 2) коммита, трогающего САМ ФАЙЛ ОТЧЁТА, за время
# задачи не появилось, а в дереве лежат незакоммиченные изменения.
# 🔴 ПОПРАВКА 13.08.2026 по итогам первой боевой ночи гейта. Первая версия считала «не доведено»
# по ГРЯЗНОМУ ДЕРЕВУ репозитория — и это оказалось слишком широко: репозиторий общий, в нём лежат
# файлы соседних задач, чужие хвосты и правки человека. Ночью 12→13.08 гейт трижды честно позвал
# агента, агент ТРИЖДЫ ПОСЛУШАЛСЯ (коммиты a3701fd/bbea365, 36ad29c/e5f4d6c, cb69f85/124f1ca —
# в том числе «вписан фактический хеш вместо плейсхолдера»), но дерево всё равно оставалось
# грязным из-за чужих файлов, и гейт трижды написал «работа так и не в git» и разбудил TG зря.
# 🔴 ВТОРАЯ ПОПРАВКА 13.08.2026 (вечер, долг из SESSION_LOG_2026-08-13 §2). Замена «чистое дерево»
# на «сдвинулся HEAD» починила ложные срабатывания, но завела ложное МОЛЧАНИЕ: HEAD двигают и
# соседние задачи общей очереди, и человек, коммитящий по ходу ЧУЖОЙ работы. Так прошёл T248 —
# работа исполнителя осталась незакоммиченной, гейт увидел чужой коммит и не позвал никого,
# коммит потом делал человек (4c9f374).
# Правильный признак — коммит, трогающий САМ ФАЙЛ ОТЧЁТА: отчёт пишет только исполнитель, и по
# предписанному порядку «коммит и пуш → хеш в отчёт → STATUS» такой коммит обязан существовать к
# моменту проверки. Дописанные ПОСЛЕ коммита хеш и строка STATUS ложным срабатыванием не станут:
# проверяется ФАКТ коммита отчёта, а не чистота файла (иначе гейт звал бы на каждой задаче).
# Отчёт вне репозитория или под .gitignore (проект не хранит отчёты в git) — признак недоступен,
# работаем по прежнему: сдвинулся HEAD, значит довёл.
commit_head_now(){ git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null; }
COMMIT_BASE_HEAD="$(commit_head_now)"

# 0 — файл отчёта закоммичен за время задачи (или судить по нему нельзя, а HEAD сдвинулся).
commit_report_done(){
  local root head rep own
  root="$1"; head="$2"
  [ -n "$head" ] || return 1
  [ "$head" != "$COMMIT_BASE_HEAD" ] || return 1          # за задачу не появилось НИ ОДНОГО коммита
  [ -n "$COMMIT_BASE_HEAD" ] || return 0                  # репозиторий был пуст — судить не по чему
  rep="$(readlink -f "$REPORT" 2>/dev/null || printf '%s' "$REPORT")"
  case "$rep" in
    "$root"/*) ;;
    *) log "COMMIT-GATE: отчёт вне репозитория ($rep) — сужу по факту коммита"; return 0 ;;
  esac
  if git -C "$root" check-ignore -q "$rep" 2>/dev/null; then
    log "COMMIT-GATE: отчёт под .gitignore — сужу по факту коммита"; return 0; fi
  own="$(git -C "$root" log --format=%h "$COMMIT_BASE_HEAD..$head" -- "$rep" 2>/dev/null | head -1)"
  [ -n "$own" ] || return 1                               # коммиты есть, но отчёт в них не входит — чужие
  log "COMMIT-GATE: отчёт закоммичен за время задачи ($own) — работа доведена"
  return 0
}

commit_pending(){
  [ "$COMMIT_GATE" = 1 ] || return 1
  local root dirty head
  root="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$root" ] || return 1
  # плейсхолдер вместо хеша — всегда повод, независимо от коммитов
  if grep -aqE "$COMMIT_PLACEHOLDER_RE" "$REPORT" 2>/dev/null; then
    log "COMMIT-GATE: в отчёте плейсхолдер вместо хеша коммита"; return 0; fi
  head="$(commit_head_now)"
  [ -n "$head" ] || return 1                              # не git-дерево — гейту нечего проверять
  commit_report_done "$root" "$head" && return 1
  dirty="$(git -C "$root" status --porcelain 2>/dev/null | head -20)"
  if [ -n "$dirty" ]; then
    log "COMMIT-GATE: своего коммита (с отчётом) за задачу нет, а дерево $root грязное:"
    printf '%s\n' "$dirty" | while IFS= read -r l; do log "    $l"; done
    return 0; fi
  return 1
}

# Напоминание в REPL агента: доведи до git. Пишется ОДИН раз, дальше ждём COMMIT_GRACE.
remind_commit(){
  local msg="$STATE_DIR/${TASK}_commitmsg.txt"
  cat > "$msg" <<EOF
Проверка очереди: строка STATUS в отчёте есть, но работа НЕ доведена до git — либо в рабочем дереве
остались незакоммиченные изменения, либо в отчёте стоит плейсхолдер вместо хеша коммита.
Задача не считается выполненной, пока изменений нет в git (правило проекта).
Сделай СЕЙЧАС, ничего не переделывая: git add по своей зоне -> git commit (ТОЛЬКО от agentuser) -> git push,
затем впиши РЕАЛЬНЫЙ хеш в отчёт вместо плейсхолдера. Строку STATUS не трогай, она уже на месте.
Если что-то коммитить сознательно не нужно (тяжёлое сырьё, чужая зона) — напиши это в отчёте одной
строкой, чтобы следующий не гадал.
EOF
  tmux load-buffer -b "cb_$TASK" "$msg" 2>/dev/null
  tmux paste-buffer -b "cb_$TASK" -t "=$PANE_SESSION:" 2>/dev/null
  sleep 1
  tmux send-keys -t "=$PANE_SESSION:" Enter 2>/dev/null
  rm -f "$msg" 2>/dev/null
  date +%s > "$COMMIT_NUDGE_TS"
  log "COMMIT-GATE: агенту отправлено напоминание довести работу до git (ждём ${COMMIT_GRACE}s)"
  notify "⏳ $TASK: отчёт готов, но работа не в git — попросил агента закоммитить" 2>&1|tail -1
}

# Возвращает 0, если надо ПРОДОЛЖАТЬ ждать (агент дочищает git), 1 — можно закрывать.
commit_gate_hold(){
  commit_pending || return 1
  alive_pid "$SUB_PID" || { log "COMMIT-GATE: работа не в git, но агент уже мёртв — закрываю как есть"
    notify "🔴 $TASK: закрыт с НЕЗАКОММИЧЕННОЙ работой (агент мёртв) — нужен коммит человеком" 2>&1|tail -1; return 1; }
  if [ ! -f "$COMMIT_NUDGE_TS" ]; then remind_commit; return 0; fi
  local waited=$(( $(date +%s) - $(cat "$COMMIT_NUDGE_TS" 2>/dev/null || echo 0) ))
  if [ "$waited" -lt "$COMMIT_GRACE" ]; then
    log "COMMIT-GATE: жду коммита ${waited}s/${COMMIT_GRACE}s"; return 0; fi
  log "COMMIT-GATE: ${COMMIT_GRACE}s прошло, работа так и не в git — закрываю задачу как есть"
  notify "🔴 $TASK: закрыт, но работа НЕ доведена до git за ${COMMIT_GRACE}s — проверь и закоммить" 2>&1|tail -1
  return 1
}

finish_on_report(){
  sleep 2; local st sz; st="$(report_status)"; sz=$(wc -c < "$REPORT" 2>/dev/null || echo 0)
  case "$st" in SUCCESS|FAIL|BLOCKED|PARTIAL) commit_gate_hold && return 11 ;; esac
  case "$st" in
    SUCCESS) log "SUCCESS report=$REPORT ${sz}b"; notify "✅ $TASK: УСПЕХ — $REPORT ($sz b)" 2>&1|tail -1; kill_agent; exit 0 ;;
    FAIL|BLOCKED|PARTIAL)
      if status_in_list "$st" "$RETRY_STATUSES"; then return 10; fi
      log "DONE-NOT-SUCCESS STATUS=$st"; notify "⚠️ $TASK: завершился STATUS=$st (не успех): $REPORT" 2>&1|tail -1; kill_agent; exit 2 ;;
    *)
      report_is_draft && return 11
      log "AMBIGUOUS: report without STATUS line"; notify "⚠️ $TASK: отчёт без строки STATUS — проверь вручную: $REPORT" 2>&1|tail -1; kill_agent; exit 3 ;;
  esac
}

# Напоминание агенту в его же REPL: работа выглядит законченной, а отчёта со STATUS нет.
# Дешевле любого respawn'а — агент со своим контекстом просто дописывает файл.
remind_report(){
  local msg="$STATE_DIR/${TASK}_remind.txt"
  cat > "$msg" <<EOF
Проверка очереди: файл отчёта $REPORT не найден или в нём нет последней строки STATUS.
Задача не может быть закрыта. Создай файл $REPORT (именно с таким именем), опиши в нём результат работы,
и последней строкой файла напиши STATUS: SUCCESS, FAIL, PARTIAL или BLOCKED. Заново работу не переделывай.
EOF
  tmux load-buffer -b "rb_$TASK" "$msg" 2>/dev/null
  tmux paste-buffer -b "rb_$TASK" -t "=$PANE_SESSION:" 2>/dev/null
  sleep 1
  tmux send-keys -t "=$PANE_SESSION:" Enter 2>/dev/null
  rm -f "$msg" 2>/dev/null
  log "REMIND: агенту отправлено напоминание про $REPORT со строкой STATUS"
}

# Побудка агента, вставшего на ошибке связи — тем же способом, что remind_commit/remind_report:
# load-buffer + paste-buffer + Enter в ЕГО ЖЕ панель. Контекст агента при этом цел, работа не
# теряется — ровно так 15.08 человек руками поднял T259 одним сообщением.
wake_api_error(){
  local msg
  msg="$STATE_DIR/${TASK}_apiwake.txt"
  cat > "$msg" <<'EOF'
Связь восстановилась. Продолжай с того места, где остановился: заново ничего не переделывай,
повтори последний шаг, который не прошёл из-за обрыва связи, и иди дальше по задаче.
EOF
  tmux load-buffer -b "ab_$TASK" "$msg" 2>/dev/null
  tmux paste-buffer -b "ab_$TASK" -t "=$PANE_SESSION:" 2>/dev/null
  sleep 1
  tmux send-keys -t "=$PANE_SESSION:" Enter 2>/dev/null
  rm -f "$msg" 2>/dev/null
}

# Ветка «агент стоит на ошибке связи». Аргумент — возраст транскрипта (с).
# Возврат: 0 — вопрос разобран, главный цикл делает continue; 1 — ошибки нет, обычная логика.
# 🔴 Единственное сознательное изменение поведения STALL: если в панели ЕСТЬ ошибка связи, сначала
# идут ограниченные побудки и только потом снятие. Ждать до STALL_LIMIT в этом случае бессмысленно —
# сам он не оживёт (T259: 1 ч 12 мин пустого ожидания). Если ошибки в панели нет, эта функция
# возвращает 1 и НИЧЕГО не меняет: все прежние ветки работают как работали.
handle_api_error(){
  local age cls line waited
  age="$1"
  cls="$(pane_tail | classify_pane "$age")"
  if [ "$cls" = RATE_LIMIT ]; then
    # Лимит сессии живёт своей логикой (handle_rate_limit на смерти агента и на STALL). Здесь
    # только отмечаем факт один раз, чтобы в логе было видно, почему API-ветка промолчала.
    if [ "$api_rl_noted" != 1 ]; then
      log "RATE-LIMIT в панели при живом агенте (jsonl тих ${age}s) — это НЕ ошибка связи, API-ветка не вмешивается"
      api_rl_noted=1
    fi
    return 1
  fi
  api_rl_noted=0
  if [ "$cls" != API_ERROR ]; then
    if [ "$api_tries" -gt 0 ]; then
      if [ "$age" -lt "$API_ERROR_QUIET" ]; then
        log "API-ERROR: разбудил, агент продолжил (побудок ${api_tries}, транскрипт ожил: ${age}s) — счётчик обнулён"
        api_tries=0; api_wake_ts=0
      else
        # 🔴 Строка ошибки ушла из хвоста панели, а транскрипт ВСЁ ЕЩЁ молчит — это НЕ «ожил».
        # Найдено стендом 15.08: каждая побудка сама дописывает текст в панель и сдвигает её, так
        # что ошибка может уехать из последних 40 строк. Обнулять счётчик здесь нельзя — побудки
        # пошли бы по кругу и до эскалации дело не дошло бы никогда. Счётчик сохраняем, дальше
        # работает обычная логика STALL.
        log "API-ERROR: строки ошибки в панели больше нет, но транскрипт молчит ${age}s — это не «ожил»: счётчик побудок сохранён (${api_tries}/${API_ERROR_TRIES}), дальше обычная логика STALL"
      fi
    fi
    return 1
  fi
  # Совпали ОБА признака: ошибка в хвосте панели и тишина транскрипта ≥ API_ERROR_QUIET.
  if [ "$api_tries" -gt 0 ] && [ "$api_wake_ts" -gt 0 ]; then
    waited=$(( $(date +%s) - api_wake_ts ))
    if [ "$waited" -lt "$API_ERROR_GRACE" ]; then
      log "API-ERROR: жду после побудки ${waited}s/${API_ERROR_GRACE}s (попытка ${api_tries}/${API_ERROR_TRIES}, jsonl тих ${age}s)"
      return 0
    fi
  fi
  line="$(api_error_line)"
  if [ "$api_tries" -lt "$API_ERROR_TRIES" ]; then
    api_tries=$((api_tries+1)); api_wake_ts=$(date +%s)
    log "API-ERROR: «$line» + транскрипт тих ${age}s → бужу агента в его панели (попытка ${api_tries}/${API_ERROR_TRIES})"
    wake_api_error
    return 0
  fi
  log "API-ERROR: 🔴 агент встал на ошибке связи, разбудить не удалось за ${API_ERROR_TRIES} попыт(ок) («$line») → снимаю, не жду до STALL ${STALL_LIMIT}s"
  api_tries=0; api_wake_ts=0
  kill_agent
  respawns=$((respawns+1))
  if [ "$respawns" -gt "$MAX_RESPAWN" ]; then
    log "FATAL: respawn-лимит исчерпан после ошибки связи — задача уходит в карантин (§24), причина: встал на ошибке связи"
    notify_daytime "❌ $TASK: агент встал на ошибке связи, разбудить не удалось — снят, авто-рестарта нет"
    exit 1
  fi
  notify_daytime "♻️ $TASK: агент стоял на ошибке связи (${API_ERROR_TRIES} побудки без ответа) → respawn $respawns/$MAX_RESPAWN"
  launch_agent || exit 1
  return 0
}

# 🔴 Харнесс: SUPERVISOR_SELFTEST=1 — только определить функции и выйти, агента не поднимать.
# Позволяет прогонять детекторы (classify_pane и др.) на образцах панели прямо из БОЕВОГО файла,
# а не с его копии, которая назавтра разъедется с оригиналом.
if [ "${SUPERVISOR_SELFTEST:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

respawns=0; LAUNCH_TS=0; SUB_PID=""; reminded=0
# Анти-петля: если файл отчёта УЖЕ существует — НЕ поднимаем поверх него свежего агента вслепую.
# Пусть finish_on_report решит исход: SUCCESS→0, FAIL/BLOCKED/PARTIAL→2, отчёт БЕЗ строки STATUS
# (AMBIGUOUS)→3 — во всех случаях БЕЗ перезапуска. Только ретраебельный статус архивируем и стартуем заново.
# (Раньше: при пустом статусе launch_agent запускался поверх STATUS-less отчёта → бесконечный respawn,
#  а для live/1С — шторм рестартов кассы. См. GOTCHAS #5.)
if [ -f "$REPORT" ]; then
  st="$(report_status)"
  if [ -n "$st" ] && status_in_list "$st" "$RETRY_STATUSES"; then
    archive_report_attempt "$st"          # ретраебельный — старый отчёт в архив, ниже свежий запуск
  else
    finish_on_report                      # выйдет для SUCCESS/FAIL/BLOCKED/PARTIAL и для AMBIGUOUS (exit 3)
  fi
fi
launch_agent || { handle_rate_limit || { notify "❌ $TASK supervisor: не смог запустить агента"; exit 1; }; }
log "supervisor start task=$TASK max_respawn=$MAX_RESPAWN stall=${STALL_LIMIT}s jsonl=$JSONL_DIR"

while true; do
  sleep "$POLL"

  if resolve_report; then
    finish_on_report; rc=$?
    # 🔴 ЧЕРНОВИК ОТЧЁТА НЕ ОТМЕНЯЕТ ПРОВЕРКУ СВЯЗИ (фикс 07.09.2026, кейс T339).
    # Было: эта ветка делала continue сразу — и главный цикл ни разу не доходил до
    # handle_api_error ниже. А отчёт «по ходу» у нас обязателен в каждом таск-файле, то есть
    # файл отчёта появляется в первые минуты работы. Итог: детектор ошибки связи, заведённый
    # 15.08 (T263), для реальных задач был выключен с самого начала — срабатывал только у тех,
    # кто отчёт ещё не создал. 07.09 агент T339 простоял 1 ч 11 мин на «API Error: Unable to
    # connect to API (ENOTIMP)», супервизор всё это время писал «агент ЖИВ и пишет», и толкать
    # его пришлось руками. В журнале задачи не было ни одной строки со словом API.
    # Стало: у черновика сначала спрашиваем панель — не стоит ли агент на обрыве связи, — и
    # только потом ждём дальше. Ошибки в панели нет → handle_api_error вернёт 1 и ничего не
    # изменит, поведение прежнее.
    if [ "$rc" -eq 11 ]; then
      Jd="$(newest_jsonl)"
      if [ -n "$Jd" ] && [ -f "$Jd" ]; then
        AGEd=$(( $(date +%s) - $(stat -c %Y "$Jd") ))
        handle_api_error "$AGEd" || true
      fi
      continue
    fi
    if [ "$rc" -eq 10 ]; then st="$(report_status)"; archive_report_attempt "$st"; kill_agent
      respawns=$((respawns+1)); [ "$respawns" -gt "$MAX_RESPAWN" ] && { log "FATAL respawn exhausted"; exit 1; }
      log "retryable STATUS=$st; respawn $respawns/$MAX_RESPAWN"; launch_agent || exit 1; continue; fi
  fi

  if ! alive_pid "$SUB_PID"; then
    sleep 3
    resolve_report && finish_on_report
    if handle_rate_limit; then continue; fi
    respawns=$((respawns+1)); [ "$respawns" -gt "$MAX_RESPAWN" ] && { log "FATAL respawn exhausted"; notify "❌ $TASK: respawn-лимит исчерпан"; exit 1; }
    log "agent died without report; respawn $respawns/$MAX_RESPAWN"; notify "♻️ $TASK: агент умер → respawn $respawns/$MAX_RESPAWN" 2>&1|tail -1
    launch_agent || exit 1; continue
  fi

  if [ -f "$PAUSE_FLAG" ]; then log "RAM pause — stall-детект пропущен"; continue; fi

  J="$(newest_jsonl)"
  if [ -n "$J" ] && [ -f "$J" ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$J") ))
    # 🔴 Тишина транскрипта — НЕ диагноз (T263). Сначала выясняем, не стоит ли агент на ошибке
    # связи: у этого случая тишина такая же, а лечение другое — побудить, а не ждать час.
    # Ошибки в панели нет → функция возвращает 1 и дальше всё идёт ровно как раньше.
    if handle_api_error "$AGE"; then continue; fi
    if [ "$AGE" -ge "$STALL_LIMIT" ]; then
      # Перед respawn'ом различаем «завис» и «закончил, но отчёт не оформил». Интерактивный REPL
      # остаётся живым после ответа, поэтому тишина в транскрипте — ещё не признак зависания.
      # Напоминаем про отчёт REMIND_LIMIT раз; агент пишет файл → jsonl оживает → счётчик AGE падает сам.
      if [ "$reminded" -lt "$REMIND_LIMIT" ] && alive_pid "$SUB_PID"; then
        reminded=$((reminded+1))
        log "jsonl тих ${AGE}s, отчёта со STATUS нет — напоминание ${reminded}/${REMIND_LIMIT} вместо respawn"
        remind_report; continue
      fi
      log "STALL jsonl quiet ${AGE}s ≥ $STALL_LIMIT → kill+respawn"; kill_agent
      if handle_rate_limit; then continue; fi
      respawns=$((respawns+1)); [ "$respawns" -gt "$MAX_RESPAWN" ] && { log FATAL; notify "❌ $TASK: respawn-лимит"; exit 1; }
      notify "♻️ $TASK: завис (jsonl тих ${AGE}s) → respawn $respawns/$MAX_RESPAWN" 2>&1|tail -1
      launch_agent || exit 1; continue
    fi
    log "alive PID=$SUB_PID jsonl=${J##*/} age=${AGE}s respawns=$respawns"
  else
    NA=$(( $(date +%s) - LAUNCH_TS ))
    if [ "$NA" -ge "$NO_JSONL_LIMIT" ]; then
      log "NO-JSONL ${NA}s ≥ $NO_JSONL_LIMIT → kill+respawn"; kill_agent
      if handle_rate_limit; then continue; fi
      respawns=$((respawns+1)); [ "$respawns" -gt "$MAX_RESPAWN" ] && { log FATAL; exit 1; }
      launch_agent || exit 1; continue
    fi
    log "alive PID=$SUB_PID (jsonl ещё нет ${NA}s/${NO_JSONL_LIMIT}s)"
  fi
done
