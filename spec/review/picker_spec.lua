--- Tests for the list of files waiting for review and its keep-all / revert-all actions.
local controller = require("claudecode.review.controller")
local notes = require("claudecode.review.notes")
local picker = require("claudecode.review.picker")
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

describe("review picker", function()
  local work, dir, store

  -- Claude changed `name` from `before` to `after` while you were away.
  local function changed(name, before, after)
    local path = work .. "/" .. name
    if before then
      write_file(path, before)
    end
    store:snapshot(path)
    write_file(path, after)
    return path
  end

  before_each(function()
    work = vim.fn.tempname()
    vim.fn.mkdir(work, "p")
    work = vim.uv.fs_realpath(work)
    dir = vim.fn.tempname()
    store = store_mod.new(dir)
    controller.setup({ dir = dir })
  end)

  after_each(function()
    controller.teardown()
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(work, "rf")
    vim.fn.delete(dir, "rf")
  end)

  it("lists the files waiting for review with their line counts", function()
    local a = changed("a.txt", "one\ntwo\n", "one\nTWO\nthree\n")
    local b = changed("b.txt", nil, "new\n")

    local items = picker.items()

    assert.equal(2, #items)
    assert.equal(a, items[1].path)
    assert.equal(2, items[1].added)
    assert.equal(1, items[1].removed)
    assert.is_false(items[1].new_file)
    assert.equal(b, items[2].path)
    assert.is_true(items[2].new_file)
    assert.matches("%+TWO", items[1].diff)
  end)

  describe("with notes", function()
    local a, c

    before_each(function()
      a = changed("a.txt", "1\n2\n3\n4\n5\n", "1\nX\n3\n4\nY\n")
      c = work .. "/c.txt"
      write_file(c, "c1\nc2\nc3\n")
      local saved = {
        { id = 1, path = a, first = 2, last = 2, text = "wrap it", created_at = 0 },
        { id = 2, path = c, first = 2, last = 3, text = "and this", created_at = 0 },
      }
      write_file(dir .. "/notes.json", vim.json.encode({ version = 1, notes = saved }))
      controller.teardown()
      controller.setup({ dir = dir })
      -- As the plugin wires them: a hunk with a note counts as decided.
      require("claudecode.review").setup({ note = notes.open, noted = notes.noted })
    end)

    after_each(function()
      require("claudecode.review").setup({})
    end)

    it("counts the hunks and notes of each file, and lists a file that has only notes", function()
      local items = picker.items()

      assert.same({ a, c }, { items[1].path, items[2].path })
      assert.same({ 2, 1 }, { items[1].hunks, items[1].notes })
      assert.same({ 0, 1 }, { items[2].hunks, items[2].notes })
      assert.matches("/a%.txt  %+2 %-2  2 hunks · 1 note$", items[1].label)
      assert.matches("/c%.txt         1 note$", items[2].label)
    end)

    it("opens a file that has only notes at its first note", function()
      picker.open(c)

      assert.equal(c, vim.api.nvim_buf_get_name(0))
      assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    ---Pick the note `index` from the list of notes, then `action`.
    local function choose(index, action)
      local select = vim.ui.select
      local labels, actions
      vim.ui.select = function(items, opts, on_choice)
        if not labels then
          labels = vim.tbl_map(opts.format_item, items)
          on_choice(items[index])
        else
          actions = items
          on_choice(action)
        end
      end
      picker.show_notes("select")
      vim.ui.select = select
      return labels, actions
    end

    it("lists the notes by file and line and deletes one", function()
      local labels, actions = choose(2, "delete")

      assert.matches("/a%.txt:2%s+wrap it$", labels[1])
      assert.matches("/c%.txt:2%-3  and this$", labels[2])
      assert.same({ "open", "delete", "send all" }, actions)
      assert.same(
        { "wrap it" },
        vim.tbl_map(function(note)
          return note.text
        end, notes.items())
      )
    end)

    it("opens a note in its box, and leaves the cursor on it once you save", function()
      choose(1, "open")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<End> in an error<CR>", true, false, true), "xt", false)

      assert.equal(a, vim.api.nvim_buf_get_name(0))
      assert.equal("wrap it in an error", notes.items()[1].text)
      assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    end)
  end)

  it("keeps a whole file without touching it", function()
    local a = changed("a.txt", "one\n", "two\n")

    picker.keep_all(a)

    assert.is_nil(store:get(a))
    assert.equal("two\n", read_file(a))
    assert.same({}, picker.items())
  end)

  it("reverts a whole closed file and tells Claude what came back", function()
    local a = changed("a.txt", "a\nb\nc\nd\ne\n", "a\nB\nc\nd\ne\nf\n")

    picker.revert_all(a)

    assert.equal("a\nb\nc\nd\ne\n", read_file(a))
    assert.is_nil(store:get(a))
    local reverts = store:take_reverts()
    assert.equal(2, #reverts)
    assert.same({ line = 2, base = { "b" }, claude = { "B" } }, {
      line = reverts[1].line,
      base = reverts[1].base_lines,
      claude = reverts[1].claude_lines,
    })
    assert.same({ line = 6, base = {}, claude = { "f" } }, {
      line = reverts[2].line,
      base = reverts[2].base_lines,
      claude = reverts[2].claude_lines,
    })
  end)

  it("deletes a new file when you revert it whole", function()
    local b = changed("b.txt", nil, "new\n")

    picker.revert_all(b)

    assert.is_nil(read_file(b))
    assert.is_nil(store:get(b))
  end)

  it("refuses to revert a file whose buffer has unsaved edits and no review", function()
    -- You were editing a.txt when Claude rewrote it on disk: the buffer never came under review.
    local a = work .. "/a.txt"
    write_file(a, "one\n")
    vim.cmd.edit(a)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "mine" })
    changed("a.txt", nil, "two\n")
    local notify = vim.notify
    local warned
    vim.notify = function(msg, level)
      warned = level
    end

    picker.revert_all(a)
    vim.notify = notify

    assert.equal(vim.log.levels.WARN, warned)
    assert.equal("two\n", read_file(a))
    assert.is_not_nil(store:get(a))
  end)

  it("keeps an open file through the review engine", function()
    local a = changed("a.txt", "one\n", "two\n")
    vim.cmd.edit(a)
    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(require("claudecode.review").is_attached(buf))

    picker.keep_all(a)

    assert.is_false(require("claudecode.review").is_attached(buf))
    assert.is_nil(store:get(a))
  end)

  it("offers open, keep all and revert all through vim.ui.select", function()
    local a = changed("a.txt", "one\n", "two\n")
    local select = vim.ui.select
    local prompts = {}
    vim.ui.select = function(items, opts, on_choice)
      prompts[#prompts + 1] = opts.prompt
      if #prompts == 1 then
        assert.matches("a%.txt  %+1 %-1", opts.format_item(items[1]))
        on_choice(items[1])
      else
        on_choice("revert all")
      end
    end

    picker.show("select")
    vim.ui.select = select

    assert.equal(2, #prompts)
    assert.equal("one\n", read_file(a))
  end)

  it("prefers snacks.picker, then fzf-lua, then vim.ui.select", function()
    local snacks = rawget(_G, "Snacks")
    _G.Snacks = { picker = { pick = function() end } }
    assert.equal("snacks", picker.backend("auto"))
    _G.Snacks = snacks
    assert.equal("select", picker.backend("select"))
  end)
end)
