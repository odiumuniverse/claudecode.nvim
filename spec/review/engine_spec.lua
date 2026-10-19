local helpers = require("helpers")
local review = require("claudecode.review")

local ns = vim.api.nvim_create_namespace("claudecode_review")

---@param bufnr integer
---@return string[]
local function lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---Callbacks that record what the engine told the caller.
---@return ClaudeCodeReviewAttachOpts opts
---@return table calls
local function recorder()
  local calls = { base = {}, revert = {}, done = {} }
  local opts = {
    on_base = function(base)
      calls.base[#calls.base + 1] = base
    end,
    on_revert = function(rec)
      calls.revert[#calls.revert + 1] = rec
    end,
    on_done = function(reason)
      calls.done[#calls.done + 1] = reason
    end,
  }
  return opts, calls
end

describe("review engine attach", function()
  before_each(function()
    review.setup({})
  end)

  after_each(helpers.reset)

  it("computes hunks against the base and draws them", function()
    local bufnr = helpers.buffer({ "a", "X", "c" })

    review.attach(bufnr, { "a", "b", "c" }, {})

    assert.is_true(review.is_attached(bufnr))
    assert.same({
      {
        base_start = 2,
        base_count = 1,
        cur_start = 2,
        cur_count = 1,
        base_lines = { "b" },
        cur_lines = { "X" },
      },
    }, review.hunks(bufnr))
    assert.same({ "a", "b", "c" }, review.base(bufnr))
    assert.is_true(#vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}) > 0)
  end)

  it("hands out copies, so callers cannot corrupt the state", function()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    review.attach(bufnr, { "a", "b", "c" }, {})

    review.base(bufnr)[1] = "changed"
    review.hunks(bufnr)[1].cur_lines[1] = "changed"

    assert.same({ "a", "b", "c" }, review.base(bufnr))
    assert.same({ "X" }, review.hunks(bufnr)[1].cur_lines)
  end)

  it("does not mutate the base it was given", function()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    local base = { "a", "b", "c" }

    review.attach(bufnr, base, {})
    review.keep(bufnr, 1)

    assert.same({ "a", "b", "c" }, base)
  end)

  it("finishes at once when there is nothing to review", function()
    local opts, calls = recorder()
    local bufnr = helpers.buffer({ "a", "b" })

    review.attach(bufnr, { "a", "b" }, opts)

    assert.is_false(review.is_attached(bufnr))
    assert.same({ "resolved" }, calls.done)
    assert.same({}, helpers.marks(bufnr))
  end)

  it("changes the base when attached again", function()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    review.attach(bufnr, { "a", "b", "c" }, {})

    review.attach(bufnr, { "a", "Z", "c" }, {})

    assert.same({ "a", "Z", "c" }, review.base(bufnr))
    assert.same({ "Z" }, review.hunks(bufnr)[1].base_lines)
  end)

  it("resolves when attached again with a base equal to the text", function()
    local opts, calls = recorder()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    review.attach(bufnr, { "a", "b", "c" }, opts)

    review.attach(bufnr, { "a", "X", "c" })

    assert.is_false(review.is_attached(bufnr))
    assert.same({ "resolved" }, calls.done)
  end)

  it("removes marks and tells the caller on detach, once", function()
    local opts, calls = recorder()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    review.attach(bufnr, { "a", "b", "c" }, opts)

    review.detach(bufnr)
    review.detach(bufnr)

    assert.is_false(review.is_attached(bufnr))
    assert.same({ "detached" }, calls.done)
    assert.same({}, helpers.marks(bufnr))
    assert.same({}, review.hunks(bufnr))
  end)

  it("detaches when the buffer is deleted", function()
    local opts, calls = recorder()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    review.attach(bufnr, { "a", "b", "c" }, opts)

    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert.is_false(review.is_attached(bufnr))
    assert.same({ "detached" }, calls.done)
  end)

  it("detaches when the buffer is unloaded", function()
    local opts, calls = recorder()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    review.attach(bufnr, { "a", "b", "c" }, opts)
    local other = helpers.buffer({ "other" })

    vim.cmd("silent bunload! " .. bufnr)
    helpers.flush()

    assert.is_false(review.is_attached(bufnr))
    assert.same({ "detached" }, calls.done)
    assert.is_true(vim.api.nvim_buf_is_valid(other))
  end)

  it("tells the User autocmd how many hunks there are", function()
    local seen = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "ClaudeCodeReviewChanged",
      callback = function(args)
        seen[#seen + 1] = args.data
      end,
    })
    local bufnr, path = helpers.file_buffer("a\nX\nc\n")

    review.attach(bufnr, { "a", "b", "c" }, {})
    vim.api.nvim_del_autocmd(id)

    assert.equal(1, #seen)
    assert.equal(bufnr, seen[1].bufnr)
    assert.equal(vim.uv.fs_realpath(path), vim.uv.fs_realpath(seen[1].path))
    assert.equal(1, seen[1].hunks)
  end)

  it("rejects a buffer that is not loaded", function()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    assert.has_error(function()
      review.attach(bufnr, {}, {})
    end)
  end)
end)

---@param bufnr integer
---@param lhs string
---@return table
local function buffer_map(bufnr, lhs)
  return vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
end

---@param keys string
local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

describe("review engine keymaps", function()
  before_each(function()
    review.setup({})
  end)

  after_each(helpers.reset)

  local default_keys = { "ko", "kx", "KO", "KX", "]k", "[k", "]K", "[K" }

  it("maps the default keys in the buffer, with descriptions for which-key", function()
    local bufnr = helpers.buffer({ "a", "X", "c" })

    review.attach(bufnr, { "a", "b", "c" }, {})

    for _, lhs in ipairs(default_keys) do
      local map = buffer_map(bufnr, lhs)
      assert.equal(1, map.buffer, lhs .. " is not buffer-local")
      assert.is_truthy(map.desc and map.desc:find("review", 1, true), lhs .. " has no description")
    end
  end)

  it("does not touch other buffers", function()
    local other = helpers.buffer({ "x" })
    local bufnr = helpers.buffer({ "a", "X", "c" })

    review.attach(bufnr, { "a", "b", "c" }, {})

    assert.same({}, buffer_map(other, "ko"))
  end)

  it("takes other keys from setup and skips the ones set to false", function()
    review.setup({ keymaps = { keep = "gk", revert = false } })
    local bufnr = helpers.buffer({ "a", "X", "c" })

    review.attach(bufnr, { "a", "b", "c" }, {})

    assert.equal(1, buffer_map(bufnr, "gk").buffer)
    assert.same({}, buffer_map(bufnr, "ko"))
    assert.same({}, buffer_map(bufnr, "kx"))
    assert.equal(1, buffer_map(bufnr, "KO").buffer)
  end)

  it("removes its keys on detach and puts back the mapping the buffer had", function()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    local pressed = {}
    vim.keymap.set("n", "ko", function()
      pressed[#pressed + 1] = "mine"
    end, { buffer = bufnr, desc = "my own ko" })
    vim.keymap.set("n", "KO", ":echo 'global'<CR>", { desc = "global KO" })

    review.attach(bufnr, { "a", "b", "c" }, {})
    assert.is_truthy(buffer_map(bufnr, "ko").desc:find("review", 1, true))
    review.detach(bufnr)

    local restored = buffer_map(bufnr, "ko")
    assert.equal(1, restored.buffer)
    assert.equal("my own ko", restored.desc)
    press("ko")
    assert.same({ "mine" }, pressed)
    assert.same({}, buffer_map(bufnr, "kx"))
    local global = buffer_map(bufnr, "KO")
    assert.equal(0, global.buffer)
    assert.equal("global KO", global.desc)
    vim.keymap.del("n", "KO")
  end)

  it("removes its keys when the review is resolved", function()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    review.attach(bufnr, { "a", "b", "c" }, {})

    review.keep(bufnr, 1)

    assert.same({}, buffer_map(bufnr, "ko"))
  end)
end)

describe("review engine keep", function()
  before_each(function()
    review.setup({})
  end)

  after_each(helpers.reset)

  it("moves the base to Claude's text and leaves the buffer alone", function()
    local opts, calls = recorder()
    local bufnr = helpers.buffer({ "a", "X", "c", "d", "Y" })
    review.attach(bufnr, { "a", "b", "c", "d", "e" }, opts)

    review.keep(bufnr, 1)

    assert.same({ "a", "X", "c", "d", "e" }, review.base(bufnr))
    assert.same({ "a", "X", "c", "d", "Y" }, lines(bufnr))
    assert.same({ { "a", "X", "c", "d", "e" } }, calls.base)
    assert.equal(1, #review.hunks(bufnr))
    assert.same({ "e" }, review.hunks(bufnr)[1].base_lines)
    assert.same({}, calls.done)
  end)

  it("resolves the review when the last hunk is kept", function()
    local opts, calls = recorder()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    review.attach(bufnr, { "a", "b", "c" }, opts)

    review.keep(bufnr, 1)

    assert.same({ "resolved" }, calls.done)
    assert.is_false(review.is_attached(bufnr))
    assert.same({}, helpers.marks(bufnr))
    assert.same({ { "a", "X", "c" } }, calls.base)
  end)

  it("keeps the hunk under the cursor by default", function()
    local bufnr = helpers.buffer({ "a", "X", "c", "d", "Y" })
    review.attach(bufnr, { "a", "b", "c", "d", "e" }, {})
    vim.api.nvim_win_set_cursor(0, { 5, 0 })

    review.keep(bufnr)

    assert.same({ "a", "b", "c", "d", "Y" }, review.base(bufnr))
  end)

  it("keeps a pure deletion and a pure insertion", function()
    local opts, calls = recorder()
    local bufnr = helpers.buffer({ "a", "c", "d", "new", "e" })
    review.attach(bufnr, { "a", "b", "c", "d", "e" }, opts)
    assert.equal(2, #review.hunks(bufnr))

    review.keep(bufnr, 1)
    assert.same({ "a", "c", "d", "e" }, review.base(bufnr))
    review.keep(bufnr, 1)

    assert.same({ { "a", "c", "d", "e" }, { "a", "c", "d", "new", "e" } }, calls.base)
    assert.same({ "resolved" }, calls.done)
  end)

  it("says so and changes nothing when no hunk is under the cursor", function()
    local messages = {}
    local notify = vim.notify
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
    local bufnr = helpers.buffer({ "a", "X", "c", "d", "e" })
    review.attach(bufnr, { "a", "b", "c", "d", "e" }, {})
    vim.api.nvim_win_set_cursor(0, { 4, 0 })

    review.keep(bufnr)
    vim.notify = notify

    assert.same({ "a", "b", "c", "d", "e" }, review.base(bufnr))
    assert.equal(1, #messages)
    assert.is_truthy(messages[1]:find("no hunk", 1, true))
  end)

  it("works from the key", function()
    local opts, calls = recorder()
    local bufnr = helpers.buffer({ "a", "X", "c", "d", "Y" })
    review.attach(bufnr, { "a", "b", "c", "d", "e" }, opts)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    press("ko")

    assert.same({ "a", "X", "c", "d", "e" }, review.base(bufnr))
    assert.same({ { "a", "X", "c", "d", "e" } }, calls.base)
  end)

  it("survives a callback that throws", function()
    local messages = {}
    local notify = vim.notify
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
    local bufnr = helpers.buffer({ "a", "X", "c", "d", "Y" })
    review.attach(bufnr, { "a", "b", "c", "d", "e" }, {
      on_base = function()
        error("boom")
      end,
    })

    review.keep(bufnr, 1)
    vim.notify = notify

    assert.is_true(review.is_attached(bufnr))
    assert.same({ "a", "X", "c", "d", "e" }, review.base(bufnr))
    assert.is_truthy(messages[1]:find("boom", 1, true))
  end)
end)

describe("review engine navigation", function()
  -- Hunks start on rows 2 (changed), 5 (two lines changed) and 9 (a deletion hangs above row 9).
  local base = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" }
  local cur = { "a", "X", "c", "d", "E1", "E2", "g", "h", "j" }

  ---@return integer bufnr
  local function review_buffer()
    local bufnr = helpers.buffer(cur)
    review.attach(bufnr, base, {})
    assert.equal(3, #review.hunks(bufnr))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    return bufnr
  end

  ---@return integer
  local function row()
    return vim.api.nvim_win_get_cursor(0)[1]
  end

  before_each(function()
    review.setup({})
  end)

  after_each(helpers.reset)

  it("goes to the start of the next hunk and stops at the last one", function()
    review_buffer()
    local seen = {}
    for _ = 1, 4 do
      press("]k")
      seen[#seen + 1] = row()
    end
    assert.same({ 2, 5, 9, 9 }, seen)
  end)

  it("goes to the start of the previous hunk and stops at the first one", function()
    review_buffer()
    vim.api.nvim_win_set_cursor(0, { 9, 0 })
    local seen = {}
    for _ = 1, 4 do
      press("[k")
      seen[#seen + 1] = row()
    end
    assert.same({ 5, 2, 2, 2 }, seen)
  end)

  it("takes a count, as far as there are hunks", function()
    review_buffer()
    press("2]k")
    assert.equal(5, row())
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    press("7]k")
    assert.equal(9, row())
    press("2[k")
    assert.equal(2, row())
    press("9[k")
    assert.equal(2, row())
  end)

  it("goes to the last and the first hunk", function()
    review_buffer()
    press("]K")
    assert.equal(9, row())
    press("[K")
    assert.equal(2, row())
  end)

  it("treats the middle of a hunk as after its start", function()
    review_buffer()
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    press("[k")
    assert.equal(5, row())
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    press("]k")
    assert.equal(9, row())
  end)

  it("stays where it is when no hunk is left in that direction", function()
    review_buffer()
    press("[k")
    assert.equal(1, row())
    vim.api.nvim_win_set_cursor(0, { 9, 0 })
    press("]k")
    assert.equal(9, row())
  end)

  it("puts the cursor on the first non-blank character", function()
    local bufnr = helpers.buffer({ "a", "    X", "c", "d", "e" })
    review.attach(bufnr, { "a", "    b", "c", "d", "e" }, {})
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    press("]k")
    assert.same({ 2, 4 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("leaves a jumplist entry, so CTRL-O comes back", function()
    review_buffer()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    press("]k")
    assert.equal(5, row())
    press("<C-o>")
    assert.equal(3, row())
  end)
end)

---Open a file holding `text` and put it under review against `base`.
---@param text string
---@param base string[]
---@param opts? ClaudeCodeReviewAttachOpts
---@return integer bufnr
---@return string path
---@return table calls
local function review_file(text, base, opts)
  local bufnr, path = helpers.file_buffer(text)
  local recorded_opts, calls = recorder()
  review.attach(bufnr, base, vim.tbl_extend("force", recorded_opts, opts or {}))
  return bufnr, path, calls
end

describe("review engine revert", function()
  before_each(function()
    review.setup({})
  end)

  after_each(helpers.reset)

  it("puts the base lines back and keeps the base", function()
    local bufnr, _, calls = review_file("a\nX\nc\nd\nY\n", { "a", "b", "c", "d", "e" })

    review.revert(bufnr, 1)

    assert.same({ "a", "b", "c", "d", "Y" }, lines(bufnr))
    assert.same({ "a", "b", "c", "d", "e" }, review.base(bufnr))
    assert.equal(1, #review.hunks(bufnr))
    assert.same({}, calls.base)
    assert.same({}, calls.done)
  end)

  it("reports what was reverted, in the file's lines after the revert", function()
    local bufnr, path, calls = review_file("a\nX\nY\nc\nd\n", { "a", "b", "c", "d" })
    local before = os.time()

    review.revert(bufnr, 1)

    assert.equal(1, #calls.revert)
    local rec = calls.revert[1]
    assert.equal(vim.api.nvim_buf_get_name(bufnr), rec.path)
    assert.equal(vim.uv.fs_realpath(path), vim.uv.fs_realpath(rec.path))
    assert.equal(2, rec.line)
    assert.same({ "b" }, rec.base_lines)
    assert.same({ "X", "Y" }, rec.claude_lines)
    assert.is_true(rec.time >= before and rec.time <= os.time())
  end)

  it("points at Claude's text for an insertion, where nothing comes back", function()
    local bufnr, _, calls = review_file("a\nnew1\nnew2\nb\n", { "a", "b" })

    review.revert(bufnr, 1)

    assert.equal(2, calls.revert[1].line)
    assert.same({}, calls.revert[1].base_lines)
    assert.same({ "new1", "new2" }, calls.revert[1].claude_lines)
    assert.same({ "a", "b" }, lines(bufnr))
  end)

  it("brings back deleted lines, from the first returned one", function()
    local bufnr, _, calls = review_file("a\nd\n", { "a", "b", "c", "d" })

    review.revert(bufnr, 1)

    assert.same({ "a", "b", "c", "d" }, lines(bufnr))
    assert.equal(2, calls.revert[1].line)
    assert.same({ "b", "c" }, calls.revert[1].base_lines)
    assert.same({}, calls.revert[1].claude_lines)
  end)

  it("brings back a deleted first line and a deleted last line", function()
    local first = review_file("b\nc\n", { "a", "b", "c" })
    review.revert(first, 1)
    assert.same({ "a", "b", "c" }, lines(first))

    local last = review_file("a\nb\n", { "a", "b", "c" })
    review.revert(last, 1)
    assert.same({ "a", "b", "c" }, lines(last))
  end)

  it("removes a new file's text and leaves an empty file on disk", function()
    local opts, calls = recorder()
    local bufnr, path = helpers.file_buffer("a\nb\n")
    review.attach(bufnr, {}, opts)

    review.revert(bufnr, 1)

    assert.equal("", helpers.read_file(path))
    assert.same({ "resolved" }, calls.done)
  end)

  it("restores an emptied file", function()
    local bufnr, path = helpers.file_buffer("")
    local opts = recorder()
    review.attach(bufnr, { "a", "b" }, opts)
    assert.equal(1, #review.hunks(bufnr))

    review.revert(bufnr, 1)

    assert.same({ "a", "b" }, lines(bufnr))
    assert.equal("a\nb\n", helpers.read_file(path))
  end)

  it("writes the file at once", function()
    local bufnr, path = review_file("a\nX\nc\nd\nY\n", { "a", "b", "c", "d", "e" })

    review.revert(bufnr, 1)

    assert.equal("a\nb\nc\nd\nY\n", helpers.read_file(path))
    assert.is_false(vim.bo[bufnr].modified)
  end)

  it("leaves the file alone with write_on_revert = false", function()
    local bufnr, path = review_file("a\nX\nc\nd\nY\n", { "a", "b", "c", "d", "e" }, { write_on_revert = false })

    review.revert(bufnr, 1)

    assert.equal("a\nX\nc\nd\nY\n", helpers.read_file(path))
    assert.is_true(vim.bo[bufnr].modified)
  end)

  it("does not run the buffer's BufWritePre, but tells BufWritePost", function()
    local bufnr = review_file("a\nX\nc\nd\nY\n", { "a", "b", "c", "d", "e" })
    local seen = {}
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = bufnr,
      callback = function()
        seen[#seen + 1] = "pre"
      end,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
      buffer = bufnr,
      callback = function()
        seen[#seen + 1] = "post"
      end,
    })

    review.revert(bufnr, 1)

    assert.same({ "post" }, seen)
  end)

  it("is one undo step", function()
    local bufnr = review_file("a\nX\nc\nd\nY\n", { "a", "b", "c", "d", "e" })

    review.revert(bufnr, 1)
    vim.cmd("normal! u")

    assert.same({ "a", "X", "c", "d", "Y" }, lines(bufnr))
  end)

  it("keeps your own edit out of its undo step", function()
    local bufnr = review_file("a\nX\nc\nd\nY\nf\n", { "a", "b", "c", "d", "e", "f" })
    vim.api.nvim_buf_set_lines(bufnr, 5, 6, false, { "typed" })

    review.revert(bufnr, 1)
    assert.same({ "a", "b", "c", "d", "Y", "typed" }, lines(bufnr))
    vim.cmd("normal! u")

    assert.same({ "a", "X", "c", "d", "Y", "typed" }, lines(bufnr))
  end)

  it("works from the key, on the hunk under the cursor", function()
    local bufnr, path = review_file("a\nX\nc\nd\nY\n", { "a", "b", "c", "d", "e" })
    vim.api.nvim_win_set_cursor(0, { 5, 0 })

    press("kx")

    assert.same({ "a", "X", "c", "d", "e" }, lines(bufnr))
    assert.equal("a\nX\nc\nd\ne\n", helpers.read_file(path))
  end)

  it("resolves the review when the last hunk is reverted", function()
    local bufnr, _, calls = review_file("a\nX\nc\n", { "a", "b", "c" })

    review.revert(bufnr, 1)

    assert.same({ "resolved" }, calls.done)
    assert.is_false(review.is_attached(bufnr))
    assert.same({}, helpers.marks(bufnr))
  end)

  it("reverts a buffer that has no file without writing", function()
    local opts, calls = recorder()
    local bufnr = helpers.buffer({ "a", "X", "c" })
    review.attach(bufnr, { "a", "b", "c" }, opts)

    review.revert(bufnr, 1)

    assert.same({ "a", "b", "c" }, lines(bufnr))
    assert.equal(1, #calls.revert)
  end)

  it("reverts a buffer with CRLF line endings", function()
    local bufnr, path = helpers.file_buffer("a\r\nX\r\nc\r\n")
    assert.equal("dos", vim.bo[bufnr].fileformat)
    review.attach(bufnr, { "a", "b", "c" }, {})

    review.revert(bufnr, 1)

    assert.same({ "a", "b", "c" }, lines(bufnr))
    assert.equal("a\r\nb\r\nc\r\n", helpers.read_file(path))
  end)
end)

describe("review engine keep_all and revert_all", function()
  -- Three hunks: b -> X1 X2 (rows 2-3), e deleted (after row 5), "new" added at the end (row 8).
  local base = { "a", "b", "c", "d", "e", "f", "g" }
  local text = "a\nX1\nX2\nc\nd\nf\ng\nnew\n"

  before_each(function()
    review.setup({})
  end)

  after_each(helpers.reset)

  it("keeps everything at once: the base becomes the text", function()
    local bufnr, _, calls = review_file(text, base)
    assert.equal(3, #review.hunks(bufnr))

    review.keep_all(bufnr)

    assert.same({ { "a", "X1", "X2", "c", "d", "f", "g", "new" } }, calls.base)
    assert.same({ "resolved" }, calls.done)
    assert.same({ "a", "X1", "X2", "c", "d", "f", "g", "new" }, lines(bufnr))
  end)

  it("keeps an emptied file as an empty base", function()
    local opts, calls = recorder()
    local bufnr = helpers.file_buffer("")
    review.attach(bufnr, { "a", "b" }, opts)

    review.keep_all(bufnr)

    assert.same({ {} }, calls.base)
    assert.same({ "resolved" }, calls.done)
  end)

  it("keeps everything from the key", function()
    local bufnr, _, calls = review_file(text, base)

    press("KO")

    assert.equal(1, #calls.base)
    assert.same({ "resolved" }, calls.done)
    assert.is_false(review.is_attached(bufnr))
  end)

  it("reverts everything: the buffer becomes the base, the file is written once", function()
    local bufnr, path, calls = review_file(text, base)
    local writes = 0
    vim.api.nvim_create_autocmd("BufWritePost", {
      buffer = bufnr,
      callback = function()
        writes = writes + 1
      end,
    })

    review.revert_all(bufnr)

    assert.same(base, lines(bufnr))
    assert.equal("a\nb\nc\nd\ne\nf\ng\n", helpers.read_file(path))
    assert.equal(1, writes)
    assert.same({ "resolved" }, calls.done)
    assert.same({}, calls.base)
  end)

  it("tells about every hunk, in the file's lines after all reverts", function()
    local bufnr, _, calls = review_file(text, base)

    review.revert_all(bufnr)

    assert.equal(3, #calls.revert)
    assert.same({ 2, 5, 8 }, {
      calls.revert[1].line,
      calls.revert[2].line,
      calls.revert[3].line,
    })
    assert.same({ { "b" }, { "e" }, {} }, {
      calls.revert[1].base_lines,
      calls.revert[2].base_lines,
      calls.revert[3].base_lines,
    })
    assert.same({ { "X1", "X2" }, {}, { "new" } }, {
      calls.revert[1].claude_lines,
      calls.revert[2].claude_lines,
      calls.revert[3].claude_lines,
    })
  end)

  it("is one undo step", function()
    local bufnr = review_file(text, base)

    review.revert_all(bufnr)
    vim.cmd("normal! u")

    assert.same({ "a", "X1", "X2", "c", "d", "f", "g", "new" }, lines(bufnr))
  end)

  it("reverts everything from the key", function()
    local bufnr, path = review_file(text, base)

    press("KX")

    assert.same(base, lines(bufnr))
    assert.equal("a\nb\nc\nd\ne\nf\ng\n", helpers.read_file(path))
  end)

  it("leaves the file alone with write_on_revert = false", function()
    local bufnr, path = review_file(text, base, { write_on_revert = false })

    review.revert_all(bufnr)

    assert.same(base, lines(bufnr))
    assert.equal(text, helpers.read_file(path))
  end)
end)

describe("review engine user edits", function()
  -- One hunk on row 3; rows 1 and 5-8 are far enough from it to be edited without touching it.
  local base = { "a", "b", "c", "d", "e", "f", "g", "h" }
  local text = "a\nb\nX\nd\ne\nf\ng\nh\n"

  ---@return integer bufnr
  ---@return table calls
  local function reviewed()
    local bufnr, _, calls = review_file(text, base)
    assert.equal(1, #review.hunks(bufnr))
    return bufnr, calls
  end

  before_each(function()
    review.setup({})
  end)

  after_each(helpers.reset)

  it("carries an edit above the hunk into the base, without making a hunk of it", function()
    local bufnr, calls = reviewed()

    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "A" })
    helpers.flush()

    assert.same({ "A", "b", "c", "d", "e", "f", "g", "h" }, review.base(bufnr))
    assert.same({ { "A", "b", "c", "d", "e", "f", "g", "h" } }, calls.base)
    local hunks = review.hunks(bufnr)
    assert.equal(1, #hunks)
    assert.same({ "c" }, hunks[1].base_lines)
    assert.same({ "X" }, hunks[1].cur_lines)
  end)

  it("carries an edit below the hunk into the base", function()
    local bufnr, calls = reviewed()

    vim.api.nvim_buf_set_lines(bufnr, 5, 6, false, { "F" })
    helpers.flush()

    assert.same({ "a", "b", "c", "d", "e", "F", "g", "h" }, review.base(bufnr))
    assert.equal(1, #calls.base)
    assert.equal(1, #review.hunks(bufnr))
  end)

  it("carries inserted and deleted lines outside the hunk into the base", function()
    local bufnr = reviewed()

    vim.api.nvim_buf_set_lines(bufnr, 5, 5, false, { "ins1", "ins2" })
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})
    helpers.flush()

    assert.same({ "b", "c", "d", "e", "ins1", "ins2", "f", "g", "h" }, review.base(bufnr))
    local hunks = review.hunks(bufnr)
    assert.equal(1, #hunks)
    assert.equal(2, hunks[1].cur_start)
    assert.equal(2, hunks[1].base_start)
  end)

  it("carries a change made inside a line", function()
    local bufnr = reviewed()

    vim.api.nvim_buf_set_text(bufnr, 7, 0, 7, 1, { "HH" })
    helpers.flush()

    assert.same({ "a", "b", "c", "d", "e", "f", "g", "HH" }, review.base(bufnr))
  end)

  it("leaves the base alone for an edit inside the hunk and changes the hunk", function()
    local bufnr, calls = reviewed()

    vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "X2" })
    helpers.flush()

    assert.same(base, review.base(bufnr))
    assert.same({}, calls.base)
    assert.same({ "X2" }, review.hunks(bufnr)[1].cur_lines)
  end)

  it("leaves the base alone for an edit right next to the hunk", function()
    local bufnr, calls = reviewed()

    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "B" })
    helpers.flush()

    assert.same(base, review.base(bufnr))
    assert.same({}, calls.base)
    local hunks = review.hunks(bufnr)
    assert.equal(1, #hunks)
    assert.same({ "b", "c" }, hunks[1].base_lines)
    assert.same({ "B", "X" }, hunks[1].cur_lines)
  end)

  it("leaves the base alone when a line is added at the border of the hunk", function()
    local bufnr, calls = reviewed()

    vim.api.nvim_buf_set_lines(bufnr, 3, 3, false, { "below" })
    helpers.flush()

    assert.same(base, review.base(bufnr))
    assert.same({}, calls.base)
    assert.same({ "X", "below" }, review.hunks(bufnr)[1].cur_lines)
  end)

  it("resolves the review when you edit the hunk back to the base", function()
    local bufnr, calls = reviewed()

    vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "c" })
    helpers.flush()

    assert.same({ "resolved" }, calls.done)
    assert.is_false(review.is_attached(bufnr))
  end)

  it("tells about a burst of edits once, with the final base", function()
    local bufnr, calls = reviewed()
    local changed = 0
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "ClaudeCodeReviewChanged",
      callback = function()
        changed = changed + 1
      end,
    })

    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "A" })
    vim.api.nvim_buf_set_lines(bufnr, 7, 8, false, { "H" })
    vim.api.nvim_buf_set_lines(bufnr, 5, 6, false, { "F" })
    helpers.flush()
    vim.api.nvim_del_autocmd(id)

    assert.same({ { "A", "b", "c", "d", "e", "F", "g", "H" } }, calls.base)
    assert.equal(1, changed)
  end)

  it("redraws the marks where the hunk moved", function()
    local bufnr = reviewed()
    local function added_rows()
      return vim.tbl_map(
        function(mark)
          return mark.row
        end,
        vim.tbl_filter(function(mark)
          return mark.details.line_hl_group ~= nil
        end, helpers.marks(bufnr))
      )
    end
    assert.same({ 2 }, added_rows())

    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "top" })
    helpers.flush()

    assert.same({ 3 }, added_rows())
  end)

  it("tells the User autocmd after each recompute", function()
    local bufnr = reviewed()
    local seen = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "ClaudeCodeReviewChanged",
      callback = function(args)
        seen[#seen + 1] = args.data.hunks
      end,
    })

    vim.api.nvim_buf_set_lines(bufnr, 5, 5, false, { "ins" })
    helpers.flush()
    vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "c" })
    helpers.flush()
    vim.api.nvim_del_autocmd(id)

    assert.same({ 1, 0 }, seen)
  end)

  it("lets undo bring Claude's text back as your own edit, after a revert", function()
    -- known behaviour: the revert is not remembered, so `u` makes Claude's text part of the base
    local bufnr, _, calls = review_file("a\nX\nc\nd\ne\nf\nY\nh\n", base)
    assert.equal(2, #review.hunks(bufnr))

    review.revert(bufnr, 1)
    vim.cmd("normal! u")
    helpers.flush()

    assert.same({ "a", "X", "c", "d", "e", "f", "Y", "h" }, lines(bufnr))
    assert.same({ "a", "X", "c", "d", "e", "f", "g", "h" }, review.base(bufnr))
    assert.equal(1, #review.hunks(bufnr))
    assert.same({ "Y" }, review.hunks(bufnr)[1].cur_lines)
    assert.equal(1, #calls.revert)
  end)

  it("stops looking at the buffer after detach", function()
    local bufnr, calls = reviewed()
    review.detach(bufnr)

    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "A" })
    helpers.flush()

    assert.same({}, calls.base)
    assert.same({ "detached" }, calls.done)
  end)

  it("delivers the base moves that are still waiting when detach comes", function()
    local bufnr, calls = reviewed()

    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "A" })
    review.detach(bufnr)

    assert.same({ { "A", "b", "c", "d", "e", "f", "g", "h" } }, calls.base)
    assert.same({ "detached" }, calls.done)
  end)

  it("keeps working after a detach and attach again", function()
    local bufnr = reviewed()
    review.detach(bufnr)

    review.attach(bufnr, base, {})
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "A" })
    helpers.flush()

    assert.same({ "A", "b", "c", "d", "e", "f", "g", "h" }, review.base(bufnr))
  end)
end)

describe("review engine reload", function()
  local base = { "a", "b", "c", "d", "e", "f", "g", "h" }
  local text = "a\nb\nX\nd\ne\nf\ng\nh\n"

  before_each(function()
    review.setup({})
  end)

  after_each(helpers.reset)

  it("recomputes the hunks after checktime and carries nothing into the base", function()
    local bufnr, path, calls = review_file(text, base)

    -- Claude writes the file again
    helpers.write_file(path, "a\nb\nX\nd\ne\nf\nGGG\nh\nnew\n")
    vim.cmd("silent checktime")
    helpers.flush()

    assert.same({ "a", "b", "X", "d", "e", "f", "GGG", "h", "new" }, lines(bufnr))
    assert.same(base, review.base(bufnr))
    assert.same({}, calls.base)
    assert.equal(3, #review.hunks(bufnr))
    assert.is_true(review.is_attached(bufnr))
  end)

  it("redraws the marks after a reload", function()
    local bufnr, path = review_file(text, base)

    helpers.write_file(path, "a\nb\nc\nd\ne\nf\nGGG\nh\n")
    vim.cmd("silent checktime")
    helpers.flush()

    local rows = vim.tbl_map(
      function(mark)
        return mark.row
      end,
      vim.tbl_filter(function(mark)
        return mark.details.line_hl_group ~= nil
      end, helpers.marks(bufnr))
    )
    assert.same({ 6 }, rows)
  end)

  it("resolves the review when the reloaded file equals the base", function()
    local bufnr, path, calls = review_file(text, base)

    helpers.write_file(path, "a\nb\nc\nd\ne\nf\ng\nh\n")
    vim.cmd("silent checktime")
    helpers.flush()

    assert.same({ "resolved" }, calls.done)
    assert.is_false(review.is_attached(bufnr))
  end)

  it("survives :edit!, keeps tracking your edits and keeps its keys", function()
    local bufnr, path, calls = review_file(text, base)

    helpers.write_file(path, "a\nb\nX\nd\ne\nf\nGGG\nh\n")
    vim.cmd("silent edit!")
    helpers.flush()

    assert.is_true(review.is_attached(bufnr))
    assert.same({}, calls.done)
    assert.same({}, calls.base)
    assert.equal(2, #review.hunks(bufnr))
    assert.equal(1, buffer_map(bufnr, "ko").buffer)

    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "A" })
    helpers.flush()
    assert.same({ "A", "b", "c", "d", "e", "f", "g", "h" }, review.base(bufnr))
  end)

  it("detaches when a file buffer is unloaded", function()
    local bufnr, _, calls = review_file(text, base)
    helpers.buffer({ "other" })

    vim.cmd("silent bunload! " .. bufnr)
    helpers.flush()

    assert.is_false(review.is_attached(bufnr))
    assert.same({ "detached" }, calls.done)
    assert.same({}, helpers.marks(bufnr))
  end)

  it("does nothing on checktime when the file did not change", function()
    local bufnr, _, calls = review_file(text, base)

    vim.cmd("silent checktime")
    helpers.flush()

    assert.equal(1, #review.hunks(bufnr))
    assert.same({}, calls.base)
    assert.same({}, calls.done)
  end)
end)
