--- Review survives a restart: Claude's edit happens in one Neovim, you review it in the next.
local root = vim.fn.fnamemodify(package.searchpath("claudecode.features", package.path), ":p:h:h:h:h")

describe("review across restarts", function()
  local work, state

  -- A fresh Neovim, set up like a user's, running `code` and printing what it returns as JSON.
  local function nvim(cwd, code)
    local script = table.concat({
      "vim.opt.rtp:prepend(" .. vim.inspect(root) .. ")",
      "require('claudecode').setup({ auto_start = false })",
      "local result = (function() " .. code .. " end)()",
      "io.write(vim.json.encode(result))",
    }, "\n")
    local res = vim
      .system({ vim.v.progpath, "--clean", "--headless", "-l", "-" }, {
        cwd = cwd,
        stdin = script,
        env = { XDG_STATE_HOME = state },
        text = true,
      })
      :wait()
    assert(res.code == 0, res.stderr)
    return vim.json.decode(res.stdout)
  end

  -- What the hooks do for one Claude edit started from `cwd`.
  local function claude_edits(cwd, file, text)
    nvim(
      cwd,
      ([[
        local hooks = require("claudecode.hooks")
        local store = require("claudecode.review.store").new(hooks.state_dir(vim.fn.getcwd()))
        store:snapshot(%q)
        local f = io.open(%q, "wb") f:write(%q) f:close()
        return true
      ]]):format(file, file, text)
    )
  end

  local function reopen(cwd, file)
    return nvim(
      cwd,
      ([[
        vim.cmd.edit(%q)
        local review = require("claudecode.review")
        return { attached = review.is_attached(0), hunks = review.is_attached(0) and #review.hunks(0) or 0 }
      ]]):format(file)
    )
  end

  before_each(function()
    work = vim.fn.tempname()
    vim.fn.mkdir(work .. "/sub", "p")
    work = vim.uv.fs_realpath(work)
    state = vim.fn.tempname()
    local f = assert(io.open(work .. "/a.txt", "wb"))
    f:write("one\ntwo\n")
    f:close()
  end)

  after_each(function()
    vim.fn.delete(work, "rf")
    vim.fn.delete(state, "rf")
  end)

  it("brings the hunks back when you open the file in a new Neovim", function()
    claude_edits(work, work .. "/a.txt", "one\nTWO\n")

    assert.same({ attached = true, hunks = 1 }, reopen(work, work .. "/a.txt"))
  end)

  it("finds them from a subdirectory of the same git repository", function()
    vim.fn.mkdir(work .. "/.git", "p")
    claude_edits(work, work .. "/a.txt", "one\nTWO\n")

    assert.same({ attached = true, hunks = 1 }, reopen(work .. "/sub", work .. "/a.txt"))
  end)
end)
