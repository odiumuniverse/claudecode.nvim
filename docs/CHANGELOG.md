# Changelog

## Unreleased

### Added

- **A list of your notes.** `<leader>an` in Normal mode, or `:ClaudeCodeReviewNotes`, lists every note by file and line before you send them, with the code and the note under it in the preview. Enter opens a note in its box to edit it, and the cursor stays on it after you save; `<A-d>` deletes it, `<C-s>` sends them all. `review.notes.list_keymap` sets the key.
- **Reject with a reason in Manual mode.** `cr` in a proposal reverts the hunk with what you type, and Claude reworks the place in the same turn. With other hunks kept, the reason goes with the note about your reverts. With every hunk reverted, the plugin answers "No, and tell Claude what to do differently" in Claude's own permission dialog in the terminal, since a rejection over the IDE connection carries no text; if the dialog is not there as expected, the proposal is rejected plainly and the reason goes to the clipboard.
- **Hunks and notes in the list of files.** `<leader>ak` shows how many hunks and notes wait in each file, `+12 -3  3 hunks · 1 note`, in columns. A file whose hunks are all decided stays on the list while it has notes and opens at the first one.

### Fixed

- **A note keeps its line after you save and close its file.** The line was written once, when you saved the note, so lines added above it and saved sent the list, `cR` and Claude to the old line once the file was closed. Now it follows the file on disk.
- **`c`, a pause, then `s` no longer starts Flash.** Neovim gave up on `cs` after `'timeoutlen'` (300 ms in LazyVim) and ran the change operator, so `s` started Flash and `r` Remote Flash, under which-key's "+Change" window. In a buffer under review `c` now waits for its next key as long as you like; any key other than ours changes text as always.
- **`]k` and `[k` work in any file.** In a file that is not under review they did nothing, though files waited for review. Now they open the next or previous one, or say that none waits.
- **Bash in a folder of repositories.** When the project folder is not a git repository but holds several, Bash edits in any of them now come up for review. Before, a Bash call that started in such a folder escaped review entirely, and so did one that went `cd ../web` from a neighbor. The plugin snapshots up to 32 repositories one level below the folder, all at once: with 22 that takes about 0.3 s per Bash call.
- **An untracked file Bash rewrote or deleted** comes up for review even when Neovim does not have it open, as a file Claude created and you kept but have not committed yet does when a formatter rewrites it. Before each Bash call the plugin copies untracked files up to 2 MB, 200 files and 20 MB at most; on APFS a copy is a clone.
- **Review no longer fights your git over `index.lock`.** The Bash snapshot took the lock on a tree with uncommitted changes, so a commit you made in lazygit while Claude ran Bash could fail, and the snapshot dropped out when your git held the lock. It now works on a copy of the index.
- Bash snapshots run their git commands at once: in a repository of 6 000 files a Bash call waits about 50 ms for review instead of 140.

## 1.1.0 (2026-10-20)

Review without leaving Neovim and with fewer keystrokes: notes that send Claude back to rework a change, a cursor that moves on by itself, and review keys that no longer slow down `k`.

### Upgrading

- The review keys moved from `ko`, `kx`, `KO` and `KX` to `cs`, `cx`, `cS` and `cX`. To keep the old ones, set `review.keymaps = { keep = "ko", revert = "kx", keep_all = "KO", revert_all = "KX" }`; `k` and `K` then wait for `'timeoutlen'` in buffers under review again.
- After `cs` or `cx` the cursor now moves to the next hunk. `review.advance = false` keeps it where it is.

### Added

- **Notes for Claude.** `cr` on a line, or `<leader>an` on a selection, opens a box right under it; the code below moves down instead of hiding. Enter saves the note, which shows as one gray line under the code and survives a restart; the cursor moves on to the next hunk. Shift+Enter in the box, `<C-s>`, or `cR` anywhere send every note from every file to Claude in one message, typed into the Claude terminal in Neovim. `review.notes.send = "enter"` sends each note on Enter; `review.notes.advance = false` keeps the cursor still. The statusline counts the notes not sent yet.
- **Review moves on by itself.** After `cs` or `cx` the cursor goes to the next hunk, and from the last one back to the first (`review.advance = "hunk"`). With `advance = "file"` the next file waiting for review opens once a file is done, by its last hunk or by `cS` or `cX`; `false` keeps the cursor where it is.
- **`]k` and `[k` cross files.** Past the last hunk `]k` opens the next file waiting for review at its first hunk, and `[k` before the first one opens the previous file at its last hunk. The list wraps around. `review.cross_files = false` keeps them inside the file.
- **Progress at a glance.** The hint at a hunk starts with its number in the file, `2/5  cs keep · cx revert`. The statusline shows how many files wait, `review: 4 files`, and nothing once they are done: the LazyVim spec adds it to lualine, and `require("claudecode.review.controller").status()` gives it to any statusline. Zen's counter says the same, on the right and in a calmer color.

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
