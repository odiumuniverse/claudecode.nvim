# claudecode.nvim (форк): ревью ханков и zen mode

Родной TUI `claude` в Neovim по IDE-протоколу, с выбором ханков как в Cursor и zen mode как в avante.

## Основа

1. **Интерфейс чата — родной TUI `claude`.** Связь с редактором идёт по IDE-протоколу (WebSocket MCP, lock-файл в `~/.claude/ide/`). Подписка законна: пользователь входит в неизменённый бинарник Claude Code своим аккаунтом. ACP и Agent SDK не используем.
2. **Своего MCP для модели нет.** nvim узнаёт о правках из хуков Claude Code. Claude правит файлы только своими Edit/Write/Bash.
3. **Форк claudecode.nvim.** Приватный репозиторий `odiumuniverse/claudecode.nvim`, не форк на GitHub: форк публичного репозитория нельзя сделать приватным. Локально лежит в `~/src/claudecode.nvim`, оригинал подключён как remote `upstream`.
4. **Синхронизация — rebase.** Наши коммиты лежат серией поверх `upstream/main`. Чистка всегда идёт последним коммитом: скрипт sync выкидывает её, делает rebase и заново удаляет файлы по списку.
5. **Удаляем** (полный список — `fork/cleanup.txt`): `communique.toml`, `reviewfixer.yaml`, `release-please*`, `CHANGELOG.md`, `VERSION`, `STORY.md`, `scripts/release-please-*`, `scripts/package*.json`, `.github/ISSUE_TEMPLATE`, все workflows upstream, а ещё `.devcontainer/` и `.claude/`. Их `test.yml` гоняет тесты release-please из удалённого `scripts/package.json`, поэтому вместо правки чужого файла у форка свой `.github/workflows/ci.yml` с теми же Lua-тестами. **Оставляем:** `mise.*` без правок (в нём остаются инструмент `communique` и задача `reviewfix`, они безвредны), `treefmt.toml`, репро-скрипты и фикстуры, `ARCHITECTURE/DEVELOPMENT/PROTOCOL/AGENTS/CLAUDE.md`. Ссылка на `STORY.md` в README повиснет, пока README не перепишем.
6. **LICENSE:** к строке Coder добавляем `Copyright (c) 2026 odiumuniverse`.
7. **Наш код живёт в отдельных модулях** (`lua/claudecode/review/`, `lua/claudecode/zen/`, `lua/claudecode/hooks/`). Файлы upstream трогаем точечно: точка для провайдера диффа и подключение в `setup`.

## Ревью: два режима

8. **«После записи», как в Cursor, — основной режим (auto).** Claude правит файлы сразу, а плагин показывает ханки поверх кода.
9. **«До записи», как в VS Code, — режим Manual.** Новая точка в форке — провайдер диффа `diff_opts.provider = { open(ctx), close(ctx, reason) }`, в `ctx` пути, предложенный текст, `is_new_file` и вызовы `ctx.accept(content)` / `ctx.reject()`. Провайдер включается по желанию: без него работают встроенные native и unified, их код мы не переписываем, чтобы rebase на upstream оставался лёгким. `close` вызывается ровно один раз на дифф, в том числе когда `open` упал (`reason = "setup failed"`). Наш провайдер открывает предложение на месте файла в том же виде, что и «после записи». Когда все ханки разобраны, результат уходит в Claude. Если откачены все ханки, уходит `DIFF_REJECTED`.
10. **Текст, принятый через провайдер, сразу становится базой** и повторно в ревью «после записи» не попадает.

Что провайдер шага 1 пока не умеет, закрыть на шагах 4–5:

- Не шлёт `ClaudeCodeDiffOpened`, а zen (п. 29) по нему понимает, что пришла правка на подтверждение.
- Не получает дифф, если в буфере файла есть несохранённые правки: проверка `is_buffer_dirty` стоит раньше нашей ветки. Это расходится с п. 16.
- Не отвечает на `:ClaudeCodeDiffAccept` / `:ClaudeCodeDiffDeny`: команды ищут дифф по `b:claudecode_diff_tab_name`, а провайдер его не ставит.

## Откуда берётся база

11. **Edit/Write.** Хук `PreToolUse` копирует файл до правки. Если файла не было, ставит отметку «новый».
12. **Bash.** `PreToolUse(Bash)` делает `git stash create` (на чистом дереве берёт HEAD), `PostToolUse(Bash)` берёт `git diff --name-only` от этого снимка. Тексты изменённых файлов сразу копируются в каталог состояния, на sha не полагаемся: `git gc` может удалить коммит, на который никто не ссылается.
13. **Неотслеживаемый файл, поправленный через Bash.** Если он открыт в nvim, базой становится старый текст буфера (`FileChangedShell`), но только внутри окна вызова Bash. Если не открыт, правка остаётся вне ревью, это отмечаем в README.
14. **Изменения вне окон инструментов Claude** (ваши правки, `git pull`) в ревью не попадают.
15. **База копится, пока ханк не разобран.** Правки за несколько ходов складываются от первого снимка. Если файл попал в несколько снимков, базой считается самый ранний.
16. **Ваши правки в буфере с ханками** (следим через `nvim_buf_attach`). Правка вне ханка переносится и в базу, ханком не становится. Правка внутри ханка меняет предложение Claude, ханк ждёт ko/kx.

## Показ и клавиши

17. **Свой движок на extmarks**, ханки считает `vim.text.diff`. Удалённые строки показываются красными виртуальными строками над ханком, добавленные — зелёным фоном. В парных изменённых строках подсвечиваются только изменившиеся слова, уже в первой версии. У ханка под курсором — подсказка `ko оставить · kx откатить`.
18. **Колонку знаков не занимаем.** gitsigns не трогаем.
19. **Список файлов** с неразобранными ханками открывается в snacks.picker по `<leader>ak`: «открыть», «оставить всё», «откатить всё».
20. **Клавиши:** `ko` — оставить ханк, `kx` — откатить, `KO`/`KX` — весь файл, `]k`/`[k` — следующий/предыдущий ханк, `]K`/`[K` — последний/первый.
21. **Диск:** `kx` сразу пишет файл (вместе с вашими несохранёнными правками в этом буфере), `ko` только сдвигает базу. После каждой записи Claude `PostToolUse` шлёт в `$NVIM` команду `checktime`, и буферы перечитываются.
22. **Сводка откатов для Claude.** В режиме «после записи» хук `UserPromptSubmit` добавляет к следующему сообщению `additionalContext`: файл, строки и что откачено. После этого сводка очищается. В режиме «до записи» Claude продолжает ход сразу, поэтому сводку отдаёт `PostToolUse` для Edit/Write в том же ходе: сам CLI сообщает модели только общую фразу (см. «Факты из опыта»).
23. **Состояние хранится на диске,** в `stdpath("state")/claudecode/<проект>/`: базы, неразобранные ханки, сводка откатов. Каталог очищается, когда разобраны все ханки.

## Хуки

24. **Хуки на Lua запускаются через `nvim --clean -l`,** чтобы не грузить LazyVim на каждую правку. С работающим nvim связываются через `$NVIM`.
25. **Хуки подключаются только к сессиям, запущенным из nvim:** `claude --settings <сгенерированный settings.json>` с абсолютными путями к скриптам. Флаг стоит во всех путях запуска: обычном, `--resume`, `--continue` и `cz`.
26. **Хуки из `--settings` добавляются к пользовательским, а не заменяют их.** Проверено 2026-10-19 на Claude Code 2.1.303: в одном запуске `claude -p --settings … --debug hooks` отработали и пробный хук, и пользовательский `zhivoe-slovo.sh`.

## Zen mode

27. **Живёт внутри nvim.** Команда `cz` открывает nvim сразу с Claude на весь экран.
28. **Два состояния:** zen (только Claude) и рабочее (код плюс Claude справа). Переключает `<M-z>`, в терминале и в коде.
29. **В zen пришла правка на подтверждение (Manual)** — показываем рабочее состояние на предложении, а после разбора возвращаемся в zen.
30. **В zen виден счётчик** «N файлов ждут ревью», чтобы правки «после записи» не копились молча.

## Факты из опыта с openDiff

2026-10-19, Claude Code 2.1.303, режим Manual. Claude переписал файл одним Write с двумя правками, мы откатили одну в буфере предложения и сохранили.

- **CLI записывает именно наш текст** из ответа `FILE_SAVED`: на диске осталась одна правка из двух.
- **Модель получает только общую фразу:** _«The file … has been updated successfully. The user modified your proposed content before accepting it.»_ Какие ханки откачены, CLI не сообщает; в метаданных транскрипта есть `userModified: true` и `structuredPatch`, но модели они не показываются. Haiku сам перечитал файл и заметил откат, но на это полагаться нельзя.
- **CLI срезает перевод строки в конце файла.** Исходный файл и наш ответ заканчивались на `\n`, а записанный файл — нет. Разобраться на шаге 4: срезается один `\n` или все пробельные символы, и чем это компенсировать.

## Модули и контракты

Контракт между модулями фиксируем до кода: движок, хранилище и zen пишутся параллельно.

```
lua/claudecode/review/hunks.lua   чистая логика: ханки, дифф слов, применение ko/kx, перенос правок
lua/claudecode/review/render.lua  extmarks, подсветка, подсказка
lua/claudecode/review/init.lua    движок: attach/detach, клавиши, ko/kx, nvim_buf_attach
lua/claudecode/review/store.lua   каталог состояния: базы, сводка откатов
lua/claudecode/review/summary.lua текст сводки откатов для Claude
lua/claudecode/review/picker.lua  список файлов (<leader>ak)
lua/claudecode/hooks/             settings.json для --settings, входной скрипт хуков
lua/claudecode/zen/init.lua       zen
spec/                             тесты в настоящем headless nvim (fork/test-nvim.sh)
```

**Ханк** — индексы как у `vim.text.diff(..., { result_type = "indices" })`, строки с единицы:

```lua
---@class ClaudeCodeHunk
---@field base_start integer  -- при base_count == 0: вставка после этой строки базы (0 — в начало)
---@field base_count integer
---@field cur_start integer   -- при cur_count == 0: удаление после этой строки буфера (0 — в начало)
---@field cur_count integer
---@field base_lines string[]
---@field cur_lines string[]
```

**Движок** (`require("claudecode.review")`):

```lua
review.attach(bufnr, base_lines, opts) -- начать ревью буфера против базы; повторный attach меняет базу
review.detach(bufnr)                   -- снять подсветку, клавиши и nvim_buf_attach
review.is_attached(bufnr) -> boolean
review.hunks(bufnr) -> ClaudeCodeHunk[]
review.base(bufnr) -> string[]
review.keep(bufnr, index?)             -- index по умолчанию — ханк под курсором
review.revert(bufnr, index?)
review.keep_all(bufnr)
review.revert_all(bufnr)

---@class ClaudeCodeReviewAttachOpts
---@field on_base? fun(base: string[])               -- база сдвинулась: ko, KO, ваша правка вне ханка
---@field on_revert? fun(rec: ClaudeCodeRevertRecord) -- kx/KX применён к буферу
---@field on_done? fun(reason: "resolved"|"detached") -- ханков не осталось или вызван detach
---@field write_on_revert? boolean                    -- по умолчанию true: kx сразу пишет файл

---@class ClaudeCodeRevertRecord
---@field path string           -- абсолютный путь буфера
---@field line integer          -- первая строка вернувшегося текста в файле после отката
---@field base_lines string[]   -- текст, который вернулся
---@field claude_lines string[] -- текст Claude, который откатили
---@field time integer          -- os.time()
```

**События.** Движок шлёт `User ClaudeCodeReviewChanged` с `data = { bufnr, path, hunks }` после каждого пересчёта, хранилище — `User ClaudeCodeReviewPending` с `data = { count, files }`, когда меняется список файлов с неразобранными ханками. Zen рисует счётчик по второму событию.

**Каталог состояния** (`stdpath("state")/claudecode/review/<sha256 корня проекта>/`, права 0700):

```
bases/<sha256 пути>.base    -- байты файла до первой правки Claude
bases/<sha256 пути>.json    -- { path, new_file, created_at }
bash/<tool_use_id>.json     -- снимок перед Bash: { stash, untracked }
reverts.jsonl               -- по записи ClaudeCodeRevertRecord на строку
```

База создаётся атомарно и только если её ещё нет (п. 15): текст во временный файл, потом `fs_link`. База, равная текущему тексту файла, удаляется при первой встрече. Хуки получают каталог через `CLAUDECODE_REVIEW_DIR`, а адрес nvim через `CLAUDECODE_NVIM`, и шлют в nvim только `rpcnotify`: хук не ждёт nvim, потому что nvim может стоять на hit-enter (см. опыт с openDiff). Любая ошибка в хуке завершает его с кодом 0: ревью может пропустить правку, но Claude не застрянет.

## Тесты

31. **TDD на busted через их `mise`.** Покрываем:
    - чистую логику: выбор базы, накопление, перенос правок пользователя, текст сводки откатов;
    - хранилище и хук-скрипты: JSON на stdin, временный каталог;
    - провайдер и движок в headless nvim: ko/kx меняют буфер и базу, accept возвращает нужный текст, старый интерфейс проходит текущие тесты upstream;
    - раскладку zen в headless nvim.

## Порядок работ

0. Репозиторий, чистка, sync-скрипт, LICENSE, этот файл в `docs/DESIGN.md`, проверка п. 26.
1. Провайдер диффа в форке.
2. Движок на extmarks: ханки, дифф слов, ko/kx, подсказка.
3. «После записи»: хуки, базы, перенос правок пользователя, список файлов, сводка откатов, `checktime`.
4. «До записи»: наш провайдер на том же движке.
5. Zen и `cz`.
6. Подключение в LazyVim: spec с `dir = "~/src/claudecode.nvim"`.
