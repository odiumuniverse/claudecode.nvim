---@brief [[
--- File bytes ↔ buffer lines. Bases are stored as the bytes on disk, the engine works on lines.
---@brief ]]
---@module 'claudecode.review.text'

local M = {}

---@param text string File bytes
---@param dos boolean|nil Strip the "\r" of CRLF endings, as a fileformat=dos buffer does
---@return string[] lines
---@return boolean eol The text ends with a newline
function M.to_lines(text, dos)
  if text == "" then
    return {}, false
  end
  local lines = vim.split(text, "\n", { plain = true })
  local eol = lines[#lines] == ""
  if eol then
    lines[#lines] = nil
  end
  if dos then
    for i, line in ipairs(lines) do
      lines[i] = line:gsub("\r$", "")
    end
  end
  return lines, eol
end

---@param lines string[]
---@param eol boolean
---@param dos boolean|nil
---@return string
function M.to_text(lines, eol, dos)
  if #lines == 0 then
    return ""
  end
  local nl = dos and "\r\n" or "\n"
  return table.concat(lines, nl) .. (eol and nl or "")
end

---The bytes `:write` would put on disk for this buffer.
---@param bufnr integer
---@return string
function M.buffer_text(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    -- An emptied buffer and a file holding one empty line look alike; only the first
    -- writes zero bytes. wordcount() counts what :write would put on disk.
    local empty = vim.api.nvim_buf_call(bufnr, function()
      return vim.fn.wordcount().bytes == 0
    end)
    if empty or not (vim.bo[bufnr].eol or vim.bo[bufnr].fixeol) then
      return ""
    end
  end
  local eol = vim.bo[bufnr].eol or vim.bo[bufnr].fixeol
  return M.to_text(lines, eol, vim.bo[bufnr].fileformat == "dos")
end

return M
