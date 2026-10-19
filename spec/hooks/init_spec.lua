--- Tests for wiring the review hooks into Claude sessions started from Neovim.
local hooks = require("claudecode.hooks")
local store_mod = require("claudecode.review.store")

describe("review hooks wiring", function()
  local state

  before_each(function()
    state = vim.fn.tempname()
    hooks.setup({ state_root = state })
  end)

  after_each(function()
    hooks.disable()
    vim.fn.delete(state, "rf")
  end)

  it("leaves the command alone until the review is set up", function()
    hooks.disable()
    local env = {}

    assert.is_nil(hooks.decorate("claude", "--resume", env))
    assert.same({}, env)
  end)

  it("adds --settings right after the claude command and passes the state directory", function()
    local env = { FOO = "1" }

    local cmd = hooks.decorate("claude", "--resume", env)

    assert.equal("claude --settings " .. vim.fn.shellescape(hooks.settings_file()) .. " --resume", cmd)
    assert.equal("1", env.FOO)
    assert.equal(hooks.state_dir(vim.fn.getcwd()), env.CLAUDECODE_REVIEW_DIR)
    assert.equal(vim.v.servername, env.CLAUDECODE_NVIM)
  end)

  it("tells the hooks whether manual mode should open edits for review first", function()
    local env = {}
    hooks.decorate("claude", nil, env)
    assert.equal("1", env.CLAUDECODE_REVIEW_BEFORE_WRITE)

    hooks.setup({ state_root = state, before_write = false })
    env = {}
    hooks.decorate("claude", nil, env)
    assert.is_nil(env.CLAUDECODE_REVIEW_BEFORE_WRITE)
  end)

  it("keys the state directory by project", function()
    assert.are_not.equal(hooks.state_dir("/a"), hooks.state_dir("/b"))
    assert.equal(hooks.state_dir("/a"), hooks.state_dir("/a"))
  end)

  it("registers the hooks for edits, Bash and prompts", function()
    hooks.decorate("claude", nil, {})
    local settings = vim.json.decode(table.concat(vim.fn.readfile(hooks.settings_file()), "\n"))

    for _, event in ipairs({ "PreToolUse", "PostToolUse", "UserPromptSubmit" }) do
      local entry = settings.hooks[event][1]
      assert.equal("command", entry.hooks[1].type)
      assert.matches("hooks/run%.lua' " .. event .. "$", entry.hooks[1].command)
      assert.is_true(entry.hooks[1].timeout > 0)
    end
    assert.equal("Edit|Write|MultiEdit|NotebookEdit|Bash", settings.hooks.PreToolUse[1].matcher)
  end)

  it("writes a command the shell can run as is", function()
    local env = {}
    hooks.decorate("claude", nil, env)
    local settings = vim.json.decode(table.concat(vim.fn.readfile(hooks.settings_file()), "\n"))
    local work = vim.fn.tempname()
    vim.fn.mkdir(work, "p")
    vim.fn.writefile({ "before" }, work .. "/a.txt")

    local res = vim
      .system({ "sh", "-c", settings.hooks.PreToolUse[1].hooks[1].command }, {
        stdin = vim.json.encode({ tool_name = "Edit", tool_input = { file_path = work .. "/a.txt" }, cwd = work }),
        env = { CLAUDECODE_REVIEW_DIR = env.CLAUDECODE_REVIEW_DIR },
      })
      :wait()

    assert.equal(0, res.code)
    assert.equal("before\n", store_mod.new(env.CLAUDECODE_REVIEW_DIR):get(work .. "/a.txt").text)
    vim.fn.delete(work, "rf")
  end)
end)
