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

  describe("the encoding of a file nobody has loaded", function()
    ---`detect` answers as ':edit' would, whatever the user's 'fileencodings'.
    local function with_fileencodings(value, action)
      local saved = vim.o.fileencodings
      vim.o.fileencodings = value
      local ok, err = pcall(action)
      vim.o.fileencodings = saved
      assert(ok, tostring(err))
    end

    it("is UTF-8 for plain ASCII and for UTF-8 text", function()
      assert.same({ "utf-8", false }, { text.detect("a\nb\n") })
      assert.same({ "utf-8", false }, { text.detect("caf\195\169\n") })
    end)

    it("is UTF-8 with a mark when the file starts with one", function()
      assert.same({ "utf-8", true }, { text.detect("\239\187\191a\n") })
    end)

    it("is UTF-16 when the mark says so", function()
      assert.same({ "utf-16le", true }, { text.detect("\255\254a\0\n\0") })
      assert.same({ "utf-16be", true }, { text.detect("\254\255\0a\0\n") })
    end)

    it("is the next encoding in 'fileencodings' when the bytes are not UTF-8", function()
      with_fileencodings("ucs-bom,utf-8,latin1", function()
        assert.same({ "latin1", false }, { text.detect("caf\233\n") })
      end)
      with_fileencodings("ucs-bom,utf-8,cp1251", function()
        assert.same({ "cp1251", false }, { text.detect("\207\240\232\226\229\242\n") })
      end)
    end)

    it("is UTF-8 when nothing in 'fileencodings' fits", function()
      with_fileencodings("ucs-bom,utf-8", function()
        assert.same({ "utf-8", false }, { text.detect("caf\233\n") })
      end)
    end)

    it("leaves the mark as text when 'fileencodings' has no ucs-bom", function()
      with_fileencodings("utf-8,latin1", function()
        assert.same({ "utf-8", false }, { text.detect("\239\187\191a\n") })
      end)
    end)

    it("brings the text to UTF-8 and the mark off", function()
      assert.equal("caf\195\169\n", text.decode_as("caf\233\n", "latin1", false))
      assert.equal("a\n", text.decode_as("\239\187\191a\n", "utf-8", true))
      assert.equal("a\n", text.decode_as("\255\254a\0\n\0", "utf-16le", true))
      assert.equal("a\n", text.decode_as("a\n", "", false))
    end)
  end)

  it("reads the lines of a buffer as they would be written", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x", "y" })
    vim.bo[buf].eol = false
    vim.bo[buf].fixeol = false

    assert.equal("x\ny", text.buffer_text(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("tells an emptied buffer from a file holding one empty line", function()
    local file = vim.fn.tempname()
    local f = assert(io.open(file, "wb"))
    f:write("\n")
    f:close()
    vim.cmd.edit(file)
    local buf = vim.api.nvim_get_current_buf()
    assert.equal("\n", text.buffer_text(buf))

    -- Emptied lines write zero bytes, whether set to {} or to {""}.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    assert.equal("", text.buffer_text(buf))
    vim.cmd("bwipeout!")
    vim.fn.delete(file)
  end)
end)
