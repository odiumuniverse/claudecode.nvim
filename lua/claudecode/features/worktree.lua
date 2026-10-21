---@brief [[
--- Neovim follows Claude into a worktree and out of it. Once a Claude session started from Neovim
--- works in a linked worktree (EnterWorktree, `claude --worktree`), Neovim changes its directory there
--- and the windows that show files of the main checkout show that worktree's copies. When Claude
--- leaves the worktree, or its terminal closes, Neovim goes back, and so do those windows.
---@brief ]]
---@module 'claudecode.features.worktree'

local repo = require("claudecode.review.repo")

local uv = vim.uv or vim.loop

local M = {}

---@class ClaudeCodeWorktreeMove
---@field from string The file the window showed before Neovim followed Claude
---@field to string The file it shows since

local state = {
  follow = false,
  home = nil, ---@type string|nil Neovim's directory before it followed Claude
  tree = nil, ---@type string|nil The worktree Neovim followed Claude into
  claude = nil, ---@type integer|nil Claude's terminal buffer then
  moved = {}, ---@type table<integer, ClaudeCodeWorktreeMove> The windows following moved, by window
  group = nil, ---@type integer|nil
}

---@return string
local function cwd()
  local dir = vim.fn.getcwd(-1)
  return uv.fs_realpath(dir) or dir
end

---The main checkout of the repository of the work tree `top`: it keeps the common git directory as
---its .git. Nil for a bare repository.
---@param top string
---@return string|nil
local function main_of(top)
  local git_dir = repo.git_dir(top)
  local common = git_dir and repo.common_dir(git_dir)
  return common and vim.fs.basename(common) == ".git" and vim.fs.dirname(common) or nil
end

---The plain file a window shows, resolved, when following may change the window.
---@param win integer
---@return string|nil
local function shown_file(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" or vim.bo[buf].modified then
    return nil
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return nil
  end
  return uv.fs_realpath(name) or name
end

---Show `target` in `win` at the line the window is on.
---@param win integer
---@param target string
---@return boolean ok
local function show(win, target)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local ok = pcall(vim.api.nvim_win_call, win, function()
    vim.cmd.edit(vim.fn.fnameescape(target))
  end)
  if ok then
    local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(cursor[1], last), cursor[2] })
  end
  return ok
end

---@param top string The linked worktree Claude works in
local function enter(top)
  local previous = state.tree
  if not previous then
    if cwd() == top then
      return -- Neovim works there already
    end
    state.home = vim.fn.getcwd(-1)
  end
  state.tree = top
  state.claude = require("claudecode.terminal").get_active_terminal_bufnr()
  vim.cmd.cd(vim.fn.fnameescape(top))
  -- Files of the main checkout, or of the worktree Claude left for this one, move along. Other
  -- worktrees of the repository stay: another Claude session may work in one.
  local main = main_of(top)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local path = shown_file(win)
    local from = path and repo.top_of(path)
    if from and from ~= top and (from == main or from == previous) then
      local target = top .. path:sub(#from + 1)
      if uv.fs_stat(target) and show(win, target) then
        local before = state.moved[win]
        state.moved[win] = { from = before and before.from or path, to = target }
      end
    end
  end
  vim.notify("claudecode: Claude works in " .. vim.fn.fnamemodify(top, ":~") .. ", and so does Neovim now")
end

---Claude left the worktree: back to where Neovim was, unless you went elsewhere yourself, and the
---windows following moved back to their files, unless you opened another file in them since.
local function leave()
  local tree, home, moved = state.tree, state.home, state.moved
  state.tree, state.home, state.claude, state.moved = nil, nil, nil, {}
  local back = home ~= nil and cwd() == tree
  if back then
    vim.cmd.cd(vim.fn.fnameescape(home))
  end
  for win, move in pairs(moved) do
    if vim.api.nvim_win_is_valid(win) and shown_file(win) == move.to and uv.fs_stat(move.from) then
      show(win, move.from)
    end
  end
  local left = "claudecode: Claude left " .. vim.fn.fnamemodify(tree, ":~")
  vim.notify(back and (left .. ", and Neovim is back in " .. vim.fn.fnamemodify(home, ":~")) or left)
end

---Claude works in `dir` now, as a hook reports: follow it into a linked worktree, and back out.
---@param dir string|nil
function M.follow(dir)
  if not state.follow or type(dir) ~= "string" or dir == "" then
    return
  end
  local top = repo.top_of(dir)
  if top and repo.is_linked(top) then
    if top ~= state.tree then
      enter(top)
    end
  elseif state.tree then
    leave()
  end
end

---@param opts { follow: boolean|nil }|nil
function M.setup(opts)
  state.follow = not (opts and opts.follow == false)
  state.group = vim.api.nvim_create_augroup("ClaudeCodeWorktree", { clear = true })
  vim.api.nvim_create_autocmd("TermClose", {
    group = state.group,
    desc = "Claude review: leave the worktree once Claude's session ends",
    callback = function(ev)
      if state.tree and state.claude == ev.buf then
        vim.schedule(function()
          if state.tree then
            leave()
          end
        end)
      end
    end,
  })
end

---Undo setup. Used by tests.
function M.teardown()
  if state.group then
    pcall(vim.api.nvim_del_augroup_by_id, state.group)
  end
  state.follow, state.home, state.tree, state.claude, state.moved, state.group = false, nil, nil, nil, {}, nil
end

return M
