---@brief [[
--- Review engine: shows what Claude changed in a buffer against a base text and lets the user
--- keep (`ko`) or revert (`kx`) it hunk by hunk. It knows nothing about hooks, state on disk or
--- Claude: the caller hands over a buffer and a base and gets callbacks back.
---@brief ]]
---@module 'claudecode.review'

local disk = require("claudecode.review.disk")
local hunk_logic = require("claudecode.review.hunks")
local keymaps = require("claudecode.review.keymaps")
local render = require("claudecode.review.render")

local M = {}

---@class ClaudeCodeReviewAttachOpts
---@field on_base? fun(base: string[])                -- the base moved: ko, KO, your edit outside a hunk
---@field on_revert? fun(rec: ClaudeCodeRevertRecord) -- kx/KX was applied to the buffer
---@field on_done? fun(reason: "resolved"|"detached") -- no hunks left, or detach was called
---@field write_on_revert? boolean                    -- default true: kx writes the file at once

---@class ClaudeCodeRevertRecord
---@field path string           -- absolute path of the buffer
---@field line integer          -- first line of the returned text in the file after the revert
---@field base_lines string[]   -- the text that came back
---@field claude_lines string[] -- Claude's text that was reverted
---@field time integer          -- os.time()

---@class ClaudeCodeReviewKeymaps
---@field keep? string|false
---@field revert? string|false
---@field keep_all? string|false
---@field revert_all? string|false
---@field next? string|false
---@field prev? string|false
---@field last? string|false
---@field first? string|false

---@class ClaudeCodeReviewConfig
---@field keymaps ClaudeCodeReviewKeymaps
---@field hint string|false
---@field word_diff boolean

---@class ClaudeCodeReviewDirty
---@field base boolean  -- on_base is owed to the caller
---@field draw boolean  -- the marks are out of date
---@field event boolean -- ClaudeCodeReviewChanged is owed

---@class ClaudeCodeReviewState
---@field bufnr integer
---@field base string[]
---@field hunks ClaudeCodeHunk[]
---@field line_count integer  -- lines of the text `hunks` describe
---@field opts ClaudeCodeReviewAttachOpts
---@field gen integer         -- generation of the nvim_buf_attach callbacks; older ones switch themselves off
---@field dead boolean
---@field own_edit boolean    -- set while the engine itself changes the buffer
---@field flush_pending boolean
---@field dirty ClaudeCodeReviewDirty
---@field augroup integer
---@field maps ClaudeCodeReviewSavedMaps
---@field stamp ClaudeCodeDiskStamp|nil -- the file as the buffer last knew it
---@field reloaded boolean    -- the buffer was reloaded from disk (checked by kx)

---@type ClaudeCodeReviewConfig
local DEFAULT_CONFIG = {
  keymaps = {
    keep = "ko",
    revert = "kx",
    keep_all = "KO",
    revert_all = "KX",
    next = "]k",
    prev = "[k",
    last = "]K",
    first = "[K",
  },
  hint = render.DEFAULT_HINT,
  word_diff = true,
}

---@type ClaudeCodeReviewConfig
local config = vim.deepcopy(DEFAULT_CONFIG)

---@type table<integer, ClaudeCodeReviewState>
local states = {}

local flush
local mappings_for
local jump

---@param msg string
local function fail(msg)
  error("claudecode.review.setup: " .. msg, 3)
end

---@param opts table|nil
local function check_setup_opts(opts)
  if opts == nil then
    return
  end
  if type(opts) ~= "table" then
    fail("opts must be a table, got " .. type(opts))
  end
  for key, value in pairs(opts) do
    if key == "keymaps" then
      if type(value) ~= "table" then
        fail("keymaps must be a table, got " .. type(value))
      end
      for name, lhs in pairs(value) do
        if DEFAULT_CONFIG.keymaps[name] == nil then
          fail("unknown keymap '" .. tostring(name) .. "'")
        end
        if lhs ~= false and (type(lhs) ~= "string" or lhs == "") then
          fail(("keymaps.%s must be a non-empty string or false, got %s"):format(name, vim.inspect(lhs)))
        end
      end
    elseif key == "hint" then
      if value ~= false and type(value) ~= "string" then
        fail("hint must be a string or false, got " .. vim.inspect(value))
      end
    elseif key == "word_diff" then
      if type(value) ~= "boolean" then
        fail("word_diff must be a boolean, got " .. vim.inspect(value))
      end
    else
      fail("unknown option '" .. tostring(key) .. "'")
    end
  end
end

---@param opts { keymaps?: ClaudeCodeReviewKeymaps, hint?: string|false, word_diff?: boolean }|nil
function M.setup(opts)
  check_setup_opts(opts)
  config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})
  render.setup()
end

---@param what string
---@param err any
local function report_error(what, err)
  vim.notify(("claudecode review: %s failed: %s"):format(what, tostring(err)), vim.log.levels.ERROR)
end

---Call a caller-supplied callback. A broken callback must not take the engine down with it.
---@param st ClaudeCodeReviewState
---@param name string
local function call(st, name, ...)
  local fn = st.opts[name]
  if not fn then
    return
  end
  local ok, err = pcall(fn, ...)
  if not ok then
    report_error(name, err)
  end
end

---The lines hunks are computed from. A buffer holding one empty line is an empty file, unless the
---base itself is that single empty line (the buffer cannot tell the two apart).
---@param st ClaudeCodeReviewState
---@return string[]
local function current_lines(st)
  local lines = vim.api.nvim_buf_get_lines(st.bufnr, 0, -1, false)
  if #lines == 1 and lines[1] == "" and not (#st.base == 1 and st.base[1] == "") then
    return {}
  end
  return lines
end

---@param st ClaudeCodeReviewState
local function recompute(st)
  local lines = current_lines(st)
  st.line_count = #lines
  st.hunks = hunk_logic.compute(st.base, lines)
  st.dirty.draw = true
  st.dirty.event = true
end

---@param st ClaudeCodeReviewState
---@return ClaudeCodeReviewDrawOpts
local function draw_opts(st)
  return { word_diff = config.word_diff, hint = config.hint, line_count = st.line_count }
end

---@param st ClaudeCodeReviewState
local function fire_changed(st)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "ClaudeCodeReviewChanged",
    modeline = false,
    data = { bufnr = st.bufnr, path = vim.api.nvim_buf_get_name(st.bufnr), hunks = #st.hunks },
  })
end

---Take the keys, autocmds and marks away and forget the buffer.
---@param st ClaudeCodeReviewState
local function cleanup(st)
  if states[st.bufnr] == st then
    states[st.bufnr] = nil
  end
  if st.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, st.augroup)
  end
  if st.maps then
    pcall(keymaps.restore, st.bufnr, st.maps)
  end
  if vim.api.nvim_buf_is_valid(st.bufnr) then
    render.clear(st.bufnr)
  end
end

---Leave review. `on_done` runs while the buffer still counts as attached, so the caller can read
---the last base and hunks; the engine does nothing in the meantime (`dead`). An `attach` from inside
---`on_done` waits until the old review is cleaned up and then starts the new one.
---@param st ClaudeCodeReviewState
---@param reason "resolved"|"detached"
local function finish(st, reason)
  if st.dead then
    return
  end
  if st.dirty.base then
    st.dirty.base = false
    call(st, "on_base", vim.deepcopy(st.base))
    if st.dead then
      return
    end
  end
  st.dead = true
  call(st, "on_done", reason)
  cleanup(st)

  local again = st.reattach
  if again and vim.api.nvim_buf_is_valid(st.bufnr) and vim.api.nvim_buf_is_loaded(st.bufnr) then
    local ok, err = pcall(M.attach, st.bufnr, again.base, again.opts)
    if not ok then
      report_error("attach", err)
    end
  end
end

---Deliver what is owed to the caller and the screen, in a fixed order.
---@param st ClaudeCodeReviewState
flush = function(st)
  if st.dead then
    return
  end
  local dirty = st.dirty
  st.dirty = { base = false, draw = false, event = false }

  if dirty.base then
    call(st, "on_base", vim.deepcopy(st.base))
    if st.dead then
      return
    end
  end
  if dirty.draw and vim.api.nvim_buf_is_valid(st.bufnr) then
    -- A drawing bug must not swallow the callbacks and the event that follow.
    local ok, err = pcall(render.draw, st.bufnr, st.hunks, draw_opts(st))
    if not ok then
      report_error("drawing", err)
    end
  end
  if dirty.event then
    fire_changed(st)
    if st.dead then
      return
    end
  end
  if #st.hunks == 0 then
    finish(st, "resolved")
  end
end

---Edits arrive from `on_lines`, where only reading is safe: deliver later, once for a burst.
---@param st ClaudeCodeReviewState
local function schedule_flush(st)
  if st.flush_pending then
    return
  end
  st.flush_pending = true
  vim.schedule(function()
    st.flush_pending = false
    flush(st)
  end)
end

---Deleted lines are padded to the width of the window, so a resize makes the padding wrong.
local function watch_resizes()
  local group = vim.api.nvim_create_augroup("ClaudeCodeReviewResize", { clear = true })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    desc = "Claude review: pad deleted lines to the new window width",
    callback = function()
      for _, st in pairs(states) do
        st.dirty.draw = true
        schedule_flush(st)
      end
    end,
  })
end

---@param list string[]
---@param first integer 0-based start of the replaced range
---@param last integer 0-based end of the replaced range, not included
---@param replacement string[]
---@return string[]
local function replace_range(list, first, last, replacement)
  last = math.min(last, #list)
  first = math.min(first, last)
  local result = vim.list_slice(list, 1, first)
  vim.list_extend(result, replacement)
  vim.list_extend(result, vim.list_slice(list, last + 1, #list))
  return result
end

---The user changed the buffer. Outside the hunks the change belongs to the base too, so that it
---does not turn into a hunk; inside or next to a hunk it changes Claude's proposal and the hunk.
---@param st ClaudeCodeReviewState
---@param first integer
---@param last_old integer
---@param last_new integer
local function on_user_edit(st, first, last_old, last_new)
  local base_first, base_last = hunk_logic.map_edit(st.hunks, first, last_old, last_new)
  if base_first and base_last then
    local lines = vim.api.nvim_buf_get_lines(st.bufnr, first, last_new, false)
    st.base = replace_range(st.base, base_first, base_last, lines)
    st.dirty.base = true
  end
  recompute(st)
  schedule_flush(st)
end

---The buffer was read from disk again (checktime, `:edit`): Claude wrote the file, so nothing is
---carried into the base; the hunks are simply worked out again.
---@param st ClaudeCodeReviewState
local function on_reload(st)
  st.reloaded = true
  st.stamp = disk.stamp(st.bufnr)
  recompute(st)
  schedule_flush(st)
end

local watch_buffer

---`:edit!` drops the nvim_buf_attach callbacks but keeps the buffer. Tell that apart from the
---buffer really going away, which can only be seen once the unload is over.
---@param st ClaudeCodeReviewState
---@param gen integer
local function on_buffer_detached(st, gen)
  vim.schedule(function()
    if st.dead or st.gen ~= gen then
      return
    end
    if vim.api.nvim_buf_is_valid(st.bufnr) and vim.api.nvim_buf_is_loaded(st.bufnr) then
      watch_buffer(st)
      on_reload(st)
      flush(st)
    else
      finish(st, "detached")
    end
  end)
end

---Follow the changes of the buffer. The callbacks must never throw or return true by accident:
---either one makes Neovim drop the attachment.
---@param st ClaudeCodeReviewState
watch_buffer = function(st)
  st.gen = st.gen + 1
  local gen = st.gen
  local function stale()
    return st.dead or st.gen ~= gen
  end
  vim.api.nvim_buf_attach(st.bufnr, false, {
    on_lines = function(_, _, _, first, last_old, last_new)
      if stale() then
        return true
      end
      if st.own_edit then
        return nil
      end
      local ok, err = pcall(on_user_edit, st, first, last_old, last_new)
      if not ok then
        report_error("tracking your edit", err)
      end
      return nil
    end,
    on_reload = function()
      if stale() then
        return true
      end
      local ok, err = pcall(on_reload, st)
      if not ok then
        report_error("reload", err)
      end
      return nil
    end,
    on_detach = function()
      if not stale() then
        on_buffer_detached(st, gen)
      end
    end,
  })
end

---@param bufnr integer
---@return ClaudeCodeReviewState|nil
local function state_of(bufnr)
  if bufnr == 0 or bufnr == nil then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return states[bufnr]
end

---@param bufnr integer
---@return integer|nil
local function window_of(bufnr)
  if vim.api.nvim_win_get_buf(0) == bufnr then
    return vim.api.nvim_get_current_win()
  end
  return vim.fn.win_findbuf(bufnr)[1]
end

---@param st ClaudeCodeReviewState
---@return integer|nil index of the hunk under the cursor
local function hunk_under_cursor(st)
  local win = window_of(st.bufnr)
  if not win then
    return nil
  end
  return hunk_logic.find(st.hunks, vim.api.nvim_win_get_cursor(win)[1], st.line_count)
end

---The hunk a command works on: the given one, else the one under the cursor.
---@param st ClaudeCodeReviewState
---@param index integer|nil
---@return integer|nil
local function pick_index(st, index)
  index = index or hunk_under_cursor(st)
  if not (index and st.hunks[index]) then
    vim.notify("claudecode review: no hunk here", vim.log.levels.INFO)
    return nil
  end
  return index
end

---Move the cursor to the start of a hunk. Like `]c`, it never wraps and a count that is too big
---goes as far as it can.
---@param bufnr integer
---@param direction "next"|"prev"|"first"|"last"
---@param count integer
jump = function(bufnr, direction, count)
  local st = states[bufnr]
  local win = window_of(bufnr)
  if not st or not win or #st.hunks == 0 then
    return
  end

  local rows = {}
  for i, hunk in ipairs(st.hunks) do
    rows[i] = hunk_logic.anchor(hunk, st.line_count)
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]

  local target
  if direction == "first" then
    target = rows[1]
  elseif direction == "last" then
    target = rows[#rows]
  else
    local ahead = {}
    for i = 1, #rows do
      -- walking backwards puts the nearest hunk first for "prev"
      local r = direction == "next" and rows[i] or rows[#rows + 1 - i]
      if (direction == "next" and r > row) or (direction == "prev" and r < row) then
        ahead[#ahead + 1] = r
      end
    end
    target = ahead[math.min(count, #ahead)]
  end
  if not target then
    return
  end

  local text = vim.api.nvim_buf_get_lines(bufnr, target - 1, target, false)[1] or ""
  local col = math.min(#text:match("^%s*"), math.max(#text - 1, 0))
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(win, { target, col })
  end)
end

---@param bufnr integer
---@return ClaudeCodeReviewMapping[]
mappings_for = function(bufnr)
  local mappings = {}
  local function add(name, desc, callback)
    local lhs = config.keymaps[name]
    if lhs then
      mappings[#mappings + 1] = { lhs = lhs, desc = "Claude review: " .. desc, callback = callback }
    end
  end
  add("keep", "keep hunk", function()
    M.keep(bufnr)
  end)
  add("revert", "revert hunk", function()
    M.revert(bufnr)
  end)
  add("keep_all", "keep all hunks", function()
    M.keep_all(bufnr)
  end)
  add("revert_all", "revert all hunks", function()
    M.revert_all(bufnr)
  end)
  add("next", "next hunk", function()
    jump(bufnr, "next", vim.v.count1)
  end)
  add("prev", "previous hunk", function()
    jump(bufnr, "prev", vim.v.count1)
  end)
  add("last", "last hunk", function()
    jump(bufnr, "last", 1)
  end)
  add("first", "first hunk", function()
    jump(bufnr, "first", 1)
  end)
  return mappings
end

---@param bufnr integer
---@param base_lines string[]
---@param opts ClaudeCodeReviewAttachOpts|nil
function M.attach(bufnr, base_lines, opts)
  if bufnr == 0 or bufnr == nil then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    error("claudecode.review.attach: buffer " .. tostring(bufnr) .. " is not loaded", 2)
  end
  if type(base_lines) ~= "table" then
    error("claudecode.review.attach: base_lines must be a list of strings", 2)
  end

  local st = states[bufnr]
  if st and st.dead then
    -- called from the on_done of the review that is just ending
    st.reattach = { base = vim.deepcopy(base_lines), opts = opts }
    return
  end
  if st then
    flush(st)
    if st.dead then
      st = nil
    end
  end
  if st then
    st.base = vim.deepcopy(base_lines)
    if opts then
      st.opts = opts
    end
    recompute(st)
    flush(st)
    return
  end

  st = {
    bufnr = bufnr,
    base = vim.deepcopy(base_lines),
    hunks = {},
    line_count = 0,
    opts = opts or {},
    gen = 0,
    dead = false,
    own_edit = false,
    flush_pending = false,
    dirty = { base = false, draw = false, event = false },
    reloaded = false,
  }
  states[bufnr] = st
  st.stamp = disk.stamp(bufnr)

  recompute(st)
  if #st.hunks == 0 then
    finish(st, "resolved")
    return
  end

  st.augroup = vim.api.nvim_create_augroup("ClaudeCodeReview" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = st.augroup,
    buffer = bufnr,
    desc = "Claude review: hint for the hunk under the cursor",
    callback = function()
      local ok, err = pcall(render.update_hint, bufnr, st.hunks, draw_opts(st))
      if not ok then
        report_error("hint", err)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = st.augroup,
    buffer = bufnr,
    desc = "Claude review: the buffer is gone",
    callback = function()
      finish(st, "detached")
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = st.augroup,
    buffer = bufnr,
    desc = "Claude review: the file on disk is what this buffer wrote",
    callback = function()
      st.stamp = disk.stamp(bufnr)
    end,
  })
  st.maps = keymaps.set(bufnr, mappings_for(bufnr))
  watch_buffer(st)
  watch_resizes()
  flush(st)
end

---@param bufnr integer
function M.detach(bufnr)
  local st = state_of(bufnr)
  if st then
    finish(st, "detached")
  end
end

---@param bufnr integer
---@return boolean
function M.is_attached(bufnr)
  return state_of(bufnr) ~= nil
end

---@param bufnr integer
---@return ClaudeCodeHunk[]
function M.hunks(bufnr)
  local st = state_of(bufnr)
  return st and vim.deepcopy(st.hunks) or {}
end

---@param bufnr integer
---@return string[]
function M.base(bufnr)
  local st = state_of(bufnr)
  return st and vim.deepcopy(st.base) or {}
end

---Let Neovim re-read the file if it changed, whatever 'autoread' says: a prompt would block.
---@param bufnr integer
local function reload_if_changed(bufnr)
  local autoread = vim.go.autoread
  vim.go.autoread = true
  pcall(vim.cmd, "silent! checktime " .. bufnr)
  vim.go.autoread = autoread
end

---Before the revert is written: is the file still what the buffer last read or wrote? If Claude wrote
---it again, saving would throw that away, so the revert is not made and the user is told.
---Done before the buffer changes: a modified buffer is not reloaded and `:write` would ask a question.
---@param st ClaudeCodeReviewState
---@return boolean current
local function disk_is_current(st)
  local bufnr = st.bufnr
  local modified = vim.bo[bufnr].modified
  st.reloaded = false
  local changed = not disk.same(st.stamp, disk.stamp(bufnr))
  if not modified then
    reload_if_changed(bufnr)
    changed = changed or st.reloaded
  end
  if not changed then
    return true
  end

  recompute(st)
  flush(st)
  local advice = modified
      and "The buffer has unsaved edits, so it was not reloaded: reload it with :edit! or save it with :write!."
    or "The buffer was reloaded and the hunks are up to date: revert again if you still want to."
  vim.notify("claudecode review: the file changed on disk, nothing was reverted. " .. advice, vim.log.levels.WARN)
  return false
end

---Revert hunks (indices ascending) in one undo step, tell the caller about each, then save the file.
---@param st ClaudeCodeReviewState
---@param indices integer[]
---@return boolean done
local function revert_hunks(st, indices)
  local bufnr = st.bufnr
  local write = st.opts.write_on_revert ~= false and disk.path(bufnr) ~= nil
  if write and not disk_is_current(st) then
    return false
  end

  local reverted = {}
  for i, index in ipairs(indices) do
    reverted[i] = st.hunks[index]
  end
  -- An empty file is one empty line in the buffer: replace that line instead of inserting next to it.
  local buffer_is_empty = #current_lines(st) == 0

  -- Close the undo step the user was in, so that one `u` takes back exactly this revert.
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("let &g:undolevels = &g:undolevels")
  end)
  st.own_edit = true
  local ok, err = pcall(function()
    -- Last hunk first: the rows of the ones above it do not move.
    for i = #reverted, 1, -1 do
      local hunk = reverted[i]
      local first, last
      if buffer_is_empty then
        first, last = 0, -1
      elseif hunk.cur_count > 0 then
        first, last = hunk.cur_start - 1, hunk.cur_start - 1 + hunk.cur_count
      else
        first, last = hunk.cur_start, hunk.cur_start
      end
      vim.api.nvim_buf_set_lines(bufnr, first, last, false, hunk.base_lines)
    end
  end)
  st.own_edit = false
  recompute(st)
  if not ok then
    report_error("revert", err)
    flush(st)
    return false
  end

  local shift = 0
  for _, hunk in ipairs(reverted) do
    local line = (hunk.cur_count > 0 and hunk.cur_start or hunk.cur_start + 1) + shift
    shift = shift + hunk.base_count - hunk.cur_count
    call(st, "on_revert", {
      path = vim.api.nvim_buf_get_name(bufnr),
      line = line,
      base_lines = vim.deepcopy(hunk.base_lines),
      claude_lines = vim.deepcopy(hunk.cur_lines),
      time = os.time(),
    })
  end

  if write then
    local written, write_err = disk.write(bufnr)
    if not written then
      report_error("write", write_err)
    end
    st.stamp = disk.stamp(bufnr)
  end
  flush(st)
  return true
end

---Revert a hunk: the base text comes back into the buffer and the file is written.
---@param bufnr integer
---@param index? integer Hunk number; the hunk under the cursor by default
function M.revert(bufnr, index)
  local st = state_of(bufnr)
  if not st then
    return
  end
  flush(st)
  if st.dead then
    return
  end
  index = pick_index(st, index)
  if index then
    revert_hunks(st, { index })
  end
end

---Keep a hunk: Claude's text becomes the base, the buffer stays as it is.
---@param bufnr integer
---@param index? integer Hunk number; the hunk under the cursor by default
function M.keep(bufnr, index)
  local st = state_of(bufnr)
  if not st then
    return
  end
  flush(st)
  if st.dead then
    return
  end
  index = pick_index(st, index)
  if not index then
    return
  end
  st.base = hunk_logic.keep(st.base, st.hunks[index])
  st.dirty.base = true
  recompute(st)
  flush(st)
end

---Keep every hunk at once: the base becomes the whole text of the buffer.
---@param bufnr integer
function M.keep_all(bufnr)
  local st = state_of(bufnr)
  if not st then
    return
  end
  flush(st)
  if st.dead or #st.hunks == 0 then
    return
  end
  st.base = current_lines(st)
  st.dirty.base = true
  recompute(st)
  flush(st)
end

---Revert every hunk at once: one undo step, one write of the file.
---@param bufnr integer
function M.revert_all(bufnr)
  local st = state_of(bufnr)
  if not st then
    return
  end
  flush(st)
  if st.dead or #st.hunks == 0 then
    return
  end
  local indices = {}
  for i = 1, #st.hunks do
    indices[i] = i
  end
  revert_hunks(st, indices)
end

return M
