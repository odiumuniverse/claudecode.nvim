---@brief [[
--- Zen mode: Claude full screen in a tab of its own, the code one key away.
---
--- The Claude terminal lives in exactly one window at a time. A terminal takes the size of
--- the widest window that shows it, so a full-screen copy in another tab would garble the
--- narrow split in the code tab.
---@brief ]]
---@module 'claudecode.zen'

local M = {}

---@class ClaudeCodeZenConfig
---@field keymap string|false Toggles zen in normal and terminal mode
---@field files_key string|nil Shown in the review counter, e.g. "<leader>ak"

local defaults = { keymap = "<M-z>", files_key = "<leader>ak" }

local state = {
  opts = vim.deepcopy(defaults), ---@type ClaudeCodeZenConfig
  tab = nil, ---@type integer|nil
  win = nil, ---@type integer|nil
  work_tab = nil, ---@type integer|nil
  showtabline = nil, ---@type integer|nil
  pending = 0,
  group = nil, ---@type integer|nil
}

local function terminal()
  return require("claudecode.terminal")
end

local function term_buf()
  local buf = terminal().get_active_terminal_bufnr()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  return nil
end

local function tab_valid(tab)
  return tab ~= nil and vim.api.nvim_tabpage_is_valid(tab)
end

---@return boolean
function M.is_active()
  return tab_valid(state.tab) and vim.api.nvim_get_current_tabpage() == state.tab
end

local function counter_text()
  if state.pending == 0 then
    return ""
  end
  local what = state.pending == 1 and "1 file waits for review" or (state.pending .. " files wait for review")
  local key = state.opts.files_key and (" · " .. state.opts.files_key) or ""
  return "%#ClaudeCodeZenPending# " .. what .. key .. " %*"
end

local function update_counter()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.wo[state.win].winbar = counter_text()
  end
end

---Take the terminal out of every window in `tab`. A window that is the last one in its tab
---gets an empty buffer instead, because a tab cannot lose its last window.
local function hide_terminal_in(tab, buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      if #vim.api.nvim_tabpage_list_wins(tab) > 1 then
        vim.api.nvim_win_close(win, false)
      else
        vim.api.nvim_win_call(win, function()
          vim.cmd("enew")
        end)
      end
    end
  end
end

---Show Claude full screen. Starts Claude if it is not running.
---@param cmd_args string|nil Arguments for a new Claude session, e.g. "--resume"
function M.enter(cmd_args)
  if M.is_active() then
    return
  end
  local buf = term_buf()
  if not buf then
    terminal().ensure_visible(nil, cmd_args)
    buf = term_buf()
  end
  if not buf then
    vim.notify(
      "claudecode: zen needs Claude running inside Neovim (terminal.provider = native or snacks)",
      vim.log.levels.WARN
    )
    return
  end

  state.work_tab = vim.api.nvim_get_current_tabpage()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    hide_terminal_in(tab, buf)
  end

  vim.cmd("tabnew")
  local scratch = vim.api.nvim_get_current_buf()
  vim.bo[scratch].bufhidden = "wipe"
  state.tab = vim.api.nvim_get_current_tabpage()
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, buf)
  for option, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
    cursorline = false,
  }) do
    vim.wo[state.win][option] = value
  end
  update_counter()

  if state.showtabline == nil then
    state.showtabline = vim.o.showtabline
  end
  vim.o.showtabline = 0
  vim.cmd("startinsert")
end

---Back to the code tab, with Claude in its split and the cursor in the code.
function M.leave()
  if not tab_valid(state.tab) then
    return
  end
  local zen_tab = state.tab
  state.tab, state.win = nil, nil

  if not tab_valid(state.work_tab) or state.work_tab == zen_tab then
    -- Started straight into zen (cz): build the code tab now.
    vim.cmd("tabnew")
    state.work_tab = vim.api.nvim_get_current_tabpage()
  else
    vim.api.nvim_set_current_tabpage(state.work_tab)
  end
  vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(zen_tab))

  if state.showtabline ~= nil then
    vim.o.showtabline = state.showtabline
    state.showtabline = nil
  end

  if term_buf() then
    terminal().ensure_visible()
  end
  -- ensure_visible keeps the focus, but never leave the cursor in Claude's split.
  if vim.bo.buftype == "terminal" then
    vim.cmd("wincmd p")
  end
  vim.cmd("stopinsert")
end

---@param cmd_args string|nil
function M.toggle(cmd_args)
  if M.is_active() then
    M.leave()
  else
    M.enter(cmd_args)
  end
end

---In terminal mode the zen key toggles only inside Claude; other terminals receive the key.
local function terminal_key()
  if vim.api.nvim_get_current_buf() == term_buf() then
    vim.schedule(M.toggle)
    return ""
  end
  return state.opts.keymap
end

---@param opts ClaudeCodeZenConfig|nil
function M.setup(opts)
  opts = opts or {}
  vim.validate("zen.keymap", opts.keymap, { "string", "boolean" }, true)
  vim.validate("zen.files_key", opts.files_key, "string", true)
  state.opts = vim.tbl_extend("force", vim.deepcopy(defaults), opts)

  vim.api.nvim_set_hl(0, "ClaudeCodeZenPending", { default = true, link = "DiagnosticWarn" })

  state.group = vim.api.nvim_create_augroup("ClaudeCodeZen", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = state.group,
    pattern = "ClaudeCodeReviewPending",
    callback = function(ev)
      state.pending = (ev.data and ev.data.count) or 0
      update_counter()
    end,
  })
  vim.api.nvim_create_autocmd("TermClose", {
    group = state.group,
    callback = function(ev)
      if state.win and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_buf(state.win) == ev.buf then
        vim.schedule(M.leave)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = state.group,
    callback = function()
      if state.tab and not tab_valid(state.tab) then
        state.tab, state.win = nil, nil
        if state.showtabline ~= nil then
          vim.o.showtabline = state.showtabline
          state.showtabline = nil
        end
      end
    end,
  })

  if state.opts.keymap then
    vim.keymap.set("n", state.opts.keymap, function()
      M.toggle()
    end, { desc = "Claude: toggle zen" })
    vim.keymap.set("t", state.opts.keymap, terminal_key, { expr = true, desc = "Claude: toggle zen" })
  end

  pcall(vim.api.nvim_del_user_command, "ClaudeCodeZen")
  vim.api.nvim_create_user_command("ClaudeCodeZen", function(cmd)
    M.toggle(cmd.args ~= "" and cmd.args or nil)
  end, { nargs = "*", desc = "Claude: toggle zen (arguments start a new session, e.g. --resume)" })
end

---Undo setup. Used by tests.
function M.teardown()
  if state.group then
    pcall(vim.api.nvim_del_augroup_by_id, state.group)
    state.group = nil
  end
  if state.opts.keymap then
    pcall(vim.keymap.del, "n", state.opts.keymap)
    pcall(vim.keymap.del, "t", state.opts.keymap)
  end
  pcall(vim.api.nvim_del_user_command, "ClaudeCodeZen")
  if state.showtabline ~= nil then
    vim.o.showtabline = state.showtabline
  end
  state.tab, state.win, state.work_tab, state.showtabline, state.pending = nil, nil, nil, nil, 0
end

return M
