#!/bin/bash
# Queue orchestrator for interactive Claude REPL task agents. Mirror of codex_orchestrator.
# Runs task files one-by-one (MAX_PARALLEL, default 1 for RAM) each under claude_supervisor,
# which launches an interactive `claude` REPL in tmux. Run AS the claude user.
#
# Dynamic queue: does NOT exit when the current tasks finish — it idles and keeps picking up
# NEW task files dropped into tasks/. Kill the orchestrator tmux session to stop.
#
# Required env: PROJECT_DIR
# Optional env: TASKS TASK_DIR REPORT_DIR LOG_DIR STATE_DIR PROGRESS OLOG SUPERVISOR
#   SESSION_PREFIX MAX_PARALLEL RAM_MIN_KB RETRY_STATUSES MAX_RESPAWN STALL_LIMIT
#   POLL RATE_LIMIT_WAIT_SECONDS IDLE_EXIT
set -u
unset TMUX TMUX_PANE
export LC_ALL=C.utf8 LANG=C.utf8

PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
TASK_DIR="${TASK_DIR:-$PROJECT_DIR/tasks}"
REPORT_DIR="${REPORT_DIR:-$PROJECT_DIR/reports}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state}"
PROGRESS="${PROGRESS:-$PROJECT_DIR/orch/progress.md}"
OLOG="${OLOG:-$LOG_DIR/claude_orchestrator.log}"
SUPERVISOR="${SUPERVISOR:-/work/settings/claude/claude_supervisor.template.sh}"
SESSION_PREFIX="${SESSION_PREFIX:-claude}"
MAX_PARALLEL="${MAX_PARALLEL:-1}"
RAM_MIN_KB="${RAM_MIN_KB:-900000}"
IDLE_EXIT="${IDLE_EXIT:-0}"
# Мин. интервал между стартами ОДНОГО таска: не перезапускать раньше, чем launcher успеет поднять
# REPL — иначе новый launcher своим `tmux kill-session` добьёт REPL ещё не вставшего предыдущего
# запуска → бесконечный churn (кейс T02 2026-07-16). Ставь > (STARTUP_WAIT launcher'а + PID-wait супервизора).
START_GRACE="${START_GRACE:-90}"
TASKS="${TASKS:-}"
# Терпим markdown-обёртку вокруг STATUS: `**STATUS: X**`, `*`, `#`, backtick, `>` (агенты часто пишут жирным) — иначе ложный AMBIGUOUS-карантин (кейс T23 2026-07-21).
STATUS_RE='^[[:space:]]*[*#`>[:space:]]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)[*`[:space:]]*$'

mkdir -p "$TASK_DIR" "$REPORT_DIR" "$LOG_DIR" "$STATE_DIR" "$(dirname "$PROGRESS")"
exec >> "$OLOG" 2>&1
log(){ echo "[$(date '+%F %T')] $*"; }
# Уведомления (TG и т.п.) — команда с ОДНИМ аргументом-сообщением. Пусто → no-op (шаблон без идентичности).
NOTIFY_CMD="${NOTIFY_CMD:-}"
notify(){ [ -n "$NOTIFY_CMD" ] && $NOTIFY_CMD "$*" >/dev/null 2>&1; return 0; }

discover_tasks(){ if [ -n "$TASKS" ]; then printf '%s\n' $TASKS; else
  find "$TASK_DIR" -maxdepth 1 -type f -name 'T*.md' -printf '%f\n' | sed 's/\.md$//' | sort; fi; }
# 🔴 Отчёт под ДРУГИМ именем (фикс 2026-07-30). Очередь ждала report_<ПОЛНОЕ_ИМЯ_ТАСКА>.md, а агенты
# регулярно называют файл короче: T121 → report_T121_honest_screen_and_register.md,
# T116 → report_T116_proactive_restart.md, T119 → report_T119_projecta2_parity.md. Итог: готовая работа со
# STATUS в отчёте уезжала в ЛОЖНЫЙ карантин «умер без отчёта», а лок держался до ручного вмешательства.
# Теперь: нет каноничного файла — ищем report_<номер таска>_*.md со строкой STATUS (самый свежий).
report_path(){
  local canon num cand
  canon="$REPORT_DIR/report_$1.md"
  [ -f "$canon" ] && { echo "$canon"; return 0; }
  num="$(printf '%s' "$1" | grep -oE '^T[0-9]+')"
  if [ -n "$num" ]; then
    cand="$(find "$REPORT_DIR" -maxdepth 1 -name "report_${num}_*.md" 2>/dev/null \
      | xargs -r grep -alE "$STATUS_RE" 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1)"
    [ -n "$cand" ] && { echo "$cand"; return 0; }
  fi
  echo "$canon"
}
task_file(){ echo "$TASK_DIR/$1.md"; }
session_name(){ echo "${SESSION_PREFIX}_$1_sup"; }
report_status(){ grep -aE "$STATUS_RE" "$1" 2>/dev/null | tail -1 \
  | sed -E 's/^[^S]*STATUS:[[:space:]]*//; s/[*`[:space:]]*$//' | tr '[:lower:]' '[:upper:]'; }
task_lock(){ grep -aE '^[[:space:]]*Resource-Lock:[[:space:]]*' "$1" 2>/dev/null | head -1 \
  | sed -E 's/^[[:space:]]*Resource-Lock:[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]'; }
tmux_alive(){ tmux has-session -t "=$1" 2>/dev/null; }
active_count(){ local n=0 s sess; for s in "$STATE_DIR"/*.session; do [ -f "$s" ]||continue
  sess=$(cat "$s" 2>/dev/null); [ -n "$sess" ] && tmux_alive "$sess" && n=$((n+1)); done; echo "$n"; }
lock_active(){ local lock="$1" lf task sess; { [ -z "$lock" ]||[ "$lock" = none ]; } && return 1
  for lf in "$STATE_DIR"/*.lock; do [ -f "$lf" ]||continue; [ "$(cat "$lf" 2>/dev/null)" = "$lock" ]||continue
    task="$(basename "$lf" .lock)"; sess="$(cat "$STATE_DIR/$task.session" 2>/dev/null)"
    [ -n "$sess" ] && tmux_alive "$sess" && return 0; done; return 1; }
ram_ok(){ local a; a=$(awk '/MemAvailable/{print $2}' /proc/meminfo); [ "${a:-0}" -ge "$RAM_MIN_KB" ]; }
# 🔴 ГЕЙТ ПО МЕСТУ НА ДИСКЕ (добавлен 12.08.2026, GOTCHAS #13). RAM-сторож меряет ПАМЯТЬ и
# переполнение диска не видит в принципе, а для WSL это смертельно: диск виртуалки — файл
# ext4.vhdx на томе Windows, он РАСТЁТ и (если не включена разрежённость) обратно место не
# отдаёт. Кончилось место на томе — файл расти не может, запись в гостевой ext4 отваливается
# ошибкой ввода-вывода, и виртуалка встаёт ЦЕЛИКОМ: все процессы одномоментно, без OOM.
# Кейс PROJECTA 12.08.2026: волна встала в 01:54 при 4 Gi свободной памяти; Windows подтвердил
# переполнение своей ошибкой в 02:05. Меряем ХОСТОВЫЙ том (в WSL это /mnt/c), а не гостевой:
# внутри виртуалки места сколько угодно, а расти файлу некуда.
DISK_MOUNT="${DISK_MOUNT:-}"
if [ -z "$DISK_MOUNT" ]; then [ -d /mnt/c ] && DISK_MOUNT=/mnt/c || DISK_MOUNT=/; fi
DISK_MIN_GB="${DISK_MIN_GB:-15}"
disk_free_gb(){ df -BG --output=avail "$DISK_MOUNT" 2>/dev/null | awk 'NR==2{gsub("G","");print $1}'; }
disk_ok(){ local g; g=$(disk_free_gb)
  [ -z "$g" ] && return 0          # не смогли измерить — не блокируем работу, но пишем в лог
  [ "$g" -ge "$DISK_MIN_GB" ]; }
mark_progress(){ local t="$1" s="$2"; grep -qa "\\b$t\\b.*STATUS=" "$PROGRESS" 2>/dev/null && return 0
  case "$s" in SUCCESS)   echo "- [x] $t STATUS=$s $(date '+%F %T')" >>"$PROGRESS";;
               AMBIGUOUS) echo "- [?] $t STATUS=AMBIGUOUS $(date '+%F %T')" >>"$PROGRESS";;
               *)         echo "- [~] $t STATUS=$s $(date '+%F %T')" >>"$PROGRESS";; esac; }
report_exists(){ [ -f "$(report_path "$1")" ]; }
quarantined(){ [ -f "$STATE_DIR/$1.ambiguous" ]; }

# --- Гейт грязного дерева (22.08.2026) ---------------------------------------
# Задача, объявившая SUCCESS, не должна оставлять работу незакоммиченной: рядом уже
# правит файлы следующий агент, и одна `git checkout` уносит целую смену. За ночь
# 22.08.2026 так едва не потерялись правки трёх задач сразу (T254, T281, T282):
# все три закрылись, а их изменения висели в рабочем дереве.
# Гейт не переписывает отчёт агента — он понижает вердикт в журнале и называет файлы.
# Выключить для проекта: GIT_DIRTY_GATE=0 в его раннере (_run_orch.sh).
# Где смотреть: GIT_DIRTY_DIRS. Что не считать грязью: GIT_DIRTY_IGNORE_RE.
GIT_DIRTY_GATE="${GIT_DIRTY_GATE:-1}"
GIT_DIRTY_DIRS="${GIT_DIRTY_DIRS:-$PROJECT_DIR/app $PROJECT_DIR}"
# Артефакты прогонов (снимки, логи, отчёты, сборочный мусор) в репозитории не держим —
# на них гейт молчит, иначе он срабатывал бы вхолостую после каждого прогона.
GIT_DIRTY_IGNORE_RE="${GIT_DIRTY_IGNORE_RE:-(^..[[:space:]]*(reports|logs|snapshots|screens)/|_screens/|\.log$|\.(png|jpg|jpeg|webp)$|tsconfig\.tsbuildinfo|next-env\.d\.ts)}"
# 🔴 Служебные файлы САМОЙ машинерии: журнал очереди, стоп-краны. Их пишет оркестратор, а не
# исполнитель — вменять их ему бессмысленно. До 10.09.2026 `progress.md` попадал почти в каждый
# список грязи и один вытягивал понижение статуса.
GIT_DIRTY_MACHINERY_RE="${GIT_DIRTY_MACHINERY_RE:-(orch/progress\.md$|/progress\.md$|ORCH_STOP$|WAVE_ON$)}"

dirty_files_raw(){                         # «репозиторий<TAB>строка porcelain», отсортировано
  [ "$GIT_DIRTY_GATE" = "1" ] || return 0
  local d top seen=" "
  for d in $GIT_DIRTY_DIRS; do
    [ -d "$d" ] || continue
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || continue
    [ -n "$top" ] || continue
    case "$seen" in *" $top "*) continue;; esac; seen="$seen$top "
    git -C "$top" status --porcelain 2>/dev/null \
      | grep -aEv "$GIT_DIRTY_IGNORE_RE" | grep -aEv "$GIT_DIRTY_MACHINERY_RE" \
      | sed "s|^|$top\t|"
  done | LC_ALL=C sort
  return 0
}

# Базовая отметка на старте задачи: что было грязным ДО того, как исполнитель начал работу.
dirty_baseline_save(){ [ "$GIT_DIRTY_GATE" = "1" ] || return 0; dirty_files_raw > "$STATE_DIR/$1.dirtybase" 2>/dev/null || :; return 0; }

# 🔴 ПРИРОСТ грязи за время задачи, а не грязь вообще (фикс 10.09.2026, разбор — GOTCHAS §22).
# Было: гейт смотрел ВСЁ дерево, поэтому исполнителя понижали за чужие файлы. Замер по логам:
# 64 срабатывания, и в свежих списках — файлы соседних задач (T353 понижена за зону T356,
# T357 — за скрипты T352/T355) плюс журнал самого оркестратора. Такой сигнал не читают.
# Стало: статус трогает только то, что появилось ПОСЛЕ старта задачи. Старое печатается отдельной
# строкой как информация — оно не теряется, но за него не наказывают.
dirty_tree_report(){                       # $1 — задача; печатает «каталог: файлы» по приросту
  [ "$GIT_DIRTY_GATE" = "1" ] || return 0
  local task="$1" base cur new top line files
  base="$STATE_DIR/$task.dirtybase"
  cur="$(dirty_files_raw)"
  [ -n "$cur" ] || return 0
  if [ -s "$base" ]; then
    new="$(printf '%s\n' "$cur" | LC_ALL=C comm -13 "$base" - 2>/dev/null)"
  else
    new="$cur"                             # базы нет (задача из прошлой жизни очереди) — как раньше
  fi
  [ -n "$new" ] || return 0
  printf '%s\n' "$new" | LC_ALL=C sort -u | awk -F'\t' 'NF==2 {a[$1]=a[$1] $2 ";"} END {for (t in a) printf "%s: %s\n", t, a[t]}'
  return 0
}

# Грязь, которая была ДО задачи: в лог как информация, статус не трогает.
dirty_preexisting(){
  [ "$GIT_DIRTY_GATE" = "1" ] || return 0
  local base="$STATE_DIR/$1.dirtybase"
  [ -s "$base" ] || return 0
  awk -F'\t' 'NF==2 {a[$1]=a[$1] $2 ";"} END {for (t in a) printf "%s: %s\n", t, a[t]}' "$base"
  return 0
}
# Live/1С-таск = НЕ перезапускать вслепую. Триггер: заголовок 'No-Respawn: true' в таск-файле
# ЛИБО Resource-Lock матчит live/касса/1С/vnc/прод/фискалку. Для таких: MAX_RESPAWN=0 и оркестратор
# не рестартит их после смерти (шторм рестартов кассы недопустим).
task_norespawn(){ local tf="$1" lock
  [ -f "$tf" ] || return 1
  grep -qaE '^[[:space:]]*No-Respawn:[[:space:]]*(true|yes|1)[[:space:]]*$' "$tf" 2>/dev/null && return 0
  lock="$(task_lock "$tf")"
  case "$lock" in node1c|node|1c|vnc_1c|vnc1c|vnc_99|live|prod|fiscal|ofd) return 0;; esac
  return 1; }

# Порог jsonl-столла (сек). GUI/live-таски (RustDesk/скрины/haiku-субагенты, длинные COM) легитимно молчат в jsonl
# долго — сидят ВНУТРИ одного долгого вызова инструмента → дефолт 600с ложно убивает рабочего агента (кейс T20 2026-07-20).
# Приоритет: явный заголовок 'Stall-Limit: N' в таск-файле → он; иначе no-respawn/live-таск → STALL_LIMIT_LIVE (деф. 1800);
# иначе глобальный STALL_LIMIT (деф. 600). Чистое ускорение времени детекта настоящего зависа для обычных тасков не меняется.
task_stall_limit(){ local tf="$1" v
  v="$(grep -aE '^[[:space:]]*Stall-Limit:[[:space:]]*[0-9]+' "$tf" 2>/dev/null | head -1 | sed -E 's/^[^0-9]*([0-9]+).*/\1/')"
  if [ -n "$v" ]; then echo "$v"; return 0; fi
  if task_norespawn "$tf"; then echo "${STALL_LIMIT_LIVE:-1800}"; return 0; fi
  echo "${STALL_LIMIT:-600}"; }

# Уровень размышлений агента — заголовок 'Effort: low|medium|high|xhigh|max' в таск-файле
# (24.08.2026, решение владельца). Зачем: диагностическим задачам глубина окупается (T309 разбила
# ложную догадку 312 нажатиями, T311 нашла max_keywords_per_run строкой из кода), а выкаткам,
# правкам текстов и уборкам она не нужна и стоит времени.
# Заголовка нет — ничего не передаём, поведение ровно прежнее. Мусор в заголовке игнорируется:
# лучше запустить агента на умолчании, чем не запустить вовсе.
task_effort(){ local tf="$1" v
  v="$(grep -aE '^[[:space:]]*Effort:[[:space:]]*[A-Za-z]+' "$tf" 2>/dev/null | head -1 \
       | sed -E 's/^[[:space:]]*Effort:[[:space:]]*//; s/[^A-Za-z].*$//' | tr '[:upper:]' '[:lower:]')"
  case "$v" in low|medium|high|xhigh|max) echo "$v" ;; *) echo "" ;; esac; }

# Модель агента — заголовок 'Model: opus|sonnet|haiku' в таск-файле (06.09.2026, решение владельца).
# Зачем: не всякой задаче нужна старшая модель. Механическая правка по готовому решению, перенос
# настройки, повтор известного прогона идут на sonnet без потери качества и заметно дешевле.
# Устроено ровно как Effort: заголовка нет — ничего не передаём, поведение прежнее; мусор в
# значении игнорируется, задача всё равно запускается на умолчании.
task_model(){ local tf="$1" v
  v="$(grep -aE '^[[:space:]]*Model:[[:space:]]*[A-Za-z0-9._-]+' "$tf" 2>/dev/null | head -1 \
       | sed -E 's/^[[:space:]]*Model:[[:space:]]*//; s/[^A-Za-z0-9._-].*$//' | tr '[:upper:]' '[:lower:]')"
  case "$v" in opus|sonnet|haiku|claude-*) echo "$v" ;; *) echo "" ;; esac; }

start_task(){
  local task="$1" tf report sess lock mr
  sess="$(session_name "$task")"
  # идемпотентность: НИКОГДА не пересоздаём (и не kill-session) живую сессию супервизора.
  if tmux_alive "$sess"; then log "start_task: $sess уже жив — пропуск"; return 0; fi
  tf="$(task_file "$task")"; report="$(report_path "$task")"
  lock="$(task_lock "$tf")"; [ -z "$lock" ] && lock=none
  mr="${MAX_RESPAWN:-4}"; if task_norespawn "$tf"; then mr=0; log "no-respawn таск $task (live/1С lock=$lock) → MAX_RESPAWN=0"; fi
  local sl; sl="$(task_stall_limit "$tf")"
  local ef md xargs; ef="$(task_effort "$tf")"; md="$(task_model "$tf")"
  xargs="${CLAUDE_EXTRA_ARGS:-}"; [ -n "$ef" ] && xargs="$xargs --effort $ef"
  [ -n "$md" ] && xargs="$xargs --model $md"
  echo "$lock" > "$STATE_DIR/$task.lock"; echo "$sess" > "$STATE_DIR/$task.session"
  date +%s > "$STATE_DIR/$task.started"
  dirty_baseline_save "$task"              # что было грязным ДО старта — не вина исполнителя
  tmux kill-session -t "=$sess" 2>/dev/null
  log "starting $task session=$sess lock=$lock max_respawn=$mr stall_limit=$sl effort=${ef:-умолчание} model=${md:-умолчание}"
  tmux new-session -d -s "$sess" -c "$PROJECT_DIR" \
    "TASK='$task' PROJECT_DIR='$PROJECT_DIR' TASK_FILE='$tf' REPORT='$report' LOG_DIR='$LOG_DIR' STATE_DIR='$STATE_DIR' PANE_SESSION='claude_${task}_repl' RETRY_STATUSES='${RETRY_STATUSES:-}' MAX_RESPAWN='$mr' STALL_LIMIT='$sl' POLL='${POLL:-10}' RATE_LIMIT_WAIT_SECONDS='${RATE_LIMIT_WAIT_SECONDS:-1500}' NOTIFY_CMD='${NOTIFY_CMD:-}' CLAUDE_EXTRA_ARGS='$xargs' bash '$SUPERVISOR'"
}

all_done(){ local t st; for t in $(discover_tasks); do
  quarantined "$t" && continue                      # карантин (AMBIGUOUS/no-respawn) — терминально
  st="$(report_status "$(report_path "$t")")"; [ -n "$st" ]||return 1; done; return 0; }

[ -f "$PROGRESS" ] || echo "# Claude REPL queue progress $(date '+%F %T')" > "$PROGRESS"
log "orchestrator start project=$PROJECT_DIR max_parallel=$MAX_PARALLEL idle_exit=$IDLE_EXIT"

while true; do
  # record finished sessions
  for sf in "$STATE_DIR"/*.session; do
    [ -f "$sf" ] || continue
    task="$(basename "$sf" .session)"; sess="$(cat "$sf" 2>/dev/null)"; [ -n "$sess" ] || continue
    tmux_alive "$sess" && continue                     # ещё живёт — не трогаем
    rp="$(report_path "$task")"; st="$(report_status "$rp")"; tf="$(task_file "$task")"
    [ "$rp" = "$REPORT_DIR/report_$task.md" ] || log "REPORT-ALIAS $task: отчёт найден как ${rp##*/}"
    if [ -n "$st" ]; then
      if [ "$st" = "SUCCESS" ]; then
        dirt="$(dirty_tree_report "$task")"
        if [ -n "$dirt" ]; then
          st="PARTIAL"
          log "DIRTY-TREE $task: SUCCESS понижен до PARTIAL, работа не закоммичена — $dirt"
          notify "ВНИМАНИЕ. $task: SUCCESS понижен до PARTIAL — работа осталась незакоммиченной: $dirt"
        else
          old_dirt="$(dirty_preexisting "$task")"
          [ -n "$old_dirt" ] && log "DIRTY-TREE-OLD $task: в дереве есть незакоммиченное, но оно было ДО старта задачи — статус не трогаю: $old_dirt"
        fi
      fi
      mark_progress "$task" "$st"; log "finished $task STATUS=$st"
    elif report_exists "$task"; then
      # Отчёт ЕСТЬ, но БЕЗ валидной строки STATUS → терминальный AMBIGUOUS. НЕ перезапускаем
      # (иначе оркестратор↔супервизор гоняют агента по кругу; для live/1С это шторм рестартов кассы).
      mark_progress "$task" "AMBIGUOUS"; : > "$STATE_DIR/$task.ambiguous"
      log "AMBIGUOUS $task: отчёт без строки STATUS → карантин, авто-рестарт СТОП"
      notify "⚠️ $task: отчёт без строки STATUS — карантин, авто-рестарт остановлен. Проверь: $(report_path "$task")"
    elif task_norespawn "$tf"; then
      # Live/1С-таск умер БЕЗ отчёта — НЕ рестартим вслепую (опасно для живой кассы). Карантин + пинг.
      : > "$STATE_DIR/$task.ambiguous"
      log "NO-RESPAWN $task: live/1С умер без отчёта → карантин, авто-рестарт СТОП"
      notify "⚠️ $task: live/1С-агент умер без отчёта — авто-рестарт ОТКЛЮЧЁН (no-respawn), проверь вручную"
    else
      log "$task: сессия мертва, отчёта нет — обычный таск вернётся в очередь"
    fi
    rm -f "$sf" "$STATE_DIR/$task.lock" "$STATE_DIR/$task.started" "$STATE_DIR/$task.dirtybase"
  done

  if all_done; then
    if [ "$IDLE_EXIT" = "1" ]; then log "ALL DONE (idle_exit=1)"; touch "$REPORT_DIR/ALL_DONE"; exit 0; fi
    log "queue drained — idle, watching tasks/ for new files"
    sleep 15; continue   # 2026-07-30: было 30
  fi

  if ram_ok && disk_ok; then
    for task in $(discover_tasks); do
      [ "$(active_count)" -lt "$MAX_PARALLEL" ] || break
      tf="$(task_file "$task")"; [ -f "$tf" ] || continue
      quarantined "$task" && continue                   # AMBIGUOUS/no-respawn карантин — не перезапускаем
      [ -n "$(report_status "$(report_path "$task")")" ] && continue
      sess="$(session_name "$task")"; tmux_alive "$sess" && continue
      # start-grace: если таск стартовали недавно — не перезапускаем, даём launcher'у поднять REPL
      # (иначе новый kill-session добьёт REPL предыдущего запуска → churn).
      started_at="$(cat "$STATE_DIR/$task.started" 2>/dev/null || echo 0)"; nows="$(date +%s)"
      [ $(( nows - started_at )) -lt "$START_GRACE" ] && { log "grace: $task стартовал $(( nows - started_at ))s назад (<${START_GRACE}s) — жду, не перезапускаю"; continue; }
      lock="$(task_lock "$tf")"; [ -z "$lock" ] && lock=none
      lock_active "$lock" && { log "waiting lock=$lock for $task"; continue; }
      start_task "$task"
    done
  else
    if ! ram_ok; then
      log "RAM gate: MemAvailable < ${RAM_MIN_KB}KB; holding new starts"
    else
      log "DISK gate: на $DISK_MOUNT свободно $(disk_free_gb)G < ${DISK_MIN_GB}G; holding new starts (переполнение тома роняет ВСЮ виртуалку, GOTCHAS #13)"
    fi
  fi
  sleep 8    # 2026-07-30: было 20 — быстрее подхватываем следующий таск после закрытия предыдущего
done
