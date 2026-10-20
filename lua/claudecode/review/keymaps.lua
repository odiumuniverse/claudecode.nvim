---@brief [[
--- Buffer-local mappings that live as long as a buffer is under review.
--- A mapping the buffer already had on the same keys is put back on `restore`.
---@brief ]]
---@module 'claudecode.review.keymaps'

local M = {}

---@class ClaudeCodeReviewMapping
---@field lhs string
---@field callback fun()
---@field desc string
---@field mode? string "n" by default

---@class ClaudeCodeReviewSavedMaps
---@field set { mode: string, lhs: string }[] Keys mapped by `set`
---@field previous table<string, table> Buffer-local mappings those keys had before, as `maparg` dicts, by mode .. lhs

---@param bufnr integer
---@param mode string
---@param lhs string
---@return table|nil
local function buffer_local_map(bufnr, mode, lhs)
  local map = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg(lhs, mode, false, true)
  end)
  -- maparg also finds global mappings; only a buffer-local one is ours to put back.
  if type(map) == "table" and map.buffer == 1 then
    return map
  end
  return nil
end

---@param bufnr integer
---@param mappings ClaudeCodeReviewMapping[]
---@return ClaudeCodeReviewSavedMaps
function M.set(bufnr, mappings)
  local saved = { set = {}, previous = {} }
  for _, mapping in ipairs(mappings) do
    local mode = mapping.mode or "n"
    saved.previous[mode .. mapping.lhs] = buffer_local_map(bufnr, mode, mapping.lhs)
    vim.keymap.set(mode, mapping.lhs, mapping.callback, { buffer = bufnr, desc = mapping.desc })
    saved.set[#saved.set + 1] = { mode = mode, lhs = mapping.lhs }
  end
  return saved
end

---@param bufnr integer
---@param saved ClaudeCodeReviewSavedMaps
function M.restore(bufnr, saved)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, key in ipairs(saved.set) do
    pcall(vim.keymap.del, key.mode, key.lhs, { buffer = bufnr })
    local previous = saved.previous[key.mode .. key.lhs]
    if previous then
      vim.api.nvim_buf_call(bufnr, function()
        pcall(vim.fn.mapset, key.mode, false, previous)
      end)
    end
  end
end

return M
