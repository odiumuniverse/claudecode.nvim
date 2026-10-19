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

---Leave review: switch the engine off for this buffer, then tell the caller.
---The caller hears about it last, so it may attach the buffer again from inside `on_done`.
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
  states[st.bufnr] = nil
  pcall(vim.api.nvim_del_augroup_by_id, st.augroup)
  pcall(keymaps.restore, st.bufnr, st.maps)
  if vim.api.nvim_buf_is_valid(st.bufnr) then
    render.clear(st.bufnr)
  end
  call(st, "on_done", reason)
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
    render.draw(st.bufnr, st.hunks, draw_opts(st))
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

---@param st ClaudeCodeReviewState
---@param index integer|nil
---@return ClaudeCodeHunk|nil
local function pick_hunk(st, index)
  index = index or hunk_under_cursor(st)
  local hunk = index and st.hunks[index]
  if not hunk then
    vim.notify("claudecode review: no hunk here", vim.log.levels.INFO)
  end
  return hunk
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
      render.update_hint(bufnr, st.hunks, draw_opts(st))
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
  st.maps = keymaps.set(bufnr, mappings_for(bufnr))
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
  local hunk = pick_hunk(st, index)
  if not hunk then
    return
  end
  st.base = hunk_logic.keep(st.base, hunk)
  st.dirty.base = true
  recompute(st)
  flush(st)
end

return M
