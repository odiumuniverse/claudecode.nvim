---@brief [[
--- What the hooks and the editor learn about a git repository from its files alone, without starting
--- git: the work tree a path belongs to, its git directory, its other worktrees and where HEAD points.
--- Runs both inside the editor and inside `nvim --clean -l` hook processes.
---@brief ]]
---@module 'claudecode.review.repo'

local uv = vim.uv or vim.loop

local M = {}

---@param path string
---@return string|nil line The first line, without trailing whitespace
local function read_line(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local line = f:read("*l")
  f:close()
  return line and (line:gsub("%s+$", "")) or nil
end

---@param path string
---@param from string Directory a relative `path` is relative to
---@return string
local function resolve(path, from)
  local full = path:sub(1, 1) == "/" and path or (from .. "/" .. path)
  return uv.fs_realpath(full) or full
end

---The work tree `path` belongs to: the nearest directory up from it that holds a `.git`.
---@param path string A file or directory; one that does not exist yet is looked up from its parents
---@return string|nil top Resolved through symlinks
function M.top_of(path)
  local top = vim.fs.root(path, ".git")
  return top and (uv.fs_realpath(top) or top) or nil
end

---The git directory of the work tree at `top`: its `.git`, or where the `.git` file of a worktree or
---a submodule points.
---@param top string
---@return string|nil
function M.git_dir(top)
  local dotgit = top .. "/.git"
  local stat = uv.fs_stat(dotgit)
  if not stat then
    return nil
  end
  if stat.type == "directory" then
    return dotgit
  end
  local dir = (read_line(dotgit) or ""):match("^gitdir: (.+)$")
  return dir and resolve(dir, top) or nil
end

---The directory a linked worktree shares with the main work tree: branches, objects, `worktrees/`.
---@param git_dir string
---@return string
function M.common_dir(git_dir)
  local common = read_line(git_dir .. "/commondir")
  return common and resolve(common, git_dir) or git_dir
end

---Is the work tree at `top` a linked worktree (`git worktree add`, `claude --worktree`)?
---@param top string
---@return boolean
function M.is_linked(top)
  local git_dir = M.git_dir(top)
  return git_dir ~= nil and M.common_dir(git_dir) ~= git_dir
end

---The other work trees of the repository at `top`: the main one, unless the repository is bare, and
---the linked worktrees. Those removed from disk are left out.
---@param top string Resolved through symlinks, as `top_of` gives it
---@return string[] roots In path order
function M.worktrees(top)
  local git_dir = M.git_dir(top)
  if not git_dir then
    return {}
  end
  local common = M.common_dir(git_dir)
  local roots = {}
  local function add(root)
    root = uv.fs_realpath(root)
    if root and root ~= top and not vim.list_contains(roots, root) then
      roots[#roots + 1] = root
    end
  end
  -- The main work tree keeps the common directory as its .git.
  if vim.fs.basename(common) == ".git" then
    add(vim.fs.dirname(common))
  end
  local handle = uv.fs_scandir(common .. "/worktrees")
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    -- The path of the worktree's .git file; relative to this directory with worktree.useRelativePaths.
    local dir = common .. "/worktrees/" .. name
    local dotgit = read_line(dir .. "/gitdir")
    if dotgit then
      add(vim.fs.dirname(dotgit:sub(1, 1) == "/" and dotgit or (dir .. "/" .. dotgit)))
    end
  end
  table.sort(roots)
  return roots
end

---@param common string
---@param ref string
---@return string|nil sha
local function packed_ref(common, ref)
  local f = io.open(common .. "/packed-refs", "rb")
  if not f then
    return nil
  end
  local found
  for line in f:lines() do
    local sha, name = line:match("^(%x+) (.+)$")
    if name == ref then
      found = sha
      break
    end
  end
  f:close()
  return found
end

---@class ClaudeCodeRepoHead
---@field head string The commit HEAD points to
---@field branch string|nil The branch checked out; nil when HEAD is detached

---Where HEAD of the work tree at `top` points.
---@param top string
---@return ClaudeCodeRepoHead|nil head Nil without a commit yet, or when refs are not plain files (reftable)
function M.head(top)
  local git_dir = M.git_dir(top)
  local line = git_dir and read_line(git_dir .. "/HEAD")
  if not line then
    return nil
  end
  local ref = line:match("^ref: (.+)$")
  if not ref then
    return line:match("^%x+$") and { head = line } or nil
  end
  -- HEAD belongs to each worktree; branches live in the common directory.
  local common = M.common_dir(git_dir)
  local sha = read_line(common .. "/" .. ref) or packed_ref(common, ref)
  if not (sha and sha:match("^%x+$")) then
    return nil
  end
  return { head = sha, branch = ref:match("^refs/heads/(.+)$") }
end

return M
