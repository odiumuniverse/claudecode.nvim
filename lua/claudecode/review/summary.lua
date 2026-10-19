---@brief [[
--- Text that tells Claude which of its changes you reverted. The hook passes it as
--- additionalContext, because Claude Code itself only says "the user modified the file".
---@brief ]]
---@module 'claudecode.review.summary'

local M = {}

-- Claude Code moves additionalContext over 10,000 characters into a file; stay well below.
M.MAX_CHARS = 8000
M.MAX_BLOCK_LINES = 20

local HEADER = table.concat({
  "The user reviewed your edits in Neovim and reverted some of them.",
  "The files on disk already contain the restored text. Do not reapply these changes unless the user asks.",
}, "\n")

local function relative(path, root)
  if root and root ~= "" then
    local prefix = root:sub(-1) == "/" and root or root .. "/"
    if path:sub(1, #prefix) == prefix then
      return path:sub(#prefix + 1)
    end
  end
  return path
end

local function add_lines(out, label, lines, empty_note)
  if #lines == 0 then
    out[#out + 1] = "  " .. label .. ": " .. empty_note
    return
  end
  out[#out + 1] = "  " .. label .. ":"
  for i = 1, math.min(#lines, M.MAX_BLOCK_LINES) do
    out[#out + 1] = "    | " .. lines[i]
  end
  if #lines > M.MAX_BLOCK_LINES then
    out[#out + 1] = string.format("    | … %d more lines", #lines - M.MAX_BLOCK_LINES)
  end
end

local function block(rec, root)
  local out = { string.format("%s, line %d", relative(rec.path, root), rec.line or 1) }
  add_lines(out, "your text, reverted", rec.claude_lines or {}, "none, you had deleted these lines")
  add_lines(out, "restored text", rec.base_lines or {}, "none, your lines were removed")
  return table.concat(out, "\n")
end

---@param records ClaudeCodeRevertRecord[] In the order you reverted them
---@param root string|nil Project root; paths under it are shown relative
---@return string|nil text Nil when there is nothing to report
function M.render(records, root)
  if #records == 0 then
    return nil
  end
  local parts = { HEADER }
  local size = #HEADER
  for i, rec in ipairs(records) do
    local text = block(rec, root)
    -- Reserve room for the closing line that names the files left out.
    if size + #text + 2 > M.MAX_CHARS - 600 then
      local seen, rest = {}, {}
      for j = i, #records do
        local name = relative(records[j].path, root)
        if not seen[name] then
          seen[name] = true
          rest[#rest + 1] = name
        end
      end
      local tail = string.format("…and %d more reverted changes in: %s", #records - i + 1, table.concat(rest, ", "))
      if size + #tail + 2 > M.MAX_CHARS then
        tail = tail:sub(1, M.MAX_CHARS - size - 2)
      end
      parts[#parts + 1] = tail
      break
    end
    parts[#parts + 1] = text
    size = size + #text + 2
  end
  return table.concat(parts, "\n\n")
end

return M
