# claudecode.nvim

The plugin connects the Claude Code CLI to Neovim over the same WebSocket MCP protocol that Anthropic's VS Code extension uses. Claude opens files, reads your selection and diagnostics, and shows its edits as diffs. Two features come on top:

- **Hunk review.** Keep or revert each change Claude makes, the way Cursor does, instead of accepting or rejecting the whole file.
- **Zen mode.** Run Claude full screen inside Neovim and flip to the code with one key.

Claude runs as the unmodified `claude` binary, so you sign in with your own Claude subscription.

Based on [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim) (upstream).

More documentation:

- [docs/DESIGN.md](https://github.com/odiumuniverse/claudecode.nvim/blob/main/docs/DESIGN.md): the design and the reasons behind it;
- [docs/ARCHITECTURE.md](https://github.com/odiumuniverse/claudecode.nvim/blob/main/docs/ARCHITECTURE.md) and [docs/PROTOCOL.md](https://github.com/odiumuniverse/claudecode.nvim/blob/main/docs/PROTOCOL.md): upstream's architecture and the IDE protocol;
- [CONTRIBUTING.md](https://github.com/odiumuniverse/claudecode.nvim/blob/main/CONTRIBUTING.md): upstream's development guide.

## Requirements

- Neovim 0.11 or newer. On older versions the plugin behaves exactly as upstream.
- Claude started from Neovim (`:ClaudeCode`, zen or `cz`). The review hooks ride on that launch.
- `git` for reviewing edits Claude makes through Bash.

## Install

With LazyVim, link the ready spec instead of the `ai.claudecode` extra. It keeps the extra's keys, moves Toggle Claude from `<leader>ac` to `<leader>at`, and adds `<leader>ak` and `<M-z>`:

```sh
ln -s ~/src/claudecode.nvim/lazyvim/claudecode.lua ~/.config/nvim/lua/plugins/claudecode.lua
```

The spec loads the plugin on `VeryLazy`, not on a key: a file Claude edited before a restart comes back under review only if the plugin is running when you open it.

With plain lazy.nvim, from a local clone:

```lua
{
  dir = "~/src/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  cmd = { "ClaudeCode", "ClaudeCodeZen", "ClaudeCodeReview" },
  keys = {
    { "<leader>at", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>ak", "<cmd>ClaudeCodeReview<cr>", desc = "Files waiting for review" },
    { "<M-z>", "<cmd>ClaudeCodeZen<cr>", desc = "Claude zen" },
  },
  opts = {},
}
```

Or from GitHub over SSH, since the repository is private:

```lua
{
  "odiumuniverse/claudecode.nvim",
  url = "git@github.com:odiumuniverse/claudecode.nvim.git",
  dependencies = { "folke/snacks.nvim" },
  opts = {},
}
```

Upstream's commands, keymaps and options all work as before; the [upstream README](https://github.com/coder/claudecode.nvim#readme) describes them. Run `:checkhealth claudecode` to check the IDE connection, the review hooks and zen.

`:help claudecode` documents the options, keys and events of review and zen.

## Hunk review

Claude edits your files right away, the way it does in the terminal. The plugin then shows what changed on top of the code:

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

**Claude learns what you reverted.** Claude Code itself never tells the model that you rejected part of an edit. The plugin adds a short note to Claude's context instead: right after Claude's next file edit or Bash call, or with your next message. The note names the file and line, shows Claude's text and the text that came back, and asks Claude not to reapply the change unless you ask.

**Your own edits stay yours.** Edit the buffer outside a hunk and the change simply becomes part of the file. Edit inside a hunk and you change Claude's proposal; the hunk still waits for `ko` or `kx`. After `kx`, `u` brings Claude's text back as your own edit.

**Review survives restarts.** The text of each file before Claude's first edit lives in `stdpath("state")/claudecode/review/`, in a directory only you can read. Hunks pile up across Claude's turns until you decide on them. The state belongs to the git repository around Neovim's working directory (or to the directory itself outside git), so start Neovim anywhere in the same repository to get your reviews back.

### What gets reviewed

- `Edit`, `Write`, `MultiEdit` and `NotebookEdit`: always.
- `Bash` in a git repository: every file it changed, created or deleted. The plugin snapshots the work tree before the call with `git stash create`, which does not touch your stash list. Files that git checks out with CRLF endings (`eol=crlf`, `core.autocrlf`) keep them through review and `kx`.
- An untracked file Bash rewrote: only when the file is open in Neovim, because its old text exists nowhere else.
- Not reviewed: binary files, files over 2 MB, new files Bash creates in paths that `.gitignore` covers, edits outside a Claude tool call (yours, `git pull`, other programs), and Bash edits outside git repositories.
- If you refuse an edit and then create or change that file yourself, review treats the file as yours.

### How it works

Every Claude session started from Neovim gets `claude --settings <file>` with three hooks: `PreToolUse`, `PostToolUse` and `UserPromptSubmit`. Claude Code adds these to the hooks you already have; it does not replace them. Each hook is a short `nvim --clean -l` script. It copies the file before the edit and sends Neovim a notification without waiting for an answer. A hook never blocks Claude: on any error it logs to `hooks.log` and exits with 0, so at worst one edit escapes review.

If you start Claude yourself (`terminal.provider = "none"`), the hooks are not attached and review after write stays off. Review before write still works: it needs only the IDE connection.

## Review before write

In Manual mode Claude asks before each edit. The plugin opens the proposal in place of the file, with the same hunks and keys. When no hunk is left, the text you kept goes to Claude; if you reverted every hunk, Claude gets a rejection. `:w` in the proposal accepts what is left as it is. `:ClaudeCodeDiffAccept` and `:ClaudeCodeDiffDeny` work too.

Claude sends UTF-8. The plugin compares it with the file in the file's own encoding, so a Latin-1 or UTF-16 file shows only what Claude changed. It reads the encoding from the open buffer, or else from the byte order mark and `'fileencodings'`. The protocol carries text only, so Claude writes UTF-8 after you accept: a Latin-1 or UTF-16 file becomes UTF-8. A byte order mark stays.

If your Claude settings allow `Edit` without asking (`permissions.allow`), Claude never asks about edits and this mode only shows up for `Write`. Review after write covers the rest.

Set `review.before_write = false` to keep upstream's diff views, or set your own `diff_opts.provider` (see below).

## Zen mode

`<M-z>` puts Claude full screen in a tab of its own and brings you back to the code, with Claude in its split. It works in normal mode and inside the Claude terminal; other terminals still get the key. Above Claude, zen shows how many files wait for review. When Claude asks to approve an edit in Manual mode, zen steps aside for the proposal and comes back once you have decided. Leaving zen returns you to the tab you entered from. If you switch to another tab while zen is open, the key brings you back into zen instead of opening a second one.

`:ClaudeCodeZen` does the same. Its arguments go to `claude` when zen has to start it, as in `:ClaudeCodeZen --resume`; they do nothing while Claude runs.

`bin/cz` opens Neovim straight into zen:

```sh
ln -s ~/src/claudecode.nvim/bin/cz ~/.local/bin/cz
cz            # new session
cz --resume   # pick a session to resume
```

Zen needs Claude inside Neovim (`terminal.provider` set to `snacks`, `native` or `auto`).

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
}
```

Highlight groups, all defined with `default = true` so your colorscheme applies: `ClaudeCodeReviewAdd`, `ClaudeCodeReviewAddText`, `ClaudeCodeReviewDelete`, `ClaudeCodeReviewDeleteText`, `ClaudeCodeReviewHint`, `ClaudeCodeZenPending`.

`User` events for your config:

- `ClaudeCodeReviewChanged`, `data = { bufnr, path, hunks }`: a buffer's hunks changed; `hunks` is how many are left.
- `ClaudeCodeReviewPending`, `data = { count, files }`: the list of files waiting for review changed.
- `ClaudeCodeDiffOpened` and `ClaudeCodeDiffClosed` now also fire for proposals. The opened event has `layout = "provider"` and none of the window fields of upstream's diffs.

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

`ctx` carries `tab_name`, `old_file_path`, `new_file_path`, `new_file_contents` and `is_new_file`.

How it behaves:

- Claude waits until you call `accept` or `reject`. Only the first call counts. `:ClaudeCodeDiffDeny` calls `reject_command`. Claude gets a rejection when the handler returns, even if the handler never called `reject`.
- `accept` may pass text that differs from Claude's proposal. Claude writes your text, but it only learns that "the user modified your proposed content", not what you changed.
- The plugin calls `close` once per diff: after Claude closes the tab, when the Claude session disconnects, when a new diff reuses the tab name, and when `open` throws (`reason` is `"setup failed"`). Make `close` safe to run on a half-built UI.
- A provider gets the diff even when the file's buffer has unsaved edits; the built-in views refuse it.
- Claude Code (checked on 2.1.303 and 2.1.304) drops one trailing newline from the text it gets back. `accept` adds one before answering, so the file ends up with exactly your text. Upstream's own diff views lose the final newline this way.

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
