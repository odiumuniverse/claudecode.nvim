---@brief [[
--- Receiving end of the hook notifications (see claudecode.hooks.notify). The hook process
--- calls `on_hook` through nvim_exec_lua; the work waits for a safe point in the main loop.
---@brief ]]
---@module 'claudecode.review.bridge'

local M = {}

M.enabled = false

---Claude's own notification ("Claude is waiting for your input"), which the hooks' settings turn off
---in the terminal. Not while you look at Claude: there it is noise.
---@param payload { message: string|nil }
local function show(payload)
  if type(payload.message) ~= "string" or payload.message == "" then
    return
  end
  local claude = require("claudecode.terminal").get_active_terminal_bufnr()
  if claude and vim.api.nvim_get_current_buf() == claude then
    return
  end
  vim.notify(payload.message, vim.log.levels.INFO, { title = "Claude" })
end

---@param payload table
function M.on_hook(payload)
  if not M.enabled or type(payload) ~= "table" then
    return
  end
  if payload.event == "Notification" then
    vim.schedule(function()
      show(payload)
    end)
    return
  end
  vim.schedule(function()
    local ok, err = pcall(require("claudecode.review.controller").on_hook, payload)
    if not ok then
      require("claudecode.logger").error("review", "Hook notification failed:", err)
    end
  end)
end

return M
