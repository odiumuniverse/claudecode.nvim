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

  -- The text Claude will write: Claude Code drops one trailing "\n" from a Write's answer and keeps
  -- an Edit's as is. Without a note from the hooks only a new file counts as a Write.
  local function written(handle, tool)
    assert.equal("FILE_SAVED", handle.result.content[1].text)
    local answer = handle.result.content[2].text
    return tool == "Write" and (answer:gsub("\n$", "")) or answer
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

  it("takes a proposal with nothing to review at once: the same text, or only a final newline", function()
    local same, newline = work .. "/same.txt", work .. "/newline.txt"
    write_file(same, "one\ntwo\n")
    write_file(newline, "one\ntwo")

    -- Claude waits on one proposal at a time.
    local function answered(path)
      local handle = propose(path, "one\ntwo\n", "tab-" .. vim.fs.basename(path))
      vim.wait(500, function()
        return handle.result ~= nil
      end, 10)
      return handle
    end

    -- A rejection would stop Claude's turn for a change you never saw.
    assert.equal("one\ntwo\n", written(answered(same)))
    assert.equal("one\ntwo\n", written(answered(newline)))
    assert.is_nil(proposal_buf())
  end)

  describe("with a reason", function()
    local function press(keys)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
    end

    before_each(function()
      -- As the plugin sets it up: notes after write are on.
      engine.setup({ note = function() end })
    end)

    it("reverts the hunk on cr and hands Claude the reason with the rest of the proposal", function()
      local file = work .. "/a.txt"
      write_file(file, "a\nb\nc\nd\ne\n")
      store:snapshot(file) -- PreToolUse already ran
      local handle = propose(file, "A\nb\nc\nd\nE\n")
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      press("crkeep e lowercase<CR>")
      press("cs")
      vim.wait(100)

      assert.equal("A\nb\nc\nd\ne\n", written(handle))
      local reverts = store:take_reverts()
      assert.equal(1, #reverts)
      assert.same({ "E" }, reverts[1].claude_lines)
      assert.equal("keep e lowercase", reverts[1].reason)
    end)

    it("rejects all of it and puts the reason in the clipboard when Claude does not run here", function()
      local file = work .. "/a.txt"
      write_file(file, "one\n")
      local handle = propose(file, "two\n")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      press("crsay three<CR>")
      vim.wait(100)

      assert.equal("DIFF_REJECTED", handle.result.content[1].text)
      assert.matches("say three", vim.fn.getreg('"'))
    end)

    it("reverts every hunk of a selection with one reason on <leader>an", function()
      local file = work .. "/a.txt"
      write_file(file, "a\nb\nc\nd\ne\n")
      local handle = propose(file, "A\nb\nc\nd\nE\n")

      press("ggVG<leader>anboth wrong<CR>")
      vim.wait(100)

      assert.equal("DIFF_REJECTED", handle.result.content[1].text)
      assert.equal("line 1: both wrong; line 5: both wrong", vim.fn.getreg('"'))
    end)
  end)

  it("keeps ]k and the moves after a decision inside the proposal, while Claude waits", function()
    local function press(keys)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
    end
    engine.setup({ advance = "file", goto_file = controller.goto_file })
    -- Next on the list of files waiting for review after write: the proposal must not jump to it.
    local other = work .. "/b.txt"
    write_file(other, "1\n")
    store:snapshot(other)
    write_file(other, "2\n")
    controller.refresh_pending()
    local file = work .. "/a.txt"
    write_file(file, "one\ntwo\nthree\n")
    vim.cmd.edit(file)
    local handle = propose(file, "ONE\ntwo\nTHREE\n")
    local buf = proposal_buf()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    press("]k")
    assert.equal(buf, vim.api.nvim_get_current_buf())
    press("cs")
    assert.equal(1, vim.api.nvim_win_get_cursor(0)[1])
    press("cs")
    vim.wait(100)

    assert.equal("ONE\ntwo\nTHREE\n", written(handle))
    assert.equal(file, vim.api.nvim_buf_get_name(0))
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

  describe("tells the tool from the note the hook left before Claude asked", function()
    local function accept_noted(tool)
      local file = work .. "/a.txt"
      write_file(file, "one\ntwo\n")
      store:begin_edit("toolu_1", file, false, nil, tool)
      local handle = propose(file, "one\nTWO\n")

      engine.keep_all(proposal_buf())
      vim.wait(100)

      assert.equal("FILE_SAVED", handle.result.content[1].text)
      return handle.result.content[2].text
    end

    it("gives a Write the newline Claude Code drops from its answer", function()
      assert.equal("one\nTWO\n\n", accept_noted("Write"))
    end)

    it("hands an Edit its text as is", function()
      assert.equal("one\nTWO\n", accept_noted("Edit"))
    end)
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

  it("tells the sessions that edited the file about the rest, and no other session", function()
    -- openDiff carries no session id: the base that PreToolUse made knows who is editing.
    local file = work .. "/a.txt"
    write_file(file, "a\nb\nc\nd\ne\n")
    store:snapshot(file, "sA")
    propose(file, "A\nb\nc\nd\nE\n")
    local buf = proposal_buf()

    engine.revert(buf, 2)
    engine.keep(buf, 1)
    vim.wait(100)

    assert.same({}, store:take_reverts("sB"))
    local reverts = store:take_reverts("sA")
    assert.equal(1, #reverts)
    assert.same({ "E" }, reverts[1].claude_lines)
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

  it("rejects the proposal when Claude closes the tab before you decide, and puts your file back", function()
    local file = work .. "/a.txt"
    write_file(file, "one\ntwo\n")
    vim.cmd.edit(file)
    local file_buf = vim.api.nvim_get_current_buf()
    local handle = propose(file, "one\nTWO\n", "tab-deny")
    local buf = proposal_buf()
    assert.equal(buf, vim.api.nvim_get_current_buf())

    assert.is_true(diff.close_diff_by_tab_name("tab-deny"))

    assert.equal("DIFF_REJECTED", handle.result.content[1].text)
    assert.is_nil(proposal_buf())
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.equal(file_buf, vim.api.nvim_get_current_buf())
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

    assert.equal("fresh\n", written(handle, "Write"))
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

  describe("a file that is not plain UTF-8", function()
    local BOM = "\239\187\191"

    ---Propose `proposal` for `before` (file bytes), keep every hunk, and return what Claude is told to write.
    local function accepted(before, proposal, opts)
      opts = opts or {}
      local file = work .. "/enc.txt"
      write_file(file, before)
      store:snapshot(file) -- PreToolUse already ran
      if opts.open then
        vim.cmd.edit(file)
      end
      local handle = propose(file, proposal)
      local buf = proposal_buf()
      local hunks = #engine.hunks(buf)
      engine.keep_all(buf)
      vim.wait(100)
      return written(handle), hunks, file
    end

    it("shows only what Claude changed in a Latin-1 file that nobody has open", function()
      local content, hunks, file = accepted("caf\233\nx\nb\n", "caf\195\169\nx\nB\n")

      assert.equal(1, hunks)
      assert.equal("caf\195\169\nx\nB\n", content)
      -- Claude writes this text as it is: it becomes the base, so it is not reviewed a second time
      assert.equal("caf\195\169\nx\nB\n", store:get(file).text)
    end)

    it("shows only what Claude changed in a Latin-1 file that is open", function()
      local content, hunks = accepted("caf\233\nx\nb\n", "caf\195\169\nx\nB\n", { open = true })

      assert.equal(1, hunks)
      assert.equal("caf\195\169\nx\nB\n", content)
    end)

    it("takes your decision to revert the one hunk Claude made in a Latin-1 file", function()
      local file = work .. "/enc.txt"
      write_file(file, "caf\233\nb\nc\nd\ne\nf\ng\n")
      local handle = propose(file, "caf\195\169!\nb\nc\nd\ne\nf\nG\n")
      local buf = proposal_buf()
      assert.equal(2, #engine.hunks(buf))

      engine.revert(buf, 1)
      engine.keep(buf, 1)
      vim.wait(100)

      assert.equal("caf\195\169\nb\nc\nd\ne\nf\nG\n", written(handle))
    end)

    it("keeps the byte order mark of a UTF-8 file that Claude's text leaves out", function()
      local content, hunks = accepted(BOM .. "a\nb\n", "a\nB\n")

      assert.equal(1, hunks)
      assert.equal(BOM .. "a\nB\n", content)
    end)

    it("does not double the byte order mark when Claude's text has it", function()
      local content, hunks = accepted(BOM .. "a\nb\n", BOM .. "a\nB\n")

      assert.equal(1, hunks)
      assert.equal(BOM .. "a\nB\n", content)
    end)

    it("shows only what Claude changed in a UTF-16 file, and hands over UTF-8 with the mark", function()
      local utf16 = "\255\254" .. vim.iconv("a\nb\n", "utf-8", "utf-16le")

      local content, hunks = accepted(utf16, "a\nB\n")

      assert.equal(1, hunks)
      assert.equal(BOM .. "a\nB\n", content)
    end)

    it("gives a plain UTF-8 file no mark", function()
      local content = accepted("a\nb\n", "a\nB\n")

      assert.equal("a\nB\n", content)
    end)
  end)

  it("hands Claude an empty file when it proposed one", function()
    local file = work .. "/emptied.txt"
    write_file(file, "a\nb\n")
    local handle = propose(file, "")

    engine.keep_all(proposal_buf())
    vim.wait(100)

    assert.equal("", written(handle))
  end)

  it("hands Claude an empty file when you delete the whole proposal", function()
    local file = work .. "/emptied.txt"
    write_file(file, "a\nb\n")
    local handle = propose(file, "A\nB\n")
    local buf = proposal_buf()

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("write")
    end)
    vim.wait(100)

    assert.equal("", written(handle))
  end)

  it("keeps a proposal of one empty line as one empty line", function()
    local file = work .. "/blank.txt"
    write_file(file, "a\nb\n")
    local handle = propose(file, "\n")

    engine.keep_all(proposal_buf())
    vim.wait(100)

    assert.equal("\n", written(handle))
  end)
end)
