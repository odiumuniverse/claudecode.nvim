---@brief [[
--- `:ClaudeCode run [account] [args]`: Claude run as an account of cswap (claude-swap). The account
--- sticks: every later launch from this Neovim (toggle, focus, zen, resume) runs it, until the next
--- `run`. Without an account cswap picks one by the directory's mapping, or the default login.
---@brief ]]
---@module 'claudecode.features.cswap'

local M = {}

local state = { cmd = "cswap" }

---@param opts { cmd: string }
function M.setup(opts)
  state.cmd = opts.cmd
end

---Back to terminal_cmd and the default cswap executable. Used by tests.
function M.reset()
  state.cmd = "cswap"
  require("claudecode.terminal").set_launch_cmd(nil)
end

local function fail(msg)
  vim.notify("claudecode: " .. msg, vim.log.levels.ERROR)
end

---`1 --resume` is account 1 and Claude's `--resume`; a first word with a dash is Claude's already.
---@param args string
---@return string|nil account
---@return string claude_args
local function parse(args)
  local account, rest = args:match("^%s*(%S+)%s*(.-)%s*$")
  if not account or account:sub(1, 1) == "-" then
    return nil, vim.trim(args)
  end
  return account, rest
end

---The accounts `cswap list --json` knows.
---@return table[]|nil accounts
---@return string|nil err
local function accounts()
  if vim.fn.executable(state.cmd) ~= 1 then
    return nil, state.cmd .. " not found: install claude-swap or set cswap.cmd"
  end
  local res = vim.system({ state.cmd, "list", "--json" }, { text = true }):wait(5000)
  if res.code ~= 0 then
    return nil, "`" .. state.cmd .. " list --json` failed: " .. vim.trim(res.stderr or "")
  end
  local ok, data = pcall(vim.json.decode, res.stdout)
  if not ok or type(data) ~= "table" or type(data.accounts) ~= "table" then
    return nil, "cannot read the output of `" .. state.cmd .. " list --json`"
  end
  return data.accounts
end

local function known(list, account)
  for _, entry in ipairs(list) do
    if tostring(entry.number) == account or entry.email == account or entry.alias == account then
      return true
    end
  end
  return false
end

---Stop the running Claude: hiding its window would leave the process behind.
local function stop(terminal)
  local buf = terminal.get_active_terminal_bufnr()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local job = vim.bo[buf].channel
  if job and job > 0 then
    pcall(vim.fn.jobstop, job)
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

---Run Claude as `account` (or as cswap's choice for this directory), replacing a running Claude.
---Claude's own arguments, the review hooks' included, go after `--`, where cswap hands them on.
---@param args string What follows `:ClaudeCode run`
function M.run(args)
  local account, claude_args = parse(args or "")
  -- Check the account before anything stops: a typo must not end the Claude you have.
  if account then
    local list, err = accounts()
    if not list then
      return fail(err)
    end
    if not known(list, account) then
      return fail("cswap has no account " .. account .. " (see `" .. state.cmd .. " list`)")
    end
  elseif vim.fn.executable(state.cmd) ~= 1 then
    return fail(state.cmd .. " not found: install claude-swap or set cswap.cmd")
  end

  local launcher = vim.fn.shellescape(state.cmd) .. " run"
  if account then
    launcher = launcher .. " " .. vim.fn.shellescape(account)
  end
  local terminal = require("claudecode.terminal")
  terminal.set_launch_cmd(launcher .. " --")

  local zen = package.loaded["claudecode.zen"]
  local in_zen = zen and zen.is_active()
  if in_zen then
    zen.leave()
  end
  stop(terminal)
  claude_args = claude_args ~= "" and claude_args or nil
  if in_zen then
    zen.enter(claude_args)
  else
    terminal.open({}, claude_args)
  end
end

---Completion for `:ClaudeCode`: `run`, then the account numbers and aliases.
---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  local words = vim.split(vim.trim(cmdline), "%s+")
  local typing_new = cmdline:match("%s$") ~= nil
  local position = #words + (typing_new and 1 or 0) -- 2: first argument, 3: the account
  local out = {}
  if position == 2 then
    if ("run"):sub(1, #arglead) == arglead then
      out[1] = "run"
    end
  elseif position == 3 and words[2] == "run" then
    local list = accounts() or {}
    for _, entry in ipairs(list) do
      for _, name in ipairs({ entry.number and tostring(entry.number), entry.alias }) do
        if name and name:sub(1, #arglead) == arglead then
          out[#out + 1] = name
        end
      end
    end
    table.sort(out)
  end
  return out
end

return M
