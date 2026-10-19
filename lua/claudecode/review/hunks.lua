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

return M
