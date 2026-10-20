---@brief [[
--- List of files with hunks you have not reviewed yet (<leader>ak): open one, keep all of it
--- or revert all of it. Uses snacks.picker, then fzf-lua, then vim.ui.select.
---@brief ]]
---@module 'claudecode.review.picker'

local text = require("claudecode.review.text")

local M = {}

local function controller()
  return require("claudecode.review.controller")
end

local function engine()
  return require("claudecode.review")
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function loaded_buf(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end
  return nil
end

---@class ClaudeCodeReviewItem
---@field path string
---@field rel string Path relative to the cwd
---@field added integer Lines Claude added
---@field removed integer Lines Claude removed
---@field hunks integer Hunks waiting for review
---@field notes integer Notes not sent to Claude yet
---@field new_file boolean
---@field diff string Unified diff, base → file; empty for a file that has only notes
---@field label string The line of the list, in columns with the other items

local function plural(count, word)
  return ("%d %s"):format(count, count == 1 and word or word .. "s")
end

local function pad(s, width, left)
  local room = string.rep(" ", width - vim.fn.strdisplaywidth(s))
  return left and room .. s or s .. room
end

---Label the items in three columns: the file, its lines, its hunks and notes.
---@param items ClaudeCodeReviewItem[]
local function label_all(items)
  local names, lines = {}, {}
  local name_width, lines_width = 0, 0
  for i, item in ipairs(items) do
    names[i] = item.rel .. (item.new_file and " (new)" or "")
    lines[i] = item.hunks > 0 and ("+%d -%d"):format(item.added, item.removed) or ""
    name_width = math.max(name_width, vim.fn.strdisplaywidth(names[i]))
    lines_width = math.max(lines_width, vim.fn.strdisplaywidth(lines[i]))
  end
  for i, item in ipairs(items) do
    local counts = {}
    if item.hunks > 0 then
      counts[#counts + 1] = plural(item.hunks, "hunk")
    end
    if item.notes > 0 then
      counts[#counts + 1] = plural(item.notes, "note")
    end
    item.label = pad(names[i], name_width)
      .. "  "
      .. pad(lines[i], lines_width, true)
      .. "  "
      .. table.concat(counts, " · ")
  end
end

---@return ClaudeCodeReviewItem[]
function M.items()
  local store = controller().store()
  local items, by_path = {}, {}
  if not store then
    return items
  end
  for _, path in ipairs(controller().refresh_pending()) do
    local base = store:get(path)
    if base then
      local current = read_file(path) or ""
      local hunks = require("claudecode.review.hunks").compute((text.to_lines(base.text)), (text.to_lines(current)))
      local added, removed = 0, 0
      for _, hunk in ipairs(hunks) do
        added = added + hunk.cur_count
        removed = removed + hunk.base_count
      end
      items[#items + 1] = {
        path = path,
        rel = vim.fn.fnamemodify(path, ":~:."),
        added = added,
        removed = removed,
        hunks = #hunks,
        notes = 0,
        new_file = base.new_file,
        diff = vim.text.diff(base.text, current, { ctxlen = 3 }) or "",
      }
      by_path[path] = items[#items]
    end
  end
  -- A file whose hunks are all decided may still have notes waiting to go to Claude.
  for _, note in ipairs(require("claudecode.review.notes").items()) do
    local item = by_path[note.path]
    if not item then
      item = {
        path = note.path,
        rel = vim.fn.fnamemodify(note.path, ":~:."),
        added = 0,
        removed = 0,
        hunks = 0,
        notes = 0,
        new_file = false,
        diff = "",
      }
      items[#items + 1] = item
      by_path[note.path] = item
    end
    item.notes = item.notes + 1
  end
  table.sort(items, function(a, b)
    return a.path < b.path
  end)
  label_all(items)
  return items
end

---Open the file at its first hunk, or at its first note when no hunk is left.
---@param path string
function M.open(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local hunks = engine().is_attached(buf) and engine().hunks(buf) or {}
  if hunks[1] then
    local row = require("claudecode.review.hunks").anchor(hunks[1], vim.api.nvim_buf_line_count(buf))
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    return
  end
  for _, note in ipairs(require("claudecode.review.notes").items()) do
    if note.path == path then
      vim.api.nvim_win_set_cursor(0, { math.min(note.first, vim.api.nvim_buf_line_count(buf)), 0 })
      return
    end
  end
end

---Accept everything Claude changed in the file.
---@param path string
function M.keep_all(path)
  -- A file that has only notes has nothing to keep.
  local store = controller().store()
  if not (store and store:get(path)) or controller().in_doubt(path) then
    return
  end
  local buf = loaded_buf(path)
  if buf and engine().is_attached(buf) then
    engine().keep_all(buf)
  else
    controller().store():remove(path)
  end
  controller().refresh_pending()
end

---Undo everything Claude changed in the file and tell Claude about it.
---@param path string
function M.revert_all(path)
  local store = controller().store()
  if not (store and store:get(path)) or controller().in_doubt(path) then
    return
  end
  local buf = loaded_buf(path)
  if buf and engine().is_attached(buf) then
    engine().revert_all(buf)
    controller().refresh_pending()
    return
  end
  if buf and vim.bo[buf].modified then
    vim.notify(
      "claudecode: " .. vim.fn.fnamemodify(path, ":~:.") .. " has unsaved edits; save or drop them first",
      vim.log.levels.WARN
    )
    return
  end
  local base = store:get(path)
  local current = read_file(path) or ""
  local base_lines = text.to_lines(base.text)
  local hunks = require("claudecode.review.hunks").compute(base_lines, (text.to_lines(current)))
  -- After the revert the file is the base, so base coordinates are file coordinates.
  for _, hunk in ipairs(hunks) do
    store:append_revert({
      path = path,
      line = hunk.base_count > 0 and hunk.base_start or hunk.base_start + 1,
      base_lines = hunk.base_lines,
      claude_lines = hunk.cur_lines,
      time = os.time(),
    })
  end
  if base.new_file then
    vim.fn.delete(path)
    if buf then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  else
    local f = assert(io.open(path, "wb"))
    f:write(base.text)
    f:close()
    if buf then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent! edit")
      end)
    end
  end
  store:remove(path)
  controller().refresh_pending()
end

local function label(item)
  return item.label
end

---What the preview shows for a file: the diff, then the notes not sent yet.
---@param item ClaudeCodeReviewItem
---@return string[]
local function preview_lines(item)
  local lines = item.diff ~= "" and vim.split(item.diff, "\n", { plain = true }) or {}
  for _, note in ipairs(require("claudecode.review.notes").items()) do
    if note.path == item.path then
      lines[#lines + 1] = ("# note at line %d: %s"):format(note.first, (note.text:gsub("\n", " ")))
    end
  end
  return lines
end

local function show_snacks(items)
  local Snacks = rawget(_G, "Snacks")
  local picker_items = {}
  for i, item in ipairs(items) do
    picker_items[i] = { idx = i, text = label(item), file = item.path, review = item }
  end
  Snacks.picker.pick({
    title = "Claude review",
    items = picker_items,
    format = "text",
    preview = function(ctx)
      ctx.preview:reset()
      ctx.preview:set_lines(preview_lines(ctx.item.review))
      ctx.preview:highlight({ ft = "diff" })
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(function()
          M.open(item.review.path)
        end)
      end
    end,
    actions = {
      review_keep_all = function(picker, item)
        picker:close()
        if item then
          M.keep_all(item.review.path)
        end
      end,
      review_revert_all = function(picker, item)
        picker:close()
        if item then
          M.revert_all(item.review.path)
        end
      end,
    },
    win = {
      input = {
        keys = {
          ["<a-o>"] = { "review_keep_all", mode = { "n", "i" }, desc = "keep all" },
          ["<a-x>"] = { "review_revert_all", mode = { "n", "i" }, desc = "revert all" },
        },
      },
    },
  })
end

local function show_fzf(items)
  local by_label = {}
  local entries = {}
  for _, item in ipairs(items) do
    local entry = label(item)
    by_label[entry] = item
    entries[#entries + 1] = entry
  end
  local function act(fn)
    return function(selected)
      local item = selected and by_label[selected[1]]
      if item then
        fn(item.path)
      end
    end
  end
  require("fzf-lua").fzf_exec(entries, {
    prompt = "Claude review> ",
    actions = {
      ["default"] = act(M.open),
      ["alt-o"] = act(M.keep_all),
      ["alt-x"] = act(M.revert_all),
    },
  })
end

local function show_select(items)
  vim.ui.select(items, { prompt = "Claude review", format_item = label }, function(item)
    if not item then
      return
    end
    local actions = { "open", "keep all", "revert all" }
    vim.ui.select(actions, { prompt = item.rel }, function(choice)
      if choice == "open" then
        M.open(item.path)
      elseif choice == "keep all" then
        M.keep_all(item.path)
      elseif choice == "revert all" then
        M.revert_all(item.path)
      end
    end)
  end)
end

---@param backend "auto"|"snacks"|"fzf"|"select"|nil
---@return "snacks"|"fzf"|"select"
function M.backend(backend)
  if backend and backend ~= "auto" then
    return backend
  end
  local Snacks = rawget(_G, "Snacks")
  if Snacks and Snacks.picker and type(Snacks.picker.pick) == "function" then
    return "snacks"
  end
  if pcall(require, "fzf-lua") then
    return "fzf"
  end
  return "select"
end

---Show the files waiting for review.
---@param backend "auto"|"snacks"|"fzf"|"select"|nil
function M.show(backend)
  local items = M.items()
  if #items == 0 then
    vim.notify("claudecode: nothing waits for review")
    return
  end
  local chosen = M.backend(backend)
  if chosen == "snacks" then
    show_snacks(items)
  elseif chosen == "fzf" then
    show_fzf(items)
  else
    show_select(items)
  end
end

local function notes()
  return require("claudecode.review.notes")
end

local preview_ns = vim.api.nvim_create_namespace("claudecode_review_notes_preview")

---The notes, each labeled in two columns: where it sits, and the first line of its text.
---@return ClaudeCodeReviewNoteItem[] items Each with a `label`
local function note_items()
  local items = notes().items()
  local places, width = {}, 0
  for i, item in ipairs(items) do
    local range = item.first == item.last and tostring(item.first) or (item.first .. "-" .. item.last)
    places[i] = vim.fn.fnamemodify(item.path, ":~:.") .. ":" .. range
    width = math.max(width, vim.fn.strdisplaywidth(places[i]))
  end
  for i, item in ipairs(items) do
    local more = item.text:find("\n", 1, true) and " …" or ""
    item.label = pad(places[i], width) .. "  " .. item.text:match("^[^\n]*") .. more
  end
  return items
end

---The file of a note in the preview, the note drawn under its lines as in the file itself.
local function preview_note(ctx)
  local note = ctx.item.note
  ctx.preview:reset()
  local lines = note.bufnr and vim.api.nvim_buf_get_lines(note.bufnr, 0, -1, false)
    or (vim.fn.filereadable(note.path) == 1 and vim.fn.readfile(note.path) or {})
  ctx.preview:set_lines(lines)
  ctx.preview:highlight({ file = note.path })
  local last = math.min(note.last, #lines)
  if last > 0 then
    local width = require("claudecode.review.note_box").width(ctx.preview.win.win)
    vim.api.nvim_buf_set_extmark(ctx.preview.win.buf, preview_ns, last - 1, 0, {
      virt_lines = notes().frame(note.text, width),
    })
  end
  ctx.preview:loc()
end

local function show_notes_snacks()
  local Snacks = rawget(_G, "Snacks")
  Snacks.picker.pick({
    title = "Claude notes",
    finder = function()
      return vim.tbl_map(function(item)
        return { text = item.label, file = item.path, pos = { item.first, 0 }, note = item }
      end, note_items())
    end,
    format = "text",
    preview = preview_note,
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(function()
          notes().edit(item.note.id)
        end)
      end
    end,
    actions = {
      note_delete = function(picker, item)
        if not item then
          return
        end
        notes().remove(item.note.id)
        if notes().count() == 0 then
          picker:close()
        else
          picker:refresh()
        end
      end,
      note_send_all = function(picker)
        picker:close()
        vim.schedule(notes().send_all)
      end,
    },
    win = {
      input = {
        keys = {
          ["<a-d>"] = { "note_delete", mode = { "n", "i" }, desc = "delete" },
          ["<c-s>"] = { "note_send_all", mode = { "n", "i" }, desc = "send all" },
        },
        footer = " ⏎ open · alt-d delete · ctrl-s send all ",
        footer_pos = "center",
      },
    },
  })
end

local function show_notes_fzf()
  local by_label, entries = {}, {}
  for _, item in ipairs(note_items()) do
    by_label[item.label] = item
    entries[#entries + 1] = item.label
  end
  local function act(fn)
    return function(selected)
      local item = selected and by_label[selected[1]]
      if item then
        fn(item)
      end
    end
  end
  require("fzf-lua").fzf_exec(entries, {
    prompt = "Claude notes> ",
    actions = {
      ["default"] = act(function(item)
        notes().edit(item.id)
      end),
      ["alt-d"] = act(function(item)
        notes().remove(item.id)
        if notes().count() > 0 then
          vim.schedule(show_notes_fzf)
        end
      end),
      ["ctrl-s"] = function()
        notes().send_all()
      end,
    },
  })
end

local function show_notes_select()
  local function format_item(item)
    return item.label
  end
  vim.ui.select(note_items(), { prompt = "Claude notes", format_item = format_item }, function(item)
    if not item then
      return
    end
    vim.ui.select({ "open", "delete", "send all" }, { prompt = item.label }, function(choice)
      if choice == "open" then
        notes().edit(item.id)
      elseif choice == "delete" then
        notes().remove(item.id)
      elseif choice == "send all" then
        notes().send_all()
      end
    end)
  end)
end

---Show the notes not sent to Claude yet: open one to edit it, delete one, or send them all.
---@param backend "auto"|"snacks"|"fzf"|"select"|nil
function M.show_notes(backend)
  if notes().count() == 0 then
    vim.notify("claudecode: no notes for Claude")
    return
  end
  local chosen = M.backend(backend)
  if chosen == "snacks" then
    show_notes_snacks()
  elseif chosen == "fzf" then
    show_notes_fzf()
  else
    show_notes_select()
  end
end

return M
