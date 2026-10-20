---@brief [[
--- Health sections for hunk review hooks and zen. `:checkhealth claudecode` appends them to its
--- report (see lua/claudecode/health.lua); the file is not called health.lua, so `:checkhealth`
--- does not list it as a plugin of its own.
---@brief ]]
---@module 'claudecode.features.checks'

local M = {}

function M.check()
  local health = vim.health
  local features = require("claudecode.features")

  health.start("Neovim for review and zen")
  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim 0.11 or newer")
  else
    -- A warning: the IDE connection works without the features, so this is no error of the plugin.
    health.warn("Hunk review and zen need Neovim 0.11 or newer; the plugin falls back to upstream behavior")
    return
  end

  local config = features.state.config
  if not config then
    health.warn("require('claudecode').setup() has not run yet")
    return
  end

  health.start("Hunk review")
  if not config.review.enabled then
    health.info("Disabled (review.enabled = false)")
  else
    local hooks = require("claudecode.hooks")
    if hooks.is_active() then
      health.ok("Hooks are attached to Claude sessions started from Neovim")
    else
      health.warn("Hooks are not active: Claude edits will not show up for review")
    end

    local settings = hooks.settings_file()
    if vim.uv.fs_stat(settings) then
      health.ok("Hook settings: " .. settings)
    else
      health.info("Hook settings are written when Claude starts: " .. settings)
    end

    if vim.fn.executable("git") == 1 then
      health.ok("git found: edits made by Bash are reviewed in git repositories")
    else
      health.warn("git not found: edits made by Bash are not reviewed")
    end

    if vim.v.servername ~= "" then
      health.ok("Neovim server address: " .. vim.v.servername)
    else
      health.info("Neovim server starts with the first Claude session")
    end

    local controller = require("claudecode.review.controller")
    local store = controller.store()
    if store then
      local stat = vim.uv.fs_stat(store.dir)
      if stat and bit.band(stat.mode, 63) ~= 0 then -- 0077: group or other bits
        health.warn("State directory is readable by other users: " .. store.dir)
      end
      health.info(string.format("%d file(s) wait for review; state in %s", #controller.pending(), store.dir))
      local log = io.open(store.dir .. "/hooks.log", "r")
      if log then
        local lines = {}
        for line in log:lines() do
          lines[#lines + 1] = line
        end
        log:close()
        if #lines > 0 then
          health.warn("Recent hook errors:\n" .. table.concat(vim.list_slice(lines, math.max(1, #lines - 4)), "\n"))
        end
      end
    end

    health.info("File list uses " .. require("claudecode.review.picker").backend(config.review.picker))
  end

  health.start("Zen")
  if not config.zen.enabled then
    health.info("Disabled (zen.enabled = false)")
  else
    local provider = require("claudecode.config").defaults.terminal.provider
    local ok_cfg, main = pcall(require, "claudecode")
    if ok_cfg and main.state and main.state.config and main.state.config.terminal then
      provider = main.state.config.terminal.provider or provider
    end
    if provider == "external" or provider == "none" then
      health.warn("Zen needs Claude inside Neovim; terminal.provider is '" .. tostring(provider) .. "'")
    else
      health.ok("Toggle with " .. tostring(config.zen.keymap) .. " or :ClaudeCodeZen")
    end
  end

  health.start("Accounts (cswap)")
  if vim.fn.executable(config.cswap.cmd) == 1 then
    health.ok(":ClaudeCode run [account] runs Claude through " .. config.cswap.cmd)
  else
    -- cswap is optional: without it only `:ClaudeCode run` is missing.
    health.info(config.cswap.cmd .. " not found: :ClaudeCode run needs it")
  end
end

return M
