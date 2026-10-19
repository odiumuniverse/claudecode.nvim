---@brief [[
--- Review hooks for Claude sessions started from Neovim. Each launch gets
--- `claude --settings <file>`: Claude Code adds those hooks to yours instead of replacing them.
---@brief ]]
---@module 'claudecode.hooks'

local M = {}

M.MATCHER = "Edit|Write|MultiEdit|NotebookEdit|Bash"
M.TIMEOUT_S = 30

local state = { active = false, state_root = nil }

local function sh_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function run_script()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":p:h") .. "/run.lua"
end

local function state_root()
  return state.state_root or (vim.fn.stdpath("state") .. "/claudecode")
end

---@param opts { state_root: string|nil, before_write: boolean|nil }|nil
function M.setup(opts)
  opts = opts or {}
  state.state_root = opts.state_root
  -- In Claude's manual mode the hooks ask before each edit so that it opens for review in Neovim.
  state.before_write = opts.before_write ~= false
  state.active = true
end

function M.disable()
  state.active = false
end

---@return boolean
function M.is_active()
  return state.active
end

---State for a project. Inside a git repository the project is the repository, so Neovim
---started from any of its subdirectories finds the same reviews.
---@param cwd string Neovim's cwd when Claude starts
---@return string
function M.state_dir(cwd)
  local root = vim.fs.root(cwd, ".git") or cwd
  return state_root() .. "/review/" .. vim.fn.sha256(root)
end

---@return string
function M.settings_file()
  return state_root() .. "/hooks-settings.json"
end

local function hook(event)
  local command =
    string.format("%s --clean --headless -l %s %s", sh_quote(vim.v.progpath), sh_quote(run_script()), event)
  return { type = "command", command = command, timeout = M.TIMEOUT_S }
end

---Write the settings file. Every editor writes the same content, so racing writers are harmless.
local function write_settings()
  local settings = {
    hooks = {
      PreToolUse = { { matcher = M.MATCHER, hooks = { hook("PreToolUse") } } },
      PostToolUse = { { matcher = M.MATCHER, hooks = { hook("PostToolUse") } } },
      UserPromptSubmit = { { hooks = { hook("UserPromptSubmit") } } },
    },
  }
  vim.fn.mkdir(state_root(), "p")
  local file = M.settings_file()
  local tmp = file .. ".tmp." .. vim.fn.getpid()
  vim.fn.writefile({ vim.json.encode(settings) }, tmp)
  vim.uv.fs_rename(tmp, file)
end

---Attach the review hooks to a Claude launch. Mutates `env`.
---@param base_cmd string The claude command (terminal_cmd or "claude")
---@param cmd_args string|nil Extra arguments such as --resume
---@param env table Environment for the Claude process
---@return string|nil cmd_string Nil when the review is off: keep the original command
function M.decorate(base_cmd, cmd_args, env)
  if not state.active then
    return nil
  end
  write_settings()
  if vim.v.servername == "" then
    vim.fn.serverstart()
  end
  env.CLAUDECODE_REVIEW_DIR = M.state_dir(vim.fn.getcwd())
  env.CLAUDECODE_NVIM = vim.v.servername
  env.CLAUDECODE_REVIEW_BEFORE_WRITE = state.before_write and "1" or nil
  local cmd = base_cmd .. " --settings " .. vim.fn.shellescape(M.settings_file())
  if cmd_args and cmd_args ~= "" then
    cmd = cmd .. " " .. cmd_args
  end
  return cmd
end

return M
