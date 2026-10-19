# claudecode.nvim with hunk review and zen mode

A private fork of [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim).

Upstream connects the Claude Code CLI to Neovim over the same WebSocket MCP protocol that Anthropic's VS Code extension uses. Claude opens files, reads your selection and diagnostics, and shows its edits as diffs. This fork keeps all of that and adds two things:

- **Hunk review.** Keep or revert each change Claude makes, the way Cursor does, instead of accepting or rejecting the whole file.
- **Zen mode.** Run Claude full screen inside Neovim and flip to the code with one key.

Claude runs as the unmodified `claude` binary, so you sign in with your own Claude subscription.

## Status

Work in progress. The plan lives in [docs/DESIGN.md](https://github.com/odiumuniverse/claudecode.nvim/blob/main/docs/DESIGN.md) (in Russian).

| Step | What                                                            | State   |
| ---- | --------------------------------------------------------------- | ------- |
| 0    | Repository, upstream sync script, CI                            | done    |
| 1    | Diff provider: plug your own UI into `openDiff`                 | done    |
| 2    | Extmark renderer: hunks, word diff, `ko` / `kx`                 | next    |
| 3    | Review after write: hooks, snapshots, file list, revert summary | planned |
| 4    | Review before write: the renderer as a diff provider            | planned |
| 5    | Zen mode and the `cz` command                                   | planned |

Until step 4 lands, diffs look and behave exactly as upstream.

## Install

With lazy.nvim, from a local clone:

```lua
{
  dir = "~/src/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
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

Commands, keymaps and options match upstream. The [upstream README](https://github.com/coder/claudecode.nvim#readme) describes them.

## Custom diff provider

Set `diff_opts.provider` to take over `openDiff` from the built-in views. Without it, the plugin uses the upstream `vertical`, `horizontal` and `unified` layouts.

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
    },
  },
})
```

`ctx` carries `tab_name`, `old_file_path`, `new_file_path`, `new_file_contents` and `is_new_file`.

How it behaves:

- Claude waits until you call `accept` or `reject`. Only the first call counts.
- `accept` may pass text that differs from Claude's proposal. Claude writes your text, but it only learns that "the user modified your proposed content", not what you changed.
- The plugin calls `close` once per diff: after Claude closes the tab, when the Claude session disconnects, when a new diff reuses the tab name, and when `open` throws (`reason` is `"setup failed"`). Make `close` safe to run on a half-built UI.
- In one test with Claude Code 2.1.303, the written file lost its final newline. We haven't found out why yet.

## Development

```sh
mise install     # Neovim, LuaJIT, formatters and linters
mise run setup   # busted, luacheck and luacov into ./.luarocks
mise run all     # format, lint and test

mise exec -- busted tests/unit/diff_provider_spec.lua   # a single spec
```

## Syncing with upstream

The `upstream` remote points at coder/claudecode.nvim, with pushes disabled. `fork/sync.sh` rebases our commits onto `upstream/main` and then recreates the cleanup commit, which removes Coder's release and agent tooling listed in `fork/cleanup.txt`.

```sh
fork/sync.sh
git push --force-with-lease origin HEAD
```

If the rebase stops on a conflict, resolve it, run `git rebase --continue`, then `fork/sync.sh --continue`.

This README sits in `.github/` so that it never conflicts with upstream's root `README.md`. GitHub shows this one first.

## License

MIT. Copyright (c) 2025 Coder Technologies Inc. and (c) 2026 odiumuniverse. See [LICENSE](https://github.com/odiumuniverse/claudecode.nvim/blob/main/LICENSE).
