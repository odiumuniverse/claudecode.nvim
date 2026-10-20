# claudecode.nvim: hunk review and zen mode

The native `claude` TUI inside Neovim over the IDE protocol, with Cursor-style hunk review and an avante-style zen mode.

## Foundation

1. **The chat is the native `claude` TUI.** It talks to the editor over the IDE protocol (WebSocket MCP, a lock file in `~/.claude/ide/`). The subscription stays within the terms: you sign in to the unmodified Claude Code binary with your own account. We use neither ACP nor the Agent SDK.
2. **No MCP server of our own for the model.** Neovim learns about edits from Claude Code hooks. Claude edits files only with its own Edit, Write and Bash.
3. **A fork of claudecode.nvim.** The private repository `odiumuniverse/claudecode.nvim` is not a GitHub fork, because GitHub does not let you make a fork of a public repository private. The local clone lives in `~/src/claudecode.nvim`; the original is the `upstream` remote.
4. **Sync by rebase.** Our commits sit on top of `upstream/main`. The cleanup commit always comes last: `fork/sync.sh` drops it, rebases, and deletes the listed files again.
5. **What we delete** (the full list is `fork/cleanup.txt`): `communique.toml`, `reviewfixer.yaml`, `release-please*`, `CHANGELOG.md`, `VERSION`, `STORY.md`, `scripts/release-please-*`, `scripts/package*.json`, `.github/ISSUE_TEMPLATE`, every upstream workflow, `.devcontainer/` and `.claude/`. Upstream's `test.yml` runs release-please tests from the deleted `scripts/package.json`, so instead of editing it we have our own `.github/workflows/ci.yml` with the same Lua tests. **What we keep:** `mise.*` as is (its `communique` tool and `reviewfix` task do no harm), `treefmt.toml`, the repro scripts and fixtures, `AGENTS.md` and `CLAUDE.md`. Upstream's architecture and protocol docs moved to `docs/`, and its development guide became `CONTRIBUTING.md`; git carries upstream's later changes over to the new paths on rebase. The root `README.md` stays upstream's, with a dead link to `STORY.md`; GitHub shows `.github/README.md` first.
6. **LICENSE:** `Copyright (c) 2026 odiumuniverse` goes under Coder's line.
7. **Our code lives in modules of its own:** `lua/claudecode/review/`, `lua/claudecode/hooks/`, `lua/claudecode/zen/` and `lua/claudecode/features/`. Upstream files get only small marked seams: the diff provider branches in `diff.lua`, `hooks.decorate` in `terminal.lua`, and `features.setup` in `init.lua`.

## Review: two modes

8. **Claude's permission mode picks the review.** Review after write, as in Cursor, is the main path: in auto, `bypassPermissions` and `dontAsk` Claude edits files at once, and the plugin shows the hunks on top of the code. Manual mode (`default`) reviews before write (item 9). Accept edits and plan mode take edits without review. How the hooks tell the modes apart is under "How the modes work" below.
9. **Review before write, as in VS Code, is Manual mode.** We add a diff provider seam: `diff_opts.provider = { open(ctx), close(ctx, reason) }`. `ctx` carries the paths, the proposed text, `is_new_file`, and the calls `ctx.accept(content)` and `ctx.reject()`. A provider is opt-in: without one, upstream's native and unified views work as before, and we leave their code alone to keep rebases cheap. The plugin calls `close` exactly once per diff, also when `open` fails (`reason = "setup failed"`). Our provider opens the proposal in place of the file and draws it the same way as review after write. Once every hunk is decided, the result goes to Claude; if you reverted every hunk, Claude gets `DIFF_REJECTED`.
10. **Text you accept through the provider becomes the base at once,** so review after write does not show it again.

The provider gets the diff even when the file's buffer has unsaved edits: its branch comes before the `is_buffer_dirty` check. It fires `ClaudeCodeDiffOpened` with `layout = "provider"`, and `:ClaudeCodeDiffAccept` and `:ClaudeCodeDiffDeny` call its `accept_command` and `reject_command`. Without these handlers the commands accept the whole proposal or reject it; after `reject_command` Claude always gets a rejection.

**How the modes work.** Every hook input carries `permission_mode`, and it changes right after shift+tab. So the hooks read the mode at each call and keep no mode of their own.

- **Manual.** `PreToolUse` of Edit, Write, MultiEdit and NotebookEdit answers `permissionDecision: "ask"`. A hook's `ask` beats `permissions.allow`, so Claude asks about every edit, the IDE gets `openDiff`, and our provider shows the proposal. Without the hook an allowed Edit never reaches `openDiff` (see "What openDiff taught us"). The hook asks only while review before write is on: `review.before_write`, or a provider of your own. Bash is never asked about; its edits come up as hunks after the call.
- **Accept edits.** The hooks take no base. If the file already has one, `PreToolUse` saves the text before the edit in `accepting/<tool_use_id>`, and `PostToolUse` carries the edit into the base (`hunks.carry`): the hunks still waiting for you stay, and an edit that touches one of them joins that hunk. A Bash call in this mode carries its edits only into bases that already exist.
- **Plan.** The same as accept edits. Claude writes only its plan file in this mode, and the plan has no place in the review list.
- `:ClaudeCode --permission-mode manual` starts Claude in Manual mode; the LazyVim spec maps it to `<leader>am`.

## Where the base comes from

11. **Edit and Write.** The `PreToolUse` hook copies the file before the edit. If the file does not exist, it marks the base as new.
12. **Bash.** `PreToolUse(Bash)` runs `git stash create` (HEAD on a clean tree), and `PostToolUse(Bash)` asks `git diff --name-only` against that snapshot. The hook copies the old text of every changed file into the state directory right away instead of keeping the sha: `git gc` may delete a commit nothing points to.
13. **An untracked file that Bash changed.** `PostToolUse(Bash)` compares the size and mtime of untracked files with the snapshot and tells Neovim which ones changed. If such a file is open and its buffer is unmodified, the old buffer text becomes the base. If it is not open, the edit escapes review; the README says so.
14. **Changes outside Claude's tool calls** (yours, other programs, `git pull`) stay out of review.
15. **The base accumulates until you decide on the hunk.** Edits over several turns add up against the first snapshot. If a file lands in several snapshots, the earliest one wins.
16. **Your edits in a buffer under review** (tracked with `nvim_buf_attach`). An edit outside a hunk goes into the base too and never becomes a hunk. An edit inside a hunk changes Claude's proposal, and the hunk still waits for `ko` or `kx`.

## Display and keys

17. **Our own extmark engine;** `vim.text.diff` finds the hunks. Deleted lines appear as red virtual lines above the hunk, added lines get a green background. In paired changed lines only the changed words light up. The hunk under the cursor shows a hint, `ko keep · kx revert`. Like the rest of the UI it is in English; the plugin builds it from your keys, and `review.hint` replaces or hides it. Deleted lines above the first line of the file show up at once: a window at the top of the file scrolls onto them (`topfill`).
18. **We do not take the sign column.** gitsigns keeps it.
19. **The list of files** with undecided hunks opens with `<leader>ak` and `:ClaudeCodeReview`: open (Enter puts the cursor on the first hunk), keep all (`<A-o>`), revert all (`<A-x>`). The list uses snacks.picker, then fzf-lua, then `vim.ui.select`, since many LazyVim setups pick fzf-lua. Revert all on a new file deletes the file: it did not exist before Claude.
20. **Keys:** `ko` keeps the hunk, `kx` reverts it, `KO` and `KX` act on the whole file, `]k` and `[k` go to the next and previous hunk, `]K` and `[K` to the last and first.
21. **Disk:** `kx` writes the file at once, together with your unsaved edits in that buffer; `ko` only moves the base. The write runs with `noautocmd` so that format-on-save cannot invent new differences, and the plugin then fires `BufWritePost` by hand. The final newline stays as the file had it. If the file changed on disk since it was loaded, `kx` does not overwrite it: it recomputes the hunks and warns. After each of Claude's writes the hook tells Neovim which files changed, and Neovim reloads their buffers.
22. **Revert summary for Claude.** The hook adds `additionalContext` to whichever comes first: `PostToolUse` of the next Edit, Write or Bash, or `UserPromptSubmit` of your next message. The summary names the file and line and shows Claude's text and the text that came back; then it is cleared. The CLI itself tells the model only a generic sentence (see "What openDiff taught us").
23. **State lives on disk,** in `stdpath("state")/claudecode/review/<sha256 of the project root>/`: bases and the revert summary. Hunks are not stored: the plugin computes them from the base and the file every time. A base goes away once its file has no hunks left.

## Hooks

24. **Hooks are Lua scripts run with `nvim --clean -l`,** so that LazyVim does not load on every edit. They reach the running Neovim through `$NVIM`.
25. **Hooks attach only to sessions started from Neovim:** `claude --settings <generated settings.json>` with absolute paths to the scripts. Every launch path carries the flag: plain, `--resume`, `--continue` and `cz`.
26. **Hooks from `--settings` add to your own hooks rather than replace them.** Checked on 2026-10-19 with Claude Code 2.1.303: in one `claude -p --settings … --debug hooks` run both a test hook and a user hook ran.

## Zen mode

27. **Zen lives inside Neovim, in a tab of its own with a single Claude window.** The Claude terminal always sits in exactly one window: a terminal takes the width of its widest window, so a full-screen copy in another tab would garble the narrow split (checked in a real UI). Zen hides the tabline while it is on. Leaving zen returns you to the tab you entered from. `bin/cz` opens Neovim straight into zen and passes its arguments to Claude (`cz --resume`).
28. **Two states:** zen (only Claude) and work (code with Claude on the right). `<M-z>` switches between them, from the terminal and from the code.
29. **A proposal arrives in zen (Manual mode):** zen switches to the work state on the proposal and comes back once you have decided.
30. **Zen shows a counter,** "N files wait for review · <leader>ak", in the winbar above Claude, so that edits waiting for review do not pile up unnoticed.

## What openDiff taught us

2026-10-19, Claude Code 2.1.303, Manual mode. Claude rewrote a file in one Write with two changes; we reverted one in the proposal buffer and saved.

- **The CLI writes exactly the text we send back** in the `FILE_SAVED` answer: one change of the two ended up on disk.
- **The model gets only a generic sentence:** _"The file … has been updated successfully. The user modified your proposed content before accepting it."_ The CLI does not say which hunks you reverted. The transcript metadata has `userModified: true` and `structuredPatch`, but the model never sees them. Haiku reread the file on its own and noticed the revert, but we cannot count on that.
- **The CLI strips exactly one `\n` from the end of the answer.** A 2026-10-20 test with three Writes: the answer `alpha\ndelta\n` gave the file `alpha\ndelta`, `…\n\n` gave `…\n`, and `…\n  \n\n` gave `…\n  \n`. The CLI leaves spaces alone. So `ctx.accept` appends one `\n`, and the file gets exactly the text passed in. Upstream's built-in diff views send the text as is and lose the final newline. A rerun on 2.1.304 with the fix: all three files matched the text byte for byte.
- **If your settings allow Edit (`permissions.allow`),** Edit runs without asking, and `openDiff` never fires, even in Manual mode. Review before write then covers Write and tools without a permission rule; review after write remains the main path. Since then the Manual-mode hook asks about every edit anyway (see "How the modes work").

## Modules and contracts

We fixed the contract between modules before writing them, because the engine, the store and zen were written in parallel.

```
lua/claudecode/review/hunks.lua      pure logic: hunks, word diff, applying ko/kx, carrying your edits
lua/claudecode/review/render.lua     extmarks, highlights, the hint
lua/claudecode/review/init.lua       engine: attach/detach, keys, ko/kx, nvim_buf_attach
lua/claudecode/review/store.lua      state directory: bases, revert records, edit and Bash notes
lua/claudecode/review/text.lua       file bytes ↔ buffer lines, encodings
lua/claudecode/review/summary.lua    the revert summary text for Claude
lua/claudecode/review/controller.lua glue: hook notifications, store and engine
lua/claudecode/review/picker.lua     list of files (<leader>ak)
lua/claudecode/review/provider.lua   review before write
lua/claudecode/hooks/                settings.json for --settings, the hook entry script, git snapshots
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
---@field on_base? fun(base: string[])                -- the base moved: ko, KO, your edit outside a hunk
---@field on_revert? fun(rec: ClaudeCodeRevertRecord) -- kx or KX changed the buffer
---@field on_done? fun(reason: "resolved"|"detached") -- no hunks left, or detach was called
---@field write_on_revert? boolean                    -- default true: kx writes the file at once

---@class ClaudeCodeRevertRecord
---@field path string           -- absolute path of the buffer
---@field line integer          -- first line of the restored text in the file after the revert
---@field base_lines string[]   -- the text that came back
---@field claude_lines string[] -- Claude's text that was reverted
---@field time integer          -- os.time()
```

**Events.** The engine fires `User ClaudeCodeReviewChanged` with `data = { bufnr, path, hunks }` after every recompute (`hunks` is how many are left). The controller fires `User ClaudeCodeReviewPending` with `data = { count, files }` when the list of files waiting for review changes; zen draws its counter from it.

**State directory** (`stdpath("state")/claudecode/review/<sha256 of the project root>/`, mode 0700):

```
bases/<sha256 of the path>  -- a JSON line { path, new_file, created_at }, then the file bytes before Claude's first edit
bash/<tool_use_id>.json     -- snapshot before Bash: { top, stash, untracked = { [path] = mtime:size } }
editing/<tool_use_id>.json  -- an Edit or Write that started and has not finished, with the file's stamp
accepting/<tool_use_id>     -- the file before an edit in accept-edits or plan mode, to carry into its base
reverts.jsonl               -- one ClaudeCodeRevertRecord per line
hooks.log                   -- hook errors, at most 64 KB
```

A base keeps its header and text in one file, so a single atomic `fs_link` creates it, and only when it does not exist yet (item 15). A base equal to the current file text goes away the first time the plugin sees it. Base paths go through `realpath`, because `/tmp` on macOS is a link to `/private/tmp`. Binary files and files over 2 MB stay out of review.

The project root is the git repository around Neovim's working directory when Claude starts, or the directory itself outside git, so Neovim started from a subdirectory of the same repository sees the same bases. Hooks get the state directory in `CLAUDECODE_REVIEW_DIR`, Neovim's address in `CLAUDECODE_NVIM`, and `CLAUDECODE_REVIEW_BEFORE_WRITE=1` while Manual mode should ask about edits. A hook sends Neovim only a msgpack notification (`nvim_exec_lua` → `claudecode.review.bridge.on_hook(payload)`) and never waits for an answer, because Neovim may sit at a hit-enter prompt (see "What openDiff taught us"). A hook logs every error to `hooks.log` and exits with 0: review may miss an edit, but Claude never hangs. Paths in the revert summary are relative to Claude's working directory from the hook input.

## Tests

31. **TDD with busted.** The tests cover:
    - pure logic: choosing the base, accumulating edits, carrying your edits, the revert summary text;
    - the store and the hook scripts: JSON on stdin, a temporary directory;
    - the provider and the engine in headless Neovim: ko and kx change the buffer and the base, accept returns the right text, and upstream's tests still pass;
    - the zen layout in headless Neovim.

## Edges the tests found

- **Encodings.** A base keeps the file bytes, a buffer holds UTF-8. Before comparing, the plugin converts the base with the buffer's `fileencoding`, or without a buffer by the byte order mark and `'fileencodings'`; the byte order mark survives. In review before write the accepted text goes to Claude as UTF-8, and Claude writes UTF-8: a Latin-1 or UTF-16 file becomes UTF-8 after you accept, because the protocol carries only text.
- **Line endings.** Review before write keeps CRLF. For a file that git checks out with CRLF (`eol=crlf`, `core.autocrlf`), the base comes through git's filters, so a Bash call that did not touch the file creates no hunks.
- **Empty files and the final newline.** An emptied buffer is an empty file, not `"\n"`. `kx` does not add a final newline to a file that had none.
- **Hook races.** Between `PreToolUse` and `PostToolUse` the base equals the file; the `editing/<tool_use_id>.json` note keeps it from being dropped. The note holds the file's stamp: if Claude was refused the edit and you later created or changed the file yourself, review treats the file as yours. The plugin forgets a note after 30 minutes.
- **Bash snapshots.** `git stash create` takes `index.lock`. If the lock is still taken after three tries, the hook takes no snapshot at all: falling back to HEAD would make your uncommitted work look like Claude's edit. Snapshots of calls that never finished go away after a day.

## Plan

Done on 2026-10-19 and 2026-10-20:

0. Repository, cleanup, sync script, LICENSE, this file, the check in item 26.
1. Diff provider seam.
2. Extmark engine: hunks, word diff, ko/kx, the hint.
3. Review after write: hooks, bases, carrying your edits, the list of files, the revert summary.
4. Review before write: our provider on the same engine.
5. Zen and `cz`.
6. LazyVim spec: `lazyvim/claudecode.lua`.
7. `:help claudecode`.
8. Modes: the review follows Claude's permission mode.

Next: a revert summary for each Claude session, so that two sessions in one project do not take each other's notes.
