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

local BOM = "\239\187\191"

---The bytes of the file as the buffer holds them: in UTF-8, without the byte order mark. A base is
---kept in the bytes of the file, and a buffer made of those bytes would never match.
---@param bytes string
---@param bufnr integer
---@return string
function M.decode(bytes, bufnr)
  local fenc = vim.bo[bufnr].fileencoding
  if fenc ~= "" and fenc ~= "utf-8" and bytes ~= "" then
    local converted = vim.iconv(bytes, fenc, "utf-8")
    -- iconv answers with "" when it cannot convert: keep the bytes then, as before.
    if converted ~= "" then
      bytes = converted
    end
  end
  if vim.bo[bufnr].bomb and bytes:sub(1, #BOM) == BOM then
    bytes = bytes:sub(#BOM + 1)
  end
  return bytes
end

---The other way round: text of the buffer to the bytes `:write` puts in the file.
---@param str string
---@param bufnr integer
---@return string
function M.encode(str, bufnr)
  if str == "" then
    return str
  end
  local fenc = vim.bo[bufnr].fileencoding
  if vim.bo[bufnr].bomb then
    str = BOM .. str
  end
  if fenc ~= "" and fenc ~= "utf-8" then
    local converted = vim.iconv(str, "utf-8", fenc)
    if converted ~= "" then
      str = converted
    end
  end
  return str
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
