# claudecode.nvim: hunk review and zen mode

The native `claude` TUI inside Neovim over the IDE protocol, with Cursor-style hunk review and an avante-style zen mode.

## Foundation

1. **The chat is the native `claude` TUI.** It talks to the editor over the IDE protocol (WebSocket MCP, a lock file in `~/.claude/ide/`). The subscription stays within the terms: you sign in to the unmodified Claude Code binary with your own account. We use neither ACP nor the Agent SDK.
2. **No MCP server of our own for the model.** Neovim learns about edits from Claude Code hooks. Claude edits files only with its own Edit, Write and Bash.
3. **A fork of claudecode.nvim.** The repository `odiumuniverse/claudecode.nvim` is not a GitHub fork: it started private, and GitHub does not let you make a private fork of a public repository. The original is the `upstream` remote.
4. **Sync by rebase.** Our commits sit on top of `upstream/main`. The cleanup commit always comes last: `fork/sync.sh` drops it, rebases, and deletes the listed files again.
5. **What we delete** (the full list is `fork/cleanup.txt`): the release tooling (`communique.toml`, `reviewfixer.yaml`, `release-please-config.json`, `.release-please-manifest.json`, `CHANGELOG.md`, `VERSION`, `STORY.md`, the release-please scripts and `scripts/package*.json`), `.github/ISSUE_TEMPLATE`, every upstream workflow, `.devcontainer/` and `.claude/`. Upstream's `test.yml` runs release-please tests from the deleted `scripts/package.json`, so instead of editing it we have our own `.github/workflows/ci.yml`: the Lua jobs of `test.yml` plus a job that runs our specs in a real Neovim. **What we keep:** `mise.*` as is (its `communique` tool and `reviewfix` task do no harm), `treefmt.toml`, the repro scripts and fixtures, `AGENTS.md` and `CLAUDE.md`. Upstream's architecture and protocol docs moved to `docs/`, and its development guide became `CONTRIBUTING.md`; git carries upstream's later changes over to the new paths on rebase. The root `README.md` stays upstream's, with a dead link to `STORY.md`; GitHub shows `.github/README.md` first.
6. **LICENSE:** `Copyright (c) 2026 odiumuniverse` goes under Coder's line.
7. **Our code lives in modules of its own:** `lua/claudecode/review/`, `lua/claudecode/hooks/`, `lua/claudecode/zen/` and `lua/claudecode/features/`. Upstream files get only small marked seams: the diff provider branches in `diff.lua`, `hooks.decorate` in `terminal.lua`, and `features.setup` in `init.lua`.

## Review: before and after write

8. **Claude's permission mode picks the review.** Review after write, as in Cursor, is the main path: in auto, `bypassPermissions` and `dontAsk` Claude edits files at once, and the plugin shows the hunks on top of the code. Manual mode (`default`) reviews before write (item 9). Accept edits and plan mode take edits without review. How the hooks tell the modes apart is under "How the modes work" below.
9. **Review before write, as in VS Code, is Manual mode.** We add a diff provider seam: `diff_opts.provider = { open(ctx), close(ctx, reason) }`. `ctx` carries `tab_name`, the paths, the proposed text, `is_new_file`, `tool`, and the calls `ctx.accept(content)` and `ctx.reject()`. A provider is opt-in: without one, upstream's native and unified views work as before, and we leave their code alone to keep rebases cheap. The plugin calls `close` exactly once per diff, also when `open` fails (`reason = "setup failed"`). Our provider opens the proposal in place of the file and draws it the same way as review after write. Once every hunk is decided, the result goes to Claude; if you reverted every hunk, Claude gets `DIFF_REJECTED`.
10. **Text you accept through the provider becomes the base at once,** so review after write does not show it again. A base that an earlier edit left, with hunks still waiting, stays as it is: you have not reviewed those hunks.

The provider gets the diff even when the file's buffer has unsaved edits: its branch comes before the `is_buffer_dirty` check. It fires `ClaudeCodeDiffOpened` with `layout = "provider"`, and `:ClaudeCodeDiffAccept` and `:ClaudeCodeDiffDeny` call its `accept_command` and `reject_command`. Without these handlers the commands accept the whole proposal or reject it; after `reject_command` Claude always gets a rejection.

**How the modes work.** Every hook input carries `permission_mode`, and it changes right after shift+tab. So the hooks read the mode at each call and keep no mode of their own.

- **Manual.** `PreToolUse` of Edit, Write, MultiEdit and NotebookEdit answers `permissionDecision: "ask"`. A hook's `ask` beats `permissions.allow`, so Claude asks about every edit, the IDE gets `openDiff`, and our provider shows the proposal. Without the hook an allowed Edit never reaches `openDiff` (see "What openDiff taught us"). The hook asks only while review before write is on: `review.before_write`, or a provider of your own. Bash is never asked about; its edits come up as hunks after the call.
- **Accept edits.** The hooks take no base. If the file already has one, `PreToolUse` saves the text before the edit in `accepting/<tool_use_id>`, and `PostToolUse` carries the edit into the base (`hunks.carry`): the hunks still waiting for you stay, and an edit that touches one of them joins that hunk. A Bash call in this mode carries its edits only into bases that already exist.
- **Plan.** The same as accept edits. Claude writes only its plan file in this mode, and the plan has no place in the review list.
- **A mode that changes between the two hooks of one call.** Shift+tab, or "Yes, and switch to accept edits" at Claude's prompt, can do it. The edit goes without review if `PreToolUse` took it so (a copy in `accepting/<tool_use_id>` and no note) or if `PostToolUse` comes in accept-edits or plan mode: switching at the prompt means you took this edit and the ones after it, so it carries into the base like any accepted edit, and the hunks still waiting stay. For that `PreToolUse` saves the file in `accepting/` under review too, next to its note in `editing/<tool_use_id>.json`, and `PostToolUse` ends the note either way. At first `PostToolUse` looked only at its own mode, and a prompt answered that way left the note behind for 30 minutes, with the file in doubt; then for a while `PreToolUse` decided alone, and the edit you had just allowed came up as a hunk.
- **Neovim hears of every file Claude wrote,** in every mode. A file without a base has nothing to review, but its open buffer still has to reload. At first accept-edits mode told Neovim only about files with a base, and the other buffers stayed stale.
- `:ClaudeCode --permission-mode manual` starts Claude in Manual mode; the LazyVim spec maps it to `<leader>am`. While Claude runs, upstream's `:ClaudeCode` only shows or hides the terminal and drops the flag, so a running session switches with shift+tab.

## Where the base comes from

11. **Edit, Write, MultiEdit and NotebookEdit.** The `PreToolUse` hook copies the file before the edit. If the file does not exist, it marks the base as new.
12. **Bash.** `PreToolUse(Bash)` runs `git stash create` (HEAD on a clean tree), and `PostToolUse(Bash)` asks `git diff --name-only` against that snapshot. The hook copies the old text of every changed file into the state directory right away instead of keeping the sha: `git gc` may delete a commit nothing points to. **A call that moves HEAD** (`git switch`, `pull`, `rebase`, `reset`) has git rewrite files, so the snapshot also keeps HEAD. A changed file that matched the old HEAD before the call and matches the new HEAD after it is git's checkout: it gets no base, and a base already waiting moves along it as an accepted edit would. A file clean before and changed after it is Claude's edit on top of the checkout: its base is the new HEAD's text. A file that was dirty before keeps the snapshot as its base, so `reset --hard` cannot quietly throw away your uncommitted work.
13. **An untracked file that Bash changed.** `PostToolUse(Bash)` compares the size and mtime of untracked files with the snapshot and tells Neovim which ones changed. If such a file is open and its buffer is unmodified, the old buffer text becomes the base. If it is not open, the edit escapes review; the README says so. The hook checks the first 5000 untracked files only.
14. **Changes outside Claude's tool calls** (yours, other programs, `git pull`) stay out of review.
15. **The base accumulates until you decide on the hunk.** Edits over several turns add up against the first snapshot. If a file lands in several snapshots, the earliest one wins.
16. **Your edits in a buffer under review** (tracked with `nvim_buf_attach`). An edit outside a hunk goes into the base too and never becomes a hunk. An edit inside a hunk changes Claude's proposal, and the hunk still waits for `cs` or `cx`.

## Display and keys

17. **Our own extmark engine;** `vim.text.diff` finds the hunks. Deleted lines appear as red virtual lines above the hunk, added lines get a green background. In paired changed lines only the changed words light up. The hunk under the cursor shows a hint, `cs keep · cx revert`. Like the rest of the UI it is in English; the plugin builds it from your keys, and `review.hint` replaces or hides it. Deleted lines above the first line of the file show up at once: a window at the top of the file scrolls onto them (`topfill`).
18. **We do not take the sign column.** gitsigns keeps it.
19. **The list of files** with undecided hunks opens with `<leader>ak` and `:ClaudeCodeReview`: open (Enter puts the cursor on the first hunk), keep all (`<A-o>`), revert all (`<A-x>`). The list uses snacks.picker, then fzf-lua, then `vim.ui.select`, since many LazyVim setups pick fzf-lua. Revert all on a new file deletes the file: it did not exist before Claude.
20. **Keys:** `cs` keeps the hunk, `cx` reverts it, `cS` and `cX` act on the whole file, `]k` and `[k` go to the next and previous hunk, `]K` and `[K` to the last and first. Every default key starts with a key after which Neovim waits anyway (`c`, `]`, `[`, `<leader>`, a modifier), so no key you press on its own waits for 'timeoutlen'; after `c` only keys that are neither motions nor text objects. A spec checks it (see "Edges the tests found"). **Moving on.** After `cs` or `cx` from a key (not from the API or the list of files), the cursor goes to the first hunk at or below the decided one, or to the first hunk after the last; a revert the disk refused decided nothing and moves nothing. `review.advance = "file"` opens the next file once this one is done. `]k` past the last hunk and `[k` before the first open the next or previous file (`review.cross_files`, on by default): the user found that `]k` on a file's only hunk did nothing at all and took the keys for broken. The engine knows nothing of files; the controller hands it `goto_file`, which walks the list of files waiting for review in path order, wraps around, and skips a proposal under review before write, which is not on that list.
21. **Disk:** `cx` writes the file at once, together with your unsaved edits in that buffer; `cs` only moves the base. The write runs with `noautocmd` so that format-on-save cannot invent new differences, and the plugin then fires `BufWritePost` by hand. The final newline stays as the file had it. If the file changed on disk since it was loaded, `cx` does not overwrite it: it recomputes the hunks and warns. After each of Claude's writes the hook tells Neovim which files changed, and Neovim reloads their buffers.
22. **Revert summary for Claude.** The hook adds `additionalContext` to whichever comes first: `PostToolUse` of the next edit or Bash call, or `UserPromptSubmit` of your next message. The summary names the file and line and shows Claude's text and the text that came back; then it is cleared. The CLI itself tells the model only a generic sentence (see "What openDiff taught us").

    **Each session hears only of its own edits.** Two Claude sessions in one project share the state directory, so the header of a base lists the sessions that edited the file (`sessions`, taken from the `session_id` of the `PreToolUse` and `PostToolUse` input). A revert goes to `reverts/<session_id>.jsonl` of every session on that list, and a hook takes the file of its own session. A base with no list (made before sessions were tracked) sends the revert to the common `reverts.jsonl`, which every session takes too; so does a hook input without a `session_id`. An edit taken without review (accept-edits mode) adds no session, unless it joined a hunk still waiting: a revert of that hunk takes the edit back too, so its session hears of it. Review before write follows the same rule: `openDiff` carries no session id (its parameters are the paths, the text and `tab_name`; the client has only a connection id), so the provider's revert goes to the sessions in the base that `PreToolUse` made. A session file untouched for 7 days is deleted by whichever hook takes reverts next.

23. **State lives on disk,** in `stdpath("state")/claudecode/review/<sha256 of the project root>/`: bases and the revert summary. Hunks are not stored: the plugin computes them from the base and the file every time. A base goes away once its file has no hunks left.

## Hooks

24. **Hooks are Lua scripts run with `nvim --clean --headless -l`,** so that LazyVim does not load on every edit. They reach the running Neovim through `CLAUDECODE_NVIM`, or `$NVIM` when that is not set.
25. **Hooks attach only to sessions started from Neovim:** `claude --settings <generated settings.json>` with absolute paths to the scripts. Every launch path carries the flag: plain, `--resume`, `--continue` and `cz`. **The settings file belongs to one pair of paths.** Its hooks run this editor's `vim.v.progpath` on this copy's `run.lua`, so its name is `hooks-settings-<first 12 characters of the sha256 of "progpath\nrun.lua">.json`. At first all editors wrote one `hooks-settings.json`, each with its own paths. Live, a test Neovim with another copy of the plugin rewrote it, so the next Claude from the main Neovim would have started with the hooks of that copy, and so would a running session if Claude Code rereads `--settings` (not checked). Now editors that write one file write the same content, as long as the code at those paths is the same: a plugin updated in place while an old Neovim still runs can differ in `MATCHER` or `TIMEOUT_S`, and the last to launch Claude wins. The old file is no longer written or deleted, since sessions started earlier still point to it.
26. **Hooks from `--settings` add to your own hooks rather than replace them.** Checked on 2026-10-19 with Claude Code 2.1.303: in one `claude -p --settings … --debug hooks` run both a test hook and a user hook ran.

## Zen mode

27. **Zen lives inside Neovim, in a tab of its own with a single Claude window.** The Claude terminal always sits in exactly one window: a terminal takes the width of its widest window, so a full-screen copy in another tab would garble the narrow split (checked in a real UI). Zen hides the tabline while it is on, and keeps it hidden when a plugin shows it again: bufferline.nvim in LazyVim does so on every `BufAdd` and `TabEnter`, from its own autocmd, which fires no `OptionSet`. When zen closes, the tabline comes back the way that plugin last set it. Leaving zen returns you to the tab you entered from. `bin/cz` opens Neovim straight into zen and passes its arguments to Claude (`cz --resume`).
28. **Two states:** zen (only Claude) and work (code with Claude on the right). `<M-z>` switches between them, from the terminal and from the code.
29. **A proposal arrives in zen (Manual mode):** zen switches to the work state on the proposal and comes back once you have decided.
30. **Zen shows a counter,** "N files wait for review · <leader>ak" ("1 file waits for review" for one, nothing for none), in the winbar above Claude, so that edits waiting for review do not pile up unnoticed.

## Accounts (cswap)

`:ClaudeCode run [account] [args]` runs Claude through cswap (claude-swap), a switcher for several Claude accounts.

- **What runs:** `cswap run <account> -- <args>`. cswap reads its own options before `--` and hands the rest to Claude, so the review hooks' `--settings` goes after `--` as well: `hooks.decorate` puts it right after the base command, and the base command ends in `--`.
- **The IDE connection holds.** `cswap run` launches Claude with `CLAUDE_CONFIG_DIR` set to the account's profile and leaves `ide/` out of that profile, yet Claude still finds Neovim through `CLAUDE_CODE_SSE_PORT` (checked on 2.1.304 with cswap 0.27.2: one client connected, the hooks attached).
- **The account sticks.** A small seam in upstream's `terminal.lua`, `set_launch_cmd`, puts the cswap command in place of `terminal_cmd` for every launch until the next `run`: the toggle, focus, zen, `cz` and `--resume` all run the same account. Otherwise, after Claude exits, the next toggle would quietly open the default login.
- **Replace, do not ask.** You typed `run`, so a running Claude is stopped: the job is stopped and its buffer wiped. Hiding the window is not enough, since the native provider keeps a hidden terminal running. The account is checked against `cswap list --json` first, and a typo leaves the running Claude alone. Zen closes for the switch and opens again with the new Claude.
- **Code:** `lua/claudecode/features/cswap.lua`; `:ClaudeCode` hands it the arguments that start with `run` and asks it for completion.

## What openDiff taught us

2026-10-19, Claude Code 2.1.303, Manual mode. Claude rewrote a file in one Write with two changes; we reverted one in the proposal buffer and saved.

- **The CLI writes exactly the text we send back** in the `FILE_SAVED` answer: one change of the two ended up on disk.
- **The model gets only a generic sentence:** _"The file … has been updated successfully. The user modified your proposed content before accepting it."_ The CLI does not say which hunks you reverted. The transcript metadata has `userModified: true` and `structuredPatch`, but the model never sees them. Haiku reread the file on its own and noticed the revert, but we cannot count on that.
- **The CLI treats the answer by tool.** A 2026-10-20 test with three Writes: the answer `alpha\ndelta\n` gave the file `alpha\ndelta`, `…\n\n` gave `…\n`, and `…\n  \n\n` gave `…\n  \n`. A Write's answer loses exactly one `\n`; the CLI leaves spaces alone. An Edit's answer keeps every byte: on 2.1.304 the CLI turns it into a patch against the file (the transcript shows `oldString` and `newString` of the changed region), and the file got the answer byte for byte. A new file loses one `\n` whatever the tool: an Edit with an empty `old_string`, answered `hello\nworld\n`, gave `hello\nworld`. So `ctx.accept` appends one `\n` for a Write and for a new file. `openDiff` does not name the tool. The `PreToolUse` hook writes it into the `editing/` note, and the seam looks it up there (`diff_provider.tool_of`, set by the controller). Without a note a new file counts as a Write, and any other text goes as is, as in upstream's views. At first we applied the Write rule to every tool, and Manual mode added an empty line to the end of each Edit we accepted; the live test caught it.
- **If your settings allow Edit (`permissions.allow`),** Edit runs without asking, and `openDiff` never fires, even in Manual mode. Review before write then covers Write and tools without a permission rule; review after write remains the main path. Since then the Manual-mode hook asks about every edit anyway (see "How the modes work").

## Modules and contracts

We fixed the contract between modules before writing them, because the engine, the store and zen were written in parallel.

```
lua/claudecode/review/hunks.lua      pure logic: hunks, word diff, applying cs/cx, carrying your edits
lua/claudecode/review/render.lua     extmarks, highlights, the hint
lua/claudecode/review/init.lua       engine: attach/detach, cs/cx, nvim_buf_attach
lua/claudecode/review/keymaps.lua    the buffer-local keys while a buffer is under review
lua/claudecode/review/disk.lua       the file behind a buffer: a stamp, a save without format-on-save
lua/claudecode/review/store.lua      state directory: bases, revert records, edit and Bash notes
lua/claudecode/review/text.lua       file bytes ↔ buffer lines, encodings
lua/claudecode/review/summary.lua    the revert summary text for Claude
lua/claudecode/review/controller.lua glue: hook notifications, store and engine
lua/claudecode/review/bridge.lua     receives a hook's message in the editor
lua/claudecode/review/picker.lua     list of files (<leader>ak)
lua/claudecode/review/provider.lua   review before write
lua/claudecode/hooks/init.lua        the settings file for --settings, attaching the hooks to a launch
lua/claudecode/hooks/run.lua         the hook entry script
lua/claudecode/hooks/handlers.lua    what each hook does
lua/claudecode/hooks/notify.lua      the hook's message to the editor
lua/claudecode/hooks/git.lua         git snapshots for Bash
lua/claudecode/zen/init.lua          zen
lua/claudecode/features/             options, setup, the review and zen sections of :checkhealth claudecode (checks.lua)
spec/                                tests in a real headless Neovim (scripts/test-nvim.sh)
```

**A hunk** uses the indices of `vim.text.diff(..., { result_type = "indices" })`, lines counted from 1:

```lua
---@class ClaudeCodeHunk
---@field base_start integer  -- with base_count == 0: insertion after this base line (0 = at the top)
---@field base_count integer
---@field cur_start integer   -- with cur_count == 0: deletion after this buffer line (0 = at the top)
---@field cur_count integer
---@field base_lines string[]
---@field cur_lines string[]
```

**The engine** (`require("claudecode.review")`):

```lua
review.attach(bufnr, base_lines, opts) -- start reviewing the buffer against the base; attaching again replaces the base
review.detach(bufnr)                   -- remove highlights, keys and nvim_buf_attach
review.is_attached(bufnr) -> boolean
review.hunks(bufnr) -> ClaudeCodeHunk[]
review.base(bufnr) -> string[]
review.keep(bufnr, index?)             -- index defaults to the hunk under the cursor
review.revert(bufnr, index?)
review.keep_all(bufnr)
review.revert_all(bufnr)

---@class ClaudeCodeReviewAttachOpts
---@field on_base? fun(base: string[])                -- the base moved: cs, cS, your edit outside a hunk
---@field on_revert? fun(rec: ClaudeCodeRevertRecord) -- cx or cX changed the buffer
---@field on_done? fun(reason: "resolved"|"detached") -- no hunks left, or detach was called
---@field write_on_revert? boolean                    -- default true: cx writes the file at once

---@class ClaudeCodeRevertRecord
---@field path string           -- absolute path of the buffer
---@field line integer          -- first line of the restored text in the file after the revert
---@field base_lines string[]   -- the text that came back
---@field claude_lines string[] -- Claude's text that was reverted
---@field time integer          -- os.time()
```

**Events.** The engine fires `User ClaudeCodeReviewChanged` with `data = { bufnr, path, hunks }` after every recompute (`hunks` is how many are left). The controller fires `User ClaudeCodeReviewPending` with `data = { count, files }` every time it counts the files waiting for review again, so the list may be the same; zen draws its counter from it.

**State directory** (`stdpath("state")/claudecode/review/<sha256 of the project root>/`, mode 0700):

```
bases/<sha256 of the path>  -- a JSON line { path, new_file, created_at, sessions }, then the file bytes before Claude's first edit
bases/<sha256 of the path>.lock -- a directory that exists while a hook or the editor changes that base's header
bash/<tool_use_id>.json     -- snapshot before Bash: { top, head, stash, untracked = { [path] = mtime:size } }
editing/<tool_use_id>.json  -- an edit that started and has not finished, with the file's stamp and the tool
accepting/<tool_use_id>     -- the file before an edit in accept-edits or plan mode, to carry into its base
reverts/<session_id>.jsonl  -- the revert records of one Claude session, one ClaudeCodeRevertRecord per line
reverts.jsonl               -- the same for a base that lists no session; every session takes it
hooks.log                   -- hook errors, at most 64 KB
```

A base keeps its header and text in one file, so a single atomic `fs_link` creates it, and only when it does not exist yet (item 15). A change to an existing header (a new session, a moved base) reads the file and writes it back, so it takes the lock of that base first; a lock older than 10 seconds belongs to a dead hook and is broken, and after 2 seconds of waiting the change goes ahead without the lock, because Claude must never hang. The editor waits only 100 ms (`controller.LOCK_WAIT_MS`): it has one thread, and a hook holds a lock for a moment (see "Edges the tests found"). Carrying an edit without review reads and writes the base under the lock too (`Store:update`), so a hunk you kept meanwhile survives, and a base you just finished with does not come back. A base equal to the current file text goes away the first time the plugin sees it. Base paths go through `realpath`, because `/tmp` on macOS is a link to `/private/tmp`. Binary files and files over 2 MB stay out of review.

The project root is the git repository around Neovim's working directory when Claude starts, or the directory itself outside git, so Neovim started from a subdirectory of the same repository sees the same bases. Hooks get the state directory in `CLAUDECODE_REVIEW_DIR`, Neovim's address in `CLAUDECODE_NVIM`, and `CLAUDECODE_REVIEW_BEFORE_WRITE=1` while Manual mode should ask about edits. A hook sends Neovim one msgpack request (`nvim_exec_lua` → `claudecode.review.bridge.on_hook(payload)`) and waits for the answer for at most 500 ms. The address is a socket path or `host:port`; the hook resolves a host name (`nvim --listen localhost:6666`) and tries each of its addresses. The bridge only schedules its work, so a free Neovim answers at once; a Neovim at a hit-enter prompt does not answer, and the hook goes on without it (see "What openDiff taught us"). A hook logs every error to `hooks.log` and exits with 0: review may miss an edit, but Claude never hangs. Paths in the revert summary are relative to Claude's working directory from the hook input.

## Tests

31. **TDD with busted.** The tests cover:
    - pure logic: choosing the base, accumulating edits, carrying your edits, the revert summary text;
    - the store and the hook scripts: JSON on stdin, a temporary directory;
    - the provider and the engine in headless Neovim: cs and cx change the buffer and the base, accept returns the right text, and upstream's tests still pass;
    - the zen layout in headless Neovim.

## Edges the tests found

- **Encodings.** A base keeps the file bytes, a buffer holds UTF-8. Before comparing, the plugin converts the base with the buffer's `fileencoding`, or without a buffer by the byte order mark and `'fileencodings'`; the byte order mark survives. In review before write the accepted text goes to Claude as UTF-8, and Claude writes UTF-8: a Latin-1 or UTF-16 file becomes UTF-8 after you accept, because the protocol carries only text.
- **Line endings.** Review before write keeps CRLF. For a file that git checks out with CRLF (`eol=crlf`, `core.autocrlf`), the base comes through git's filters, so a Bash call that did not touch the file creates no hunks.
- **Empty files and the final newline.** An emptied buffer is an empty file, not `"\n"`. `cx` does not add a final newline to a file that had none.
- **Hook races.** Between `PreToolUse` and `PostToolUse` the base equals the file; the `editing/<tool_use_id>.json` note keeps it from being dropped. The note holds the file's stamp: if Claude was refused the edit and you later created or changed the file yourself, review treats the file as yours. The plugin forgets a note after 30 minutes.
- **A hook that hangs up at once loses its message.** At first the hook sent a notification and closed the socket. A Neovim busy with a terminal (the Claude TUI redrawing after you approve a plan) dropped some of them: 95 of 100 notifications arrived while another terminal poured out text, and live, the first edit after a plan was approved never showed up for review. A request whose answer the hook waits for arrived 100 times of 100 under the same load.
- **A mode that changes between the two hooks of one call,** and accept-edits mode that told Neovim only about files with a base: both are under "How the modes work".
- **A lock left behind freezes the editor.** A hook killed while it held the lock of a base leaves the lock for 10 seconds. The editor waited up to 2 seconds for it at every keep and revert: a keep and a revert stood still for 4 seconds in a test. Now it waits 100 ms and goes on without the lock. 20 ms was too short: with three hooks hammering one base, a live hook sometimes held the lock longer and a session was lost, in about 3 runs of 14; 45 runs at 100 ms lost none.
- **An address that names a host.** `nvim --listen localhost:6666` makes `$NVIM` a name, and libuv connects to addresses only, so the hook waited its 500 ms and gave up without a word. It resolves the name now and tries every address.
- **Bash snapshots.** `git stash create` takes `index.lock`. If the lock is still taken after three tries, the hook takes no snapshot at all: falling back to HEAD would make your uncommitted work look like Claude's edit. Snapshots of calls that never finished go away after a day.
- **A branch switch is not an edit.** At first `PostToolUse(Bash)` put every file the call changed under review against the snapshot. Live, Claude ran `git switch -c <branch> origin/<base>`, and 44 files that differ between the branches came up as Claude's edits, while `git status` was clean. Now the hook tells git's checkout from Claude's edits by HEAD (item 12). The price: `sed -i f && git commit -am …` in one call leaves `f` clean before and after, so its edit escapes review. Telling a commit from a checkout by the new commits does not work either, since `rebase` writes new commits too.
- **Keys that make a motion wait.** The first defaults were `ko`, `kx`, `KO` and `KX`. In a buffer under review `k` became the start of a mapping, so every `k` waited for 'timeoutlen' before the cursor moved up, and `K` (LSP hover in LazyVim) waited the same way. `<M-y>` and `<M-n>` were next: they need Option-as-Meta on macOS, and LazyVim maps `<a-n>` in the buffer on LspAttach, which can land after the review's keys. `ca` and `cd` were proposed too, but `a` starts a text object, and `ca` would swallow `caw`. Now `cs`, `cx`, `cS`, `cX`: Neovim waits for a motion after `c` anyway, and these letters are none. A spec checks every default key.

## Plan

Done on 2026-10-19 and 2026-10-20:

0. Repository, cleanup, sync script, LICENSE, this file, the check in item 26.
1. Diff provider seam.
2. Extmark engine: hunks, word diff, keep and revert, the hint.
3. Review after write: hooks, bases, carrying your edits, the list of files, the revert summary.
4. Review before write: our provider on the same engine.
5. Zen and `cz`.
6. LazyVim spec: `lazyvim/claudecode.lua`.
7. `:help claudecode`.
8. Modes: the review follows Claude's permission mode.
9. A revert summary for each Claude session, so that two sessions in one project do not take each other's notes.
10. A settings file for each copy of the plugin and binary of Neovim (item 25).
11. A second look at modes and sessions: a mode that changes between the hooks, buffers that reload in every mode, a short lock wait in the editor, host names (see "Edges the tests found").
