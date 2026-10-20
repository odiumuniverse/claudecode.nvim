--- Tests for notes on Claude's changes: the box you type them in, what is saved, what Claude gets.
local controller = require("claudecode.review.controller")
local engine = require("claudecode.review")
local notes = require("claudecode.review.notes")
local store_mod = require("claudecode.review.store")

local function write_file(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

---@return integer|nil win The box a note is typed in
local function box()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "claudecode_note" then
      return win
    end
  end
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

---The lines a saved note is drawn with under `row` (0-based), and their highlight groups.
---@return string[] lines, table<string, true> groups
local function drawn(bufnr, row)
  local lines, groups = {}, {}
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, notes.ns, { row, 0 }, { row, -1 }, { details = true })
  for _, mark in ipairs(marks) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      local text = ""
      for _, chunk in ipairs(line) do
        text = text .. chunk[1]
        if chunk[1] ~= "" then
          groups[chunk[2]] = true
        end
      end
      if text ~= "" then
        lines[#lines + 1] = text
      end
    end
  end
  return lines, groups
end

---The text of the saved note shown under `row` (0-based): the lines inside its box.
local function shown(bufnr, row)
  local inside = {}
  for _, line in ipairs((drawn(bufnr, row))) do
    local text = line:match("^%s*│ (.-)%s*│$")
    if text then
      inside[#inside + 1] = text
    end
  end
  return table.concat(inside, "\n")
end

---How many empty virtual lines hold the code apart under `row` (0-based) for the box.
local function spacer(bufnr, row)
  local count = 0
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, notes.ns, { row, 0 }, { row, -1 }, { details = true })
  for _, mark in ipairs(marks) do
    if mark[4].virt_lines and mark[4].virt_lines[1][1][1] == "" then
      count = count + #mark[4].virt_lines
    end
  end
  return count
end

describe("review notes", function()
  local work, dir, store, file, buf

  before_each(function()
    work = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(work, "p")
    work = vim.uv.fs_realpath(work)
    dir = vim.fn.tempname()
    store = store_mod.new(dir)
    controller.setup({ dir = dir })
    notes.setup({})
    engine.setup({ note = notes.open })
    -- Hunks on rows 2 and 5.
    file = work .. "/a.txt"
    write_file(file, "1\n2\n3\n4\n5\n")
    store:snapshot(file)
    write_file(file, "1\nX\n3\n4\nY\n")
    controller.refresh_pending()
    vim.cmd.edit(vim.fn.fnameescape(file))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    controller.teardown()
    engine.setup({})
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(work, "rf")
    vim.fn.delete(dir, "rf")
  end)

  it("opens a box under the line with the cursor and moves the code below out of its way", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    press("cr")

    local win = box()
    assert.is_not_nil(win)
    local config = vim.api.nvim_win_get_config(win)
    assert.equal("win", config.relative)
    assert.same({ 1, 0 }, config.bufpos)
    assert.equal(config.height + 2, spacer(buf, 1))
  end)

  it("saves the note on Enter, on disk, and leaves the box in place, dimmed", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    press("crwrap the error<CR>")

    assert.is_nil(box())
    assert.equal(buf, vim.api.nvim_get_current_buf())
    assert.equal("n", vim.api.nvim_get_mode().mode)
    assert.equal(0, spacer(buf, 1))
    local lines, groups = drawn(buf, 1)
    assert.equal(3, #lines)
    assert.equal("╭ note ╮", (lines[1]:gsub("─", "")))
    assert.equal("╰╯", (lines[3]:gsub("─", "")))
    assert.equal(vim.fn.strdisplaywidth(lines[1]), vim.fn.strdisplaywidth(lines[3]))
    assert.equal("wrap the error", shown(buf, 1))
    -- No hints about keys: the box is done with.
    assert.is_nil(table.concat(lines):find("save", 1, true))
    assert.same({ ClaudeCodeReviewNote = true, ClaudeCodeReviewNoteBorder = true }, groups)
    local saved = vim.json.decode(read_file(dir .. "/notes.json")).notes
    assert.equal(1, #saved)
    assert.same({ file, 2, 2, "wrap the error" }, { saved[1].path, saved[1].first, saved[1].last, saved[1].text })
  end)

  it("drops what you typed on Esc", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    press("crnever mind<Esc>")

    assert.is_nil(box())
    assert.equal(0, spacer(buf, 1))
    assert.equal("", shown(buf, 1))
    assert.same({}, notes.list())
  end)

  it("opens the note already on the line to edit it, and deletes it once emptied", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    press("crfirst<CR>")

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    press("cr and more<CR>")
    assert.equal("first and more", shown(buf, 1))
    assert.equal(1, #notes.list())

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    press("cr<C-u><CR>")
    assert.equal("", shown(buf, 1))
    assert.same({}, notes.list())
    assert.same({}, vim.json.decode(read_file(dir .. "/notes.json")).notes)
  end)

  it("takes the selected lines with <leader>an in visual mode", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    press("Vjj\\anthese three<CR>")

    local note = notes.list()[1]
    assert.same({ 2, 4 }, { note.first, note.last })
    assert.equal("these three", shown(buf, 3))
  end)

  it("keeps every line of a long note, wrapped inside the box", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local long = string.rep("one two three four five six seven eight nine ten ", 3)
    long = vim.trim(long)

    press("cr" .. long .. "<C-j>and a second line<CR>")

    local inside = vim.split(shown(buf, 1), "\n")
    assert.is_true(#inside >= 3)
    assert.equal(long, table.concat(vim.list_slice(inside, 1, #inside - 1), " "))
    assert.equal("and a second line", inside[#inside])
    local lines = drawn(buf, 1)
    for _, line in ipairs(lines) do
      assert.equal(vim.fn.strdisplaywidth(lines[1]), vim.fn.strdisplaywidth(line))
    end
  end)

  it("steps aside for the box that edits it, and comes back after Esc", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    press("crkeep me<CR>")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    notes.open(buf, 2, 2)
    assert.is_not_nil(box())
    assert.equal("", shown(buf, 1))
    press("<C-u>changed my mind<Esc>")

    assert.is_nil(box())
    assert.equal("keep me", shown(buf, 1))
  end)

  it("fits its box to the window again when the window gets narrower", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    press("crwrap the error<CR>")
    local wide = vim.fn.strdisplaywidth(drawn(buf, 1)[1])

    -- The Claude split opening next to the code, say. Both windows show the file: the box fits the
    -- narrower one, whichever comes first.
    -- The first window on the list is the wider one here.
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(0, 50)
    vim.cmd("wincmd l")
    local right = vim.api.nvim_get_current_win()
    local room = vim.api.nvim_win_get_width(right) - vim.fn.getwininfo(right)[1].textoff
    vim.api.nvim_exec_autocmds("WinResized", {})

    local narrow = vim.fn.strdisplaywidth(drawn(buf, 1)[1])
    vim.cmd("only")
    assert.is_true(narrow < wide)
    assert.is_true(narrow <= room, ("box %d, room %d"):format(narrow, room))
  end)

  it("shows at most as many lines as the box that typed it, and says there is more", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local lines = {}
    for i = 1, 15 do
      lines[i] = "line " .. i
    end

    press("cr" .. table.concat(lines, "<C-j>") .. "<CR>")

    local inside = vim.split(shown(buf, 1), "\n")
    assert.equal(require("claudecode.review.note_box").MAX_HEIGHT, #inside)
    assert.equal("…", inside[#inside])
    assert.equal(15, #vim.split(notes.list()[1].text, "\n"))
  end)

  it("keeps the indentation of code in a note", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    -- <C-u> takes back the indent 'autoindent' gives the new line.
    press("crif x then<C-j>  return y<C-j><C-u>end<CR>")

    assert.equal("if x then\n  return y\nend", shown(buf, 1))
  end)

  describe("sending to Claude", function()
    local terminal = require("claudecode.terminal")
    local original, original_bufnr, sent, accepted

    before_each(function()
      original, original_bufnr, sent, accepted = terminal.send_to_terminal, terminal.get_active_terminal_bufnr, {}, true
      terminal.send_to_terminal = function(text)
        sent[#sent + 1] = text
        return accepted
      end
      -- A Claude terminal runs, unless a test says otherwise.
      local claude_buf = vim.api.nvim_create_buf(false, true)
      terminal.get_active_terminal_bufnr = function()
        return accepted and claude_buf or nil
      end
    end)

    after_each(function()
      terminal.send_to_terminal = original
      terminal.get_active_terminal_bufnr = original_bufnr
    end)

    it("sends the notes of every file in one message on Shift+Enter, and forgets them", function()
      local other = work .. "/b.txt"
      write_file(other, "x\ny\n")
      store:snapshot(other)
      write_file(other, "x\nY\n")
      vim.cmd.edit(vim.fn.fnameescape(other))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      press("cruse a map<CR>")
      vim.cmd.edit(vim.fn.fnameescape(file))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      press("crwrap the error<S-CR>")

      assert.equal(1, #sent)
      assert.equal(
        table.concat({
          "Notes on your edits from my review in Neovim. Please rework these places:",
          "",
          "1. " .. file .. ":2",
          "   > X",
          "   wrap the error",
          "",
          "2. " .. other .. ":2",
          "   > Y",
          "   use a map",
        }, "\n"),
        sent[1]
      )
      assert.same({}, notes.list())
      assert.equal("", shown(buf, 1))
    end)

    it("sends with <C-s> as well, for a terminal that cannot tell Shift+Enter from Enter", function()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      press("crwrap the error<C-s>")

      assert.equal(1, #sent)
    end)

    it("sends every note with cR from anywhere", function()
      notes.setup({ send_keymap = "cR" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      press("crwrap the error<CR>")
      vim.cmd.enew()

      press("cR")

      assert.equal(1, #sent)
      assert.same({}, notes.list())
      pcall(vim.keymap.del, "n", "cR")
    end)

    it("sends on Enter with send = 'enter'", function()
      notes.setup({ send = "enter" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      press("crwrap the error<CR>")

      assert.equal(1, #sent)
    end)

    it("keeps the notes and puts the message in a register when no Claude terminal takes it", function()
      accepted = false
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      press("crwrap the error<S-CR>")

      assert.equal(1, #notes.list())
      assert.matches("wrap the error", vim.fn.getreg('"'))
    end)
  end)

  describe("as a decision on the hunk", function()
    -- Hunks on rows 2, 4 and 6.
    local three

    before_each(function()
      engine.setup({ note = notes.open, noted = notes.noted, goto_file = controller.goto_file })
      three = work .. "/c.txt"
      write_file(three, "1\n2\n3\n4\n5\n6\n7\n")
      store:snapshot(three)
      write_file(three, "1\nX\n3\nY\n5\nZ\n7\n")
      controller.refresh_pending()
      vim.cmd.edit(vim.fn.fnameescape(three))
    end)

    local function row()
      return vim.api.nvim_win_get_cursor(0)[1]
    end

    it("moves on to the next hunk once the note is saved", function()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      press("crfix<CR>")

      assert.equal(4, row())
    end)

    it("lets cs skip a hunk with a note", function()
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      press("crfix<CR>")
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      press("cs")

      assert.equal(6, row())
    end)

    it("counts a file whose hunks all have notes as done, with advance = 'file'", function()
      engine.setup({ advance = "file", note = notes.open, noted = notes.noted, goto_file = controller.goto_file })
      for _, r in ipairs({ 2, 4 }) do
        vim.api.nvim_win_set_cursor(0, { r, 0 })
        press("crfix<CR>")
      end
      vim.api.nvim_win_set_cursor(0, { 6, 0 })

      press("crfix<CR>")

      assert.equal("a.txt", vim.fn.expand("%:t"))
    end)

    it("stays on the spot with notes.advance = false", function()
      notes.setup({ advance = false })
      engine.setup({ note = notes.open, goto_file = controller.goto_file })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      press("crfix<CR>")

      assert.equal(2, row())
    end)
  end)

  it("drops a note on lines you revert: the text it was about is gone", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    press("crfix<CR>")
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    press("crand this<CR>")

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    press("cx")

    assert.equal("", shown(buf, 1))
    assert.equal(1, #notes.list())
    assert.equal("and this", notes.list()[1].text)
  end)

  it("keeps the notes through a restart and counts them in the status", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    press("crwrap the error<CR>")
    assert.equal("review: 1 file · 1 note", controller.status())

    controller.teardown()
    vim.cmd("silent! %bwipeout!")
    controller.setup({ dir = dir })
    vim.cmd.edit(vim.fn.fnameescape(file))

    assert.equal(1, #notes.list())
    assert.equal("wrap the error", shown(vim.api.nvim_get_current_buf(), 1))
    assert.equal("review: 1 file · 1 note", controller.status())
  end)

  it("keeps the note on its line when lines are added above it", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    press("crhere<CR>")

    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new 1", "new 2" })

    assert.equal("here", shown(buf, 3))
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    press("cr<C-u>moved<CR>")
    assert.equal(1, #notes.list())
    assert.equal("moved", notes.list()[1].text)
  end)

  describe("in a list", function()
    local other

    before_each(function()
      other = work .. "/b.txt"
      write_file(other, "b1\nb2\n")
      store:snapshot(other)
      write_file(other, "b1\nB2\n")
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      press("crlast<CR>")
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      press("crfirst<CR>")
      vim.cmd.edit(vim.fn.fnameescape(other))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      press("crin b<CR>")
    end)

    local function summary()
      return vim.tbl_map(function(item)
        return { vim.fn.fnamemodify(item.path, ":t"), item.first, item.text }
      end, notes.items())
    end

    it("lists the notes by file and line", function()
      assert.same({ { "a.txt", 2, "first" }, { "a.txt", 5, "last" }, { "b.txt", 2, "in b" } }, summary())
    end)

    it("knows where a note went once its file is saved and closed", function()
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new 1", "new 2" })
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
      vim.cmd("bwipeout " .. buf)

      assert.same({ { "a.txt", 4, "first" }, { "a.txt", 7, "last" }, { "b.txt", 2, "in b" } }, summary())
    end)

    it("removes a note from its open file, from disk and from the count", function()
      local b = vim.api.nvim_get_current_buf()

      notes.remove(notes.items()[3].id)

      assert.equal("", shown(b, 1))
      local saved = vim.tbl_map(function(note)
        return note.text
      end, vim.json.decode(read_file(dir .. "/notes.json")).notes)
      table.sort(saved)
      assert.same({ "first", "last" }, saved)
      assert.matches("· 2 notes$", controller.status())
    end)

    it("removes a note of a file that is not open", function()
      vim.cmd("bwipeout " .. buf)

      notes.remove(notes.items()[1].id)
      vim.cmd.edit(vim.fn.fnameescape(file))

      assert.equal("", shown(vim.api.nvim_get_current_buf(), 1))
      assert.same({ { "a.txt", 5, "last" }, { "b.txt", 2, "in b" } }, summary())
    end)
  end)
end)
