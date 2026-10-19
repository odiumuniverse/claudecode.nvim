---@brief [[
--- The file behind a reviewed buffer: a stamp to notice that someone else wrote it, and a save that
--- does not run the user's format-on-save.
---@brief ]]
---@module 'claudecode.review.disk'

local uv = vim.uv or vim.loop

local M = {}

---@class ClaudeCodeDiskStamp
---@field size integer
---@field sec integer
---@field nsec integer

---Path of the file behind the buffer, or nil for buffers that are not plain files.
---@param bufnr integer
---@return string|nil
function M.path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  return name
end

---@param bufnr integer
---@return ClaudeCodeDiskStamp|nil stamp nil when there is no file (yet)
function M.stamp(bufnr)
  local path = M.path(bufnr)
  local stat = path and uv.fs_stat(path)
  if not stat then
    return nil
  end
  return { size = stat.size, sec = stat.mtime.sec, nsec = stat.mtime.nsec }
end

---@param a ClaudeCodeDiskStamp|nil
---@param b ClaudeCodeDiskStamp|nil
---@return boolean
function M.same(a, b)
  if a == nil or b == nil then
    return a == b
  end
  return a.size == b.size and a.sec == b.sec and a.nsec == b.nsec
end

---Save the buffer without BufWritePre (format-on-save would invent new differences against the
---base), then let the BufWritePost listeners know.
---@param bufnr integer
---@return boolean ok
---@return string|nil err
function M.write(bufnr)
  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("noautocmd silent write")
  end)
  if not ok then
    return false, tostring(err)
  end
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
  return true
end

return M
