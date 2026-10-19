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
