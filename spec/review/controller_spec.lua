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
