---@brief [[
--- Extmarks for the review engine: added lines, deleted lines as virtual lines, changed words
--- and the hint next to the hunk under the cursor. Knows hunks and a buffer to draw on, nothing else.
---@brief ]]
---@module 'claudecode.review.render'

local hunk_logic = require("claudecode.review.hunks")

local M = {}

local HIGHLIGHT_GROUP = "ClaudeCodeReviewHighlights"

-- Syntax and treesitter run at 100: keep the added-line background below them so the text keeps its
-- colors, and the changed words above the line background.
local LINE_PRIORITY = 10
local WORD_PRIORITY = 20

local ns = vim.api.nvim_create_namespace("claudecode_review")

M.DEFAULT_HINT = "cs keep · cx revert"

---@class ClaudeCodeReviewDrawOpts
---@field word_diff? boolean  Highlight changed words inside paired lines (default true)
---@field hint? string|false Text at the end of the hunk under the cursor (default `DEFAULT_HINT`); false hides it
---@field hint_overflow? "above"|"statusline" Where the hint goes when it does not fit at the end of the line (default "above")
---@field line_count? integer Lines of the text the hunks describe; an empty file is 0 although its buffer has one line

---Define the highlight groups. `default = true`, so a colorscheme can override them.
---Called from `setup`, from the first draw and again on `ColorScheme`: `:colorscheme` clears the groups
---that are not plain links.
local function define_highlights()
  local links = {
    ClaudeCodeReviewAdd = "DiffAdd",
    ClaudeCodeReviewAddText = "DiffText",
    ClaudeCodeReviewDelete = "DiffDelete",
    ClaudeCodeReviewHint = "Comment",
    ClaudeCodeReviewCount = "Special",
    ClaudeCodeReviewNote = "Comment",
    -- The box of a saved note: dimmed, so the code stays the brightest thing on screen.
    ClaudeCodeReviewNoteBorder = "NonText",
    -- +12 and -3 in the lists of files and notes.
    ClaudeCodeReviewAdded = "Added",
    ClaudeCodeReviewRemoved = "Removed",
    -- Since when a file waits and on which branch, in the list of files.
    ClaudeCodeReviewMeta = "Comment",
  }
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { default = true, link = target })
  end
  -- Used together with ClaudeCodeReviewDelete, so only the extra attributes live here and a
  -- theme change needs no copying of colors.
  vim.api.nvim_set_hl(0, "ClaudeCodeReviewDeleteText", { default = true, bold = true, strikethrough = true })
end

local highlights_ready = false

function M.setup()
  define_highlights()
  highlights_ready = true
  local group = vim.api.nvim_create_augroup(HIGHLIGHT_GROUP, { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    desc = "Define the claudecode review highlight groups again",
    callback = define_highlights,
  })
end

---@param bufnr integer
---@return integer|nil
local function window_of(bufnr)
  if vim.api.nvim_win_get_buf(0) == bufnr then
    return vim.api.nvim_get_current_win()
  end
  return vim.fn.win_findbuf(bufnr)[1]
end

---Columns available for text in the window that shows the buffer.
---@param bufnr integer
---@return integer
local function text_width(bufnr)
  local win = window_of(bufnr)
  if not win then
    return vim.o.columns
  end
  return vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
end

---Tabs become spaces by the buffer's tabstop, the way the window would show them.
---@param text string
---@param col integer Display column where `text` starts
---@param tabstop integer
---@return string expanded
---@return integer col Display column after `text`
local function expand_tabs(text, col, tabstop)
  if not text:find("\t", 1, true) then
    return text, col + vim.fn.strdisplaywidth(text)
  end
  local parts = vim.split(text, "\t", { plain = true })
  local out = { parts[1] }
  col = col + vim.fn.strdisplaywidth(parts[1])
  for i = 2, #parts do
    local spaces = tabstop - (col % tabstop)
    out[#out + 1] = string.rep(" ", spaces) .. parts[i]
    col = col + spaces + vim.fn.strdisplaywidth(parts[i])
  end
  return table.concat(out), col
end

---Chunks of one deleted line: changed words in their own group, the rest padded to the window width.
---@param line string
---@param ranges integer[][]|nil Byte ranges of changed words, from 0, end not included
---@param width integer
---@param tabstop integer
---@return table[] chunks
local function deleted_chunks(line, ranges, width, tabstop)
  local chunks = {}
  local col = 0
  local function push(first, last, group)
    if last <= first then
      return
    end
    local text
    text, col = expand_tabs(line:sub(first + 1, last), col, tabstop)
    chunks[#chunks + 1] = { text, group }
  end

  local pos = 0
  for _, range in ipairs(ranges or {}) do
    push(pos, range[1], "ClaudeCodeReviewDelete")
    push(range[1], range[2], { "ClaudeCodeReviewDelete", "ClaudeCodeReviewDeleteText" })
    pos = range[2]
  end
  push(pos, #line, "ClaudeCodeReviewDelete")

  if col < width then
    chunks[#chunks + 1] = { string.rep(" ", width - col), "ClaudeCodeReviewDelete" }
  end
  return chunks
end

---Byte ranges of changed words per line of the hunk, by line index inside the hunk.
---@param hunk ClaudeCodeHunk
---@return table<integer, integer[][]> base_ranges
---@return table<integer, integer[][]> cur_ranges
local function word_ranges(hunk)
  local base_ranges, cur_ranges = {}, {}
  for _, pair in ipairs(hunk_logic.pairs(hunk)) do
    base_ranges[pair.base] = pair.base_ranges
    cur_ranges[pair.cur] = pair.cur_ranges
  end
  return base_ranges, cur_ranges
end

---@param bufnr integer
---@param hunk ClaudeCodeHunk
---@param line_count integer
---@param word_diff boolean
local function draw_hunk(bufnr, hunk, line_count, word_diff)
  local base_ranges, cur_ranges = {}, {}
  if word_diff then
    base_ranges, cur_ranges = word_ranges(hunk)
  end

  for i = 1, hunk.cur_count do
    local row = hunk.cur_start - 1 + (i - 1)
    -- A range to the start of the next line, not line_hl_group: Neovim draws a line_hl_group over
    -- the background of every other highlight on the line, whatever their priorities, and the
    -- changed words lost their color.
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      end_row = row + 1,
      end_col = 0,
      hl_group = "ClaudeCodeReviewAdd",
      hl_eol = true,
      priority = LINE_PRIORITY,
      strict = false,
    })
    for _, range in ipairs(cur_ranges[i] or {}) do
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, range[1], {
        end_col = range[2],
        hl_group = "ClaudeCodeReviewAddText",
        priority = WORD_PRIORITY,
        strict = false,
      })
    end
  end

  if hunk.base_count > 0 then
    local width = text_width(bufnr)
    local tabstop = vim.bo[bufnr].tabstop
    local virt_lines = {}
    for i, line in ipairs(hunk.base_lines) do
      virt_lines[i] = deleted_chunks(line, base_ranges[i], width, tabstop)
    end
    local row, above = hunk_logic.anchor(hunk, line_count)
    vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      virt_lines = virt_lines,
      virt_lines_above = above,
      strict = false,
    })
  end
end

---The hint is one extmark of its own, so moving the cursor does not redraw the buffer.
---@type table<integer, integer>
local hint_marks = {}

---The hint of a buffer that went to the statusline, by buffer.
---@type table<integer, string>
local overflowing = {}

---Does text `need` cells wide fit at the end of line `row` in every window that shows the buffer?
---Neovim cuts end-of-line text at the window's edge, and the extmark shows in all of them.
---@param bufnr integer
---@param row integer
---@param need integer
---@return boolean
local function fits_at_eol(bufnr, row, need)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local width = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.strdisplaywidth(line)
  end)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local room = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
    local used
    if vim.wo[win].wrap then
      -- The text goes after the last screen line of a wrapped line.
      used = width == 0 and 0 or (width - 1) % room + 1
    else
      used = math.max(0, width - vim.api.nvim_win_call(win, vim.fn.winsaveview).leftcol)
    end
    -- One cell stays between the line and the text.
    if used + 1 + need > room then
      return false
    end
  end
  return true
end

---A line of its own above line 1 stays hidden until the window scrolls up into it ('topfill').
---@param bufnr integer
---@param fill integer Virtual lines above line 1
local function show_above_first(bufnr, fill)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.api.nvim_win_call(win, function()
      local view = vim.fn.winsaveview()
      if view.topline == 1 and view.topfill < fill then
        vim.fn.winrestview({ topline = 1, topfill = fill })
      end
    end)
  end
end

---Show the hint at the end of the first line of the hunk under the cursor; remove it elsewhere. When
---it does not fit there, it goes on a line of its own above the hunk, or to the statusline: at the
---end of a long line in a narrow window the hint was cut off, and with it the keys.
---@param bufnr integer
---@param hunks ClaudeCodeHunk[]
---@param opts ClaudeCodeReviewDrawOpts
function M.update_hint(bufnr, hunks, opts)
  opts = opts or {}
  overflowing[bufnr] = nil
  if hint_marks[bufnr] then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, hint_marks[bufnr])
    hint_marks[bufnr] = nil
  end

  local hint = opts.hint
  if hint == nil then
    hint = M.DEFAULT_HINT
  end
  local win = window_of(bufnr)
  if not hint or hint == "" or not win then
    return
  end

  local line_count = opts.line_count or vim.api.nvim_buf_line_count(bufnr)
  local index = hunk_logic.find(hunks, vim.api.nvim_win_get_cursor(win)[1], line_count)
  if not index then
    return
  end
  local row, above = hunk_logic.anchor(hunks[index], line_count)
  -- Which hunk of how many: the hunks left in this file at a glance.
  local chunks = { { index .. "/" .. #hunks, "ClaudeCodeReviewCount" }, { "  " .. hint, "ClaudeCodeReviewHint" } }
  if fits_at_eol(bufnr, row, vim.fn.strdisplaywidth(chunks[1][1] .. chunks[2][1])) then
    hint_marks[bufnr] = vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      virt_text = chunks,
      virt_text_pos = "eol",
      strict = false,
    })
  elseif opts.hint_overflow == "statusline" then
    overflowing[bufnr] = chunks[1][1] .. " " .. hint
  else
    -- Above the hunk, over its deleted lines.
    hint_marks[bufnr] = vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      virt_lines = { chunks },
      virt_lines_above = true,
      strict = false,
    })
    if row == 1 then
      show_above_first(bufnr, 1 + (above and hunks[index].base_count or 0))
    end
  end
end

---The hint of the hunk under the cursor when it went to the statusline (`hint_overflow`), else nil.
---@param bufnr integer
---@return string|nil
function M.overflowing_hint(bufnr)
  return overflowing[bufnr]
end

---Redraw every hunk of the buffer from scratch, hint included.
---@param bufnr integer
---@param hunks ClaudeCodeHunk[]
---@param opts ClaudeCodeReviewDrawOpts
function M.draw(bufnr, hunks, opts)
  if not highlights_ready then
    M.setup()
  end
  opts = opts or {}
  local word_diff = opts.word_diff ~= false
  local line_count = opts.line_count or vim.api.nvim_buf_line_count(bufnr)

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  hint_marks[bufnr] = nil
  local above_first = 0
  for _, hunk in ipairs(hunks) do
    draw_hunk(bufnr, hunk, line_count, word_diff)
    local row, above = hunk_logic.anchor(hunk, line_count)
    if row == 1 and above then
      above_first = hunk.base_count
    end
  end
  M.update_hint(bufnr, hunks, opts)

  -- Neovim hides virtual lines above line 1 until the window scrolls up into them ('topfill').
  -- Show them in every window that sits at the top; a window scrolled further down keeps its view.
  if above_first > 0 then
    show_above_first(bufnr, above_first)
  end
end

---@param bufnr integer
function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  hint_marks[bufnr] = nil
  overflowing[bufnr] = nil
end

return M
