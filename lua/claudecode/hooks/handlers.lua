---@brief [[
--- What each Claude Code hook does for the review. Runs in the hook process, not the editor.
---@brief ]]
---@module 'claudecode.hooks.handlers'

local uv = vim.uv or vim.loop

local M = {}

local EDIT_TOOLS = { Edit = true, Write = true, MultiEdit = true, NotebookEdit = true }

-- Bigger files and binary files stay out of review: extmarks over megabytes of text crawl.
M.MAX_BYTES = 2 * 1024 * 1024
local SNIFF_BYTES = 8000

local function read_all(path)
  local fd = uv.fs_open(path, "r", 384)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  return data
end

---@param text string|nil
---@return boolean
local function reviewable(text)
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

local function context(event, text)
  if not text then
    return nil
  end
  return { hookSpecificOutput = { hookEventName = event, additionalContext = text } }
end

-- Paths in the summary are relative to Claude's working directory, as Claude names them.
local function take_summary(store, input)
  local records = store:take_reverts()
  return require("claudecode.review.summary").render(records, input.cwd)
end

local function pre_tool_use(store, input)
  if EDIT_TOOLS[input.tool_name] then
    local path = edit_path(input)
    if path and reviewable(read_all(path)) then
      store:snapshot(path)
    end
  elseif input.tool_name == "Bash" then
    local snap = require("claudecode.hooks.git").snapshot(input.cwd or uv.cwd())
    if snap then
      store:save_bash(input.tool_use_id, snap)
    end
  end
end

local function post_tool_use(store, input, env)
  local payload =
    { event = "PostToolUse", dir = env.dir, tool_name = input.tool_name, files = {}, untracked_changed = {} }

  if EDIT_TOOLS[input.tool_name] then
    local path = edit_path(input)
    if path then
      local base = store:get(path)
      if base and base.text == (read_all(path) or "") and not base.new_file then
        store:remove(path)
      end
      payload.files[1] = require("claudecode.review.store").normalize(path)
    end
  elseif input.tool_name == "Bash" then
    local snap = store:take_bash(input.tool_use_id)
    if snap then
      local changes = require("claudecode.hooks.git").changes(snap)
      for _, change in ipairs(changes.tracked) do
        if reviewable(change.text) and reviewable(read_all(change.path)) then
          store:snapshot_text(change.path, change.text or "", change.text == nil)
          payload.files[#payload.files + 1] = change.path
        end
      end
      for _, path in ipairs(changes.created) do
        if reviewable(read_all(path)) then
          store:snapshot_text(path, "", true)
          payload.files[#payload.files + 1] = path
        end
      end
      payload.untracked_changed = changes.untracked_changed
    end
  end

  require("claudecode.hooks.notify").send(env.nvim, payload)
  return context("PostToolUse", take_summary(store, input))
end

---@param event string Hook event name from argv
---@param input table Decoded hook input
---@param env { dir: string, nvim: string|nil }
---@return table|nil output JSON object for stdout
function M.handle(event, input, env)
  local store = require("claudecode.review.store").new(env.dir)
  if event == "PreToolUse" then
    pre_tool_use(store, input)
  elseif event == "PostToolUse" then
    return post_tool_use(store, input, env)
  elseif event == "UserPromptSubmit" then
    return context("UserPromptSubmit", take_summary(store, input))
  end
  return nil
end

---Keep the last hook errors where `:checkhealth claudecode.review` can show them.
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
