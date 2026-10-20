# Changelog

## Unreleased

### Changed

- **Review keys are `cs` and `cx` now,** `cS` and `cX` for the whole file. `ko` and `kx` made every `k` in a buffer under review wait for `'timeoutlen'` before the cursor moved, and `KO` and `KX` did the same to `K` (LSP hover). Neovim waits for a motion after `c` anyway, so the new keys delay nothing. Your own `review.keymaps` still win.

### Fixed

- **A branch switch no longer floods review.** When Claude ran `git switch`, `pull`, `rebase` or `reset`, every file git checked out came up as Claude's edit, compared with the old branch. Now only Claude's own edits on top of the new HEAD, and your uncommitted work the command threw away, come up for review.

## 1.0.0 (2026-10-20)

The first release of claudecode.nvim as a product of its own. It is built on [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim) at `2390c6e` (2026-06-25); upstream's IDE connection, commands, keymaps and options work as before.

### Added

- **Hunk review.** Claude's edits show up as hunks on top of the code: deleted lines in red above the change, added lines in green, changed words highlighted, and a hint at the hunk under the cursor. `ko` keeps a hunk, `kx` reverts it and writes the file, `KO` and `KX` act on the whole file, `]k` and `[k` move between hunks. `<leader>ak` (`:ClaudeCodeReview`) lists the files waiting for review.
- Review covers Edit, Write, MultiEdit and NotebookEdit, and every file Bash changes, creates or deletes in a git repository. It survives a restart of Neovim.
- **Claude learns what you reverted.** A short note goes into Claude's context with its next tool call or your next message. Each Claude session hears only of the reverts of its own edits.
- **Review before write.** In Manual mode Claude's proposal opens in place of the file, with the same hunks and keys, and Claude writes only what you kept.
- **Modes follow Claude's permission mode.** Manual reviews before write, auto and bypass after write, accept edits and plan without review. `<leader>am` in the LazyVim spec starts Claude in Manual mode.
- **Zen mode.** `<M-z>` (`:ClaudeCodeZen`) runs Claude full screen in a tab of its own and brings you back to the code; `bin/cz` opens Neovim straight into zen.
- **Accounts.** `:ClaudeCode run [account]` runs Claude as a [cswap](https://github.com/realiti4/claude-swap) account and keeps it for later launches.
- `diff_opts.provider`, a seam for a diff UI of your own.
- `:help claudecode`, sections in `:checkhealth claudecode` for review, zen and cswap, and a LazyVim spec in `lazyvim/claudecode.lua`.

### Requirements

- Neovim 0.11 or newer. On older versions the plugin behaves as upstream.
- Claude started from Neovim, for review after write and the modes. Checked with Claude Code 2.1.304.
- `git`, to review edits made through Bash; cswap only for `:ClaudeCode run`.
