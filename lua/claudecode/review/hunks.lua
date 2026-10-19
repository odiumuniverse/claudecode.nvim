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

---Share of a line that must stay unchanged for word highlights to make sense, as a fraction 2/5.
local MIN_UNCHANGED_NUM, MIN_UNCHANGED_DEN = 2, 5

---@class ClaudeCodeToken
---@field text string
---@field start integer  -- byte offset from 0
---@field stop integer   -- byte offset from 0, not included

---@param byte integer
---@return "word"|"space"|"punct"
local function token_class(byte)
  if
    byte >= 0x80
    or byte == 0x5F
    or (byte >= 0x30 and byte <= 0x39)
    or (byte >= 0x41 and byte <= 0x5A)
    or (byte >= 0x61 and byte <= 0x7A)
  then
    return "word"
  end
  if byte == 0x20 or (byte >= 0x09 and byte <= 0x0D) then
    return "space"
  end
  return "punct"
end

---Words (ASCII letters, digits, "_" and whole UTF-8 sequences), runs of whitespace, single punctuation signs.
---@param line string
---@return ClaudeCodeToken[]
local function tokenize(line)
  local tokens = {}
  local i = 1
  while i <= #line do
    local class = token_class(line:byte(i))
    local j = i + 1
    if class ~= "punct" then
      while j <= #line and token_class(line:byte(j)) == class do
        j = j + 1
      end
    end
    tokens[#tokens + 1] = { text = line:sub(i, j - 1), start = i - 1, stop = j - 1 }
    i = j
  end
  return tokens
end

---@param tokens ClaudeCodeToken[]
---@return string
local function tokens_to_text(tokens)
  local texts = {}
  for i, token in ipairs(tokens) do
    texts[i] = token.text
  end
  return to_text(texts)
end

---A run of changed tokens is one range, so neighbouring changes come out already merged.
---@param tokens ClaudeCodeToken[]
---@param first integer
---@param count integer
---@param ranges integer[][]
local function add_range(tokens, first, count, ranges)
  if count > 0 then
    ranges[#ranges + 1] = { tokens[first].start, tokens[first + count - 1].stop }
  end
end

---@param ranges integer[][]
---@return integer
local function total_length(ranges)
  local total = 0
  for _, range in ipairs(ranges) do
    total = total + range[2] - range[1]
  end
  return total
end

---Changed byte ranges inside a pair of lines, `{ start_col, end_col }` from 0, end not included.
---Returns `nil, nil` when so little is shared that highlighting the whole line reads better.
---@param old_line string
---@param new_line string
---@return integer[][]|nil old_ranges
---@return integer[][]|nil new_ranges
function M.word_diff(old_line, new_line)
  local old_tokens, new_tokens = tokenize(old_line), tokenize(new_line)
  local indices = vim.text.diff(tokens_to_text(old_tokens), tokens_to_text(new_tokens), {
    result_type = "indices",
    algorithm = "histogram",
  })

  local old_ranges, new_ranges = {}, {}
  for _, idx in ipairs(indices) do
    add_range(old_tokens, idx[1], idx[2], old_ranges)
    add_range(new_tokens, idx[3], idx[4], new_ranges)
  end

  local unchanged = #old_line - total_length(old_ranges)
  local longest = math.max(#old_line, #new_line)
  if unchanged * MIN_UNCHANGED_DEN < longest * MIN_UNCHANGED_NUM then
    return nil, nil
  end
  return old_ranges, new_ranges
end

---@class ClaudeCodeWordPair
---@field base integer  -- line inside the hunk's base_lines, from 1
---@field cur integer   -- line inside the hunk's cur_lines, from 1
---@field base_ranges integer[][]
---@field cur_ranges integer[][]

---The i-th base line against the i-th Claude line, only where word highlights apply.
---@param hunk ClaudeCodeHunk
---@return ClaudeCodeWordPair[]
function M.pairs(hunk)
  local result = {}
  for i = 1, math.min(hunk.base_count, hunk.cur_count) do
    local base_ranges, cur_ranges = M.word_diff(hunk.base_lines[i], hunk.cur_lines[i])
    if base_ranges and cur_ranges then
      result[#result + 1] = { base = i, cur = i, base_ranges = base_ranges, cur_ranges = cur_ranges }
    end
  end
  return result
end

---Where a hunk sits in the buffer as the 0-based half-open range `[start, stop)`.
---A pure deletion "after line k" has no lines of its own: it is the point between line k and line k + 1.
---@param hunk ClaudeCodeHunk
---@return integer start
---@return integer stop
local function buffer_range(hunk)
  if hunk.cur_count == 0 then
    return hunk.cur_start, hunk.cur_start
  end
  return hunk.cur_start - 1, hunk.cur_start - 1 + hunk.cur_count
end

---Carry a user edit made outside any hunk over to the base.
---Arguments follow `on_lines` of `nvim_buf_attach`: lines from 0, `[first, last_old)` of the old text
---became `[first, last_new)` of the new one; `hunks` are the hunks from before the edit.
---Returns the 0-based half-open range `[base_first, base_last)` of the base that the old segment
---corresponds to, or `nil` when the edit overlaps a hunk or touches its border (it belongs to the hunk then).
---@param hunks ClaudeCodeHunk[]
---@param first integer
---@param last_old integer
---@param last_new integer
---@return integer|nil base_first
---@return integer|nil base_last
function M.map_edit(hunks, first, last_old, last_new)
  local shift = 0
  for _, hunk in ipairs(hunks) do
    local start, stop = buffer_range(hunk)
    if first <= stop and last_old >= start then
      return nil, nil
    end
    if first > stop then
      shift = shift + hunk.cur_count - hunk.base_count
    end
  end
  return first - shift, last_old - shift
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

---New base after an edit that needs no review (Claude in accept-edits mode) turned `before` into
---`after`. Parts of the edit away from the pending hunks (base → before) go into the base, the way
---your own edits outside a hunk do; a part that overlaps or touches a pending hunk stays in it.
---@param base_lines string[]
---@param before_lines string[] The file before the edit
---@param after_lines string[] The file after the edit
---@return string[]
function M.carry(base_lines, before_lines, after_lines)
  local pending = M.compute(base_lines, before_lines)
  local edits = M.compute(before_lines, after_lines)
  local result = vim.list_slice(base_lines, 1, #base_lines)
  -- Bottom up, so the base ranges of the edits above stay where map_edit put them.
  for i = #edits, 1, -1 do
    local edit = edits[i]
    local first = edit.base_count == 0 and edit.base_start or edit.base_start - 1
    local base_first, base_last = M.map_edit(pending, first, first + edit.base_count, first + edit.cur_count)
    if base_first then
      local head = vim.list_slice(result, 1, base_first)
      vim.list_extend(head, edit.cur_lines)
      result = vim.list_extend(head, vim.list_slice(result, base_last + 1, #result))
    end
  end
  return result
end

return M
