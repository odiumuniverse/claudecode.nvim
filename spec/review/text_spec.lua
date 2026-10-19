--- Tests for converting file bytes to buffer lines and back.
local text = require("claudecode.review.text")

describe("review text", function()
  it("splits text into lines and notes the final newline", function()
    local lines, eol = text.to_lines("a\nb\n")
    assert.same({ "a", "b" }, lines)
    assert.is_true(eol)

    lines, eol = text.to_lines("a\nb")
    assert.same({ "a", "b" }, lines)
    assert.is_false(eol)
  end)

  it("gives no lines for an empty file", function()
    local lines, eol = text.to_lines("")
    assert.same({}, lines)
    assert.is_false(eol)
  end)

  it("strips carriage returns for a dos buffer only", function()
    assert.same({ "a", "b" }, (text.to_lines("a\r\nb\r\n", true)))
    assert.same({ "a\r", "b\r" }, (text.to_lines("a\r\nb\r\n", false)))
  end)

  it("joins lines back into the same bytes", function()
    assert.equal("a\nb\n", text.to_text({ "a", "b" }, true))
    assert.equal("a\nb", text.to_text({ "a", "b" }, false))
    assert.equal("a\r\nb\r\n", text.to_text({ "a", "b" }, true, true))
    assert.equal("", text.to_text({}, true))
  end)

  it("reads the lines of a buffer as they would be written", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x", "y" })
    vim.bo[buf].eol = false
    vim.bo[buf].fixeol = false

    assert.equal("x\ny", text.buffer_text(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
