--- Tests for how Claude's permission mode picks the review: before write, after write, or none.
local store_mod = require("claudecode.review.store")

local script = vim.fn.fnamemodify(package.searchpath("claudecode.hooks.run", package.path), ":p")

local function write_file(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

describe("review by permission mode", function()
  local dir, work, store

  local function run_hook(event, input, env)
    local res = vim
      .system({ vim.v.progpath, "--clean", "--headless", "-l", script, event }, {
        stdin = vim.json.encode(input),
        -- NVIM would point at this test Neovim, which cannot answer while it waits for the hook.
        env = vim.tbl_extend(
          "force",
          { CLAUDECODE_REVIEW_DIR = dir, CLAUDECODE_REVIEW_BEFORE_WRITE = "1", NVIM = "" },
          env or {}
        ),
        text = true,
      })
      :wait()
    assert.equal(0, res.code)
    return res.stdout ~= "" and vim.json.decode(res.stdout) or nil
  end

  local function edit(event, mode, path, extra)
    return vim.tbl_extend("force", {
      session_id = "s1",
      cwd = work,
      hook_event_name = event,
      tool_name = "Edit",
      tool_input = { file_path = path },
      tool_use_id = "toolu_1",
      permission_mode = mode,
    }, extra or {})
  end

  local function decision(out)
    return out and out.hookSpecificOutput and out.hookSpecificOutput.permissionDecision
  end

  before_each(function()
    dir = vim.fn.tempname()
    work = vim.fn.tempname()
    vim.fn.mkdir(work, "p")
    work = vim.uv.fs_realpath(work)
    store = store_mod.new(dir)
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
    vim.fn.delete(work, "rf")
  end)

  it("asks before every edit in manual mode, so the proposal opens in Neovim", function()
    local file = work .. "/a.txt"
    write_file(file, "one\n")

    for _, mode in ipairs({ "default", "manual" }) do
      local out = run_hook("PreToolUse", edit("PreToolUse", mode, file))
      assert.equal("ask", decision(out), mode)
      assert.equal("PreToolUse", out.hookSpecificOutput.hookEventName)
    end
    assert.equal("one\n", store:get(file).text)
  end)

  it("notes which tool asks, since Claude Code writes the answer to an Edit and a Write differently", function()
    local file = work .. "/a.txt"
    write_file(file, "one\n")

    run_hook("PreToolUse", edit("PreToolUse", "default", file, { tool_name = "Write" }))

    assert.equal("Write", store:edit_tool(file, 3600))
  end)

  it("lets Claude edit on its own in the other modes", function()
    local file = work .. "/a.txt"
    write_file(file, "one\n")

    for _, mode in ipairs({ "auto", "bypassPermissions", "dontAsk", "acceptEdits", "plan", "somethingNew" }) do
      assert.is_nil(decision(run_hook("PreToolUse", edit("PreToolUse", mode, file))), mode)
    end
    assert.is_nil(decision(run_hook("PreToolUse", edit("PreToolUse", nil, file))))
  end)

  it("does not ask when review before write is off", function()
    local file = work .. "/a.txt"
    write_file(file, "one\n")

    local out = run_hook("PreToolUse", edit("PreToolUse", "default", file), { CLAUDECODE_REVIEW_BEFORE_WRITE = "" })

    assert.is_nil(decision(out))
  end)

  it("never asks for Bash", function()
    local out = run_hook("PreToolUse", {
      cwd = work,
      tool_name = "Bash",
      tool_input = { command = "ls" },
      tool_use_id = "toolu_2",
      permission_mode = "default",
    })

    assert.is_nil(decision(out))
  end)

  it("takes no base in plan mode, so the plan file Claude writes stays out of review", function()
    local file = work .. "/plan.md"

    run_hook("PreToolUse", edit("PreToolUse", "plan", file, { tool_name = "Write" }))
    write_file(file, "# Plan\n")
    run_hook("PostToolUse", edit("PostToolUse", "plan", file, { tool_name = "Write" }))

    assert.is_nil(store:get(file))
  end)

  describe("in accept-edits mode", function()
    it("takes no base, so the edit leaves no hunk", function()
      local file = work .. "/a.txt"
      write_file(file, "one\n")

      run_hook("PreToolUse", edit("PreToolUse", "acceptEdits", file))
      write_file(file, "two\n")
      run_hook("PostToolUse", edit("PostToolUse", "acceptEdits", file))

      assert.is_nil(store:get(file))
    end)

    it("carries the edit into an existing base and keeps the hunks still pending", function()
      local file = work .. "/a.txt"
      write_file(file, "a\nb\nc\nd\ne\n")
      store:snapshot(file)
      write_file(file, "A\nb\nc\nd\ne\n") -- an earlier edit in auto mode, still pending

      run_hook("PreToolUse", edit("PreToolUse", "acceptEdits", file))
      write_file(file, "A\nb\nc\nd\nE\n")
      run_hook("PostToolUse", edit("PostToolUse", "acceptEdits", file))

      assert.equal("a\nb\nc\nd\nE\n", store:get(file).text)
    end)

    it("keeps the sessions of the base it moves along, and does not add its own", function()
      local file = work .. "/a.txt"
      write_file(file, "a\nb\nc\nd\ne\n")
      store:snapshot(file, "sA")
      write_file(file, "A\nb\nc\nd\ne\n")

      run_hook("PreToolUse", edit("PreToolUse", "acceptEdits", file))
      write_file(file, "A\nb\nc\nd\nE\n")
      run_hook("PostToolUse", edit("PostToolUse", "acceptEdits", file))

      -- the hunk still waiting is sA's: s1 took its own edit without review
      assert.same({ "sA" }, store:get(file).sessions)
    end)

    it("leaves an edit of a new file still under review inside its one big hunk", function()
      local file = work .. "/new.txt"
      store:snapshot(file)
      write_file(file, "first\n")

      run_hook("PreToolUse", edit("PreToolUse", "acceptEdits", file))
      write_file(file, "first\nsecond\n")
      run_hook("PostToolUse", edit("PostToolUse", "acceptEdits", file))

      local base = store:get(file)
      assert.is_true(base.new_file)
      assert.equal("", base.text)
    end)

    it("leaves Bash's edits out of review and moves an existing base along", function()
      local function git(...)
        local res = vim.system({ "git", "-C", work, ... }, { text = true }):wait()
        assert(res.code == 0, res.stderr)
      end
      git("init", "-q")
      git("config", "user.email", "t@example.com")
      git("config", "user.name", "t")
      write_file(work .. "/pending.txt", "a\nb\nc\nd\ne\n")
      write_file(work .. "/fresh.txt", "x\n")
      git("add", ".")
      git("commit", "-qm", "init")
      store:snapshot(work .. "/pending.txt")
      write_file(work .. "/pending.txt", "A\nb\nc\nd\ne\n") -- pending from an earlier turn
      local bash = {
        cwd = work,
        tool_name = "Bash",
        tool_input = { command = "sed" },
        tool_use_id = "toolu_3",
        permission_mode = "acceptEdits",
      }

      run_hook("PreToolUse", bash)
      write_file(work .. "/pending.txt", "A\nb\nc\nd\nE\n")
      write_file(work .. "/fresh.txt", "y\n")
      write_file(work .. "/created.txt", "new\n")
      run_hook("PostToolUse", bash)

      assert.equal("a\nb\nc\nd\nE\n", store:get(work .. "/pending.txt").text)
      assert.is_nil(store:get(work .. "/fresh.txt"))
      assert.is_nil(store:get(work .. "/created.txt"))
    end)
  end)
end)
