--- Tests for the glue between hook notifications, the state store and the review engine.
local controller = require("claudecode.review.controller")
local engine = require("claudecode.review")
local store_mod = require("claudecode.review.store")

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

describe("review controller", function()
  local work, dir, store, pending_events, autocmd

  local function open(path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf()
  end

  -- Claude edits a file the way the hooks see it: snapshot, write, notify.
  local function claude_writes(path, text)
    store:snapshot(path)
    write_file(path, text)
    controller.on_hook({ event = "PostToolUse", dir = dir, tool_name = "Write", files = { path } })
  end

  before_each(function()
    work = vim.fn.tempname()
    vim.fn.mkdir(work, "p")
    work = vim.uv.fs_realpath(work)
    dir = vim.fn.tempname()
    store = store_mod.new(dir)
    pending_events = {}
    autocmd = vim.api.nvim_create_autocmd("User", {
      pattern = "ClaudeCodeReviewPending",
      callback = function(ev)
        pending_events[#pending_events + 1] = ev.data
      end,
    })
    controller.setup({ dir = dir })
  end)

  after_each(function()
    vim.api.nvim_del_autocmd(autocmd)
    controller.teardown()
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(work, "rf")
    vim.fn.delete(dir, "rf")
  end)

  it("reviews a file with a base as soon as you open it", function()
    local file = work .. "/a.txt"
    write_file(file, "one\ntwo\n")
    store:snapshot(file)
    write_file(file, "one\nTWO\n")

    local buf = open(file)

    assert.is_true(engine.is_attached(buf))
    assert.equal(1, #engine.hunks(buf))
  end)

  it("reloads an open file Claude changed and starts the review", function()
    local file = work .. "/a.txt"
    write_file(file, "one\n")
    local buf = open(file)

    claude_writes(file, "one\nadded\n")

    assert.same({ "one", "added" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(engine.is_attached(buf))
    assert.equal(1, pending_events[#pending_events].count)
  end)

  it("leaves a buffer with your unsaved edits alone and warns", function()
    local file = work .. "/a.txt"
    write_file(file, "one\n")
    local buf = open(file)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mine" })
    local warned
    local notify = vim.notify
    vim.notify = function(msg, level)
      warned = { msg = msg, level = level }
    end

    claude_writes(file, "claude\n")
    vim.notify = notify

    assert.same({ "mine" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_false(engine.is_attached(buf))
    assert.equal(vim.log.levels.WARN, warned.level)
    assert.matches("a%.txt", warned.msg)
  end)

  it("forgets the base once you keep every hunk", function()
    local file = work .. "/a.txt"
    write_file(file, "one\n")
    local buf = open(file)
    claude_writes(file, "one\ntwo\n")

    engine.keep_all(buf)

    assert.is_nil(store:get(file))
    assert.is_false(engine.is_attached(buf))
    assert.equal(0, pending_events[#pending_events].count)
  end)

  it("saves the moved base when you keep one hunk of two", function()
    local file = work .. "/a.txt"
    write_file(file, "a\nb\nc\nd\ne\n")
    local buf = open(file)
    claude_writes(file, "A\nb\nc\nd\nE\n")

    engine.keep(buf, 1)

    assert.equal("A\nb\nc\nd\ne\n", store:get(file).text)
  end)

  it("restores the file and records the revert for Claude", function()
    local file = work .. "/a.txt"
    write_file(file, "keep me\n")
    local buf = open(file)
    claude_writes(file, "changed\n")

    engine.revert(buf, 1)

    assert.equal("keep me\n", read_file(file))
    local reverts = store:take_reverts()
    assert.equal(1, #reverts)
    assert.equal(file, reverts[1].path)
    assert.same({ "changed" }, reverts[1].claude_lines)
  end)

  describe("reverting a hunk writes the file with the final newline it had", function()
    ---Claude rewrites `before` as `after`, you open the file and revert hunk `index`.
    local function revert(before, after, index)
      local file = work .. "/a.txt"
      write_file(file, before)
      local buf = open(file)
      claude_writes(file, after)
      engine.revert(buf, index)
      return read_file(file)
    end

    it("when the file has none", function()
      assert.equal("one\ntwo", revert("one\ntwo", "one\nTWO", 1))
    end)

    it("when the file has none and a hunk before the last line is the one reverted", function()
      assert.equal("a\nb\nc\nd\nE", revert("a\nb\nc\nd\ne", "A\nb\nc\nd\nE", 1))
    end)

    it("when Claude took the final newline away and you revert its last line", function()
      assert.equal("a\nb\n", revert("a\nb\n", "a\nb\nc", 1))
    end)

    it("when Claude added the final newline and you revert its last line", function()
      assert.equal("a\nb", revert("a\nb", "a\nb\nc\n", 1))
    end)

    it("when it has one, as before", function()
      assert.equal("a\nb\n", revert("a\nb\n", "A\nb\n", 1))
    end)
  end)

  it("takes the base of an untracked file Bash rewrote from its buffer", function()
    local file = work .. "/notes.txt"
    write_file(file, "before\n")
    local buf = open(file)
    write_file(file, "after\n")

    controller.on_hook({
      event = "PostToolUse",
      dir = dir,
      tool_name = "Bash",
      files = {},
      untracked_changed = { file },
    })

    assert.equal("before\n", store:get(file).text)
    assert.same({ "after" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(engine.is_attached(buf))
  end)

  it("deletes a new file when you revert all of it", function()
    local file = work .. "/new.txt"
    store:snapshot(file)
    write_file(file, "fresh\n")
    local buf = open(file)

    engine.revert_all(buf)

    assert.is_true(vim.wait(1000, function()
      return read_file(file) == nil
    end))
    assert.is_nil(store:get(file))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("drops bases that already match the file and counts the rest", function()
    write_file(work .. "/same.txt", "x\n")
    store:snapshot(work .. "/same.txt")
    write_file(work .. "/diff.txt", "x\n")
    store:snapshot(work .. "/diff.txt")
    write_file(work .. "/diff.txt", "y\n")

    local pending = controller.refresh_pending()

    assert.same({ work .. "/diff.txt" }, pending)
    assert.is_nil(store:get(work .. "/same.txt"))
    assert.equal(1, pending_events[#pending_events].count)
  end)

  it("does not show a byte order mark as a change, and keeps it when you revert", function()
    local file = work .. "/bom.txt"
    write_file(file, "\239\187\191a\nb\n")
    store:snapshot(file)
    write_file(file, "\239\187\191a\nB\n")

    local buf = open(file)

    local hunks = engine.hunks(buf)
    assert.equal(1, #hunks)
    assert.same({ "b" }, hunks[1].base_lines)
    engine.revert(buf, 1)
    assert.equal("\239\187\191a\nb\n", read_file(file))
  end)

  it("compares a file in another encoding with its base in the file's bytes", function()
    local file = work .. "/latin1.txt"
    write_file(file, "caf\233\nb\n")
    store:snapshot(file)
    write_file(file, "caf\233\nB\n")

    local buf = open(file)

    assert.equal("latin1", vim.bo[buf].fileencoding)
    local hunks = engine.hunks(buf)
    assert.equal(1, #hunks)
    assert.same({ "b" }, hunks[1].base_lines)
    engine.revert(buf, 1)
    assert.equal("caf\233\nb\n", read_file(file))
  end)

  it("saves the base in the bytes of the file when your edit is carried into it", function()
    local file = work .. "/latin1.txt"
    write_file(file, "caf\233\n2\n3\n4\n5\n6\nseven\n")
    store:snapshot(file)
    write_file(file, "caf\233\n2\n3\n4\n5\n6\nSEVEN\n")
    local buf = open(file)

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "café!" })
    require("helpers").flush()

    assert.equal("caf\233!\n2\n3\n4\n5\n6\nseven\n", store:get(file).text)
  end)

  it("saves the base with its byte order mark when your edit is carried into it", function()
    local file = work .. "/bom.txt"
    write_file(file, "\239\187\1911\n2\n3\n4\n5\n6\nseven\n")
    store:snapshot(file)
    write_file(file, "\239\187\1911\n2\n3\n4\n5\n6\nSEVEN\n")
    local buf = open(file)

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "one" })
    require("helpers").flush()

    assert.equal("\239\187\191one\n2\n3\n4\n5\n6\nseven\n", store:get(file).text)
  end)

  it("keeps a file Bash deleted in the list when it was open in a buffer", function()
    local file = work .. "/a.txt"
    write_file(file, "one\ntwo\n")
    open(file)
    -- PostToolUse(Bash) saw the file go: its base is the text from before the call
    store:snapshot_text(file, "one\ntwo\n", false)
    vim.fn.delete(file)

    controller.on_hook({ event = "PostToolUse", dir = dir, tool_name = "Bash", files = { file } })

    assert.same({ file }, controller.pending())
    assert.equal("one\ntwo\n", store:get(file).text)
  end)

  it("brings back a file Bash deleted from the list, also when it was open", function()
    local file = work .. "/a.txt"
    write_file(file, "one\ntwo\n")
    local buf = open(file)
    store:snapshot_text(file, "one\ntwo\n", false)
    vim.fn.delete(file)
    controller.on_hook({ event = "PostToolUse", dir = dir, tool_name = "Bash", files = { file } })

    require("claudecode.review.picker").revert_all(file)

    assert.equal("one\ntwo\n", read_file(file))
    assert.same({ "one", "two" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.same({}, controller.pending())
    assert.equal(1, #store:take_reverts())
  end)

  describe("while Claude is in the middle of an edit", function()
    local handlers = require("claudecode.hooks.handlers")

    local function edit_input(file)
      return { tool_name = "Edit", tool_use_id = "toolu_edit", cwd = work, tool_input = { file_path = file } }
    end

    it("keeps the base that PreToolUse took, however often the list is refreshed", function()
      local file = work .. "/a.txt"
      write_file(file, "one\n")
      handlers.handle("PreToolUse", edit_input(file), { dir = dir })

      -- you resolved another file, or opened the list, while Claude waits for permission
      assert.same({}, controller.refresh_pending())
      assert.equal("one\n", store:get(file).text)

      write_file(file, "two\n")
      handlers.handle("PostToolUse", edit_input(file), { dir = dir })

      assert.same({ file }, controller.refresh_pending())
      assert.equal("one\n", store:get(file).text)
    end)

    it("keeps the base of a file Claude is about to create", function()
      local file = work .. "/new.txt"
      handlers.handle("PreToolUse", edit_input(file), { dir = dir })

      assert.same({}, controller.refresh_pending())

      write_file(file, "fresh\n")
      handlers.handle("PostToolUse", edit_input(file), { dir = dir })

      assert.same({ file }, controller.refresh_pending())
      assert.is_true(store:get(file).new_file)
    end)

    ---Claude Code asked for permission an hour ago and was refused: PostToolUse never came.
    local function age_notes(seconds)
      local when = os.time() - seconds
      for name in vim.fs.dir(dir .. "/editing") do
        vim.uv.fs_utime(dir .. "/editing/" .. name, when, when)
      end
    end

    it("forgets the base of an edit that was refused, so your own edits are not taken for Claude's", function()
      local file = work .. "/a.txt"
      write_file(file, "one\ntwo\n")
      handlers.handle("PreToolUse", edit_input(file), { dir = dir })
      -- refused; you make the change yourself
      write_file(file, "one\nmine\n")
      age_notes(controller.EDITING_MAX_AGE_S + 60)

      assert.same({}, controller.refresh_pending())
      assert.is_nil(store:get(file))
    end)

    it("keeps the base of a refused edit when a later edit of the file did finish", function()
      local file = work .. "/a.txt"
      write_file(file, "one\ntwo\n")
      handlers.handle("PreToolUse", edit_input(file), { dir = dir })
      age_notes(controller.EDITING_MAX_AGE_S + 60)
      local again = { tool_name = "Edit", tool_use_id = "toolu_again", cwd = work, tool_input = { file_path = file } }
      handlers.handle("PreToolUse", again, { dir = dir })
      write_file(file, "one\nclaude\n")
      handlers.handle("PostToolUse", again, { dir = dir })

      assert.same({ file }, controller.refresh_pending())
      assert.equal("one\ntwo\n", store:get(file).text)
    end)

    it("keeps the base of an earlier edit when a later one was refused", function()
      local file = work .. "/a.txt"
      write_file(file, "one\n")
      handlers.handle("PreToolUse", edit_input(file), { dir = dir })
      write_file(file, "one\nclaude\n")
      handlers.handle("PostToolUse", edit_input(file), { dir = dir })
      local refused = { tool_name = "Edit", tool_use_id = "toolu_no", cwd = work, tool_input = { file_path = file } }
      handlers.handle("PreToolUse", refused, { dir = dir })
      age_notes(controller.EDITING_MAX_AGE_S + 60)

      assert.same({ file }, controller.refresh_pending())
      assert.equal("one\n", store:get(file).text)
    end)

    it("keeps the base of a Bash change when an edit of the same file was refused before it", function()
      local file = work .. "/a.txt"
      write_file(file, "one\n")
      handlers.handle("PreToolUse", edit_input(file), { dir = dir })
      store:snapshot_text(file, "one\n", false)
      write_file(file, "one\nbash\n")
      -- what PostToolUse(Bash) does for a tracked file
      store:end_edit(nil, file)
      age_notes(controller.EDITING_MAX_AGE_S + 60)

      assert.same({ file }, controller.refresh_pending())
    end)

    it("drops the base again once the edit has finished and changed nothing", function()
      local file = work .. "/a.txt"
      write_file(file, "one\n")
      handlers.handle("PreToolUse", edit_input(file), { dir = dir })
      handlers.handle("PostToolUse", edit_input(file), { dir = dir })

      assert.same({}, controller.refresh_pending())
      assert.is_nil(store:get(file))
    end)

    describe("and you create the file Claude was about to create", function()
      local picker = require("claudecode.review.picker")

      ---Claude Code refused the Write: PostToolUse never comes, and the file is yours.
      local function refused_then_created()
        local file = work .. "/new.txt"
        handlers.handle("PreToolUse", edit_input(file), { dir = dir })
        write_file(file, "mine\n")
        return file
      end

      it("does not list your file as Claude's new file", function()
        refused_then_created()

        assert.same({}, controller.refresh_pending())
        assert.equal(0, pending_events[#pending_events].count)
      end)

      it("does not review your file when you open it", function()
        local file = refused_then_created()

        local buf = open(file)

        assert.is_false(engine.is_attached(buf))
      end)

      it("does not delete your file on revert all or keep all in the list", function()
        local file = refused_then_created()

        picker.revert_all(file)
        picker.keep_all(file)

        assert.equal("mine\n", read_file(file))
      end)

      it("does not delete your file once the note is old, even before the list was refreshed", function()
        local file = refused_then_created()
        age_notes(controller.EDITING_MAX_AGE_S + 60)

        local buf = open(file)

        assert.is_false(engine.is_attached(buf))
        assert.equal("mine\n", read_file(file))
        assert.is_nil(store:get(file))
        assert.same({}, controller.refresh_pending())
      end)

      it("reviews the file as you made it when Claude then really edits it", function()
        local file = refused_then_created()
        local again = { tool_name = "Edit", tool_use_id = "toolu_again", cwd = work, tool_input = { file_path = file } }
        handlers.handle("PreToolUse", again, { dir = dir })
        write_file(file, "mine\nclaude\n")
        handlers.handle("PostToolUse", again, { dir = dir })

        assert.same({ file }, controller.refresh_pending())
        local base = store:get(file)
        assert.equal("mine\n", base.text)
        assert.is_false(base.new_file)
        picker.revert_all(file)
        assert.equal("mine\n", read_file(file))
      end)
    end)

    it("reviews the file with your edits when Bash changes it after an edit of it was refused", function()
      local function sh(...)
        local res = vim.system({ "git", "-C", work, ... }, { text = true }):wait()
        assert(res.code == 0, res.stderr)
      end
      local file = work .. "/f.txt"
      write_file(file, "one\n")
      sh("init", "-q")
      sh("-c", "user.email=t@example.com", "-c", "user.name=t", "add", "-A")
      sh("-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "init")
      handlers.handle("PreToolUse", edit_input(file), { dir = dir })
      -- refused; you edit the file yourself, then Claude runs a command that changes it
      write_file(file, "one\nmine\n")
      local bash = { tool_name = "Bash", tool_use_id = "toolu_bash", cwd = work, tool_input = {} }
      handlers.handle("PreToolUse", bash, { dir = dir })
      write_file(file, "one\nmine\nbash\n")
      handlers.handle("PostToolUse", bash, { dir = dir })

      assert.same({ file }, controller.refresh_pending())
      assert.equal("one\nmine\n", store:get(file).text)
    end)
  end)

  it("follows the state directory a new Claude session reports", function()
    local other = vim.fn.tempname()
    local other_store = store_mod.new(other)
    local file = work .. "/a.txt"
    write_file(file, "one\n")
    other_store:snapshot(file)
    write_file(file, "two\n")

    controller.on_hook({ event = "PostToolUse", dir = other, tool_name = "Edit", files = { file } })

    assert.same({ file }, controller.refresh_pending())
    vim.fn.delete(other, "rf")
  end)
end)
