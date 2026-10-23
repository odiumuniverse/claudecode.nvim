local helpers = require("helpers")
local render = require("claudecode.review.render")

describe("review.render highlights", function()
  it("links the review groups to the diff groups", function()
    render.setup()
    local function link(name)
      return vim.api.nvim_get_hl(0, { name = name, link = true }).link
    end
    assert.equal("DiffAdd", link("ClaudeCodeReviewAdd"))
    assert.equal("DiffText", link("ClaudeCodeReviewAddText"))
    assert.equal("DiffDelete", link("ClaudeCodeReviewDelete"))
    assert.equal("Comment", link("ClaudeCodeReviewHint"))
  end)

  it("keeps a colorscheme override", function()
    vim.api.nvim_set_hl(0, "ClaudeCodeReviewAdd", { bg = "#102030" })
    render.setup()
    assert.equal(0x102030, vim.api.nvim_get_hl(0, { name = "ClaudeCodeReviewAdd" }).bg)
    vim.cmd("highlight clear ClaudeCodeReviewAdd")
  end)

  it("defines the groups again after :colorscheme clears them", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/colors", "p")
    helpers.write_file(
      dir .. "/colors/claudecode_spec.lua",
      'vim.cmd("highlight clear")\nvim.g.colors_name = "claudecode_spec"\n'
    )
    local saved_rtp = vim.o.runtimepath
    vim.opt.runtimepath:prepend(dir)

    render.setup()
    vim.cmd.colorscheme("claudecode_spec")
    local hl = vim.api.nvim_get_hl(0, { name = "ClaudeCodeReviewDeleteText" })
    vim.o.runtimepath = saved_rtp
    assert.is_true(hl.bold)
    assert.is_true(hl.strikethrough)
  end)

  it("draws deleted words in a group of their own", function()
    render.setup()
    local hl = vim.api.nvim_get_hl(0, { name = "ClaudeCodeReviewDeleteText" })
    assert.is_true(hl.bold)
    assert.is_true(hl.strikethrough)
  end)

  after_each(helpers.reset)
end)

---@param fields table
---@return ClaudeCodeHunk
local function hunk(fields)
  return vim.tbl_extend("force", {
    base_start = 0,
    base_count = 0,
    cur_start = 0,
    cur_count = 0,
    base_lines = {},
    cur_lines = {},
  }, fields)
end

---@param bufnr integer
---@param key string
---@return table[]
local function marks_with(bufnr, key)
  return vim.tbl_filter(function(mark)
    return mark.details[key] ~= nil
  end, helpers.marks(bufnr))
end

---Marks painted with one highlight group: "ClaudeCodeReviewAdd" for added lines,
---"ClaudeCodeReviewAddText" for the changed words in them.
---@param bufnr integer
---@param group string
---@return table[]
local function marks_of(bufnr, group)
  return vim.tbl_filter(function(mark)
    return mark.details.hl_group == group
  end, helpers.marks(bufnr))
end

---Text of one virtual line, chunks glued.
---@param virt_line table[]
---@return string
local function virt_text(virt_line)
  local texts = {}
  for _, chunk in ipairs(virt_line) do
    texts[#texts + 1] = chunk[1]
  end
  return table.concat(texts)
end

---@param win integer
---@return integer
local function text_width(win)
  return vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
end

---The background Neovim draws at a buffer position of the current window, as the screen shows it.
---@param lnum integer 1-based
---@param col integer 0-based byte
---@return integer|nil
local function screen_bg(lnum, col)
  vim.cmd("redraw!")
  local pos = vim.fn.screenpos(0, lnum, col + 1)
  return vim.api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)[2].background
end

---Plain colors for the review groups, so that a spec can tell them apart on the screen.
local function distinct_colors()
  vim.o.termguicolors = true
  vim.api.nvim_set_hl(0, "ClaudeCodeReviewAdd", { bg = 0x24462a })
  vim.api.nvim_set_hl(0, "ClaudeCodeReviewAddText", { bg = 0x7a5a00 })
end

describe("review.render.draw", function()
  before_each(function()
    render.setup()
  end)

  after_each(helpers.reset)

  it("paints added lines and hangs deleted ones above them", function()
    local bufnr = helpers.buffer({ "a", "X", "Y", "c" })
    local h = hunk({
      base_start = 2,
      base_count = 1,
      cur_start = 2,
      cur_count = 2,
      base_lines = { "b" },
      cur_lines = { "X", "Y" },
    })

    render.draw(bufnr, { h }, {})

    local added = marks_of(bufnr, "ClaudeCodeReviewAdd")
    assert.equal(2, #added)
    assert.same({ 1, 2 }, { added[1].row, added[2].row })

    local deleted = marks_with(bufnr, "virt_lines")
    assert.equal(1, #deleted)
    assert.equal(1, deleted[1].row)
    assert.is_true(deleted[1].details.virt_lines_above)
    assert.equal(1, #deleted[1].details.virt_lines)
    assert.equal("b", vim.trim(virt_text(deleted[1].details.virt_lines[1])))
  end)

  it("pads a deleted line to the width of the window", function()
    local bufnr = helpers.buffer({ "a", "c" })
    local h = hunk({ base_start = 2, base_count = 1, cur_start = 1, base_lines = { "b" } })

    render.draw(bufnr, { h }, {})

    local line = marks_with(bufnr, "virt_lines")[1].details.virt_lines[1]
    assert.equal("b" .. string.rep(" ", text_width(vim.api.nvim_get_current_win()) - 1), virt_text(line))
    for _, chunk in ipairs(line) do
      assert.equal("ClaudeCodeReviewDelete", chunk[2])
    end
  end)

  it("expands tabs of a deleted line by tabstop", function()
    local bufnr = helpers.buffer({ "a", "c" })
    vim.bo[bufnr].tabstop = 4
    local h = hunk({ base_start = 2, base_count = 1, cur_start = 1, base_lines = { "\tfoo\tbar" } })

    render.draw(bufnr, { h }, {})

    local line = marks_with(bufnr, "virt_lines")[1].details.virt_lines[1]
    -- tab at column 0 -> 4 spaces; tab at column 7 ("    foo") -> 1 space
    assert.equal("    foo bar" .. string.rep(" ", text_width(vim.api.nvim_get_current_win()) - 11), virt_text(line))
  end)

  it("hangs a pure deletion above the next line", function()
    local bufnr = helpers.buffer({ "a", "c" })
    local h = hunk({ base_start = 2, base_count = 1, cur_start = 1, base_lines = { "b" } })

    render.draw(bufnr, { h }, {})

    local deleted = marks_with(bufnr, "virt_lines")[1]
    assert.equal(1, deleted.row)
    assert.is_true(deleted.details.virt_lines_above)
    assert.same({}, marks_of(bufnr, "ClaudeCodeReviewAdd"))
  end)

  it("hangs a deleted file tail below the last line", function()
    local bufnr = helpers.buffer({ "a", "b" })
    local h = hunk({ base_start = 3, base_count = 2, cur_start = 2, base_lines = { "c", "d" } })

    render.draw(bufnr, { h }, {})

    local deleted = marks_with(bufnr, "virt_lines")[1]
    assert.equal(1, deleted.row)
    assert.is_false(deleted.details.virt_lines_above == true)
    assert.equal(2, #deleted.details.virt_lines)
  end)

  it("hangs the deleted lines above line 1 when the text is empty", function()
    local bufnr = helpers.buffer({ "" })
    local h = hunk({ base_start = 1, base_count = 1, base_lines = { "a" } })

    render.draw(bufnr, { h }, { line_count = 0 })

    local deleted = marks_with(bufnr, "virt_lines")[1]
    assert.equal(0, deleted.row)
    assert.is_true(deleted.details.virt_lines_above)
  end)

  it("paints a new file entirely as added", function()
    local bufnr = helpers.buffer({ "a", "b", "c" })
    local h = hunk({ cur_start = 1, cur_count = 3, cur_lines = { "a", "b", "c" } })

    render.draw(bufnr, { h }, {})

    assert.same(
      { 0, 1, 2 },
      vim.tbl_map(function(mark)
        return mark.row
      end, marks_of(bufnr, "ClaudeCodeReviewAdd"))
    )
    assert.same({}, marks_with(bufnr, "virt_lines"))
  end)

  it("marks the changed words on both sides of a changed line", function()
    local bufnr = helpers.buffer({ "foo qux baz" })
    local h = hunk({
      base_start = 1,
      base_count = 1,
      cur_start = 1,
      cur_count = 1,
      base_lines = { "foo bar baz" },
      cur_lines = { "foo qux baz" },
    })

    render.draw(bufnr, { h }, {})

    local words = marks_of(bufnr, "ClaudeCodeReviewAddText")
    assert.equal(1, #words)
    assert.equal(0, words[1].row)
    assert.equal(4, words[1].col)
    assert.equal(7, words[1].details.end_col)

    local chunks = marks_with(bufnr, "virt_lines")[1].details.virt_lines[1]
    assert.equal("foo ", chunks[1][1])
    assert.equal("bar", chunks[2][1])
    assert.equal(" baz", chunks[3][1])
    assert.same({ "ClaudeCodeReviewDelete", "ClaudeCodeReviewDeleteText" }, chunks[2][2])
    assert.equal("ClaudeCodeReviewDelete", chunks[1][2])
  end)

  describe("on the screen", function()
    after_each(function()
      vim.o.cursorline = false
      vim.cmd("highlight clear ClaudeCodeReviewAdd")
      vim.cmd("highlight clear ClaudeCodeReviewAddText")
      render.setup()
    end)

    it("shows a changed word of an added line in its own color", function()
      local bufnr = helpers.buffer({ "top", "foo qux baz" })
      distinct_colors()
      render.draw(bufnr, {
        hunk({
          base_start = 2,
          base_count = 1,
          cur_start = 2,
          cur_count = 1,
          base_lines = { "foo bar baz" },
          cur_lines = { "foo qux baz" },
        }),
      }, {})

      assert.equal(0x7a5a00, screen_bg(2, 4))
      assert.equal(0x24462a, screen_bg(2, 0))
    end)

    it("keeps an added line green under the cursor line", function()
      local bufnr = helpers.buffer({ "top", "new", "end" })
      distinct_colors()
      vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x303030 })
      vim.o.cursorline = true
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      render.draw(bufnr, { hunk({ base_start = 1, cur_start = 2, cur_count = 1, cur_lines = { "new" } }) }, {})

      assert.equal(0x24462a, screen_bg(2, 1))
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      assert.equal(0x303030, screen_bg(3, 1))
    end)

    it("paints an empty added line and an added last line to the window edge", function()
      local bufnr = helpers.buffer({ "top", "", "last" })
      distinct_colors()
      render.draw(bufnr, { hunk({ base_start = 1, cur_start = 2, cur_count = 2, cur_lines = { "", "last" } }) }, {})

      vim.cmd("redraw!")
      local width = vim.api.nvim_win_get_width(0)
      for _, row in ipairs({ 1, 2 }) do
        assert.equal(0x24462a, vim.api.nvim__inspect_cell(1, row, 0)[2].background)
        assert.equal(0x24462a, vim.api.nvim__inspect_cell(1, row, width - 1)[2].background)
      end
    end)
  end)

  it("counts the bytes of Cyrillic words, not characters", function()
    local bufnr = helpers.buffer({ "привет всем" })
    local h = hunk({
      base_start = 1,
      base_count = 1,
      cur_start = 1,
      cur_count = 1,
      base_lines = { "привет мир" },
      cur_lines = { "привет всем" },
    })

    render.draw(bufnr, { h }, {})

    local words = marks_of(bufnr, "ClaudeCodeReviewAddText")
    assert.equal(13, words[1].col)
    assert.equal(21, words[1].details.end_col)
    local chunks = marks_with(bufnr, "virt_lines")[1].details.virt_lines[1]
    assert.equal("мир", chunks[2][1])
  end)

  it("skips word highlights when word_diff is off", function()
    local bufnr = helpers.buffer({ "foo qux baz" })
    local h = hunk({
      base_start = 1,
      base_count = 1,
      cur_start = 1,
      cur_count = 1,
      base_lines = { "foo bar baz" },
      cur_lines = { "foo qux baz" },
    })

    render.draw(bufnr, { h }, { word_diff = false })

    assert.same({}, marks_of(bufnr, "ClaudeCodeReviewAddText"))
    local chunks = marks_with(bufnr, "virt_lines")[1].details.virt_lines[1]
    assert.equal("foo bar baz", vim.trim(chunks[1][1]))
    assert.equal("ClaudeCodeReviewDelete", chunks[1][2])
  end)

  it("redraws instead of adding up", function()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    local h = hunk({
      base_start = 2,
      base_count = 1,
      cur_start = 2,
      cur_count = 1,
      base_lines = { "b" },
      cur_lines = { "X" },
    })

    render.draw(bufnr, { h }, {})
    render.draw(bufnr, { h }, {})

    assert.equal(1, #marks_of(bufnr, "ClaudeCodeReviewAdd"))
    assert.equal(1, #marks_with(bufnr, "virt_lines"))
  end)

  it("clears everything", function()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    local h = hunk({
      base_start = 2,
      base_count = 1,
      cur_start = 2,
      cur_count = 1,
      base_lines = { "b" },
      cur_lines = { "X" },
    })

    render.draw(bufnr, { h }, {})
    render.clear(bufnr)

    assert.same({}, helpers.marks(bufnr))
  end)
end)

describe("review.render hint", function()
  local hint = "cs keep · cx revert"

  ---@return table[]
  local function hints(bufnr)
    return marks_with(bufnr, "virt_text")
  end

  local changed = hunk({
    base_start = 2,
    base_count = 1,
    cur_start = 2,
    cur_count = 2,
    base_lines = { "b" },
    cur_lines = { "X", "Y" },
  })
  local second = hunk({
    base_start = 5,
    base_count = 1,
    cur_start = 6,
    cur_count = 1,
    base_lines = { "e" },
    cur_lines = { "E" },
  })

  before_each(function()
    render.setup()
  end)

  after_each(helpers.reset)

  it("shows at the end of the first line of the hunk under the cursor", function()
    local bufnr = helpers.buffer({ "a", "X", "Y", "c", "d", "E" })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    render.draw(bufnr, { changed, second }, { hint = hint })

    local found = hints(bufnr)
    assert.equal(1, #found)
    assert.equal(1, found[1].row)
    assert.same(
      { { "1/2", "ClaudeCodeReviewCount" }, { "  " .. hint, "ClaudeCodeReviewHint" } },
      found[1].details.virt_text
    )
    assert.equal("eol", found[1].details.virt_text_pos)
  end)

  it("counts the hunk under the cursor among the hunks of the file", function()
    local bufnr = helpers.buffer({ "a", "X", "Y", "c", "d", "E" })
    vim.api.nvim_win_set_cursor(0, { 6, 0 })

    render.draw(bufnr, { changed, second }, { hint = hint })

    assert.equal("2/2", hints(bufnr)[1].details.virt_text[1][1])
  end)

  it("is absent when the cursor is outside every hunk", function()
    local bufnr = helpers.buffer({ "a", "X", "Y", "c", "d", "E" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    render.draw(bufnr, { changed, second }, { hint = hint })

    assert.same({}, hints(bufnr))
  end)

  it("follows the cursor with update_hint and leaves the other marks alone", function()
    local bufnr = helpers.buffer({ "a", "X", "Y", "c", "d", "E" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    render.draw(bufnr, { changed, second }, { hint = hint })
    local before = #helpers.marks(bufnr)

    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    render.update_hint(bufnr, { changed, second }, { hint = hint })
    local found = hints(bufnr)
    assert.equal(1, #found)
    assert.equal(5, found[1].row)
    assert.equal(before, #helpers.marks(bufnr))

    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    render.update_hint(bufnr, { changed, second }, { hint = hint })
    assert.same({}, hints(bufnr))
    assert.equal(before - 1, #helpers.marks(bufnr))
  end)

  it("sits on the line a pure deletion hangs on", function()
    local bufnr = helpers.buffer({ "a", "c" })
    local deletion = hunk({ base_start = 2, base_count = 1, cur_start = 1, base_lines = { "b" } })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    render.draw(bufnr, { deletion }, { hint = hint })

    assert.equal(1, hints(bufnr)[1].row)
  end)

  it("is off when hint is false", function()
    local bufnr = helpers.buffer({ "a", "X", "Y", "c", "d", "E" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    render.draw(bufnr, { changed, second }, { hint = false })

    assert.same({}, hints(bufnr))
  end)

  it("defaults to cs keep · cx revert", function()
    local bufnr = helpers.buffer({ "a", "X", "Y", "c", "d", "E" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    render.draw(bufnr, { changed, second }, {})

    assert.equal("  cs keep · cx revert", hints(bufnr)[1].details.virt_text[2][1])
  end)

  describe("that does not fit at the end of the line", function()
    local expected = { { "1/1", "ClaudeCodeReviewCount" }, { "  " .. hint, "ClaudeCodeReviewHint" } }

    ---Virtual lines that carry the hint, not the deleted text.
    local function hint_lines(bufnr)
      return vim.tbl_filter(function(mark)
        return virt_text(mark.details.virt_lines[1]):find(hint, 1, true) ~= nil
      end, marks_with(bufnr, "virt_lines"))
    end

    ---A hunk that changed line 2 into `line`.
    local function changed_into(line)
      return hunk({
        base_start = 2,
        base_count = 1,
        cur_start = 2,
        cur_count = 1,
        base_lines = { "b" },
        cur_lines = { line },
      })
    end

    it("goes on a line of its own above the hunk", function()
      local long = string.rep("x", vim.api.nvim_win_get_width(0) - 10)
      local bufnr = helpers.buffer({ "a", long, "c" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      render.draw(bufnr, { changed_into(long) }, { hint = hint })

      assert.same({}, hints(bufnr))
      local found = hint_lines(bufnr)
      assert.equal(1, #found)
      assert.equal(1, found[1].row)
      assert.is_true(found[1].details.virt_lines_above)
      assert.same({ expected }, found[1].details.virt_lines)
    end)

    it("is measured against the narrowest window that shows the file", function()
      local line = string.rep("x", 30)
      local bufnr = helpers.buffer({ "a", line, "c" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      local wide = vim.api.nvim_get_current_win()
      vim.cmd("vsplit")
      vim.api.nvim_win_set_width(0, 40)
      vim.api.nvim_set_current_win(wide)

      render.draw(bufnr, { changed_into(line) }, { hint = hint })

      assert.same({}, hints(bufnr))
      assert.equal(1, #hint_lines(bufnr))
    end)

    it("goes above the line a pure deletion hangs on", function()
      local long = string.rep("x", vim.api.nvim_win_get_width(0) - 10)
      local bufnr = helpers.buffer({ "a", long })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      render.draw(bufnr, { hunk({ base_start = 2, base_count = 1, cur_start = 1, base_lines = { "b" } }) }, {
        hint = hint,
      })

      local found = hint_lines(bufnr)
      assert.equal(1, #found)
      assert.equal(1, found[1].row)
    end)

    it("goes to the statusline instead, when you say so", function()
      local long = string.rep("x", vim.api.nvim_win_get_width(0) - 10)
      local bufnr = helpers.buffer({ "a", long, "c" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      render.draw(bufnr, { changed_into(long) }, { hint = hint, hint_overflow = "statusline" })

      assert.same({}, hints(bufnr))
      assert.same({}, hint_lines(bufnr))
      assert.equal("1/1 " .. hint, render.overflowing_hint(bufnr))

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      render.update_hint(bufnr, { changed_into(long) }, { hint = hint, hint_overflow = "statusline" })
      assert.is_nil(render.overflowing_hint(bufnr))
    end)
  end)
end)
