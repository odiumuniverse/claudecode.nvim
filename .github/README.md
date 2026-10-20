# claudecode.nvim

[![CI](https://github.com/odiumuniverse/claudecode.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/odiumuniverse/claudecode.nvim/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/odiumuniverse/claudecode.nvim)](https://github.com/odiumuniverse/claudecode.nvim/releases)
[![Neovim 0.11+](https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](https://github.com/odiumuniverse/claudecode.nvim/blob/main/LICENSE)

**Claude Code in Neovim, with Cursor-style review: keep or revert each change Claude makes, hunk by hunk.**

> [!NOTE]
> The original [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim) has had no new commits since June 2026. This repository is the up-to-date version: it keeps everything upstream does and adds hunk review, Claude's permission modes, zen mode and account switching.

The plugin connects the Claude Code CLI to Neovim over the same WebSocket MCP protocol that Anthropic's VS Code extension uses. Claude opens files, reads your selection and diagnostics, and shows its edits as diffs. Two features come on top:

- **Hunk review.** Keep or revert each change Claude makes, the way Cursor does, instead of accepting or rejecting the whole file.
- **Zen mode.** Run Claude full screen inside Neovim and flip to the code with one key.

![Claude edits cart.py; the edits show up as hunks; kx reverts one, ko keeps the other; Alt+z opens zen and goes back](demo.gif)

With [cswap](https://github.com/realiti4/claude-swap) (claude-swap) it also switches the Claude account Neovim runs: `:ClaudeCode run 1`.

Claude runs as the unmodified `claude` binary, so you sign in with your own Claude subscription.

Based on [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim) (upstream).

More documentation:

- [docs/CHANGELOG.md](https://github.com/odiumuniverse/claudecode.nvim/blob/main/docs/CHANGELOG.md): what each release brought;
- [docs/DESIGN.md](https://github.com/odiumuniverse/claudecode.nvim/blob/main/docs/DESIGN.md): the design and the reasons behind it;
- [docs/ARCHITECTURE.md](https://github.com/odiumuniverse/claudecode.nvim/blob/main/docs/ARCHITECTURE.md) and [docs/PROTOCOL.md](https://github.com/odiumuniverse/claudecode.nvim/blob/main/docs/PROTOCOL.md): upstream's architecture and the IDE protocol;
- [CONTRIBUTING.md](https://github.com/odiumuniverse/claudecode.nvim/blob/main/CONTRIBUTING.md): upstream's development guide.

## Requirements

- Neovim 0.11 or newer. On older versions the plugin behaves exactly as upstream.
- Claude started from Neovim (`:ClaudeCode`, zen or `cz`). The review hooks ride on that launch.
- `git` for reviewing edits Claude makes through Bash.

## Install

With LazyVim, use the ready spec instead of the `ai.claudecode` extra: copy [lazyvim/claudecode.lua](https://github.com/odiumuniverse/claudecode.nvim/blob/main/lazyvim/claudecode.lua) to `~/.config/nvim/lua/plugins/claudecode.lua`. It keeps the extra's keys, moves Toggle Claude from `<leader>ac` to `<leader>at`, and adds `<leader>am`, `<leader>ak` and `<M-z>`.

The spec loads the plugin on `VeryLazy`, not on a key: a file Claude edited before a restart comes back under review only if the plugin is running when you open it.

With plain lazy.nvim:

```lua
{
  "odiumuniverse/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  event = "VeryLazy", -- not only on a key: a file Claude edited before a restart comes back under review
  cmd = { "ClaudeCode", "ClaudeCodeZen", "ClaudeCodeReview" },
  keys = {
    { "<leader>at", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>ak", "<cmd>ClaudeCodeReview<cr>", desc = "Files waiting for review" },
    { "<M-z>", "<cmd>ClaudeCodeZen<cr>", desc = "Claude zen" },
  },
  opts = {},
}
```

To run the plugin from a clone of your own, add `dir = "<path to the clone>"` to either spec.

Upstream's commands, keymaps and options all work as before; the [upstream README](https://github.com/coder/claudecode.nvim#readme) describes them. Run `:checkhealth claudecode` to check the IDE connection, the review hooks and zen.

`:help claudecode` documents the options, keys and events of review and zen.

## Modes

Claude's permission mode picks the review. Switch it in Claude with shift+tab; the next edit follows the new mode, and an edit already under way ends the way it began.

| Claude's mode                           | What happens to an edit                                                                                                                                                                                                  |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Manual (`default`)                      | Claude waits for you. The proposal opens in Neovim, and you keep or revert each hunk before Claude writes the file.                                                                                                      |
| Auto, `bypassPermissions` and `dontAsk` | Claude does not ask about edits. What it writes waits for you as hunks in the file.                                                                                                                                      |
| Accept edits                            | Claude writes, and the plugin keeps the edit without review. Hunks left from earlier edits stay; an edit that touches one joins it. So does an edit you allow with "Yes, and switch to accept edits" at Claude's prompt. |
| Plan                                    | No review. Claude writes only its plan file here.                                                                                                                                                                        |

In Manual mode the plugin asks about every edit, even one your Claude settings allow without asking (`permissions.allow`): its `PreToolUse` hook answers `ask` for Claude's edit tools. Bash keeps your own permission rules, and its edits come up as hunks after the call.

`<leader>am` in the LazyVim spec starts Claude in Manual mode (`:ClaudeCode --permission-mode manual`). `<leader>at` starts it in the mode from your Claude settings (`permissions.defaultMode`). The flag counts only when Claude starts: while Claude runs, the key just shows or hides it, like `<leader>at`. Switch a running session with shift+tab.

The modes need the hooks, so they work only for Claude started from Neovim. A Claude you start yourself has no hooks and asks only when your Claude settings say so.

## Hunk review

In auto mode Claude edits your files right away, the way it does in the terminal. The plugin then shows what changed on top of the code:

- deleted lines appear in red above the change, as virtual lines that are not part of the file;
- added lines get a green background;
- inside a changed line, only the changed words are highlighted;
- the hunk under the cursor shows a hint: `ko keep · kx revert`.

| Key          | What it does                                         |
| ------------ | ---------------------------------------------------- |
| `ko`         | Keep the hunk under the cursor                       |
| `kx`         | Revert it; the file is written at once               |
| `KO` / `KX`  | Keep or revert every hunk in the file                |
| `]k` / `[k`  | Next or previous hunk (takes a count)                |
| `]K` / `[K`  | Last or first hunk                                   |
| `<leader>ak` | Files waiting for review: open, keep all, revert all |

The hunk keys exist only in buffers under review; `<leader>ak` works everywhere. The list of files uses snacks.picker, fzf-lua or `vim.ui.select`, whichever it finds first; in snacks.picker and fzf-lua, `<A-o>` keeps a whole file and `<A-x>` reverts it.

**Claude learns what you reverted.** Claude Code itself never tells the model that you rejected part of an edit. The plugin adds a short note to Claude's context instead: right after Claude's next file edit or Bash call, or with your next message. The note names the file and line, shows Claude's text and the text that came back, and asks Claude not to reapply the change unless you ask. With several Claude sessions in one project, each session hears only about the files it edited; the note about a file two sessions edited reaches both.

**Your own edits stay yours.** Edit the buffer outside a hunk and the change simply becomes part of the file. Edit inside a hunk and you change Claude's proposal; the hunk still waits for `ko` or `kx`. After `kx`, `u` brings Claude's text back as your own edit.

**Review survives restarts.** The text of each file before Claude's first edit lives in `stdpath("state")/claudecode/review/`, in a directory only you can read. Hunks pile up across Claude's turns until you decide on them. The state belongs to the git repository around Neovim's working directory (or to the directory itself outside git), so start Neovim anywhere in the same repository to get your reviews back.

### What gets reviewed

Unless Claude is in accept-edits or plan mode (see [Modes](#modes)):

- `Edit`, `Write`, `MultiEdit` and `NotebookEdit`: every call. In Manual mode you see the proposal first (see [Review before write](#review-before-write)).
- `Bash` in a git repository: every file it changed, created or deleted. The plugin snapshots the work tree before the call with `git stash create`, which does not touch your stash list. Files that git checks out with CRLF endings (`eol=crlf`, `core.autocrlf`) keep them through review and `kx`.
- An untracked file Bash rewrote: only when the file is open in Neovim and unmodified, because its old text exists nowhere else.
- Files outside the project as well, such as Claude's memory under `~/.claude/`: review follows Claude's edit tools wherever they write.
- Not reviewed: binary files, files over 2 MB, new files Bash creates in paths that `.gitignore` covers, edits outside a Claude tool call (yours, `git pull`, other programs), and Bash edits outside git repositories.
- If you refuse an edit and then create or change that file yourself, review treats the file as yours.

### How it works

Every Claude session started from Neovim gets `claude --settings <file>` with three hooks: `PreToolUse`, `PostToolUse` and `UserPromptSubmit`. Claude Code adds these to the hooks you already have; it does not replace them. Each hook is a short `nvim --clean --headless -l` script. It copies the file before the edit and tells Neovim about it, waiting half a second at most for Neovim to take the message. A hook never blocks Claude: on any error it logs to `hooks.log` and exits with 0, so at worst one edit escapes review. The name of the settings file is computed from the paths of your `nvim` and of this copy of the plugin, so a second Neovim with another copy writes a file of its own and leaves yours alone.

If you start Claude yourself (`terminal.provider = "none"`), the hooks are not attached and review after write stays off. Review before write still works: it needs only the IDE connection.

## Review before write

In Manual mode Claude asks before each edit. The plugin opens the proposal in place of the file, with the same hunks and keys. When no hunk is left, the text you kept goes to Claude; if you reverted every hunk, Claude gets a rejection. `:w` in the proposal answers with what is there now: Claude writes it, or gets a rejection when it equals the file. `:ClaudeCodeDiffAccept` does the same, and `:ClaudeCodeDiffDeny` refuses the whole proposal.

Claude sends UTF-8. The plugin compares it with the file in the file's own encoding, so a Latin-1 or UTF-16 file shows only what Claude changed. It reads the encoding from the open buffer, or else from the byte order mark and `'fileencodings'`. The protocol carries text only, so Claude writes UTF-8 after you accept: a Latin-1 or UTF-16 file becomes UTF-8. A byte order mark stays.

Set `review.before_write = false` to keep upstream's diff views, or set your own `diff_opts.provider` (see below).

## Zen mode

`<M-z>` puts Claude full screen in a tab of its own, with no tabline even if bufferline.nvim wants one, and brings you back to the code, with Claude in its split. It works in normal mode and inside the Claude terminal; other terminals still get the key. Above Claude, zen shows how many files wait for review. When Claude asks to approve an edit in Manual mode, zen steps aside for the proposal and comes back once you have decided. Leaving zen returns you to the tab you entered from. If you switch to another tab while zen is open, the key brings you back into zen instead of opening a second one.

`:ClaudeCodeZen` does the same. Its arguments go to `claude` when zen has to start it, as in `:ClaudeCodeZen --resume`; they do nothing while Claude runs.

`bin/cz` opens Neovim straight into zen:

```sh
ln -s ~/.local/share/nvim/lazy/claudecode.nvim/bin/cz ~/.local/bin/cz
cz            # new session
cz --resume   # pick a session to resume
```

Zen needs Claude inside Neovim (`terminal.provider` set to `snacks`, `native` or `auto`).

## Accounts (cswap)

`:ClaudeCode run` runs Claude as one of your accounts in cswap (claude-swap), a switcher for several Claude accounts:

```vim
:ClaudeCode run 1             " account 1
:ClaudeCode run work          " an alias, or the account's email
:ClaudeCode run 1 --resume    " Claude's own arguments follow the account
:ClaudeCode run               " the account `cswap map` gives this directory, or your default login
```

- The account sticks. Every later launch from this Neovim runs it: the toggle, focus, zen and `--resume` too, until the next `:ClaudeCode run`.
- A Claude that already runs is stopped and replaced, without asking; its conversation ends. cswap keeps the history of each account apart.
- The plugin checks the account against `cswap list --json` before it stops anything, so a mistyped account leaves the running Claude alone. `<Tab>` completes the account numbers and aliases.
- When zen is open, the new Claude opens in zen.
- The plugin runs `cswap run <account> -- <args>`: cswap hands everything after `--` to Claude, the review hooks' `--settings` included.
- Each account has a profile of its own, so Claude asks once per account whether you trust the project folder.

## Options

These go into the same `opts` table as upstream's. Shown with their defaults:

```lua
opts = {
  review = {
    enabled = true,
    before_write = true,        -- review Manual-mode proposals with the same engine
    keymaps = {                 -- buffer-local while a file is under review; false disables a key
      keep = "ko", revert = "kx", keep_all = "KO", revert_all = "KX",
      next = "]k", prev = "[k", last = "]K", first = "[K",
    },
    files_keymap = "<leader>ak",
    hint = true,                -- true builds the hint from your keys; a string replaces it; false hides it
    word_diff = true,
    picker = "auto",            -- "snacks", "fzf" or "select"
  },
  zen = {
    enabled = true,
    keymap = "<M-z>",
  },
  cswap = {
    cmd = "cswap",              -- the cswap executable for :ClaudeCode run: a name on PATH or a full path
  },
}
```

Highlight groups, all defined with `default = true` so your colorscheme applies: `ClaudeCodeReviewAdd`, `ClaudeCodeReviewAddText`, `ClaudeCodeReviewDelete`, `ClaudeCodeReviewDeleteText`, `ClaudeCodeReviewHint`, `ClaudeCodeZenPending`.

`User` events for your config:

- `ClaudeCodeReviewChanged`, `data = { bufnr, path, hunks }`: the hunks of a buffer were worked out again; `hunks` is how many are left.
- `ClaudeCodeReviewPending`, `data = { count, files }`: the files waiting for review were counted again; the list may be the same.
- `ClaudeCodeDiffOpened` and `ClaudeCodeDiffClosed` also fire for proposals. The opened event has `layout = "provider"` and none of the window fields of upstream's diffs.

## Custom diff provider

Set `diff_opts.provider` to take over `openDiff` from the built-in views. Review before write is one such provider; yours replaces it.

```lua
require("claudecode").setup({
  diff_opts = {
    provider = {
      open = function(ctx)
        -- Show ctx.new_file_contents against ctx.old_file_path, then answer Claude once:
        --   ctx.accept(text)  Claude writes `text` to the file
        --   ctx.reject()      the file stays as it is
      end,
      close = function(ctx, reason)
        -- Remove your UI.
      end,
      accept_command = function(ctx) -- optional: what :ClaudeCodeDiffAccept does
        ctx.accept(ctx.new_file_contents)
      end,
      reject_command = function(ctx) -- optional: what :ClaudeCodeDiffDeny does
        ctx.reject()
      end,
    },
  },
})
```

`ctx` carries `tab_name`, `old_file_path`, `new_file_path`, `new_file_contents`, `is_new_file` and `tool`: Claude's tool, `"Edit"` or `"Write"`, when the plugin knows it.

How it behaves:

- Claude waits until you call `accept` or `reject`. Only the first call counts. `:ClaudeCodeDiffDeny` calls `reject_command`. Claude gets a rejection when the handler returns, even if the handler never called `reject`.
- `accept` may pass text that differs from Claude's proposal. Claude writes your text, but it only learns that "the user modified your proposed content", not what you changed.
- The plugin calls `close` once per diff: after Claude closes the tab, when the Claude session disconnects, when a new diff reuses the tab name, and when `open` throws (`reason` is `"setup failed"`). Make `close` safe to run on a half-built UI.
- A provider gets the diff even when the file's buffer has unsaved edits; the built-in views refuse it.
- Claude Code (checked on 2.1.304) treats the answer by tool. An Edit of an existing file becomes a patch against it and lands byte for byte. The text of a Write, or of any new file, loses one trailing newline, so `accept` adds one, and the file ends up with exactly your text. `openDiff` does not name the tool: the review hooks note it before Claude asks. Without their note (Claude started outside Neovim) an existing file's text goes as is, as in upstream's views.

## Development

```sh
mise install          # Neovim, LuaJIT, formatters and linters
mise run setup        # busted, luacheck and luacov into ./.luarocks
mise run all          # format, lint and upstream's tests (mocked vim)
scripts/test-nvim.sh  # our specs, inside a real headless Neovim

mise exec -- busted tests/unit/diff_provider_spec.lua   # one upstream-style spec
scripts/test-nvim.sh spec/review/hunks_spec.lua         # one real-Neovim spec
```

Our code lives in its own modules: `lua/claudecode/review/`, `lua/claudecode/hooks/`, `lua/claudecode/zen/` and `lua/claudecode/features/`. Upstream's files get only small marked seams, so rebasing stays cheap.

## Syncing with upstream

For maintainers. The `upstream` remote points at coder/claudecode.nvim, with pushes disabled. `fork/sync.sh` rebases our commits onto `upstream/main` and then recreates the cleanup commit, which removes Coder's release and agent tooling listed in `fork/cleanup.txt`.

```sh
fork/sync.sh
git push --force-with-lease origin HEAD
```

If the rebase stops on a conflict, resolve it, run `git rebase --continue`, then `fork/sync.sh --continue`.

This README sits in `.github/` so that it never conflicts with upstream's root `README.md`. GitHub shows this one first.

## License

MIT. Copyright (c) 2025 Coder Technologies Inc. and (c) 2026 odiumuniverse. See [LICENSE](https://github.com/odiumuniverse/claudecode.nvim/blob/main/LICENSE).
