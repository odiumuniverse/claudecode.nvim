---@brief [[
--- Glue between the hooks, the state store and the review engine: attaches the engine to
--- every buffer whose file has a base, saves your cs/cx decisions, and keeps the list of
--- files still waiting for review.
---@brief ]]
---@module 'claudecode.review.controller'

local engine = require("claudecode.review")
local store_mod = require("claudecode.review.store")
local text = require("claudecode.review.text")

local M = {}

-- An edit that Claude Code was not allowed to make never reports back: forget its note after this long.
M.EDITING_MAX_AGE_S = 30 * 60

-- Waiting for a lock blocks the editor's only thread; a hook holds a lock for a moment, so a lock
-- still there after this long was left behind. The change goes on without it. 20 ms was too short:
-- with three hooks hammering one base, a live hook sometimes held the lock longer, and a session
-- written down in the header was lost.
M.LOCK_WAIT_MS = 100

local state = {
  store = nil, ---@type ClaudeCodeReviewStore|nil
  group = nil, ---@type integer|nil
  pending = {}, ---@type string[]
}

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function is_dos(buf)
  return vim.bo[buf].fileformat == "dos"
end

local function loaded_buf(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and store_mod.normalize(name) == path then
        return buf
      end
    end
  end
  return nil
end

local function same_lines(a, b, dos)
  return vim.deep_equal((text.to_lines(a, dos)), (text.to_lines(b, dos)))
end

---Point the controller at a state directory. A Claude session started from another cwd
---reports its own directory with every hook.
---@param dir string
function M.use_dir(dir)
  if state.store and state.store.dir == dir then
    return
  end
  state.store = store_mod.new(dir, { lock_wait_ms = M.LOCK_WAIT_MS })
  require("claudecode.review.notes").use_dir(dir)
end

---@return ClaudeCodeReviewStore|nil
function M.store()
  return state.store
end

---A whole new file you reverted is Claude's file, not yours: remove it from disk.
local function remove_new_file(buf, path)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    vim.fn.delete(path)
    vim.notify("claudecode: removed " .. vim.fn.fnamemodify(path, ":~:.") .. ", you reverted the whole new file")
  end)
end

---An edit that Claude Code was not allowed to make never reports back, and what changed in the file
---since is yours, not Claude's: forget the bases such edits made.
---@param store ClaudeCodeReviewStore
---@return table<string, true> editing Paths of the edits still under way
local function forget_refused(store)
  local editing, stale = store:editing(M.EDITING_MAX_AGE_S)
  for _, note in ipairs(stale) do
    if note.created then
      store:remove(note.path)
    end
  end
  return editing
end

---Is the file one that an unfinished edit may still be writing, or that you made after Claude Code
---refused that edit? Then it is not listed, reviewed or deleted as Claude's.
---@param path string
---@return boolean
function M.in_doubt(path)
  return state.store ~= nil and state.store:in_doubt(path, M.EDITING_MAX_AGE_S)
end

---No hunk holds the final newline. When the text that came back reaches the end of the file, the
---file gets the final newline, or the lack of it, that the base had.
---@param buf integer
---@param rec ClaudeCodeRevertRecord
---@param base ClaudeCodeReviewBase|nil
local function restore_final_newline(buf, rec, base)
  if not base or base.text == "" then
    return
  end
  local last = rec.line + #rec.base_lines - 1
  if last >= vim.api.nvim_buf_line_count(buf) then
    -- the bytes of a UTF-16 file end in "\n\0": look at the text the buffer holds
    vim.bo[buf].eol = text.decode(base.text, buf):sub(-1) == "\n"
  end
end

---Start or refresh the review of `buf` if its file has a base.
---@param buf integer
function M.attach_if_pending(buf)
  if not state.store or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].modified then
    return
  end
  local path = store_mod.normalize(name)
  local store = state.store
  forget_refused(store)
  local base = store:get(path)
  if not base then
    if engine.is_attached(buf) then
      engine.detach(buf)
    end
    return
  end
  if store:in_doubt(path, M.EDITING_MAX_AGE_S) then
    return
  end

  local reverted = false
  engine.attach(buf, (text.to_lines(text.decode(base.text, buf), is_dos(buf))), {
    on_base = function(lines)
      store:set(path, text.encode(text.to_text(lines, vim.bo[buf].eol, is_dos(buf)), buf))
    end,
    on_revert = function(rec)
      reverted = true
      store:append_revert(rec)
      restore_final_newline(buf, rec, store:get(path))
      require("claudecode.review.notes").drop(buf, rec.line, rec.line + math.max(#rec.base_lines, 1) - 1)
    end,
    on_done = function(reason)
      if reason ~= "resolved" then
        return
      end
      store:remove(path)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      if base.new_file and reverted and #lines == 1 and lines[1] == "" then
        remove_new_file(buf, path)
      end
      M.refresh_pending()
    end,
  })
end

---Re-read a file Claude rewrote. Reload without a prompt even with 'noautoread'.
local function reload(buf)
  vim.api.nvim_buf_call(buf, function()
    if vim.api.nvim_get_option_value("autoread", { buf = buf }) then
      vim.cmd("silent! checktime " .. buf)
    else
      vim.cmd("silent! edit")
    end
  end)
end

---Handle a PostToolUse notification from the hook process.
---@param payload { dir: string|nil, tool_name: string|nil, session_id: string|nil, files: string[]|nil, untracked_changed: string[]|nil }
function M.on_hook(payload)
  if payload.dir and payload.dir ~= "" then
    M.use_dir(payload.dir)
  end
  if not state.store then
    return
  end
  local files = vim.deepcopy(payload.files or {})

  -- An untracked file has no snapshot in git: its open buffer still holds the old text (DESIGN p. 13).
  for _, path in ipairs(payload.untracked_changed or {}) do
    local buf = loaded_buf(path)
    if buf and not vim.bo[buf].modified then
      local old = text.encode(text.buffer_text(buf), buf)
      local now = read_file(path)
      if now and old ~= now then
        state.store:snapshot_text(path, old, false, payload.session_id)
        files[#files + 1] = path
      end
    end
  end

  for _, path in ipairs(files) do
    local buf = loaded_buf(path)
    if buf then
      if vim.bo[buf].modified then
        -- A file without a base (an edit taken without review) has no review to start.
        local later = state.store:get(path) and " Review starts after :e! loads Claude's version." or ""
        vim.notify(
          "claudecode: Claude changed "
            .. vim.fn.fnamemodify(path, ":~:.")
            .. " on disk, but the buffer has unsaved edits."
            .. later,
          vim.log.levels.WARN
        )
      else
        reload(buf)
        M.attach_if_pending(buf)
      end
    end
  end
  M.refresh_pending()
end

---Files whose base still differs from the file on disk. Drops the bases that no longer do,
---and tells listeners (zen counter, picker) when the list changes.
---@return string[] paths
function M.refresh_pending()
  local pending = {}
  if state.store then
    -- PreToolUse takes the base before Claude writes: it equals the file until then (or the file
    -- is not there yet), and the user may well be refreshing the list while Claude waits for permission.
    local editing = forget_refused(state.store)
    for _, base in ipairs(state.store:list()) do
      local current = read_file(base.path)
      local unchanged = (current == nil and base.new_file) or (current ~= nil and same_lines(base.text, current, false))
      -- A file in doubt is not Claude's yet, and perhaps never: neither listed nor forgotten.
      if not state.store:in_doubt(base.path, M.EDITING_MAX_AGE_S) then
        if not unchanged then
          pending[#pending + 1] = base.path
        elseif not editing[base.path] then
          -- a leftover: Claude's new file is gone again, or the file already equals its base
          state.store:remove(base.path)
        end
      end
    end
  end
  table.sort(pending)
  state.pending = pending
  M.announce()
  return pending
end

---Tell listeners (zen, a statusline) what waits for you: the files and the notes.
function M.announce()
  vim.api.nvim_exec_autocmds("User", {
    pattern = "ClaudeCodeReviewPending",
    data = {
      count = #state.pending,
      files = vim.deepcopy(state.pending),
      notes = require("claudecode.review.notes").count(),
    },
  })
end

---@return string[]
function M.pending()
  return vim.deepcopy(state.pending)
end

---What waits for you as a short text for a statusline: "review: 2 files · 3 notes", or "" when
---nothing waits, so that a statusline component disappears.
---@param files? integer Files waiting for review; the controller's count by default
---@param notes? integer Notes not sent yet
---@return string
function M.status(files, notes)
  files = files or #state.pending
  notes = notes or require("claudecode.review.notes").count()
  local parts = {}
  if files > 0 then
    parts[#parts + 1] = ("%d %s"):format(files, files == 1 and "file" or "files")
  end
  if notes > 0 then
    parts[#parts + 1] = ("%d %s"):format(notes, notes == 1 and "note" or "notes")
  end
  return #parts > 0 and ("review: " .. table.concat(parts, " · ")) or ""
end

---Open the file after (or before) the one in `bufnr` among the files waiting for review, at its
---first (or last) hunk. The list goes in path order and wraps around. A proposal under review
---before write is not on the list and goes nowhere.
---@param bufnr integer
---@param direction "next"|"prev"
---@return boolean opened
function M.goto_file(bufnr, direction)
  -- The buffer may be gone already: a resolved proposal or a reverted new file wipes it.
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].claudecode_proposal then
    return false
  end
  local current = store_mod.normalize(vim.api.nvim_buf_get_name(bufnr))
  local others = vim.tbl_filter(function(path)
    return path ~= current
  end, M.refresh_pending())
  if #others == 0 then
    return false
  end
  local forward = direction == "next"
  local target = forward and others[1] or others[#others]
  for i = 1, #others do
    local path = forward and others[i] or others[#others + 1 - i]
    if (forward and path > current) or (not forward and path < current) then
      target = path
      break
    end
  end
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target))
  if not ok then
    vim.notify("claudecode review: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  engine.jump(vim.api.nvim_get_current_buf(), forward and "first" or "last")
  return true
end

---The keys that move between hunks, global as well: a buffer under review has its own, and in any
---other file they go to the files waiting for review. Without them `]k` in a file of your own did
---nothing, and the user took the review for broken.
---@param keymaps { next: string|false|nil, prev: string|false|nil }|nil
local function map_moves(keymaps)
  for _, lhs in ipairs(state.moves or {}) do
    pcall(vim.keymap.del, "n", lhs)
  end
  state.moves = {}
  for direction, lhs in pairs(keymaps or {}) do
    -- A global mapping of your own stays: it is yours outside review, ours inside.
    local yours = vim.fn.maparg(lhs or "", "n", false, true)
    if lhs and not (yours.lhs and yours.buffer == 0) then
      vim.keymap.set("n", lhs, function()
        if not M.goto_file(vim.api.nvim_get_current_buf(), direction) then
          vim.notify("claudecode: nothing waits for review")
        end
      end, { desc = "Claude review: " .. direction .. " file waiting for review" })
      state.moves[#state.moves + 1] = lhs
    end
  end
end

---@param opts { dir: string|nil, keymaps: { next: string|false|nil, prev: string|false|nil }|nil }|nil
function M.setup(opts)
  opts = opts or {}
  M.use_dir(opts.dir or require("claudecode.hooks").state_dir(vim.fn.getcwd()))
  map_moves(opts.keymaps)
  require("claudecode.diff_provider").tool_of = function(path)
    return state.store and state.store:edit_tool(path, M.EDITING_MAX_AGE_S)
  end
  state.group = vim.api.nvim_create_augroup("ClaudeCodeReviewController", { clear = true })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = state.group,
    callback = function(ev)
      M.attach_if_pending(ev.buf)
      require("claudecode.review.notes").attach(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = state.group,
    callback = function(ev)
      require("claudecode.review.notes").written(ev.buf)
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.attach_if_pending(buf)
  end
  M.refresh_pending()
end

---Undo setup: detach every buffer and drop the autocmds. Used by tests.
function M.teardown()
  if state.group then
    pcall(vim.api.nvim_del_augroup_by_id, state.group)
    state.group = nil
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if engine.is_attached(buf) then
      engine.detach(buf)
    end
  end
  map_moves(nil)
  state.store = nil
  state.pending = {}
  require("claudecode.review.notes").reset()
  require("claudecode.diff_provider").tool_of = function()
    return nil
  end
end

return M
