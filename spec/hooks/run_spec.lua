--- Tests for the hook entry script: Claude Code pipes hook JSON to it on stdin.
local store_mod = require("claudecode.review.store")

local script = vim.fn.fnamemodify(package.searchpath("claudecode.hooks.run", package.path), ":p")

local function write_file(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

local function git(cwd, ...)
  local res = vim.system({ "git", "-C", cwd, ... }, { text = true }):wait()
  assert(res.code == 0, res.stderr)
  return res.stdout
end

-- A separate headless Neovim standing in for your editor; its bridge stub keeps what it receives.
local function start_editor()
  local addr = vim.fn.tempname()
  local stub = "package.loaded['claudecode.review.bridge'] = { on_hook = function(p) "
    .. "vim.g.received = vim.json.encode(p) end }"
  local job = vim.fn.jobstart({ vim.v.progpath, "--clean", "--headless", "--listen", addr, "-c", "lua " .. stub })
  assert(vim.wait(5000, function()
    return vim.uv.fs_stat(addr) ~= nil
  end, 20))
  local editor = { addr = addr }
  local chan = vim.fn.sockconnect("pipe", addr, { rpc = true })

  ---Wait for the hook's message and return the payload, or nil after the timeout.
  function editor.received()
    local payload
    vim.wait(3000, function()
      local ok, got = pcall(vim.rpcrequest, chan, "nvim_get_var", "received")
      if ok and got then
        payload = vim.json.decode(got)
      end
      return payload ~= nil
    end, 20)
    return payload
  end

  function editor.stop()
    vim.fn.chanclose(chan)
    vim.fn.jobstop(job)
  end

  return editor
end

describe("hook script", function()
  local dir, work, store

  -- Run the hook the way Claude Code does and return exit code, decoded stdout and stderr.
  local function run_hook(event, input, env)
    local res = vim
      .system({ vim.v.progpath, "--clean", "--headless", "-l", script, event }, {
        stdin = vim.json.encode(input),
        -- NVIM would point at this test Neovim, which cannot answer while it waits for the hook.
        env = vim.tbl_extend("force", { CLAUDECODE_REVIEW_DIR = dir, NVIM = "" }, env or {}),
        text = true,
      })
      :wait()
    local out = res.stdout ~= "" and vim.json.decode(res.stdout) or nil
    return res.code, out, res.stderr
  end

  local function tool(event, name, tool_input, extra)
    return vim.tbl_extend("force", {
      session_id = "s1",
      cwd = work,
      hook_event_name = event,
      tool_name = name,
      tool_input = tool_input,
      tool_use_id = "toolu_01",
    }, extra or {})
  end

  before_each(function()
    dir = vim.fn.tempname()
    work = vim.fn.tempname()
    vim.fn.mkdir(work, "p")
    -- Hooks report resolved paths; $TMPDIR on macOS sits behind a symlink.
    work = vim.uv.fs_realpath(work)
    store = store_mod.new(dir)
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
    vim.fn.delete(work, "rf")
  end)

  it("snapshots a file before Claude edits it", function()
    local file = work .. "/a.lua"
    write_file(file, "old\n")

    local code, out = run_hook("PreToolUse", tool("PreToolUse", "Edit", { file_path = file }))

    assert.equal(0, code)
    assert.is_nil(out)
    assert.equal("old\n", store:get(file).text)
  end)

  it("marks a file Claude is about to create as new", function()
    local code = run_hook("PreToolUse", tool("PreToolUse", "Write", { file_path = work .. "/new.lua", content = "x" }))

    assert.equal(0, code)
    assert.is_true(store:get(work .. "/new.lua").new_file)
  end)

  it("does not snapshot a binary file", function()
    local file = work .. "/img.bin"
    write_file(file, "PNG\0\1\2")

    run_hook("PreToolUse", tool("PreToolUse", "Write", { file_path = file }))

    assert.is_nil(store:get(file))
  end)

  it("drops a base that turned out equal to the file after the edit", function()
    local file = work .. "/a.lua"
    write_file(file, "same\n")
    run_hook("PreToolUse", tool("PreToolUse", "Edit", { file_path = file }))

    local code = run_hook("PostToolUse", tool("PostToolUse", "Edit", { file_path = file }))

    assert.equal(0, code)
    assert.is_nil(store:get(file))
  end)

  it("keeps the base when the edit changed the file", function()
    local file = work .. "/a.lua"
    write_file(file, "old\n")
    run_hook("PreToolUse", tool("PreToolUse", "Edit", { file_path = file }))
    write_file(file, "new\n")

    run_hook("PostToolUse", tool("PostToolUse", "Edit", { file_path = file }))

    assert.equal("old\n", store:get(file).text)
  end)

  it("tells Claude about your reverts with the next prompt, once", function()
    store:append_revert({ path = work .. "/a.lua", line = 2, base_lines = { "a" }, claude_lines = { "b" }, time = 1 })

    local code, out = run_hook("UserPromptSubmit", { session_id = "s1", cwd = work, prompt = "go on" })

    assert.equal(0, code)
    assert.equal("UserPromptSubmit", out.hookSpecificOutput.hookEventName)
    assert.matches("a%.lua, line 2", out.hookSpecificOutput.additionalContext)
    local _, again = run_hook("UserPromptSubmit", { session_id = "s1", cwd = work, prompt = "next" })
    assert.is_nil(again)
  end)

  it("tells Claude about your reverts right after its next edit", function()
    local file = work .. "/a.lua"
    write_file(file, "x\n")
    store:append_revert({ path = file, line = 1, base_lines = { "a" }, claude_lines = { "b" }, time = 1 })

    local _, out = run_hook("PostToolUse", tool("PostToolUse", "Edit", { file_path = file }))

    assert.equal("PostToolUse", out.hookSpecificOutput.hookEventName)
    assert.matches("your text, reverted", out.hookSpecificOutput.additionalContext)
  end)

  it("exits 0 and stays silent on input it cannot parse", function()
    local res = vim
      .system({ vim.v.progpath, "--clean", "--headless", "-l", script, "PreToolUse" }, {
        stdin = "{oops",
        env = { CLAUDECODE_REVIEW_DIR = dir },
        text = true,
      })
      :wait()

    assert.equal(0, res.code)
    assert.equal("", res.stdout)
  end)

  it("does nothing outside a session started from Neovim", function()
    local file = work .. "/a.lua"
    write_file(file, "old\n")
    local res = vim
      .system({ vim.v.progpath, "--clean", "--headless", "-l", script, "PreToolUse" }, {
        stdin = vim.json.encode(tool("PreToolUse", "Edit", { file_path = file })),
        env = { CLAUDECODE_REVIEW_DIR = "" },
        text = true,
      })
      :wait()

    assert.equal(0, res.code)
    assert.is_nil(store:get(file))
  end)

  describe("around Bash", function()
    before_each(function()
      git(work, "init", "-q")
      git(work, "config", "user.email", "t@example.com")
      git(work, "config", "user.name", "t")
      write_file(work .. "/tracked.txt", "committed\n")
      git(work, "add", "tracked.txt")
      git(work, "commit", "-qm", "init")
    end)

    it("takes bases of tracked files Bash changed, including your uncommitted edits", function()
      write_file(work .. "/tracked.txt", "uncommitted\n")
      run_hook("PreToolUse", tool("PreToolUse", "Bash", { command = "sed" }))
      write_file(work .. "/tracked.txt", "by bash\n")

      run_hook("PostToolUse", tool("PostToolUse", "Bash", { command = "sed" }))

      assert.equal("uncommitted\n", store:get(work .. "/tracked.txt").text)
      assert.is_nil(read_file(dir .. "/bash/toolu_01.json"))
    end)

    it("takes over the base of an edit that was refused earlier, once Bash changes the file", function()
      local file = work .. "/tracked.txt"
      run_hook("PreToolUse", tool("PreToolUse", "Edit", { file_path = file }, { tool_use_id = "toolu_refused" }))
      assert.is_not_nil(store:get(file))
      local when = os.time() - 3 * 3600
      vim.uv.fs_utime(dir .. "/editing/toolu_refused.json", when, when)
      run_hook("PreToolUse", tool("PreToolUse", "Bash", { command = "sed" }))
      write_file(file, "by bash\n")

      run_hook("PostToolUse", tool("PostToolUse", "Bash", { command = "sed" }))

      -- no note of the refused edit is left to take the base away later
      assert.is_nil(vim.uv.fs_stat(dir .. "/editing/toolu_refused.json"))
      assert.equal("committed\n", store:get(file).text)
    end)

    it("marks files Bash created as new and leaves untouched files alone", function()
      write_file(work .. "/old-untracked.txt", "mine\n")
      run_hook("PreToolUse", tool("PreToolUse", "Bash", { command = "touch" }))
      write_file(work .. "/created.txt", "by bash\n")

      run_hook("PostToolUse", tool("PostToolUse", "Bash", { command = "touch" }))

      assert.is_true(store:get(work .. "/created.txt").new_file)
      assert.is_nil(store:get(work .. "/old-untracked.txt"))
      assert.is_nil(store:get(work .. "/tracked.txt"))
    end)

    it("reports untracked files Bash changed so the editor can take their base from the buffer", function()
      write_file(work .. "/notes.txt", "before\n")
      local editor = start_editor()
      run_hook("PreToolUse", tool("PreToolUse", "Bash", { command = "echo" }), { CLAUDECODE_NVIM = editor.addr })
      -- mtime granularity: make sure the rewrite is visible as a change.
      vim.uv.fs_utime(work .. "/notes.txt", 1, 1)
      write_file(work .. "/notes.txt", "after, longer\n")

      run_hook("PostToolUse", tool("PostToolUse", "Bash", { command = "echo" }), { CLAUDECODE_NVIM = editor.addr })

      local received = editor.received()
      editor.stop()
      assert.equal("PostToolUse", received.event)
      assert.same({ work .. "/notes.txt" }, received.untracked_changed)
      assert.is_nil(store:get(work .. "/notes.txt"))
    end)
  end)

  it("notifies the editor after an edit without waiting for it", function()
    local file = work .. "/a.lua"
    write_file(file, "x\n")
    local editor = start_editor()

    run_hook("PostToolUse", tool("PostToolUse", "Write", { file_path = file }), { CLAUDECODE_NVIM = editor.addr })

    local received = editor.received()
    editor.stop()
    assert.same({ file }, received.files)
    assert.equal("Write", received.tool_name)
  end)

  it("finishes quickly when the editor socket is gone", function()
    local start = vim.uv.hrtime()

    local code = run_hook("PostToolUse", tool("PostToolUse", "Write", { file_path = work .. "/a.lua" }), {
      CLAUDECODE_NVIM = "/nonexistent/socket",
    })

    assert.equal(0, code)
    assert.is_true((vim.uv.hrtime() - start) / 1e6 < 2000)
  end)
end)
