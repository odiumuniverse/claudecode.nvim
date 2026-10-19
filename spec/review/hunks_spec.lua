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
