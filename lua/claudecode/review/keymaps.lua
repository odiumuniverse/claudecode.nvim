---@brief [[
--- Buffer-local normal-mode mappings that live as long as a buffer is under review.
--- A mapping the buffer already had on the same keys is put back on `restore`.
---@brief ]]
---@module 'claudecode.review.keymaps'

local M = {}

---@class ClaudeCodeReviewMapping
---@field lhs string
---@field callback fun()
---@field desc string

---@class ClaudeCodeReviewSavedMaps
---@field set string[]                 Keys mapped by `set`
---@field previous table<string, table> Buffer-local mappings those keys had before, as `maparg` dicts

---@param bufnr integer
---@param lhs string
---@return table|nil
local function buffer_local_map(bufnr, lhs)
  local map = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg(lhs, "n", false, true)
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
    saved.previous[mapping.lhs] = buffer_local_map(bufnr, mapping.lhs)
    vim.keymap.set("n", mapping.lhs, mapping.callback, { buffer = bufnr, desc = mapping.desc })
    saved.set[#saved.set + 1] = mapping.lhs
  end
  return saved
end

---@param bufnr integer
---@param saved ClaudeCodeReviewSavedMaps
function M.restore(bufnr, saved)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, lhs in ipairs(saved.set) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
    local previous = saved.previous[lhs]
    if previous then
      vim.api.nvim_buf_call(bufnr, function()
        pcall(vim.fn.mapset, "n", false, previous)
      end)
    end
  end
end

return M
