--- Tests for hunks.carry: an edit accepted without review moves the base, pending hunks stay.
local hunks = require("claudecode.review.hunks")

describe("hunks.carry", function()
  it("moves the whole edit into the base when nothing is pending", function()
    assert.same({ "a", "B", "c" }, hunks.carry({ "a", "b", "c" }, { "a", "b", "c" }, { "a", "B", "c" }))
  end)

  it("carries an edit below a pending hunk and keeps the hunk", function()
    local base = { "a", "b", "c", "d", "e" }
    local before = { "A", "b", "c", "d", "e" }
    local after = { "A", "b", "c", "d", "E" }

    local new_base = hunks.carry(base, before, after)

    assert.same({ "a", "b", "c", "d", "E" }, new_base)
    local left = hunks.compute(new_base, after)
    assert.equal(1, #left)
    assert.same({ "a" }, left[1].base_lines)
    assert.same({ "A" }, left[1].cur_lines)
  end)

  it("carries an insertion above a pending hunk", function()
    assert.same(
      { "x", "a", "b", "c", "d", "e" },
      hunks.carry({ "a", "b", "c", "d", "e" }, { "a", "b", "c", "d", "E" }, { "x", "a", "b", "c", "d", "E" })
    )
  end)

  it("carries a deletion and an insertion at the end of the file", function()
    local base = { "a", "b", "c", "d", "e" }
    local before = { "A", "b", "c", "d", "e" }

    assert.same({ "a", "b", "c", "e" }, hunks.carry(base, before, { "A", "b", "c", "e" }))
    assert.same({ "a", "b", "c", "d", "e", "f" }, hunks.carry(base, before, { "A", "b", "c", "d", "e", "f" }))
  end)

  it("leaves an edit inside a pending hunk to that hunk", function()
    assert.same({ "a", "b", "c" }, hunks.carry({ "a", "b", "c" }, { "A", "b", "c" }, { "AA", "b", "c" }))
  end)

  it("leaves an edit that touches a pending hunk to that hunk", function()
    assert.same(
      { "a", "b", "c", "d" },
      hunks.carry({ "a", "b", "c", "d" }, { "A", "b", "c", "d" }, { "A", "B", "c", "d" })
    )
  end)

  it("carries several separate edits at once", function()
    local base = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }
    local before = { "1", "2", "3", "4", "FIVE", "6", "7", "8", "9" }
    local after = { "ONE", "2", "3", "4", "FIVE", "6", "7", "8", "NINE" }

    assert.same({ "ONE", "2", "3", "4", "5", "6", "7", "8", "NINE" }, hunks.carry(base, before, after))
  end)

  it("does not change its arguments", function()
    local base, before, after = { "a", "b" }, { "a", "b" }, { "a", "c" }

    hunks.carry(base, before, after)

    assert.same({ "a", "b" }, base)
    assert.same({ "a", "b" }, before)
    assert.same({ "a", "c" }, after)
  end)
end)
