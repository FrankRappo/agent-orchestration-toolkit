# OMX Autopilot: автономный запуск из WSL

Каталог содержит обезличенный воспроизводимый профиль автономного OMX/Codex-оркестратора.
Проектный подробный пример должен храниться в документации самого проекта; этот общий профиль не содержит аутентификацию,
секреты, SSH-ключи или состояние конкретной сессии.

## Файлы

- `omx_autopilot_launcher.template.sh` — detached launcher (`nohup + setsid`).
- `omx_autopilot_status.template.sh` — проверка PID, JSONL и metadata.
- `omx_autonomous.config.template.toml` — безопасный фрагмент Codex-конфигурации.
- `AGENTS.autonomous.md` — снимок рабочего автономного контракта агентов.
- `hooks.autonomous.json` — снимок OMX native hooks без секретов.
- `autopilot.prompt.template.md` — минимальный prompt-контракт Autopilot.
- `omx_autonomous.sha256` — контрольные суммы этого профиля.

Проектный подробный пример должен храниться в документации самого проекта; общий публичный
профиль намеренно не содержит имён проектов, клиентов, хостов или дат конкретных запусков.

## Установка OMX/Codex

```bash
omx setup
omx doctor
codex login status
```

`codex login` выполняется отдельно. Никогда не копируйте сюда `~/.codex/auth.json`.

## Подготовка проекта

```bash
mkdir -p /work/<project>/.omx/{context,prompts,logs,run}
cp /work/settings/codex/autopilot.prompt.template.md \
  /work/<project>/.omx/prompts/<task>-autopilot.md
```

Заполните prompt конкретными целями, проверками, ограничениями и stop condition. Секреты в prompt
не помещать.

## Запуск в sandbox

```bash
PROJECT_DIR=/work/<project> \
PROMPT_FILE=/work/<project>/.omx/prompts/<task>-autopilot.md \
RUN_NAME=<task>-autopilot \
OMX_REASONING=high \
bash /work/settings/codex/omx_autopilot_launcher.template.sh
```

## Запуск с полным доступом

Только если задача действительно требует SSH, удалённого деплоя или записи за пределами project
root и prompt содержит жёсткие safety boundaries:

```bash
PROJECT_DIR=/work/<project> \
PROMPT_FILE=/work/<project>/.omx/prompts/<task>-autopilot.md \
RUN_NAME=<task>-autopilot \
OMX_REASONING=xhigh \
OMX_FULL_ACCESS=1 \
OMX_ADD_DIR=/work \
bash /work/settings/codex/omx_autopilot_launcher.template.sh
```

`OMX_FULL_ACCESS=1` преобразуется в `--dangerously-bypass-approvals-and-sandbox`. Без этого
переменного шаблон использует `--sandbox workspace-write`.

## Настройки

| Переменная | Значение по умолчанию | Назначение |
|---|---:|---|
| `PROJECT_DIR` | обязательно | корень проекта |
| `PROMPT_FILE` | обязательно | prompt через stdin |
| `RUN_NAME` | `omx-autopilot` | безопасный префикс логов |
| `OMX_REASONING` | `high` | `low`, `medium`, `high`, `xhigh` |
| `OMX_FULL_ACCESS` | `0` | полный доступ только при `1` |
| `OMX_ADD_DIR` | пусто | дополнительный доступный каталог |
| `OMX_MODEL` | пусто | пусто = модель из актуального Codex config |
| `OMX_LOG_DIR` | `$PROJECT_DIR/.omx/logs` | JSONL/final output |
| `OMX_RUN_DIR` | `$PROJECT_DIR/.omx/run` | PID/metadata |

Не фиксируйте модель в шаблонах без необходимости: актуальная модель выбирается из установленного
Codex/OMX-профиля. Reasoning задаётся отдельно.

## Статус

```bash
PROJECT_DIR=/work/<project> \
bash /work/settings/codex/omx_autopilot_status.template.sh
```

Для конкретного metadata-файла:

```bash
META=/work/<project>/.omx/run/<run>.meta.json \
bash /work/settings/codex/omx_autopilot_status.template.sh
```

## Что переживает отключение

- Закрытие терминала/SSH/Codex UI: да.
- Завершение родительского shell: да, благодаря `nohup + setsid`.
- Выключение компьютера или `wsl --shutdown`: нет.
- Пропадание OpenAI-сети/аутентификации/квоты: агент может остановиться или ждать.
- Отдельно detached удалённые скрипты: могут продолжить работу независимо.

## Безопасность

- Не копировать credentials и runtime-state.
- Не считать PID доказательством успеха: проверять state, отчёты и hashes.
- Не запускать два оркестратора на один output root без явного locking.
- Не делать `git push`, production deploy или полное обучение без явного разрешения/gate.
- Данные uncertainty/conflict не превращать в clean positives.
- Для остановки использовать точный PID, не широкий `pkill -f`.
