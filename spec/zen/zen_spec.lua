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
