---Helpers shared by the specs that run in a real headless Neovim.
local M = {}

---Create a loaded scratch buffer holding `lines`, shown in the current window.
---@param lines string[]
---@return integer bufnr
function M.buffer(lines)
  local bufnr = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

---Write bytes to a path.
---@param path string
---@param data string
function M.write_file(path, data)
  local file = assert(io.open(path, "wb"))
  file:write(data)
  file:close()
end

---@param path string
---@return string
function M.read_file(path)
  local file = assert(io.open(path, "rb"))
  local data = file:read("*a")
  file:close()
  return data
end

---Open a temp file holding `text` in the current window and return its buffer.
---The path is unique per call, so specs may run next to each other.
---@param text string
---@return integer bufnr
---@return string path
function M.file_buffer(text)
  local path = vim.fn.tempname()
  M.write_file(path, text)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf(), path
end

---Run everything that was scheduled so far. Callbacks run in order, so a sentinel that fires
---means the earlier ones are done.
function M.flush()
  local reached = false
  vim.schedule(function()
    reached = true
  end)
  vim.wait(1000, function()
    return reached
  end, 1)
end

---Wipe every buffer a spec left behind, and the extra windows.
function M.reset()
  vim.cmd("silent! only!")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

---Extmarks of the review namespace with details, sorted as Neovim returns them.
---@param bufnr integer
---@return table[] marks `{ id, row, col, details }`
function M.marks(bufnr)
  local ns = vim.api.nvim_create_namespace("claudecode_review")
  local marks = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    marks[#marks + 1] = { id = mark[1], row = mark[2], col = mark[3], details = mark[4] }
  end
  return marks
end

return M
