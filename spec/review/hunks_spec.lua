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
