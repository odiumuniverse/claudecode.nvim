---@brief [[
--- Glue between the hooks, the state store and the review engine: attaches the engine to
--- every buffer whose file has a base, saves your ko/kx decisions, and keeps the list of
--- files still waiting for review.
---@brief ]]
---@module 'claudecode.review.controller'

local engine = require("claudecode.review")
local store_mod = require("claudecode.review.store")
local text = require("claudecode.review.text")

local M = {}

-- An edit that Claude Code was not allowed to make never reports back: forget its note after this long.
M.EDITING_MAX_AGE_S = 30 * 60

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
  state.store = store_mod.new(dir)
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
  local base = store:get(path)
  if not base then
    if engine.is_attached(buf) then
      engine.detach(buf)
    end
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
---@param payload { dir: string|nil, tool_name: string|nil, files: string[]|nil, untracked_changed: string[]|nil }
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
        state.store:snapshot_text(path, old, false)
        files[#files + 1] = path
      end
    end
  end

  for _, path in ipairs(files) do
    local buf = loaded_buf(path)
    if buf then
      if vim.bo[buf].modified then
        vim.notify(
          "claudecode: Claude changed "
            .. vim.fn.fnamemodify(path, ":~:.")
            .. " on disk, but the buffer has unsaved edits. Review starts after :e! loads Claude's version.",
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
    local editing = state.store:editing(M.EDITING_MAX_AGE_S)
    for _, base in ipairs(state.store:list()) do
      local current = read_file(base.path)
      local unchanged = (current == nil and base.new_file) or (current ~= nil and same_lines(base.text, current, false))
      if not unchanged then
        pending[#pending + 1] = base.path
      elseif not editing[base.path] then
        -- a leftover: Claude's new file is gone again, or the file already equals its base
        state.store:remove(base.path)
      end
    end
  end
  table.sort(pending)
  state.pending = pending
  vim.api.nvim_exec_autocmds("User", {
    pattern = "ClaudeCodeReviewPending",
    data = { count = #pending, files = vim.deepcopy(pending) },
  })
  return pending
end

---@return string[]
function M.pending()
  return vim.deepcopy(state.pending)
end

---@param opts { dir: string|nil }|nil
function M.setup(opts)
  opts = opts or {}
  M.use_dir(opts.dir or require("claudecode.hooks").state_dir(vim.fn.getcwd()))
  state.group = vim.api.nvim_create_augroup("ClaudeCodeReviewController", { clear = true })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = state.group,
    callback = function(ev)
      M.attach_if_pending(ev.buf)
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.attach_if_pending(buf)
  end
  M.refresh_pending()
end

---Undo setup: detach every buffer and drop the autocmds. Used by tests and :ClaudeCodeStop paths.
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
  state.store = nil
  state.pending = {}
end

return M
