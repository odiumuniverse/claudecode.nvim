---@brief [[
--- What each Claude Code hook does for the review. Runs in the hook process, not the editor.
---@brief ]]
---@module 'claudecode.hooks.handlers'

local uv = vim.uv or vim.loop

local M = {}

local EDIT_TOOLS = { Edit = true, Write = true, MultiEdit = true, NotebookEdit = true }

-- Bigger files and binary files stay out of review: extmarks over megabytes of text crawl.
M.MAX_BYTES = 2 * 1024 * 1024
-- A Bash snapshot older than this belongs to a call that never finished.
M.STALE_BASH_S = 24 * 3600
local SNIFF_BYTES = 8000

---A file past MAX_BYTES is not read at all: it stays out of review, and reading it would cost
---the memory and time for nothing.
---@param path string
---@return string|nil data nil when the file is missing or too big
---@return boolean too_big
local function read_all(path)
  local info = uv.fs_stat(path)
  if info and info.size > M.MAX_BYTES then
    return nil, true
  end
  local fd = uv.fs_open(path, "r", 384)
  if not fd then
    return nil, false
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  return data, false
end

---@param text string|nil
---@param too_big boolean|nil The file was too big to read
---@return boolean
local function reviewable(text, too_big)
  if too_big then
    return false
  end
  if not text then
    return true -- a new file
  end
  return #text <= M.MAX_BYTES and not text:sub(1, SNIFF_BYTES):find("\0", 1, true)
end

local function edit_path(input)
  local tool_input = type(input.tool_input) == "table" and input.tool_input or {}
  local path = tool_input.file_path or tool_input.notebook_path
  return type(path) == "string" and path ~= "" and path or nil
end

-- Claude's permission mode picks the review (docs/DESIGN.md, "Modes"): manual asks before every
-- edit, so the proposal opens in Neovim; accept-edits takes edits without review, and so does plan
-- mode, where Claude writes only its plan file; the other modes let Claude go on and leave hunks behind.
local ASK_MODES = { default = true, manual = true }
local UNREVIEWED_MODES = { acceptEdits = true, plan = true }

local function unreviewed(input)
  return UNREVIEWED_MODES[input.permission_mode] == true
end

local function ask()
  return {
    hookSpecificOutput = {
      hookEventName = "PreToolUse",
      permissionDecision = "ask",
      permissionDecisionReason = "Review this edit in Neovim",
    },
  }
end

---Move a base along an edit made without review: only the hunks still waiting for you stay.
local function carry(store, path, before, current)
  local base = store:get(path)
  if not base or not before or not current then
    return false
  end
  local text = require("claudecode.review.text")
  local lines = require("claudecode.review.hunks").carry(
    (text.to_lines(base.text)),
    (text.to_lines(before)),
    (text.to_lines(current))
  )
  local eol = base.text == "" and current:sub(-1) == "\n" or base.text:sub(-1) == "\n"
  store:set(path, text.to_text(lines, eol), base.new_file)
  return true
end

local function context(event, text)
  if not text then
    return nil
  end
  return { hookSpecificOutput = { hookEventName = event, additionalContext = text } }
end

-- Paths in the summary are relative to Claude's working directory, as Claude names them.
-- A session hears of the reverts of its own edits, and of those that no session claims.
local function take_summary(store, input)
  local records = store:take_reverts(input.session_id)
  return require("claudecode.review.summary").render(records, input.cwd)
end

local function pre_tool_use(store, input, env)
  if EDIT_TOOLS[input.tool_name] then
    local path = edit_path(input)
    local text, too_big = nil, false
    if path then
      text, too_big = read_all(path)
    end
    if path and reviewable(text, too_big) then
      if unreviewed(input) then
        -- No review for this edit: a base already waiting for you only moves along with it.
        if store:get(path) then
          store:save_before(input.tool_use_id, text or "")
        end
        return nil
      end
      local stamp = require("claudecode.review.store").stamp(path)
      -- An earlier edit of this file was refused and you changed the file since: its base is out of date.
      store:forget_refused(path, stamp)
      store:begin_edit(input.tool_use_id, path, store:snapshot(path, input.session_id), stamp, input.tool_name)
      if ASK_MODES[input.permission_mode] and env.before_write then
        return ask()
      end
    end
  elseif input.tool_name == "Bash" then
    store:drop_stale_bash(M.STALE_BASH_S)
    local snap = require("claudecode.hooks.git").snapshot(input.cwd or uv.cwd())
    if snap then
      store:save_bash(input.tool_use_id, snap)
    end
  end
end

local function post_tool_use(store, input, env)
  local payload = {
    event = "PostToolUse",
    dir = env.dir,
    tool_name = input.tool_name,
    -- the editor takes the base of an untracked file Bash changed, and needs to know whose edit it was
    session_id = type(input.session_id) == "string" and input.session_id or nil,
    files = {},
    untracked_changed = {},
  }

  if EDIT_TOOLS[input.tool_name] and unreviewed(input) then
    local path = edit_path(input)
    if path then
      local current, too_big = read_all(path)
      local before = store:take_before(input.tool_use_id)
      if not too_big then
        carry(store, path, before, current)
      end
      -- Without a base there is nothing to move, but an open buffer still has to reload.
      payload.files[1] = require("claudecode.review.store").normalize(path)
    end
  elseif EDIT_TOOLS[input.tool_name] then
    local path = edit_path(input)
    store:end_edit(input.tool_use_id, path)
    if path then
      local base = store:get(path)
      local current, too_big = read_all(path)
      if base and not too_big and base.text == (current or "") and not base.new_file then
        store:remove(path)
      elseif base then
        store:add_session(path, input.session_id)
      end
      payload.files[1] = require("claudecode.review.store").normalize(path)
    end
  elseif input.tool_name == "Bash" then
    local snap = store:take_bash(input.tool_use_id)
    if snap then
      local changes = require("claudecode.hooks.git").changes(snap)
      if unreviewed(input) then
        -- Bash's edits need no review either: only bases already waiting for you move along.
        for _, change in ipairs(changes.tracked) do
          local current, too_big = read_all(change.path)
          if not too_big then
            carry(store, change.path, change.text, current)
          end
          payload.files[#payload.files + 1] = change.path
        end
        -- Open buffers of the other files Bash wrote reload too; none of them gets a base.
        vim.list_extend(payload.files, changes.created)
        vim.list_extend(payload.files, changes.untracked_changed)
      else
        for _, change in ipairs(changes.tracked) do
          if reviewable(change.text) and reviewable(read_all(change.path)) then
            store:forget_refused(change.path)
            store:snapshot_text(change.path, change.text or "", change.text == nil, input.session_id)
            payload.files[#payload.files + 1] = change.path
          end
        end
        for _, path in ipairs(changes.created) do
          if reviewable(read_all(path)) then
            store:forget_refused(path)
            store:snapshot_text(path, "", true, input.session_id)
            payload.files[#payload.files + 1] = path
          end
        end
        payload.untracked_changed = changes.untracked_changed
      end
      for _, file in ipairs(payload.files) do
        store:end_edit(nil, file)
      end
    end
  end

  require("claudecode.hooks.notify").send(env.nvim, payload)
  return context("PostToolUse", take_summary(store, input))
end

---@param event string Hook event name from argv
---@param input table Decoded hook input
---@param env { dir: string, nvim: string|nil, before_write: boolean|nil }
---@return table|nil output JSON object for stdout
function M.handle(event, input, env)
  local store = require("claudecode.review.store").new(env.dir)
  if event == "PreToolUse" then
    return pre_tool_use(store, input, env)
  elseif event == "PostToolUse" then
    return post_tool_use(store, input, env)
  elseif event == "UserPromptSubmit" then
    return context("UserPromptSubmit", take_summary(store, input))
  end
  return nil
end

---Keep the last hook errors where `:checkhealth claudecode` can show them.
---@param dir string
---@param event string|nil
---@param err any
function M.log(dir, event, err)
  local path = dir .. "/hooks.log"
  local stat = uv.fs_stat(path)
  local mode = (stat and stat.size > 64 * 1024) and "w" or "a"
  local f = io.open(path, mode)
  if f then
    f:write(string.format("%s %s %s\n", os.date("!%Y-%m-%dT%H:%M:%SZ"), tostring(event), tostring(err)))
    f:close()
  end
end

return M
