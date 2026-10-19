---@brief [[
--- Receiving end of the hook notifications (see claudecode.hooks.notify). The hook process
--- calls `on_hook` through nvim_exec_lua; the work waits for a safe point in the main loop.
---@brief ]]
---@module 'claudecode.review.bridge'

local M = {}

M.enabled = false

---@param payload table
function M.on_hook(payload)
  if not M.enabled or type(payload) ~= "table" then
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
