--- Deleted lines above line 1 are virtual lines that Neovim hides unless the window scrolls
--- up into them ('topfill'). Found in the end-to-end run: a proposal that changed line 1 showed
--- Claude's new text without the old one above it.
local engine = require("claudecode.review")

describe("deleted lines above the first line", function()
  local buf

  before_each(function()
    engine.setup({})
    vim.cmd("enew")
    buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
  end)

  after_each(function()
    if engine.is_attached(buf) then
      engine.detach(buf)
    end
    vim.cmd("silent! bwipeout! " .. buf)
  end)

  it("scroll into view when the window shows the top of the buffer", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "ALPHA", "beta" })

    engine.attach(buf, { "alpha", "old", "beta" }, { write_on_revert = false })
    vim.wait(50)

    assert.equal(2, vim.fn.winsaveview().topfill)
  end)

  it("leave a window that is scrolled further down alone", function()
    local lines = { "ALPHA" }
    for i = 2, 200 do
      lines[i] = "line " .. i
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { 150, 0 })
    vim.cmd("normal! zt")
    local base = vim.deepcopy(lines)
    base[1] = "alpha"

    engine.attach(buf, base, { write_on_revert = false })
    vim.wait(50)

    assert.equal(150, vim.fn.line("w0"))
    assert.equal(0, vim.fn.winsaveview().topfill)
  end)
end)
