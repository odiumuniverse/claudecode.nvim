---@brief [[
--- Notes on Claude's changes: what you want Claude to rework, typed right under the line in
--- question. They are kept on disk next to the bases and go to Claude together, in one message.
---@brief ]]
---@module 'claudecode.review.notes'

local note_box = require("claudecode.review.note_box")

local M = {}

M.ns = vim.api.nvim_create_namespace("claudecode_review_notes")
-- The lines of each note in a loaded buffer, kept apart from what is drawn.
local track_ns = vim.api.nvim_create_namespace("claudecode_review_notes_track")

---@class ClaudeCodeReviewNotesOpts
---@field send? "batch"|"enter"
---@field advance? boolean
---@field send_keymap? string|false Global normal-mode key that sends every note

---@class ClaudeCodeReviewNote
---@field id integer
---@field path string
---@field first integer 1-based
---@field last integer
---@field text string
---@field created_at integer

local DEFAULTS = { send = "batch", advance = true, send_keymap = false }

local config = vim.deepcopy(DEFAULTS)

---@type { dir: string|nil, notes: ClaudeCodeReviewNote[], marks: table<integer, { buf: integer, track: integer, shown: integer }>, send_key: string|nil }
local state = { dir = nil, notes = {}, marks = {}, send_key = nil }

---@param opts ClaudeCodeReviewNotesOpts|nil
function M.setup(opts)
  config = vim.tbl_extend("force", vim.deepcopy(DEFAULTS), opts or {})
  if state.send_key then
    pcall(vim.keymap.del, "n", state.send_key)
    state.send_key = nil
  end
  -- Global, not buffer-local: the last cs of a review takes the buffer's keys away, and that is
  -- just when you want to send.
  if config.send_keymap then
    vim.keymap.set("n", config.send_keymap, function()
      M.send_all()
    end, { desc = "Claude: send the review notes" })
    state.send_key = config.send_keymap
  end
  pcall(vim.api.nvim_del_user_command, "ClaudeCodeReviewSend")
  vim.api.nvim_create_user_command("ClaudeCodeReviewSend", function()
    M.send_all()
  end, { desc = "Claude: send the review notes" })
  -- Virtual lines do not wrap: a box drawn for a wider window would lose its right edge once the
  -- Claude split, zen or a :vsplit narrows the window.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = vim.api.nvim_create_augroup("ClaudeCodeReviewNotes", { clear = true }),
    callback = function()
      M.refit()
    end,
  })
end

local function file_of(dir)
  return dir .. "/notes.json"
end

---Write the notes through a temporary file and a rename, as the store writes bases.
local function persist()
  if not state.dir then
    return
  end
  vim.fn.mkdir(state.dir, "p", tonumber("700", 8))
  local path = file_of(state.dir)
  local tmp = path .. ".tmp" .. vim.uv.os_getpid()
  local f = io.open(tmp, "wb")
  if not f then
    return
  end
  f:write(vim.json.encode({ version = 1, notes = state.notes }))
  f:close()
  vim.uv.fs_rename(tmp, path)
  require("claudecode.review.controller").announce()
end

---@param bufnr integer
---@return string|nil path
local function path_of(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return require("claudecode.review.store").normalize(name)
end

---Break `text` into lines of at most `width` display cells, at spaces where it can.
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
  local out = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    -- The indentation of code in a note stays; past the box's width it cannot.
    local indent = line:match("^%s*"):sub(1, math.floor(width / 2))
    local cur = indent
    for word in line:gmatch("%S+") do
      local joined = cur == indent and (indent .. word) or (cur .. " " .. word)
      if vim.fn.strdisplaywidth(joined) <= width then
        cur = joined
      else
        if cur ~= indent then
          out[#out + 1] = cur
        end
        while vim.fn.strdisplaywidth(word) > width do
          local part = vim.fn.strcharpart(word, 0, width)
          out[#out + 1] = part
          word = vim.fn.strcharpart(word, vim.fn.strchars(part))
        end
        cur = word
      end
    end
    out[#out + 1] = cur
  end
  return out
end

---A saved note as the box it was typed in, dimmed and without the hints, so it stays where your eyes
---were. The user found the one gray line it used to be hard to find. As high as the live box at most.
---@param text string
---@param width integer Text width of the box, as note_box.width gives it
---@return table[] virt_lines
function M.frame(text, width)
  local border, inner = "ClaudeCodeReviewNoteBorder", "ClaudeCodeReviewNote"
  local title = " note "
  local lines = { { { "╭" .. title .. string.rep("─", width - vim.fn.strdisplaywidth(title)) .. "╮", border } } }
  local wrapped = wrap(text, width - 2)
  local max = note_box.MAX_HEIGHT
  if #wrapped > max then
    wrapped = vim.list_slice(wrapped, 1, max - 1)
    wrapped[#wrapped + 1] = "…"
  end
  for _, line in ipairs(wrapped) do
    local pad = string.rep(" ", width - 2 - vim.fn.strdisplaywidth(line))
    lines[#lines + 1] = { { "│ ", border }, { line .. pad, inner }, { " │", border } }
  end
  lines[#lines + 1] = { { "╰" .. string.rep("─", width) .. "╯", border } }
  return lines
end

---Draw a saved note as a dimmed box under its last line.
---@param note ClaudeCodeReviewNote
---@param bufnr integer
local function draw(note, bufnr)
  local mark = state.marks[note.id]
  local first, last = note.first, note.last
  if mark then
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark.track, { details = true })
    if pos[1] then
      first, last = pos[1] + 1, (pos[3].end_row or pos[1]) + 1
    end
  end
  local count = vim.api.nvim_buf_line_count(bufnr)
  first, last = math.min(first, count), math.min(last, count)
  local track = vim.api.nvim_buf_set_extmark(bufnr, track_ns, first - 1, 0, {
    id = mark and mark.track or nil,
    end_row = last - 1,
    end_col = 0,
    right_gravity = false,
    end_right_gravity = true,
  })
  -- Virtual lines belong to the buffer, not to a window: fit the narrowest window that shows it.
  local width
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    width = math.min(width or math.huge, note_box.width(win))
  end
  local shown = vim.api.nvim_buf_set_extmark(bufnr, M.ns, last - 1, 0, {
    id = mark and mark.shown or nil,
    virt_lines = M.frame(note.text, width or note_box.width(nil)),
  })
  state.marks[note.id] = { buf = bufnr, track = track, shown = shown }
end

---Take the dimmed box off the screen while the live box edits the note; its lines stay tracked.
---@param note ClaudeCodeReviewNote
local function hide(note)
  local mark = state.marks[note.id]
  if mark and mark.shown and vim.api.nvim_buf_is_valid(mark.buf) then
    pcall(vim.api.nvim_buf_del_extmark, mark.buf, M.ns, mark.shown)
    mark.shown = nil
  end
end

---Draw every shown note again at the width of its window now.
function M.refit()
  for _, note in ipairs(state.notes) do
    local mark = state.marks[note.id]
    -- A box hidden for editing stays hidden.
    if mark and mark.shown and vim.api.nvim_buf_is_valid(mark.buf) then
      draw(note, mark.buf)
    end
  end
end

---@param note ClaudeCodeReviewNote
local function undraw(note)
  local mark = state.marks[note.id]
  if mark and vim.api.nvim_buf_is_valid(mark.buf) then
    pcall(vim.api.nvim_buf_del_extmark, mark.buf, track_ns, mark.track)
    pcall(vim.api.nvim_buf_del_extmark, mark.buf, M.ns, mark.shown)
  end
  state.marks[note.id] = nil
end

---Draw the notes of a buffer that was just read.
---@param bufnr integer
function M.attach(bufnr)
  local path = path_of(bufnr)
  if not path then
    return
  end
  for _, note in ipairs(state.notes) do
    if note.path == path then
      draw(note, bufnr)
    end
  end
end

---Use the notes in a state directory: the one of the project Claude works in.
---@param dir string
function M.use_dir(dir)
  if state.dir == dir then
    return
  end
  for _, note in ipairs(state.notes) do
    undraw(note)
  end
  state.dir = dir
  state.notes = {}
  local f = io.open(file_of(dir), "rb")
  if f then
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    f:close()
    if ok and type(data) == "table" and type(data.notes) == "table" then
      state.notes = data.notes
    end
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.attach(bufnr)
    end
  end
end

---Forget the directory and take the notes off the screen; they stay on disk. Used by teardown.
function M.reset()
  for _, note in ipairs(state.notes) do
    undraw(note)
  end
  state.dir, state.notes = nil, {}
end

---@return integer
function M.count()
  return #state.notes
end

---@return ClaudeCodeReviewNote[]
function M.list()
  return vim.deepcopy(state.notes)
end

---The note whose lines take in `row` of the buffer.
---@param bufnr integer
---@param row integer
---@return ClaudeCodeReviewNote|nil
local function note_at(bufnr, row)
  for _, note in ipairs(state.notes) do
    local mark = state.marks[note.id]
    if mark and mark.buf == bufnr then
      local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark.track, { details = true })
      if pos[1] and row - 1 >= pos[1] and row - 1 <= (pos[3].end_row or pos[1]) then
        return note
      end
    end
  end
end

---Is there a note on any of the lines `first`..`last` of the buffer?
---@param bufnr integer
---@param first integer
---@param last integer
---@return boolean
function M.noted(bufnr, first, last)
  for _, note in ipairs(state.notes) do
    local mark = state.marks[note.id]
    if mark and mark.buf == bufnr then
      local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark.track, { details = true })
      if pos[1] and pos[1] + 1 <= last and (pos[3].end_row or pos[1]) + 1 >= first then
        return true
      end
    end
  end
  return false
end

---Forget the notes on lines `first`..`last`: you reverted them, and the text they were about is gone.
---@param bufnr integer
---@param first integer
---@param last integer
function M.drop(bufnr, first, last)
  local before = #state.notes
  state.notes = vim.tbl_filter(function(note)
    local mark = state.marks[note.id]
    if not (mark and mark.buf == bufnr) then
      return true
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark.track, { details = true })
    if pos[1] and pos[1] + 1 <= last and (pos[3].end_row or pos[1]) + 1 >= first then
      undraw(note)
      return false
    end
    return true
  end, state.notes)
  if #state.notes ~= before then
    persist()
  end
end

---@param id integer
---@return boolean forgotten
local function forget(id)
  local before = #state.notes
  state.notes = vim.tbl_filter(function(note)
    if note.id == id then
      undraw(note)
      return false
    end
    return true
  end, state.notes)
  return #state.notes ~= before
end

---Delete a note, whether its file is open or not.
---@param id integer
function M.remove(id)
  if forget(id) then
    persist()
  end
end

---Save the text of a note, a new one or `note`; an empty text deletes it.
---@param bufnr integer
---@param first integer
---@param last integer
---@param text string
---@param note ClaudeCodeReviewNote|nil
local function save(bufnr, first, last, text, note)
  if note then
    if text == "" then
      forget(note.id)
    else
      note.text = text
      draw(note, bufnr)
    end
  elseif text ~= "" then
    local id = 1
    for _, n in ipairs(state.notes) do
      id = math.max(id, n.id + 1)
    end
    note = { id = id, path = path_of(bufnr), first = first, last = last, text = text, created_at = os.time() }
    state.notes[#state.notes + 1] = note
    draw(note, bufnr)
  end
  persist()
end

---Open the box for a note on lines `first`..`last` of the buffer, or for the note already there.
---@param bufnr integer
---@param first integer
---@param last integer
---@param opts { advance: boolean|nil }|nil `advance = false` keeps the cursor still after Enter
function M.open(bufnr, first, last, opts)
  local advance = config.advance and not (opts and opts.advance == false)
  local win = vim.api.nvim_win_get_buf(0) == bufnr and vim.api.nvim_get_current_win() or vim.fn.win_findbuf(bufnr)[1]
  if not win or not path_of(bufnr) then
    return
  end
  local note = note_at(bufnr, first)
  if note then
    local mark = state.marks[note.id]
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, track_ns, mark.track, { details = true })
    first, last = pos[1] + 1, (pos[3].end_row or pos[1]) + 1
  end
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
  local lines = first == last and tostring(first) or (first .. "-" .. last)
  local function save_and_send(text)
    save(bufnr, first, last, text, note)
    M.send_all()
  end
  -- The live box takes the place of the dimmed one while you edit; it comes back if you do not save.
  local function put_back()
    if note and state.marks[note.id] and vim.api.nvim_buf_is_valid(bufnr) then
      draw(note, bufnr)
    end
  end
  if note then
    hide(note)
  end
  note_box.open(win, last, {
    ns = M.ns,
    title = " note · " .. name .. ":" .. lines .. " ",
    footer = config.send == "enter" and " ⏎ send · esc cancel " or " ⏎ save · ⇧⏎ send all · esc cancel ",
    text = note and note.text or nil,
    keys = {
      ["<CR>"] = config.send == "enter" and save_and_send or function(text)
        save(bufnr, first, last, text, note)
        -- A note is a decision on the hunk: on to the next one, as after cs.
        if advance and text ~= "" then
          require("claudecode.review").move_on(bufnr, first)
        end
      end,
      ["<S-CR>"] = save_and_send,
      -- For a terminal that sends Shift+Enter as a plain Enter.
      ["<C-s>"] = save_and_send,
      ["<Esc>"] = put_back,
    },
    on_dismiss = put_back,
  })
end

---Where a note sits now: the lines of its mark while its buffer is loaded, else the saved ones.
---@param note ClaudeCodeReviewNote
---@return integer first, integer last, integer|nil bufnr
local function lines_of(note)
  local mark = state.marks[note.id]
  if mark and vim.api.nvim_buf_is_valid(mark.buf) then
    local pos = vim.api.nvim_buf_get_extmark_by_id(mark.buf, track_ns, mark.track, { details = true })
    if pos[1] then
      return pos[1] + 1, (pos[3].end_row or pos[1]) + 1, mark.buf
    end
  end
  return note.first, note.last, nil
end

---Open the file of a note at the note, with its box to edit it. Editing decides nothing, so the
---cursor stays on the note after Enter.
---@param id integer
function M.edit(id)
  local note
  for _, n in ipairs(state.notes) do
    if n.id == id then
      note = n
    end
  end
  if not note then
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(note.path))
  local bufnr = vim.api.nvim_get_current_buf()
  local first, last = lines_of(note)
  local count = vim.api.nvim_buf_line_count(bufnr)
  first, last = math.min(first, count), math.min(last, count)
  vim.api.nvim_win_set_cursor(0, { first, 0 })
  M.open(bufnr, first, last, { advance = false })
end

---The buffer is on disk now: its notes keep their lines there, for when the buffer is gone.
---Unsaved edits that move a note do not count, since they may never reach the file.
---@param bufnr integer
function M.written(bufnr)
  local moved = false
  for _, note in ipairs(state.notes) do
    local first, last, from = lines_of(note)
    if from == bufnr and (first ~= note.first or last ~= note.last) then
      note.first, note.last = first, last
      moved = true
    end
  end
  if moved then
    persist()
  end
end

---@class ClaudeCodeReviewNoteItem
---@field id integer
---@field path string
---@field first integer The line the note starts on now
---@field last integer
---@field text string
---@field bufnr integer|nil The loaded buffer of its file

---The notes by file and line, on the lines they sit on now.
---@return ClaudeCodeReviewNoteItem[]
function M.items()
  local items = {}
  for _, note in ipairs(state.notes) do
    local first, last, bufnr = lines_of(note)
    items[#items + 1] = { id = note.id, path = note.path, first = first, last = last, text = note.text, bufnr = bufnr }
  end
  table.sort(items, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.first < b.first
  end)
  return items
end

-- At most this many lines of the code a note is about go into the message, so Claude finds the spot.
local EXCERPT_LINES = 3

---@param path string
---@param first integer
---@param last integer
---@param bufnr integer|nil
---@return string[]
local function excerpt(path, first, last, bufnr)
  local stop = math.min(last, first + EXCERPT_LINES - 1)
  if bufnr then
    return vim.api.nvim_buf_get_lines(bufnr, first - 1, stop, false)
  end
  local lines, n = {}, 0
  local ok, iter = pcall(io.lines, path)
  if ok then
    for line in iter do
      n = n + 1
      if n >= first and n <= stop then
        lines[#lines + 1] = line
      elseif n > stop then
        break
      end
    end
  end
  return lines
end

---A path as Claude names it: relative to the working directory when the file is inside it.
---@param path string
---@return string
local function display_path(path)
  local cwd = vim.uv.cwd()
  if cwd and vim.startswith(path, cwd .. "/") then
    return path:sub(#cwd + 2)
  end
  return path
end

---The message that carries every note to Claude.
---@return string
function M.message()
  local parts = { "Notes on your edits from my review in Neovim. Please rework these places:" }
  for i, item in ipairs(M.items()) do
    local range = item.first == item.last and tostring(item.first) or (item.first .. "-" .. item.last)
    parts[#parts + 1] = ""
    parts[#parts + 1] = ("%d. %s:%s"):format(i, display_path(item.path), range)
    for _, line in ipairs(excerpt(item.path, item.first, item.last, item.bufnr)) do
      parts[#parts + 1] = "   > " .. vim.trim(line)
    end
    if item.last - item.first + 1 > EXCERPT_LINES then
      parts[#parts + 1] = "   > …"
    end
    for _, line in ipairs(vim.split(item.text, "\n", { plain = true })) do
      parts[#parts + 1] = "   " .. line
    end
  end
  return table.concat(parts, "\n")
end

---Send every note to the Claude terminal in Neovim and forget them. Without a terminal to take
---the message the notes stay, and the message goes to the clipboard.
---@return boolean sent
function M.send_all()
  if #state.notes == 0 then
    vim.notify("claudecode: no notes to send", vim.log.levels.INFO)
    return false
  end
  local message = M.message()
  local count = #state.notes
  local terminal = require("claudecode.terminal")
  -- Asked first, so that only this one warning shows when Claude is not running here.
  local term_buf = terminal.get_active_terminal_bufnr()
  local running = term_buf ~= nil and vim.api.nvim_buf_is_valid(term_buf)
  if running and terminal.send_to_terminal(message) then
    for _, note in ipairs(state.notes) do
      undraw(note)
    end
    state.notes = {}
    persist()
    vim.notify(("claudecode: sent %d %s to Claude"):format(count, count == 1 and "note" or "notes"))
    return true
  end
  pcall(vim.fn.setreg, "+", message)
  vim.fn.setreg('"', message)
  vim.notify(
    "claudecode: Claude is not running in Neovim. The notes stay, and the message is in the clipboard",
    vim.log.levels.WARN
  )
  return false
end

return M
