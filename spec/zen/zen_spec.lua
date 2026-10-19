--- Tests for zen mode: Claude full screen in its own tab, the code one key away.
local zen = require("claudecode.zen")

describe("zen", function()
  local term_buf, fake_terminal, real_terminal

  -- Stand-in for claudecode.terminal: a real terminal buffer shown in a right split.
  local function make_fake_terminal()
    local fake = { opened = 0 }
    function fake.get_active_terminal_bufnr()
      if term_buf and vim.api.nvim_buf_is_valid(term_buf) then
        return term_buf
      end
      return nil
    end
    function fake.ensure_visible()
      fake.opened = fake.opened + 1
      local prev = vim.api.nvim_get_current_win()
      if not term_buf or not vim.api.nvim_buf_is_valid(term_buf) then
        vim.cmd("botright vsplit")
        vim.cmd("enew")
        term_buf = vim.api.nvim_get_current_buf()
        vim.fn.jobstart({ "sh", "-c", "sleep 30" }, { term = true })
      elseif #vim.fn.win_findbuf(term_buf) == 0 then
        vim.cmd("botright vsplit")
        vim.api.nvim_win_set_buf(0, term_buf)
      end
      vim.api.nvim_set_current_win(prev)
    end
    return fake
  end

  local function windows_showing(buf, tab)
    local wins = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(win) == buf then
        wins[#wins + 1] = win
      end
    end
    return wins
  end

  before_each(function()
    real_terminal = package.loaded["claudecode.terminal"]
    fake_terminal = make_fake_terminal()
    package.loaded["claudecode.terminal"] = fake_terminal
    vim.o.showtabline = 1
    zen.setup({})
  end)

  after_each(function()
    zen.teardown()
    package.loaded["claudecode.terminal"] = real_terminal
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    if term_buf and vim.api.nvim_buf_is_valid(term_buf) then
      vim.api.nvim_buf_delete(term_buf, { force = true })
    end
    term_buf = nil
  end)

  it("shows Claude alone in its own tab and takes it out of the code tab", function()
    local work_tab = vim.api.nvim_get_current_tabpage()
    fake_terminal.ensure_visible()

    zen.enter()

    local zen_tab = vim.api.nvim_get_current_tabpage()
    assert.are_not.equal(work_tab, zen_tab)
    assert.is_true(zen.is_active())
    local wins = vim.api.nvim_tabpage_list_wins(zen_tab)
    assert.equal(1, #wins)
    assert.equal(term_buf, vim.api.nvim_win_get_buf(wins[1]))
    -- A terminal sized by its widest window would garble the narrow split: one window only.
    assert.same({}, windows_showing(term_buf, work_tab))
    assert.equal(0, vim.o.showtabline)
  end)

  it("starts Claude when it is not running yet", function()
    zen.enter()

    assert.is_true(zen.is_active())
    assert.equal(term_buf, vim.api.nvim_get_current_buf())
  end)

  it("goes back to the code with Claude in its split and the cursor in the code", function()
    local work_tab = vim.api.nvim_get_current_tabpage()
    local code_win = vim.api.nvim_get_current_win()
    fake_terminal.ensure_visible()
    zen.enter()

    zen.leave()

    assert.is_false(zen.is_active())
    assert.equal(work_tab, vim.api.nvim_get_current_tabpage())
    assert.equal(1, #vim.api.nvim_list_tabpages())
    assert.equal(1, #windows_showing(term_buf, work_tab))
    assert.equal(code_win, vim.api.nvim_get_current_win())
    assert.equal(1, vim.o.showtabline)
  end)

  it("toggles between the two states", function()
    fake_terminal.ensure_visible()

    zen.toggle()
    assert.is_true(zen.is_active())
    zen.toggle()
    assert.is_false(zen.is_active())
  end)

  it("builds a code tab when Claude was started straight into zen", function()
    zen.enter()
    vim.cmd("tabonly") -- cz: the zen tab is the only one

    zen.leave()

    assert.is_false(zen.is_active())
    assert.equal(1, #vim.api.nvim_list_tabpages())
    assert.equal(1, #windows_showing(term_buf, vim.api.nvim_get_current_tabpage()))
    assert.are_not.equal(term_buf, vim.api.nvim_get_current_buf())
  end)

  it("handles Claude being the only window of the code tab", function()
    fake_terminal.ensure_visible()
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(term_buf)[1])
    vim.cmd("only")

    zen.enter()
    zen.leave()

    assert.equal(1, #windows_showing(term_buf, vim.api.nvim_get_current_tabpage()))
  end)

  describe("with several tabs", function()
    ---A first tab with some other work, and the code tab where Claude sits in its split.
    local function two_code_tabs()
      local first_tab = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      local work_tab = vim.api.nvim_get_current_tabpage()
      fake_terminal.ensure_visible()
      return first_tab, work_tab
    end

    it("comes back to the tab zen was started from, not to the first one", function()
      local first_tab, work_tab = two_code_tabs()
      local code_win = vim.api.nvim_get_current_win()

      zen.enter()
      assert.equal(3, #vim.api.nvim_list_tabpages())
      zen.leave()

      assert.equal(work_tab, vim.api.nvim_get_current_tabpage())
      assert.equal(code_win, vim.api.nvim_get_current_win())
      assert.equal(2, #vim.api.nvim_list_tabpages())
      assert.same({}, windows_showing(term_buf, first_tab))
      assert.equal(1, #windows_showing(term_buf, work_tab))
    end)

    it("takes Claude out of every code tab, and puts it back in one only", function()
      local first_tab, work_tab = two_code_tabs()
      vim.api.nvim_set_current_tabpage(first_tab)
      vim.cmd("botright vsplit")
      vim.api.nvim_win_set_buf(0, term_buf)
      vim.api.nvim_set_current_tabpage(work_tab)

      zen.enter()

      assert.same({}, windows_showing(term_buf, first_tab))
      assert.same({}, windows_showing(term_buf, work_tab))
      zen.leave()
      assert.equal(1, #windows_showing(term_buf, work_tab))
      assert.same({}, windows_showing(term_buf, first_tab))
    end)

    it("builds a new code tab when the one zen came from is closed meanwhile", function()
      local first_tab, work_tab = two_code_tabs()
      zen.enter()

      vim.cmd(vim.api.nvim_tabpage_get_number(work_tab) .. "tabclose")
      assert.is_true(zen.is_active())
      zen.leave()

      assert.is_false(zen.is_active())
      assert.equal(2, #vim.api.nvim_list_tabpages())
      assert.are_not.equal(first_tab, vim.api.nvim_get_current_tabpage())
      assert.equal(1, #windows_showing(term_buf, vim.api.nvim_get_current_tabpage()))
      assert.equal(1, vim.o.showtabline)
    end)

    it("survives :tabonly in zen and builds a code tab on leave", function()
      two_code_tabs()
      zen.enter()

      vim.cmd("tabonly")
      zen.leave()

      assert.is_false(zen.is_active())
      assert.equal(1, #vim.api.nvim_list_tabpages())
      assert.equal(1, #windows_showing(term_buf, vim.api.nvim_get_current_tabpage()))
      assert.equal(1, vim.o.showtabline)
    end)

    it("gives the screen back when you close the zen tab yourself", function()
      two_code_tabs()
      zen.enter()

      vim.cmd("tabclose")

      assert.is_false(zen.is_active())
      assert.equal(1, vim.o.showtabline)
      -- and zen works again afterwards
      zen.enter()
      assert.is_true(zen.is_active())
    end)

    it("does not leave a second zen tab behind when zen is entered from another tab", function()
      local first_tab = two_code_tabs()
      zen.enter()
      vim.api.nvim_set_current_tabpage(first_tab) -- gt, while zen is still there

      zen.enter()

      assert.equal(1, #vim.tbl_filter(function(tab)
        return #windows_showing(term_buf, tab) > 0
      end, vim.api.nvim_list_tabpages()))
      assert.equal(3, #vim.api.nvim_list_tabpages())
      assert.is_true(zen.is_active())
      zen.leave()
      assert.equal(first_tab, vim.api.nvim_get_current_tabpage())
    end)
  end)

  it("shows how many files wait for review above Claude", function()
    zen.enter()

    vim.api.nvim_exec_autocmds("User", { pattern = "ClaudeCodeReviewPending", data = { count = 2, files = {} } })
    assert.matches("2 files wait for review", vim.wo.winbar)

    vim.api.nvim_exec_autocmds("User", { pattern = "ClaudeCodeReviewPending", data = { count = 1, files = {} } })
    assert.matches("1 file waits for review", vim.wo.winbar)

    vim.api.nvim_exec_autocmds("User", { pattern = "ClaudeCodeReviewPending", data = { count = 0, files = {} } })
    assert.equal("", vim.wo.winbar)
  end)

  it("returns to the code when Claude exits", function()
    zen.enter()
    local job = vim.b[term_buf].terminal_job_id

    vim.fn.jobstop(job)
    vim.wait(2000, function()
      return not zen.is_active()
    end)

    assert.is_false(zen.is_active())
  end)

  it("toggles with the zen key in normal mode", function()
    fake_terminal.ensure_visible()

    vim.api.nvim_feedkeys(vim.keycode("<M-z>"), "xt", false)

    assert.is_true(zen.is_active())
  end)
end)
