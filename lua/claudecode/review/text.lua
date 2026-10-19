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

---The byte order mark as UTF-8 text, which is what a converted mark becomes.
M.BOM = "\239\187\191"
local BOM = M.BOM

---The marks `ucs-bom` in 'fileencodings' looks for. The four-byte ones come first: they start like UTF-16.
local BOMS = {
  { "\255\254\0\0", "utf-32le" },
  { "\0\0\254\255", "utf-32be" },
  { "\239\187\191", "utf-8" },
  { "\255\254", "utf-16le" },
  { "\254\255", "utf-16be" },
}

---@param bytes string
---@return boolean
local function is_utf8(bytes)
  local i = bytes:find("[\128-\255]")
  while i do
    local lead = bytes:byte(i)
    local len = (lead >= 0xC2 and lead <= 0xDF and 2)
      or (lead >= 0xE0 and lead <= 0xEF and 3)
      or (lead >= 0xF0 and lead <= 0xF4 and 4)
    if not len then
      return false
    end
    for k = 1, len - 1 do
      local b = bytes:byte(i + k)
      if not b or b < 0x80 or b > 0xBF then
        return false
      end
    end
    -- overlong forms, surrogates and what lies past U+10FFFF
    local second = bytes:byte(i + 1)
    if (lead == 0xE0 and second < 0xA0) or (lead == 0xED and second > 0x9F) then
      return false
    end
    if (lead == 0xF0 and second < 0x90) or (lead == 0xF4 and second > 0x8F) then
      return false
    end
    i = bytes:find("[\128-\255]", i + len)
  end
  return true
end

---The encoding of a file that no buffer holds, and whether it starts with a byte order mark: found as
---`:edit` would find it, by the mark and then by trying 'fileencodings' in order.
---@param bytes string File bytes
---@return string encoding
---@return boolean bomb
function M.detect(bytes)
  for entry in vim.gsplit(vim.o.fileencodings, ",", { plain = true }) do
    entry = entry:lower()
    if entry == "ucs-bom" then
      for _, bom in ipairs(BOMS) do
        if bytes:sub(1, #bom[1]) == bom[1] then
          return bom[2], true
        end
      end
    elseif entry == "utf-8" or entry == "utf8" then
      if is_utf8(bytes) then
        return "utf-8", false
      end
    elseif entry ~= "default" and entry ~= "" then
      local converted = vim.iconv(bytes, entry, "utf-8")
      if converted ~= nil and (converted ~= "" or bytes == "") then
        return entry, false
      end
    end
  end
  return "utf-8", false
end

---Bytes of a file in `fenc`, with or without a byte order mark, as UTF-8 text without the mark. A base
---is kept in the bytes of the file, and a buffer made of those bytes would never match.
---@param bytes string
---@param fenc string 'fileencoding'; "" is UTF-8
---@param bomb boolean 'bomb'
---@return string
function M.decode_as(bytes, fenc, bomb)
  if fenc ~= "" and fenc ~= "utf-8" and bytes ~= "" then
    local converted = vim.iconv(bytes, fenc, "utf-8")
    -- iconv answers with "" (or nothing) when it cannot convert: keep the bytes then.
    if converted ~= nil and converted ~= "" then
      bytes = converted
    end
  end
  if bomb and bytes:sub(1, #BOM) == BOM then
    bytes = bytes:sub(#BOM + 1)
  end
  return bytes
end

---The bytes of the file as the buffer holds them.
---@param bytes string
---@param bufnr integer
---@return string
function M.decode(bytes, bufnr)
  return M.decode_as(bytes, vim.bo[bufnr].fileencoding, vim.bo[bufnr].bomb)
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
