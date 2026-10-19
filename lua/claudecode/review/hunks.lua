---Pure hunk logic for the review engine: functions of data only, no buffers or windows.
---@module 'claudecode.review.hunks'
local M = {}

---One changed region. Indices follow `vim.text.diff(..., { result_type = "indices" })`, lines count from 1.
---@class ClaudeCodeHunk
---@field base_start integer  -- when base_count == 0: insertion after this base line (0 = at the top)
---@field base_count integer
---@field cur_start integer   -- when cur_count == 0: deletion after this buffer line (0 = at the top)
---@field cur_count integer
---@field base_lines string[]
---@field cur_lines string[]

---Join lines the way `vim.text.diff` wants them: every line ends with "\n", no lines is "".
---@param lines string[]
---@return string
local function to_text(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

---@param lines string[]
---@param first integer
---@param count integer
---@return string[]
local function copy_range(lines, first, count)
  return vim.list_slice(lines, first, first + count - 1)
end

---A hunk with zero count sits *after* line `start`, so the text before it is `1..start`;
---otherwise the replaced range begins at `start` and the text before it is `1..start - 1`.
---@param lines string[]
---@param start integer
---@param count integer
---@param replacement string[]
---@return string[]
local function splice(lines, start, count, replacement)
  local before = count == 0 and start or start - 1
  local result = vim.list_slice(lines, 1, before)
  vim.list_extend(result, replacement)
  vim.list_extend(result, vim.list_slice(lines, before + count + 1, #lines))
  return result
end

---@param base_lines string[]
---@param cur_lines string[]
---@return ClaudeCodeHunk[]
function M.compute(base_lines, cur_lines)
  local indices = vim.text.diff(to_text(base_lines), to_text(cur_lines), {
    result_type = "indices",
    algorithm = "histogram",
  })

  local result = {}
  for _, idx in ipairs(indices) do
    local base_start, base_count, cur_start, cur_count = idx[1], idx[2], idx[3], idx[4]
    result[#result + 1] = {
      base_start = base_start,
      base_count = base_count,
      cur_start = cur_start,
      cur_count = cur_count,
      base_lines = copy_range(base_lines, base_start, base_count),
      cur_lines = copy_range(cur_lines, cur_start, cur_count),
    }
  end
  return result
end

---Row (from 1) the hunk is drawn on, and whether its deleted lines go above that row.
---A pure deletion "after line k" hangs above line k + 1; at the end of the buffer there is no such
---line, so it goes below line k; in an empty buffer it goes above line 1.
---@param hunk ClaudeCodeHunk
---@param line_count integer
---@return integer row
---@return boolean above
function M.anchor(hunk, line_count)
  if hunk.cur_count > 0 then
    return hunk.cur_start, true
  end
  if line_count == 0 then
    return 1, true
  end
  if hunk.cur_start + 1 > line_count then
    return hunk.cur_start, false
  end
  return hunk.cur_start + 1, true
end

---Index of the hunk under `row` (from 1). A pure deletion belongs to the row it hangs on.
---Without `line_count` a deletion is assumed to have a line below it, so a deleted file tail
---is only found when `line_count` is passed.
---@param hunks ClaudeCodeHunk[]
---@param row integer
---@param line_count? integer
---@return integer|nil
function M.find(hunks, row, line_count)
  for i, hunk in ipairs(hunks) do
    if hunk.cur_count > 0 then
      if row >= hunk.cur_start and row < hunk.cur_start + hunk.cur_count then
        return i
      end
    else
      local anchor_row = line_count and M.anchor(hunk, line_count) or hunk.cur_start + 1
      if row == anchor_row then
        return i
      end
    end
  end
  return nil
end

---New base after the user keeps `hunk`: its base range is replaced by Claude's lines.
---@param base_lines string[]
---@param hunk ClaudeCodeHunk
---@return string[]
function M.keep(base_lines, hunk)
  return splice(base_lines, hunk.base_start, hunk.base_count, hunk.cur_lines)
end

---New buffer text after the user reverts `hunk`: Claude's range is replaced by the base lines.
---@param cur_lines string[]
---@param hunk ClaudeCodeHunk
---@return string[]
function M.revert(cur_lines, hunk)
  return splice(cur_lines, hunk.cur_start, hunk.cur_count, hunk.base_lines)
end

return M
