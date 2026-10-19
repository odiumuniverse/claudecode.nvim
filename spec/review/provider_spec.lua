--- Tests for review before write: Claude's proposal shown with the review engine (Manual mode).
local controller = require("claudecode.review.controller")
local diff = require("claudecode.diff")
local engine = require("claudecode.review")
local provider = require("claudecode.review.provider")
local store_mod = require("claudecode.review.store")

local function write_file(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

describe("review provider", function()
  local work, dir, store

  -- Ask for a diff the way the openDiff tool does and return a handle with the MCP result.
  local function propose(path, proposal, tab_name)
    local handle = {}
    handle.co = coroutine.create(function()
      handle.result = diff.open_diff_blocking(path, path, proposal, tab_name or "tab-1")
    end)
    local ok, err = coroutine.resume(handle.co)
    assert(ok, tostring(err))
    return handle
  end

  local function proposal_buf()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].claudecode_proposal then
        return buf
      end
    end
  end

  -- The text Claude will write, with the trailing "\n" Claude Code drops undone.
  local function written(handle)
    assert.equal("FILE_SAVED", handle.result.content[1].text)
    return (handle.result.content[2].text:gsub("\n$", ""))
  end

  before_each(function()
    work = vim.fn.tempname()
    vim.fn.mkdir(work, "p")
    work = vim.uv.fs_realpath(work)
    dir = vim.fn.tempname()
    store = store_mod.new(dir)
    engine.setup({})
    controller.setup({ dir = dir })
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test_cleanup")
    diff.setup({ terminal = {}, diff_opts = {} })
    controller.teardown()
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(work, "rf")
    vim.fn.delete(dir, "rf")
  end)

  it("shows the proposal in place of the file, with its hunks", function()
    local file = work .. "/a.lua"
    write_file(file, "one\ntwo\n")
    vim.cmd.edit(file)
    local file_buf = vim.api.nvim_get_current_buf()

    propose(file, "one\nTWO\n")

    local buf = proposal_buf()
    assert.is_not_nil(buf)
    assert.equal(buf, vim.api.nvim_get_current_buf())
    assert.same({ "one", "TWO" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equal("lua", vim.bo[buf].filetype)
    assert.equal(1, #engine.hunks(buf))
    assert.is_true(vim.api.nvim_buf_is_valid(file_buf))
  end)

  it("accepts Claude's text when you keep every hunk and puts your file back in the window", function()
    local file = work .. "/a.txt"
    write_file(file, "one\ntwo\n")
    vim.cmd.edit(file)
    local file_buf = vim.api.nvim_get_current_buf()
    local handle = propose(file, "one\nTWO\nthree\n")

    engine.keep_all(proposal_buf())
    vim.wait(100)

    assert.equal("one\nTWO\nthree\n", written(handle))
    assert.equal(file_buf, vim.api.nvim_get_current_buf())
    assert.is_nil(proposal_buf())
  end)

  it("rejects the proposal when you revert every hunk", function()
    local file = work .. "/a.txt"
    write_file(file, "one\n")
    local handle = propose(file, "two\n")

    engine.revert_all(proposal_buf())
    vim.wait(100)

    assert.equal("DIFF_REJECTED", handle.result.content[1].text)
  end)

  it("writes only the hunks you kept and tells Claude about the rest", function()
    local file = work .. "/a.txt"
    write_file(file, "a\nb\nc\nd\ne\n")
    store:snapshot(file) -- PreToolUse already ran
    local handle = propose(file, "A\nb\nc\nd\nE\n")
    local buf = proposal_buf()

    engine.revert(buf, 2)
    engine.keep(buf, 1)
    vim.wait(100)

    assert.equal("A\nb\nc\nd\ne\n", written(handle))
    local reverts = store:take_reverts()
    assert.equal(1, #reverts)
    assert.equal(file, reverts[1].path)
    assert.same({ "E" }, reverts[1].claude_lines)
    assert.same({ "e" }, reverts[1].base_lines)
  end)

  it("makes the text you accepted the new base, so it is not reviewed twice", function()
    local file = work .. "/a.txt"
    write_file(file, "one\n")
    store:snapshot(file)
    local handle = propose(file, "two\n")

    engine.keep_all(proposal_buf())
    vim.wait(100)

    assert.equal("two\n", written(handle))
    assert.equal("two\n", store:get(file).text)
  end)

  it("accepts the rest of the proposal on :w", function()
    local file = work .. "/a.txt"
    write_file(file, "a\nb\nc\nd\ne\n")
    local handle = propose(file, "A\nb\nc\nd\nE\n")
    local buf = proposal_buf()
    engine.revert(buf, 1)

    vim.api.nvim_buf_call(buf, function()
      vim.cmd("write")
    end)
    vim.wait(100)

    assert.equal("a\nb\nc\nd\nE\n", written(handle))
  end)

  it("accepts what you kept on :ClaudeCodeDiffAccept", function()
    local file = work .. "/a.txt"
    write_file(file, "a\nb\nc\nd\ne\n")
    local handle = propose(file, "A\nb\nc\nd\nE\n")
    local buf = proposal_buf()
    engine.revert(buf, 2)

    diff._resolve_diff_as_saved(vim.b[buf].claudecode_diff_tab_name, buf)
    vim.wait(100)

    assert.equal("A\nb\nc\nd\ne\n", written(handle))
  end)

  it("reviews a file that has unsaved edits in its buffer", function()
    local file = work .. "/a.txt"
    write_file(file, "one\n")
    vim.cmd.edit(file)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "mine" })

    local handle = propose(file, "two\n")

    assert.is_nil(handle.result)
    assert.is_not_nil(proposal_buf())
  end)

  it("shows a new file as all added and creates it on accept", function()
    local file = work .. "/new.txt"
    local handle = propose(file, "fresh\n")
    local buf = proposal_buf()
    assert.equal(1, #engine.hunks(buf))

    engine.keep_all(buf)
    vim.wait(100)

    assert.equal("fresh\n", written(handle))
  end)

  it("steps out of zen for the proposal and goes back once you decide", function()
    local zen = require("claudecode.zen")
    local real_terminal = package.loaded["claudecode.terminal"]
    local term_buf
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return term_buf
      end,
      ensure_visible = function()
        if #vim.fn.win_findbuf(term_buf) == 0 then
          local prev = vim.api.nvim_get_current_win()
          vim.cmd("botright vsplit")
          vim.api.nvim_win_set_buf(0, term_buf)
          vim.api.nvim_set_current_win(prev)
        end
      end,
    }
    vim.cmd("botright vsplit | enew")
    term_buf = vim.api.nvim_get_current_buf()
    vim.fn.jobstart({ "sh", "-c", "sleep 30" }, { term = true })
    vim.cmd("wincmd p")
    zen.setup({})
    local file = work .. "/a.txt"
    write_file(file, "one\n")

    zen.enter()
    local handle = propose(file, "two\n")
    assert.is_false(zen.is_active())
    assert.is_not_nil(proposal_buf())

    engine.keep_all(proposal_buf())
    vim.wait(200, function()
      return zen.is_active()
    end)

    assert.equal("two\n", written(handle))
    assert.is_true(zen.is_active())
    zen.leave()
    zen.teardown()
    package.loaded["claudecode.terminal"] = real_terminal
    vim.api.nvim_buf_delete(term_buf, { force = true })
    vim.cmd("silent! only")
  end)

  it("cleans up when Claude goes away before you decide", function()
    local file = work .. "/a.txt"
    write_file(file, "one\n")
    vim.cmd.edit(file)
    local file_buf = vim.api.nvim_get_current_buf()
    propose(file, "two\n", "tab-gone")

    diff._cleanup_all_active_diffs("client disconnected")

    assert.is_nil(proposal_buf())
    assert.equal(file_buf, vim.api.nvim_get_current_buf())
  end)

  it("keeps the CRLF line endings of the file in what it hands to Claude", function()
    local file = work .. "/crlf.txt"
    write_file(file, "one\r\ntwo\r\nthree\r\n")
    local handle = propose(file, "one\r\nTWO\r\nthree\r\n")

    engine.keep_all(proposal_buf())
    vim.wait(100)

    assert.equal("one\r\nTWO\r\nthree\r\n", written(handle))
  end)

  it("keeps CRLF in the hunks you kept when you reverted another one", function()
    local file = work .. "/crlf.txt"
    write_file(file, "a\r\nb\r\nc\r\nd\r\ne\r\n")
    local handle = propose(file, "A\r\nb\r\nc\r\nd\r\nE\r\n")
    local buf = proposal_buf()

    engine.revert(buf, 2)
    engine.keep(buf, 1)
    vim.wait(100)

    assert.equal("A\r\nb\r\nc\r\nd\r\ne\r\n", written(handle))
  end)
end)
