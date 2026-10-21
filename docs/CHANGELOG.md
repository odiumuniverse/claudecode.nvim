# Changelog

## Unreleased

Review that keeps up with git and with worktrees, Neovim that follows Claude into a worktree, and a list of files that shows what matters first.

### Upgrading

- A file under review now follows git's HEAD: once you commit it, it leaves the list as after `cs`, and after a partial commit only the hunks you did not commit wait. Bases made by an earlier version are taken to match HEAD as it is when this one first sees them.
- When Claude works in a worktree, Neovim changes its directory there and shows the worktree's copies of the files you look at, and goes back once Claude leaves. `worktree.follow = false` turns this off.
- The list of files puts the path last: `+12 -3  3 hunks · 1 note  14:58  lua/cart.lua`. "(new)" after the path became "new file" in the column of what waits.
- The hint names the note key: `2/5  cs keep · cx revert · cr note`. With `review.hint = true` and notes off it stays as it was.
- In snacks.picker the lists of files and notes sit over their preview, both full width. A layout you set for the sources `claudecode_review` and `claudecode_review_notes` in snacks.picker wins.

### Added

- **Neovim follows Claude into a worktree.** Once a Claude session started from Neovim works in a linked worktree (EnterWorktree, `claude --worktree`), Neovim runs `:cd` there, and each window that shows a file of the main checkout shows the worktree's copy, at the same line. A buffer with unsaved edits stays, and so do a file the worktree does not have and a file of another worktree. When Claude leaves the worktree, or its terminal closes, Neovim goes back, and so do the windows it moved, unless you changed the directory yourself meanwhile. The review hooks now run after EnterWorktree and ExitWorktree too.
- **Several files at once in the list.** In snacks.picker and fzf-lua `<Tab>` picks files, and `<A-o>` keeps and `<A-x>` reverts each of them; reverting more than one file asks first. The snacks list names its keys at the bottom.
- **When a file came under review, and where.** Each line of the list shows the time the file came under review today, or the date before that, and, when the files lie in more than one work tree, the branch of each. "deleted" marks a file Claude removed. The highlight group is `ClaudeCodeReviewMeta`.

### Fixed

- **Files you committed stayed on the list for good.** A base moved only along Claude's own Bash calls, so after your commit, branch switch, rebase or pull it kept the text from before Claude's edit, and the list showed the whole difference between that and the file now: in one project 66 files of a finished task, one of them `+5714`. Now a base moves along any change of HEAD, the way it moves along Claude's checkout, and Neovim reads HEAD from the git directory, running git only once it moved. The files of a removed worktree leave the list as well.
- **Bash in a worktree outside the project escaped review.** Claude Code puts its shell back into the project after a `cd` that leaves it, so `cd ~/project-worktrees/api-feat && make generate` ran with the hooks standing in the project, and the snapshot never saw the worktree. Now every Bash call also snapshots the worktrees of the project's repositories, those the command names first.
- **A worktree inside the repository came up as a file.** `git ls-files --others` names `.claude/worktrees/x/` as a directory, and the hook took a base for it. Now the hook leaves such directories out and snapshots the worktree as one of its own.
- **The counts fell off the list.** A long path came first and pushed `-12  3 hunks · 1 note` past the edge of snacks.picker's list, leaving `+461 -`. Now the counts come first, and the path last shortens to the room left: the directory gives way first, from the left and at a slash, then the file name, from the left, so its end and extension stay. snacks.picker's own shortening kept a long name whole and lost its end at the edge.
- **A message to Neovim at a hit-enter prompt was lost.** Neovim at "Press ENTER" runs no message until you leave the prompt, and the hook hung up after half a second, which dropped it: the buffers Claude changed did not reload, and Neovim did not follow Claude into a worktree. Now the hook hands its connection to a small `head -c 1` process that holds it until Neovim answers, and goes on at once as before.
- **A proposal with nothing to review was rejected.** In Manual mode a proposal with no hunk, the same text or one that changes only the final newline, came back rejected, and Claude stopped its turn for a change you never saw. Now it goes back accepted at once.
- **Reverting a deleted file whose folder is gone** raised a Lua error from the list. Now the folder comes back with the file.
- **The list found a buffer by a pattern.** `bufnr()` takes a name for a pattern, so `app/[id]/page.tsx` could stand for another buffer; now the list finds a buffer by its resolved path, as the rest of the review does.

## 1.2.0 (2026-10-21)

Notes you can read over before they go and that go as a diff, review that keeps up with git and with folders of repositories, Claude's notifications in Neovim, and fewer upstream commands that did nothing in this flow.

### Upgrading

- Ten upstream commands are gone (see Removed). A mapping of your own to one of them now fails with "Not an editor command"; the list below names what to use instead.
- In a buffer under review `c` now waits for its next key without `'timeoutlen'`. A key that is not one of the review keys changes text as before: `cw`, `ciw`, `cc`, `2cw`, `"acw`.
- Shift+Enter in Normal mode, in a file under review or with a note, sends your notes; where no note waits it is Enter. `review.notes.local_send_keymap = false` turns this off.
- Claude started from Neovim no longer sends its own desktop notification or bell: its notifications come as `vim.notify`. The plugin's settings file sets `preferredNotifChannel = "notifications_disabled"` for that Claude only; Claude outside Neovim keeps yours.
- The highlight group `ClaudeCodeReviewNoteSign` is now `ClaudeCodeReviewNoteBorder`, and the lists use `ClaudeCodeReviewAdded` and `ClaudeCodeReviewRemoved`.

### Removed

- **Upstream commands the review replaces, or whose work the plugin does on its own.** In a proposal `cS` takes it all, `cX` refuses it and `:w` answers with what is there, instead of `:ClaudeCodeDiffAccept`, `:ClaudeCodeDiffDeny` and `:ClaudeCodeCloseAllDiffs`. `:ClaudeCode` toggles instead of `:ClaudeCodeOpen` and `:ClaudeCodeClose`. The server starts with the plugin and `:checkhealth claudecode` shows its state, instead of `:ClaudeCodeStart`, `:ClaudeCodeStop` and `:ClaudeCodeStatus`. `:ClaudeCode --model` or Claude's `/model` picks the model instead of `:ClaudeCodeSelectModel`, and notes send text instead of `:ClaudeCodeSendText`. The LazyVim spec drops `<leader>aa` and `<leader>ad`, and `diff_opts.provider` loses `accept_command`.

### Added

- **Shift+Enter sends your notes from the file, not only from the box.** In Normal mode, in a file under review or with a note, Shift+Enter sends every note, as `cR` does; where no note waits it is Enter, and in neo-tree, quickfix and other lists it stays theirs. `review.notes.local_send_keymap` sets the key.
- **A list of your notes.** `<leader>an` in Normal mode, or `:ClaudeCodeReviewNotes`, lists every note by file and line before you send them, with the code and the note under it in the preview. Enter opens a note in its box to edit it, and the cursor stays on it after you save; `<A-d>` deletes it, `<C-s>` sends them all. `review.notes.list_keymap` sets the key.
- **Reject with a reason in Manual mode.** `cr` in a proposal reverts the hunk with what you type, and Claude reworks the place in the same turn. With other hunks kept, the reason goes with the note about your reverts. With every hunk reverted, the plugin answers "No, and tell Claude what to do differently" in Claude's own permission dialog in the terminal, since a rejection over the IDE connection carries no text; if the dialog is not there as expected, the proposal is rejected plainly and the reason goes to the clipboard.
- **Hunks and notes in the list of files.** `<leader>ak` shows how many hunks and notes wait in each file, `+12 -3  3 hunks · 1 note`, in columns. A file whose hunks are all decided stays on the list while it has notes and opens at the first one.

### Changed

- **Claude sees the code of a note as a diff.** The message marks what Claude removed with `-`, above the line it was removed at, and what it added with `+`, in a `diff` block, so Claude's terminal shows the lines as they are and not as a Markdown list. It used to send only the lines there now, so a note under a deleted comment never told Claude which comment it meant.
- **Green and red in the lists.** `+12` is green and `-3` red in `<leader>ak`, in snacks.picker and fzf-lua alike. `<leader>an` shows the same for the hunk under each note, and its preview shows the hunks as the review does. The highlight groups are `ClaudeCodeReviewAdded` and `ClaudeCodeReviewRemoved`.
- **A saved note stays where you typed it.** It used to turn into one gray line, `▎ note: …`, cut at the window's edge, and the box you had typed in was gone. Now the box stays, dimmed and without the key hints, up to its ten lines, and fits the window again when a split narrows it. The highlight group `ClaudeCodeReviewNoteSign` gave way to `ClaudeCodeReviewNoteBorder`.

### Fixed

- **A change thrown away outside review leaves no notes behind.** After `git checkout` or a discard in lazygit the file left the list only at the next hook, and its notes stayed in both lists and the statusline. Now the notes of a file go once Claude's change there is gone, and the lists look at the disk again when a terminal such as lazygit's closes, when Neovim gets the focus back and after a `:!` command. After `cs` the notes stay, as before.
- **A note keeps its line after you save and close its file.** The line was written once, when you saved the note, so lines added above it and saved sent the list, `cR` and Claude to the old line once the file was closed. Now it follows the file on disk.
- **`c`, a pause, then `s` no longer starts Flash.** Neovim gave up on `cs` after `'timeoutlen'` (300 ms in LazyVim) and ran the change operator, so `s` started Flash and `r` Remote Flash, under which-key's "+Change" window. In a buffer under review `c` now waits for its next key as long as you like; any key other than ours changes text as always.
- **No escape-sequence garbage over Claude's prompt, and Claude's notifications in Neovim.** Under some multiplexers or Kitty, Claude Code sent its "waiting for your input" notification as Kitty's OSC 99, and the outer terminal printed it as text such as `99;i=3352:d=1:a=focus;`. Claude started from Neovim now sends nothing to the terminal (`preferredNotifChannel = "notifications_disabled"` in its settings file); a `Notification` hook shows "Claude is waiting for your input" and "Claude needs your permission" with `vim.notify` instead, except while the cursor is in Claude's terminal.
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
