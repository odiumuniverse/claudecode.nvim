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

local start_editor = require("helpers").start_editor

describe("hook script", function()
  local dir, work, store

  -- Run the hook the way Claude Code does and return exit code, decoded stdout and stderr.
  local function run_hook(event, input, env)
    local res = vim
      .system({ vim.v.progpath, "--clean", "--headless", "-l", script, event }, {
        stdin = vim.json.encode(input),
        -- NVIM would point at this test Neovim, which cannot answer while it waits for the hook.
        -- CLAUDE_PROJECT_DIR is set when the tests run under Claude Code.
        env = vim.tbl_extend("force", { CLAUDECODE_REVIEW_DIR = dir, NVIM = "", CLAUDE_PROJECT_DIR = "" }, env or {}),
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

  describe("with several Claude sessions in the project", function()
    local a, b

    local function edits(session, file)
      run_hook("PreToolUse", tool("PreToolUse", "Edit", { file_path = file }, { session_id = session }))
    end

    local function reverted(file)
      store:append_revert({ path = file, line = 1, base_lines = { "a" }, claude_lines = { "b" }, time = 1 })
    end

    ---What the session's next prompt carries, or nil.
    local function hears(session)
      local input = { cwd = work, prompt = "go on" }
      input.session_id = session
      local _, out = run_hook("UserPromptSubmit", input)
      return out and out.hookSpecificOutput.additionalContext
    end

    before_each(function()
      a, b = work .. "/a.lua", work .. "/b.lua"
      write_file(a, "old a\n")
      write_file(b, "old b\n")
    end)

    it("writes down who edits a file", function()
      edits("s1", a)
      edits("s2", a)
      edits("s2", a)

      assert.same({ "s1", "s2" }, store:get(a).sessions)
    end)

    it("keeps the base and every session when hooks of several sessions start together", function()
      local runs = {}
      for _, session in ipairs({ "s1", "s2", "s3", "s4" }) do
        local input = tool("PreToolUse", "Edit", { file_path = a }, { session_id = session, tool_use_id = session })
        runs[#runs + 1] = vim.system({ vim.v.progpath, "--clean", "--headless", "-l", script, "PreToolUse" }, {
          stdin = vim.json.encode(input),
          env = { CLAUDECODE_REVIEW_DIR = dir },
          text = true,
        })
      end
      for _, run in ipairs(runs) do
        assert.equal(0, run:wait().code)
      end

      local base = store:get(a)
      assert.equal("old a\n", base.text)
      table.sort(base.sessions)
      assert.same({ "s1", "s2", "s3", "s4" }, base.sessions)
    end)

    it("tells a session about the reverts of its own edits only", function()
      edits("s1", a)
      edits("s2", b)
      reverted(a)

      assert.is_nil(hears("s2"))
      assert.matches("a%.lua, line 1", hears("s1"))
      assert.is_nil(hears("s1"))
    end)

    it("tells both sessions when both edited the file", function()
      edits("s1", a)
      edits("s2", a)
      reverted(a)

      assert.matches("a%.lua", hears("s1"))
      assert.matches("a%.lua", hears("s2"))
    end)

    it("tells only the session whose edit follows, right after that edit", function()
      edits("s1", a)
      reverted(a)

      local _, other = run_hook("PostToolUse", tool("PostToolUse", "Edit", { file_path = b }, { session_id = "s2" }))
      local _, own = run_hook("PostToolUse", tool("PostToolUse", "Edit", { file_path = b }, { session_id = "s1" }))

      assert.is_nil(other)
      assert.matches("your text, reverted", own.hookSpecificOutput.additionalContext)
    end)

    it("hands a base made before sessions were tracked to whichever session asks first", function()
      store:snapshot(a)
      reverted(a)

      assert.matches("a%.lua", hears("s2"))
      assert.is_nil(hears("s1"))
    end)

    it("adds the session that finishes an edit to a base it did not make", function()
      store:snapshot(a)
      write_file(a, "new a\n")

      run_hook("PostToolUse", tool("PostToolUse", "Edit", { file_path = a }, { session_id = "s3" }))

      assert.same({ "s3" }, store:get(a).sessions)
    end)

    it("takes a session id that is not a plain file name for no session at all", function()
      edits("../x", a)
      reverted(a)

      assert.same({}, store:get(a).sessions)
      assert.is_nil(vim.uv.fs_stat(dir .. "/reverts"))
      assert.is_nil(vim.uv.fs_stat(dir .. "/x.jsonl"))
      assert.matches("a%.lua", hears("../x"))
    end)

    it("lets a prompt without a session id take only the common file", function()
      edits("s1", a)
      store:snapshot(b)
      reverted(a)
      reverted(b)

      local heard = hears(nil)

      assert.matches("b%.lua", heard)
      assert.is_nil(heard:find("a%.lua"))
      assert.matches("a%.lua", hears("s1"))
    end)
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

    it("writes down the session in the bases of the files Bash changed or created", function()
      run_hook("PreToolUse", tool("PreToolUse", "Bash", { command = "sed" }, { session_id = "s7" }))
      write_file(work .. "/tracked.txt", "by bash\n")
      write_file(work .. "/created.txt", "by bash\n")

      run_hook("PostToolUse", tool("PostToolUse", "Bash", { command = "sed" }, { session_id = "s7" }))

      assert.same({ "s7" }, store:get(work .. "/tracked.txt").sessions)
      assert.same({ "s7" }, store:get(work .. "/created.txt").sessions)
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

    describe("when git moves HEAD", function()
      before_each(function()
        git(work, "switch", "-q", "-c", "other")
        write_file(work .. "/tracked.txt", "on other\n")
        write_file(work .. "/only-other.txt", "only on other\n")
        git(work, "add", "-A")
        git(work, "commit", "-qm", "other")
        git(work, "switch", "-q", "-")
      end)

      it("takes no base for the files a branch switch checked out, and reloads their buffers", function()
        local editor = start_editor()
        local env = { CLAUDECODE_NVIM = editor.addr }
        run_hook("PreToolUse", tool("PreToolUse", "Bash", { command = "git switch other" }), env)
        git(work, "switch", "-q", "other")

        run_hook("PostToolUse", tool("PostToolUse", "Bash", { command = "git switch other" }), env)

        local received = editor.received()
        editor.stop()
        assert.is_nil(store:get(work .. "/tracked.txt"))
        assert.is_nil(store:get(work .. "/only-other.txt"))
        table.sort(received.files)
        assert.same({ work .. "/only-other.txt", work .. "/tracked.txt" }, received.files)
      end)

      it("moves a base still waiting along a fast-forward, and its hunk stays", function()
        local file = work .. "/pending.txt"
        write_file(file, "a\nb\nc\nd\ne\n")
        git(work, "add", "pending.txt")
        git(work, "commit", "-qm", "pending")
        store:snapshot(file)
        write_file(file, "A\nb\nc\nd\ne\n") -- Claude's edit, committed before you reviewed it
        git(work, "commit", "-qam", "claude")
        git(work, "switch", "-q", "-c", "upstream")
        write_file(file, "A\nb\nc\nd\nE\n")
        git(work, "commit", "-qam", "upstream")
        git(work, "switch", "-q", "-")
        local merge = { command = "git merge --ff-only upstream" }
        run_hook("PreToolUse", tool("PreToolUse", "Bash", merge))
        git(work, "merge", "-q", "--ff-only", "upstream")

        run_hook("PostToolUse", tool("PostToolUse", "Bash", merge))

        assert.equal("a\nb\nc\nd\nE\n", store:get(file).text)
      end)

      it("bases a file Bash edited after a switch on the branch it switched to", function()
        local cmd = { command = "git switch other && sed -i '' s/other/both/ tracked.txt" }
        run_hook("PreToolUse", tool("PreToolUse", "Bash", cmd))
        git(work, "switch", "-q", "other")
        write_file(work .. "/tracked.txt", "on both\n")

        run_hook("PostToolUse", tool("PostToolUse", "Bash", cmd))

        assert.equal("on other\n", store:get(work .. "/tracked.txt").text)
        assert.is_nil(store:get(work .. "/only-other.txt"))
      end)

      it("keeps your uncommitted work that a hard reset threw away under review", function()
        write_file(work .. "/tracked.txt", "uncommitted\n")
        local reset = { command = "git reset --hard other" }
        run_hook("PreToolUse", tool("PreToolUse", "Bash", reset))
        git(work, "reset", "-q", "--hard", "other")

        run_hook("PostToolUse", tool("PostToolUse", "Bash", reset))

        assert.equal("uncommitted\n", store:get(work .. "/tracked.txt").text)
      end)
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
      assert.equal("s1", received.session_id)
      assert.is_nil(store:get(work .. "/notes.txt"))
    end)
  end)

  describe("around Bash in a folder of repositories", function()
    before_each(function()
      for _, name in ipairs({ "api", "web" }) do
        local repo = work .. "/" .. name
        vim.fn.mkdir(repo, "p")
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "t@example.com")
        git(repo, "config", "user.name", "t")
        write_file(repo .. "/tracked.txt", "committed in " .. name .. "\n")
        git(repo, "add", "tracked.txt")
        git(repo, "commit", "-qm", "init")
      end
    end)

    it("takes bases of the files Bash changed in a repository below the folder", function()
      local cmd = { command = "cd api && sed -i '' s/committed/changed/ tracked.txt" }
      run_hook("PreToolUse", tool("PreToolUse", "Bash", cmd))
      write_file(work .. "/api/tracked.txt", "changed in api\n")

      run_hook("PostToolUse", tool("PostToolUse", "Bash", cmd))

      assert.equal("committed in api\n", store:get(work .. "/api/tracked.txt").text)
      assert.is_nil(store:get(work .. "/web/tracked.txt"))
    end)

    it("takes no base for the files a branch switch below the folder checked out", function()
      local api = work .. "/api"
      git(api, "switch", "-q", "-c", "other")
      write_file(api .. "/tracked.txt", "on other\n")
      git(api, "commit", "-qam", "other")
      git(api, "switch", "-q", "-")
      local cmd = { command = "cd api && git switch other" }
      run_hook("PreToolUse", tool("PreToolUse", "Bash", cmd))
      git(api, "switch", "-q", "other")

      run_hook("PostToolUse", tool("PostToolUse", "Bash", cmd))

      assert.is_nil(store:get(api .. "/tracked.txt"))
    end)

    it("takes bases in a neighbor of the repository Claude stands in", function()
      local env = { CLAUDE_PROJECT_DIR = work }
      local cmd = { command = "cd ../web && sed -i '' s/committed/changed/ tracked.txt" }
      local extra = { cwd = work .. "/api" }
      run_hook("PreToolUse", tool("PreToolUse", "Bash", cmd, extra), env)
      write_file(work .. "/web/tracked.txt", "changed in web\n")

      run_hook("PostToolUse", tool("PostToolUse", "Bash", cmd, extra), env)

      assert.equal("committed in web\n", store:get(work .. "/web/tracked.txt").text)
    end)
  end)

  it("tells the editor about an edit", function()
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
