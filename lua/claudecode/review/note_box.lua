---@brief [[
--- The box a note is typed in: a bordered float right under a line of the buffer. Empty virtual
--- lines under that line make room for it, so the code below moves down instead of hiding behind
--- the box, and `bufpos` keeps the box on its line when the window scrolls.
---@brief ]]
---@module 'claudecode.review.note_box'

local M = {}

M.MAX_HEIGHT = 10

---@class ClaudeCodeNoteBoxOpts
---@field ns integer Namespace of the empty lines that make room for the box
---@field title string
---@field footer string
---@field text? string The note to edit
---@field keys table<string, fun(text: string)> Keys that close the box, in insert and normal mode, and what each does with the text
---@field on_dismiss? fun() The box closed without one of `keys`: you left its window

---@param n integer
---@return table[]
local function empty_lines(n)
  local lines = {}
  for i = 1, n do
    lines[i] = { { "", "" } }
  end
  return lines
end

---The width of the text in a box under a line of `win`; the border takes one more column on each side.
---A saved note is drawn as the same box, so both use this.
---@param win integer|nil
---@return integer
function M.width(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return 76
  end
  local info = vim.fn.getwininfo(win)[1]
  return math.max(20, math.min(100, info.width - info.textoff - 2))
end

---Open the box under `row` of the buffer in `win` and start Insert mode in it.
---@param win integer
---@param row integer 1-based
---@param opts ClaudeCodeNoteBoxOpts
---@return integer box The box's window
function M.open(win, row, opts)
  local bufnr = vim.api.nvim_win_get_buf(win)
  local width = M.width(win)

  local note_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[note_buf].bufhidden = "wipe"
  vim.bo[note_buf].filetype = "claudecode_note"
  -- blink.cmp and the like: <CR> must save the note, not accept a completion.
  vim.b[note_buf].completion = false
  if opts.text and opts.text ~= "" then
    vim.api.nvim_buf_set_lines(note_buf, 0, -1, false, vim.split(opts.text, "\n", { plain = true }))
  end

  -- The box sits under the last screen line of `row`, which may wrap.
  local row_height = vim.api.nvim_win_text_height(win, { start_row = row - 1, end_row = row - 1 })
  local box = vim.api.nvim_open_win(note_buf, true, {
    relative = "win",
    win = win,
    bufpos = { row - 1, 0 },
    row = row_height.all - row_height.fill,
    col = 0,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = opts.title,
    title_pos = "left",
    footer = opts.footer,
    footer_pos = "right",
    zindex = 50,
  })
  vim.wo[box].wrap = true
  vim.wo[box].linebreak = true

  ---Scroll the window down until `row` and the `room` lines under it fit, so the box never hangs
  ---over the statusline or past the window's bottom.
  ---@param room integer
  local function make_room(room)
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    local win_height = vim.api.nvim_win_get_height(win)
    local topline = vim.fn.getwininfo(win)[1].topline
    local top = topline
    -- The text height of a range leaves out the virtual lines under its last row: the room.
    local function used(t)
      return vim.api.nvim_win_text_height(win, { start_row = t - 1, end_row = row - 1 }).all + room
    end
    while top < row and used(top) > win_height do
      top = top + 1
    end
    if top ~= topline then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({ topline = top })
      end)
    end
  end

  local spacer
  local function fit()
    if not vim.api.nvim_win_is_valid(box) then
      return
    end
    local lines = vim.api.nvim_win_text_height(box, {}).all
    local h = math.max(1, math.min(M.MAX_HEIGHT, lines))
    vim.api.nvim_win_set_config(box, { height = h })
    -- Two more for the border.
    spacer = vim.api.nvim_buf_set_extmark(bufnr, opts.ns, row - 1, 0, { id = spacer, virt_lines = empty_lines(h + 2) })
    make_room(h + 2)
  end
  fit()

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    pcall(vim.api.nvim_buf_del_extmark, bufnr, opts.ns, spacer)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    end
    if vim.api.nvim_win_is_valid(box) then
      vim.api.nvim_win_close(box, true)
    end
  end

  local group = vim.api.nvim_create_augroup("ClaudeCodeNoteBox" .. box, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { group = group, buffer = note_buf, callback = fit })
  -- Leaving the box any other way (a window key, a mouse click) drops what was typed.
  vim.api.nvim_create_autocmd({ "WinLeave", "BufWipeout" }, {
    group = group,
    buffer = note_buf,
    callback = function()
      vim.schedule(function()
        if not closed then
          close()
          if opts.on_dismiss then
            opts.on_dismiss()
          end
        end
      end)
    end,
  })

  for lhs, action in pairs(opts.keys) do
    vim.keymap.set({ "i", "n" }, lhs, function()
      local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(note_buf, 0, -1, false), "\n"))
      vim.cmd.stopinsert()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      close()
      action(text)
    end, { buffer = note_buf, nowait = true })
  end

  vim.cmd(opts.text and opts.text ~= "" and "startinsert!" or "startinsert")
  return box
end

return M
