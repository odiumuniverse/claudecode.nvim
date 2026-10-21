--- Tests for Neovim following Claude into a worktree and out of it.
local controller = require("claudecode.review.controller")
local worktree = require("claudecode.features.worktree")

local function git(cwd, ...)
  local res = vim.system({ "git", "-C", cwd, ... }, { text = true, env = { GIT_CONFIG_GLOBAL = "/dev/null" } }):wait()
  assert(res.code == 0, res.stderr)
end

local function write_file(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

describe("following Claude into a worktree", function()
  local start_cwd, root, main, wt, dir

  ---A hook tells the editor where Claude works now.
  local function claude_works_in(cwd, tool)
    controller.on_hook({ event = "PostToolUse", dir = dir, tool_name = tool or "Bash", cwd = cwd, files = {} })
  end

  before_each(function()
    start_cwd = vim.fn.getcwd()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/main", "p")
    root = vim.uv.fs_realpath(root)
    main = root .. "/main"
    git(main, "init", "-q")
    git(main, "config", "user.email", "t@example.com")
    git(main, "config", "user.name", "t")
    write_file(main .. "/a.txt", "1\n2\n3\n4\n5\n")
    git(main, "add", "a.txt")
    git(main, "commit", "-qm", "init")
    wt = root .. "/feat"
    git(main, "worktree", "add", "-q", wt, "-b", "feat")
    dir = vim.fn.tempname()
    controller.setup({ dir = dir })
    worktree.setup({ follow = true })
    vim.cmd.cd(root)
  end)

  after_each(function()
    worktree.teardown()
    controller.teardown()
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.cmd.cd(start_cwd)
    vim.fn.delete(root, "rf")
    vim.fn.delete(dir, "rf")
  end)

  it("takes Neovim and the files you look at into the worktree Claude enters, and back once it leaves", function()
    vim.cmd.edit(main .. "/a.txt")
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    claude_works_in(wt, "EnterWorktree")

    assert.equal(wt, vim.fn.getcwd())
    assert.equal(wt .. "/a.txt", vim.api.nvim_buf_get_name(0))
    assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))

    claude_works_in(main, "ExitWorktree")

    assert.equal(root, vim.fn.getcwd())
    assert.equal(main .. "/a.txt", vim.api.nvim_buf_get_name(0))
  end)

  it("leaves a buffer with unsaved edits and a file the worktree does not have where they are", function()
    write_file(main .. "/only-here.txt", "x\n")
    vim.cmd.edit(main .. "/a.txt")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "mine" })
    vim.cmd("vsplit " .. vim.fn.fnameescape(main .. "/only-here.txt"))

    claude_works_in(wt, "EnterWorktree")

    local names = vim.tbl_map(function(win)
      return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    end, vim.api.nvim_tabpage_list_wins(0))
    table.sort(names)
    assert.same({ main .. "/a.txt", main .. "/only-here.txt" }, names)
    assert.equal(wt, vim.fn.getcwd())
  end)

  it("leaves a file of another worktree alone, and brings back exactly the windows it moved", function()
    -- Another Claude session may work in a third worktree of the same repository.
    local other = root .. "/other"
    git(main, "worktree", "add", "-q", other, "-b", "other")
    vim.cmd.edit(other .. "/a.txt")
    vim.cmd("vsplit " .. vim.fn.fnameescape(main .. "/a.txt"))
    local moved = vim.api.nvim_get_current_win()

    claude_works_in(wt, "EnterWorktree")
    local function shown()
      local names = {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        names[#names + 1] = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
      end
      table.sort(names)
      return names
    end
    assert.same({ wt .. "/a.txt", other .. "/a.txt" }, shown())
    assert.equal(wt .. "/a.txt", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(moved)))

    claude_works_in(other, "EnterWorktree")
    claude_works_in(root)

    assert.same({ main .. "/a.txt", other .. "/a.txt" }, shown())
    assert.equal(main .. "/a.txt", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(moved)))
  end)

  it("stays where you went yourself once Claude leaves", function()
    claude_works_in(wt, "EnterWorktree")
    vim.cmd.cd(main)

    claude_works_in(main, "ExitWorktree")

    assert.equal(main, vim.fn.getcwd())
  end)

  it("stays put with follow = false, and for a Claude that only goes into another repository", function()
    worktree.setup({ follow = false })
    claude_works_in(wt, "EnterWorktree")
    assert.equal(root, vim.fn.getcwd())

    worktree.setup({ follow = true })
    claude_works_in(main)
    assert.equal(root, vim.fn.getcwd())
  end)

  it("goes back once Claude's terminal closes in the worktree", function()
    vim.cmd("new")
    local job = vim.fn.jobstart({ "sleep", "30" }, { term = true })
    local term = vim.api.nvim_get_current_buf()
    vim.cmd("wincmd p")
    local terminal = require("claudecode.terminal")
    local active = terminal.get_active_terminal_bufnr
    terminal.get_active_terminal_bufnr = function()
      return term
    end
    claude_works_in(wt, "EnterWorktree")
    assert.equal(wt, vim.fn.getcwd())

    vim.fn.jobstop(job)
    vim.wait(2000, function()
      return vim.fn.getcwd() == root
    end, 10)
    terminal.get_active_terminal_bufnr = active

    assert.equal(root, vim.fn.getcwd())
  end)
end)
