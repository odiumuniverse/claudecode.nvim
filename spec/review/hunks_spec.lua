local hunks = require("claudecode.review.hunks")

describe("review.hunks.compute", function()
  it("returns no hunks for identical text", function()
    assert.same({}, hunks.compute({ "a", "b" }, { "a", "b" }))
  end)

  it("returns no hunks for two empty texts", function()
    assert.same({}, hunks.compute({}, {}))
  end)

  it("describes a changed line", function()
    assert.same({
      {
        base_start = 2,
        base_count = 1,
        cur_start = 2,
        cur_count = 1,
        base_lines = { "b" },
        cur_lines = { "x" },
      },
    }, hunks.compute({ "a", "b", "c" }, { "a", "x", "c" }))
  end)

  it("treats an empty base as one insertion at the top (new file)", function()
    assert.same({
      {
        base_start = 0,
        base_count = 0,
        cur_start = 1,
        cur_count = 2,
        base_lines = {},
        cur_lines = { "a", "b" },
      },
    }, hunks.compute({}, { "a", "b" }))
  end)

  it("treats an empty current text as one deletion at the top", function()
    assert.same({
      {
        base_start = 1,
        base_count = 2,
        cur_start = 0,
        cur_count = 0,
        base_lines = { "a", "b" },
        cur_lines = {},
      },
    }, hunks.compute({ "a", "b" }, {}))
  end)

  it("tells a single empty line from an empty file", function()
    assert.same({
      {
        base_start = 0,
        base_count = 0,
        cur_start = 1,
        cur_count = 1,
        base_lines = {},
        cur_lines = { "" },
      },
    }, hunks.compute({}, { "" }))
  end)

  it("describes deletion of the first line", function()
    assert.same({
      {
        base_start = 1,
        base_count = 1,
        cur_start = 0,
        cur_count = 0,
        base_lines = { "a" },
        cur_lines = {},
      },
    }, hunks.compute({ "a", "b", "c" }, { "b", "c" }))
  end)

  it("describes deletion of the last line", function()
    assert.same({
      {
        base_start = 3,
        base_count = 1,
        cur_start = 2,
        cur_count = 0,
        base_lines = { "c" },
        cur_lines = {},
      },
    }, hunks.compute({ "a", "b", "c" }, { "a", "b" }))
  end)

  it("describes insertion at the start", function()
    assert.same({
      {
        base_start = 0,
        base_count = 0,
        cur_start = 1,
        cur_count = 1,
        base_lines = {},
        cur_lines = { "a" },
      },
    }, hunks.compute({ "b", "c" }, { "a", "b", "c" }))
  end)

  it("describes insertion at the end", function()
    assert.same({
      {
        base_start = 2,
        base_count = 0,
        cur_start = 3,
        cur_count = 1,
        base_lines = {},
        cur_lines = { "c" },
      },
    }, hunks.compute({ "a", "b" }, { "a", "b", "c" }))
  end)

  it("describes deletion in the middle", function()
    assert.same({
      {
        base_start = 2,
        base_count = 1,
        cur_start = 1,
        cur_count = 0,
        base_lines = { "b" },
        cur_lines = {},
      },
    }, hunks.compute({ "a", "b", "c" }, { "a", "c" }))
  end)

  it("returns several hunks in order", function()
    assert.same({
      {
        base_start = 2,
        base_count = 1,
        cur_start = 2,
        cur_count = 1,
        base_lines = { "b" },
        cur_lines = { "B" },
      },
      {
        base_start = 4,
        base_count = 1,
        cur_start = 4,
        cur_count = 1,
        base_lines = { "d" },
        cur_lines = { "D" },
      },
    }, hunks.compute({ "a", "b", "c", "d", "e" }, { "a", "B", "c", "D", "e" }))
  end)

  it("does not mutate its inputs", function()
    local base = { "a", "b", "c" }
    local cur = { "a", "x", "y", "c" }
    hunks.compute(base, cur)
    assert.same({ "a", "b", "c" }, base)
    assert.same({ "a", "x", "y", "c" }, cur)
  end)
end)

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

describe("review.hunks.keep", function()
  it("takes the changed lines into the base", function()
    local h =
      hunk({ base_start = 2, base_count = 1, cur_start = 2, cur_count = 1, base_lines = { "b" }, cur_lines = { "x" } })
    assert.same({ "a", "x", "c" }, hunks.keep({ "a", "b", "c" }, h))
  end)

  it("takes an insertion in the middle (after base line 1)", function()
    local h = hunk({ base_start = 1, cur_start = 2, cur_count = 1, cur_lines = { "b" } })
    assert.same({ "a", "b", "c" }, hunks.keep({ "a", "c" }, h))
  end)

  it("takes an insertion at the top (base_start 0)", function()
    local h = hunk({ cur_start = 1, cur_count = 1, cur_lines = { "a" } })
    assert.same({ "a", "b" }, hunks.keep({ "b" }, h))
  end)

  it("takes an insertion at the end", function()
    local h = hunk({ base_start = 1, cur_start = 2, cur_count = 1, cur_lines = { "b" } })
    assert.same({ "a", "b" }, hunks.keep({ "a" }, h))
  end)

  it("takes a deletion of the first line", function()
    local h = hunk({ base_start = 1, base_count = 1, base_lines = { "a" } })
    assert.same({ "b", "c" }, hunks.keep({ "a", "b", "c" }, h))
  end)

  it("takes a deletion in the middle", function()
    local h = hunk({ base_start = 2, base_count = 1, cur_start = 1, base_lines = { "b" } })
    assert.same({ "a", "c" }, hunks.keep({ "a", "b", "c" }, h))
  end)

  it("takes a deletion of the last line", function()
    local h = hunk({ base_start = 3, base_count = 1, cur_start = 2, base_lines = { "c" } })
    assert.same({ "a", "b" }, hunks.keep({ "a", "b", "c" }, h))
  end)

  it("turns an empty base into the new file", function()
    local h = hunk({ cur_start = 1, cur_count = 2, cur_lines = { "a", "b" } })
    assert.same({ "a", "b" }, hunks.keep({}, h))
  end)

  it("turns the base into an empty file when everything was deleted", function()
    local h = hunk({ base_start = 1, base_count = 2, base_lines = { "a", "b" } })
    assert.same({}, hunks.keep({ "a", "b" }, h))
  end)

  it("does not mutate its inputs", function()
    local base = { "a", "b", "c" }
    local h = hunk({
      base_start = 2,
      base_count = 1,
      cur_start = 2,
      cur_count = 2,
      base_lines = { "b" },
      cur_lines = { "x", "y" },
    })
    local h_before = vim.deepcopy(h)
    local result = hunks.keep(base, h)
    assert.same({ "a", "x", "y", "c" }, result)
    assert.same({ "a", "b", "c" }, base)
    assert.same(h_before, h)
    assert.are_not.equal(base, result)
  end)
end)

describe("review.hunks.revert", function()
  it("puts the base lines back over the changed ones", function()
    local h =
      hunk({ base_start = 2, base_count = 1, cur_start = 2, cur_count = 1, base_lines = { "b" }, cur_lines = { "x" } })
    assert.same({ "a", "b", "c" }, hunks.revert({ "a", "x", "c" }, h))
  end)

  it("removes an insertion in the middle", function()
    local h = hunk({ base_start = 1, cur_start = 2, cur_count = 1, cur_lines = { "b" } })
    assert.same({ "a", "c" }, hunks.revert({ "a", "b", "c" }, h))
  end)

  it("removes an insertion at the top", function()
    local h = hunk({ cur_start = 1, cur_count = 1, cur_lines = { "a" } })
    assert.same({ "b", "c" }, hunks.revert({ "a", "b", "c" }, h))
  end)

  it("removes an insertion at the end", function()
    local h = hunk({ base_start = 2, cur_start = 3, cur_count = 1, cur_lines = { "c" } })
    assert.same({ "a", "b" }, hunks.revert({ "a", "b", "c" }, h))
  end)

  it("restores a deleted first line (cur_start 0)", function()
    local h = hunk({ base_start = 1, base_count = 1, base_lines = { "a" } })
    assert.same({ "a", "b", "c" }, hunks.revert({ "b", "c" }, h))
  end)

  it("restores a line deleted in the middle", function()
    local h = hunk({ base_start = 2, base_count = 1, cur_start = 1, base_lines = { "b" } })
    assert.same({ "a", "b", "c" }, hunks.revert({ "a", "c" }, h))
  end)

  it("restores a deleted last line", function()
    local h = hunk({ base_start = 3, base_count = 1, cur_start = 2, base_lines = { "c" } })
    assert.same({ "a", "b", "c" }, hunks.revert({ "a", "b" }, h))
  end)

  it("empties the buffer when reverting a new file", function()
    local h = hunk({ cur_start = 1, cur_count = 2, cur_lines = { "a", "b" } })
    assert.same({}, hunks.revert({ "a", "b" }, h))
  end)

  it("restores everything into an emptied buffer", function()
    local h = hunk({ base_start = 1, base_count = 2, base_lines = { "a", "b" } })
    assert.same({ "a", "b" }, hunks.revert({}, h))
  end)

  it("does not mutate its inputs", function()
    local cur = { "a", "x", "y", "c" }
    local h = hunk({
      base_start = 2,
      base_count = 1,
      cur_start = 2,
      cur_count = 2,
      base_lines = { "b" },
      cur_lines = { "x", "y" },
    })
    local h_before = vim.deepcopy(h)
    local result = hunks.revert(cur, h)
    assert.same({ "a", "b", "c" }, result)
    assert.same({ "a", "x", "y", "c" }, cur)
    assert.same(h_before, h)
    assert.are_not.equal(cur, result)
  end)
end)

describe("review.hunks.anchor", function()
  it("anchors a changed hunk on its first line, above", function()
    local h = hunk({
      base_start = 3,
      base_count = 1,
      cur_start = 3,
      cur_count = 2,
      base_lines = { "c" },
      cur_lines = { "x", "y" },
    })
    local row, above = hunks.anchor(h, 6)
    assert.equal(3, row)
    assert.is_true(above)
  end)

  it("anchors a pure insertion on its first line, above", function()
    local h = hunk({ base_start = 1, cur_start = 2, cur_count = 1, cur_lines = { "x" } })
    local row, above = hunks.anchor(h, 3)
    assert.equal(2, row)
    assert.is_true(above)
  end)

  it("anchors a deletion after line k above line k + 1", function()
    local h = hunk({ base_start = 3, base_count = 1, cur_start = 2, base_lines = { "c" } })
    local row, above = hunks.anchor(h, 5)
    assert.equal(3, row)
    assert.is_true(above)
  end)

  it("anchors a deletion before the first line above line 1", function()
    local h = hunk({ base_start = 1, base_count = 1, base_lines = { "a" } })
    local row, above = hunks.anchor(h, 2)
    assert.equal(1, row)
    assert.is_true(above)
  end)

  it("anchors a deletion of the file tail below the last line", function()
    local h = hunk({ base_start = 4, base_count = 2, cur_start = 3, base_lines = { "d", "e" } })
    local row, above = hunks.anchor(h, 3)
    assert.equal(3, row)
    assert.is_false(above)
  end)

  it("anchors a deletion of the last line, when the next line does not exist", function()
    local h = hunk({ base_start = 3, base_count = 1, cur_start = 2, base_lines = { "c" } })
    local row, above = hunks.anchor(h, 2)
    assert.equal(2, row)
    assert.is_false(above)
  end)

  it("anchors on line 1, above, when the buffer is empty", function()
    local h = hunk({ base_start = 1, base_count = 2, base_lines = { "a", "b" } })
    local row, above = hunks.anchor(h, 0)
    assert.equal(1, row)
    assert.is_true(above)
  end)
end)

describe("review.hunks.find", function()
  local changed = hunk({
    base_start = 3,
    base_count = 1,
    cur_start = 3,
    cur_count = 2,
    base_lines = { "c" },
    cur_lines = { "x", "y" },
  })

  it("returns nil when there are no hunks", function()
    assert.is_nil(hunks.find({}, 1))
  end)

  it("covers cur_start .. cur_start + cur_count - 1 and nothing around", function()
    local list = { changed }
    assert.is_nil(hunks.find(list, 2))
    assert.equal(1, hunks.find(list, 3))
    assert.equal(1, hunks.find(list, 4))
    assert.is_nil(hunks.find(list, 5))
  end)

  it("puts a pure deletion on the line its virtual lines hang above", function()
    local deletion = hunk({ base_start = 3, base_count = 1, cur_start = 2, base_lines = { "c" } })
    local list = { deletion }
    assert.is_nil(hunks.find(list, 2, 5))
    assert.equal(1, hunks.find(list, 3, 5))
    assert.is_nil(hunks.find(list, 4, 5))
  end)

  it("puts a deleted file tail on the last line", function()
    local tail = hunk({ base_start = 4, base_count = 2, cur_start = 3, base_lines = { "d", "e" } })
    assert.equal(1, hunks.find({ tail }, 3, 3))
    assert.is_nil(hunks.find({ tail }, 4, 3))
  end)

  it("puts a deletion in an empty buffer on line 1", function()
    local all_gone = hunk({ base_start = 1, base_count = 2, base_lines = { "a", "b" } })
    assert.equal(1, hunks.find({ all_gone }, 1, 0))
  end)

  it("puts a deletion at the top on line 1", function()
    local first_gone = hunk({ base_start = 1, base_count = 1, base_lines = { "a" } })
    assert.equal(1, hunks.find({ first_gone }, 1, 2))
  end)

  it("assumes the next line exists when line_count is not given", function()
    local deletion = hunk({ base_start = 3, base_count = 1, cur_start = 2, base_lines = { "c" } })
    assert.equal(1, hunks.find({ deletion }, 3))
  end)

  it("picks the right hunk among several", function()
    local first =
      hunk({ base_start = 1, base_count = 1, cur_start = 1, cur_count = 1, base_lines = { "a" }, cur_lines = { "A" } })
    local second =
      hunk({ base_start = 5, base_count = 1, cur_start = 5, cur_count = 1, base_lines = { "e" }, cur_lines = { "E" } })
    local list = { first, second }
    assert.equal(1, hunks.find(list, 1, 6))
    assert.is_nil(hunks.find(list, 3, 6))
    assert.equal(2, hunks.find(list, 5, 6))
  end)
end)

describe("review.hunks.word_diff", function()
  ---@param old_line string
  ---@param new_line string
  local function assert_whole_line(old_line, new_line)
    local old_ranges, new_ranges = hunks.word_diff(old_line, new_line)
    assert.is_nil(old_ranges)
    assert.is_nil(new_ranges)
  end

  it("returns empty ranges for identical lines", function()
    local old_ranges, new_ranges = hunks.word_diff("foo bar", "foo bar")
    assert.same({}, old_ranges)
    assert.same({}, new_ranges)
  end)

  it("marks the changed word on both sides", function()
    local old_ranges, new_ranges = hunks.word_diff("foo bar baz", "foo qux baz")
    assert.same({ { 4, 7 } }, old_ranges)
    assert.same({ { 4, 7 } }, new_ranges)
  end)

  it("marks only the new text for a pure insertion", function()
    local old_ranges, new_ranges = hunks.word_diff("hello world", "hello world again")
    assert.same({}, old_ranges)
    assert.same({ { 11, 17 } }, new_ranges)
  end)

  it("marks only the old text for a pure deletion", function()
    local old_ranges, new_ranges = hunks.word_diff("hello world again", "hello world")
    assert.same({ { 11, 17 } }, old_ranges)
    assert.same({}, new_ranges)
  end)

  it("joins a run of changed tokens into one range", function()
    local old_ranges, new_ranges = hunks.word_diff("foo bar baz", "foo x-yy baz")
    assert.same({ { 4, 7 } }, old_ranges)
    assert.same({ { 4, 8 } }, new_ranges)
  end)

  it("keeps separate ranges for changes that have unchanged text between them", function()
    local old_ranges, new_ranges = hunks.word_diff("x = foo + bar", "x = qux + zip")
    assert.same({ { 4, 7 }, { 10, 13 } }, old_ranges)
    assert.same({ { 4, 7 }, { 10, 13 } }, new_ranges)
  end)

  it("treats punctuation as one token per sign", function()
    local old_ranges, new_ranges = hunks.word_diff("foo(bar)", "foo(baz)")
    assert.same({ { 4, 7 } }, old_ranges)
    assert.same({ { 4, 7 } }, new_ranges)
  end)

  it("treats underscores as part of a word", function()
    local old_ranges, new_ranges = hunks.word_diff("foo_bar baz qux", "foo_qux baz qux")
    assert.same({ { 0, 7 } }, old_ranges)
    assert.same({ { 0, 7 } }, new_ranges)
  end)

  it("treats a run of spaces as one token", function()
    local old_ranges, new_ranges = hunks.word_diff("a  b", "a b")
    assert.same({ { 1, 3 } }, old_ranges)
    assert.same({ { 1, 2 } }, new_ranges)
  end)

  it("counts bytes, not characters, for Cyrillic", function()
    local old_ranges, new_ranges = hunks.word_diff("привет мир", "привет всем")
    assert.same({ { 13, 19 } }, old_ranges)
    assert.same({ { 13, 21 } }, new_ranges)
  end)

  it("never cuts a multibyte character in the middle of a word", function()
    local old_ranges, new_ranges = hunks.word_diff("я сказал привет", "я сказал приказ")
    assert.same({ { 16, 28 } }, old_ranges)
    assert.same({ { 16, 28 } }, new_ranges)
  end)

  it("highlights the line as a whole when nothing is shared", function()
    assert_whole_line("foo", "bar")
  end)

  it("highlights the line as a whole when less than 40% is unchanged", function()
    -- 3 unchanged bytes of 10
    assert_whole_line("ab xxxxxxx", "ab yyyyyyy")
  end)

  it("keeps word ranges when exactly 40% is unchanged", function()
    -- 4 unchanged bytes of 10
    local old_ranges, new_ranges = hunks.word_diff("abc xxxxxx", "abc yyyyyy")
    assert.same({ { 4, 10 } }, old_ranges)
    assert.same({ { 4, 10 } }, new_ranges)
  end)

  it("measures the unchanged share against the longer line", function()
    -- 11 unchanged bytes of 36
    assert_whole_line("hello world", "hello world and many more words here")
  end)
end)

describe("review.hunks.pairs", function()
  it("pairs the i-th base line with the i-th Claude line", function()
    local h = hunk({
      base_start = 1,
      base_count = 2,
      cur_start = 1,
      cur_count = 2,
      base_lines = { "foo bar baz", "see the old text here" },
      cur_lines = { "foo qux baz", "see the new text here" },
    })
    assert.same({
      { base = 1, cur = 1, base_ranges = { { 4, 7 } }, cur_ranges = { { 4, 7 } } },
      { base = 2, cur = 2, base_ranges = { { 8, 11 } }, cur_ranges = { { 8, 11 } } },
    }, hunks.pairs(h))
  end)

  it("skips pairs highlighted as a whole line", function()
    local h = hunk({
      base_start = 1,
      base_count = 2,
      cur_start = 1,
      cur_count = 2,
      base_lines = { "alpha", "foo bar baz" },
      cur_lines = { "omega", "foo qux baz" },
    })
    assert.same({
      { base = 2, cur = 2, base_ranges = { { 4, 7 } }, cur_ranges = { { 4, 7 } } },
    }, hunks.pairs(h))
  end)

  it("pairs only up to the shorter side", function()
    local h = hunk({
      base_start = 1,
      base_count = 1,
      cur_start = 1,
      cur_count = 3,
      base_lines = { "foo bar baz" },
      cur_lines = { "foo qux baz", "second", "third" },
    })
    assert.same({
      { base = 1, cur = 1, base_ranges = { { 4, 7 } }, cur_ranges = { { 4, 7 } } },
    }, hunks.pairs(h))
  end)

  it("returns nothing for a pure insertion or deletion", function()
    local insertion = hunk({ base_start = 1, cur_start = 2, cur_count = 1, cur_lines = { "x" } })
    local deletion = hunk({ base_start = 2, base_count = 1, cur_start = 1, base_lines = { "x" } })
    assert.same({}, hunks.pairs(insertion))
    assert.same({}, hunks.pairs(deletion))
  end)
end)
