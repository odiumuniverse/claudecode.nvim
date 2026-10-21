---@brief [[
--- Git snapshots around a Bash call. Bash can touch any file, so the hook records the work
--- tree before the call and asks git afterwards what changed.
---@brief ]]
---@module 'claudecode.hooks.git'

local uv = vim.uv or vim.loop

local repo = require("claudecode.review.repo")

local M = {}

-- `git hash-object -t tree /dev/null`: the tree of a repository with no commits yet.
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

-- Past this many untracked files, skip the per-file stat that spots Bash rewriting one.
local MAX_UNTRACKED_STAT = 5000

-- A folder of repositories gets a snapshot of this many of them at most: each one costs every Bash call.
M.MAX_REPOS = 32

local HEAD = { "rev-parse", "--verify", "-q", "HEAD" }
local STASH = { "stash", "create" }
local UNTRACKED = { "ls-files", "--others", "--exclude-standard", "-z" }

local function start(cwd, args, env)
  local cmd = { "git", "-C", cwd }
  vim.list_extend(cmd, args)
  -- Optional locks off: our read-only calls must not fight your git commands over index.lock.
  return vim.system(cmd, { text = false, env = vim.tbl_extend("force", { GIT_OPTIONAL_LOCKS = "0" }, env or {}) })
end

---@return string|nil stdout Nil when git failed
local function finish(job)
  local res = job:wait(10000)
  if res.code ~= 0 then
    return nil
  end
  return res.stdout or ""
end

local function run(cwd, args)
  return finish(start(cwd, args))
end

---Start git in several repositories at once: a folder of them costs the slowest one, not the sum.
---Start every command a step needs before waiting for any of them.
---@param tops string[]
---@param args string[]|fun(i: integer): string[] The same arguments everywhere, or per repository
---@return table[] jobs
local function start_each(tops, args)
  local jobs = {}
  for i, top in ipairs(tops) do
    jobs[i] = start(top, type(args) == "function" and args(i) or args)
  end
  return jobs
end

---@param jobs table[] From start_each
---@return table<integer, string> outs By index; nil where git failed
local function finish_each(jobs)
  local outs = {}
  for i, job in ipairs(jobs) do
    outs[i] = finish(job)
  end
  return outs
end

local function trim(out)
  return (out or ""):gsub("%s+$", "")
end

local function split_z(out)
  local items = {}
  for item in (out or ""):gmatch("[^%z]+") do
    items[#items + 1] = item
  end
  return items
end

---What `ls-files --others` printed, without the directories: git names a repository or worktree inside
---the work tree as a directory, and its files come up in its own snapshot.
local function untracked_files(out)
  return vim.tbl_filter(function(rel)
    return rel:sub(-1) ~= "/"
  end, split_z(out))
end

local function stat_key(path)
  local st = uv.fs_stat(path)
  if not st then
    return nil
  end
  return string.format("%d.%d:%d", st.mtime.sec, st.mtime.nsec or 0, st.size)
end

---@param cwd string
---@return string|nil toplevel
function M.toplevel(cwd)
  local out = run(cwd, { "rev-parse", "--show-toplevel" })
  if not out then
    return nil
  end
  local top = out:gsub("%s+$", "")
  return uv.fs_realpath(top) or top
end

---@param top string
---@param head string The commit HEAD points to, "" in a repository without commits
---@param stash string|nil What `stash create` printed; nil when it failed
---@param untracked_out string|nil What `ls-files --others` printed
---@return table|nil snap
local function snapshot_of(top, head, stash, untracked_out)
  if head == "" then
    stash = EMPTY_TREE
  elseif stash == nil then
    -- Falling back to HEAD would make all of your uncommitted work look like Claude's change:
    -- better no snapshot.
    return nil
  else
    -- `stash create` stores the work tree as a dangling commit without touching the stash list;
    -- it prints nothing on a clean tree, where HEAD already is the snapshot.
    stash = trim(stash)
    if stash == "" then
      stash = head
    end
  end
  local untracked = {}
  for i, rel in ipairs(untracked_files(untracked_out)) do
    untracked[rel] = i <= MAX_UNTRACKED_STAT and (stat_key(top .. "/" .. rel) or "") or ""
  end
  return { top = top, head = head, stash = stash, untracked = untracked }
end

---The index of the repository at `top`: in `.git`, or in the git dir that the `.git` file of a
---worktree or a submodule points to.
---@param top string
---@return string|nil
local function index_of(top)
  local git_dir = repo.git_dir(top)
  return git_dir and git_dir .. "/index" or nil
end

---Start `stash create` on a copy of each index. On the index itself it takes `index.lock`: it would
---fail next to your own git command, lazygit committing say, or make that command fail.
---@param tops string[]
---@return table[] jobs
---@return table<integer, string> copies To remove once the jobs are done
local function start_stashes(tops)
  local jobs, copies = {}, {}
  for i, top in ipairs(tops) do
    local index = index_of(top)
    local stat = index and uv.fs_stat(index)
    local copy = vim.fn.tempname()
    if stat and uv.fs_copyfile(index, copy, { ficlone = true }) then
      -- Git trusts the size and time of a file changed before the index was written, and compares
      -- the contents of one changed in that very second. A copy dated now would hide such an edit.
      -- The whole second errs on the safe side: git then compares a little more.
      uv.fs_utime(copy, stat.atime.sec, stat.mtime.sec)
      copies[i] = copy
    end
    jobs[i] = start(top, STASH, copies[i] and { GIT_INDEX_FILE = copies[i] } or nil)
  end
  return jobs, copies
end

---@param tops string[]
---@return table<integer, table> snaps By index in `tops`; nil where git could not take one
local function snapshot_all(tops)
  local head_jobs, untracked_jobs = start_each(tops, HEAD), start_each(tops, UNTRACKED)
  local stash_jobs, copies = start_stashes(tops)
  local heads, stashes, untracked = finish_each(head_jobs), finish_each(stash_jobs), finish_each(untracked_jobs)
  for _, copy in pairs(copies) do
    os.remove(copy)
  end
  local snaps = {}
  for i, top in ipairs(tops) do
    snaps[i] = snapshot_of(top, trim(heads[i]), stashes[i], untracked[i])
  end
  return snaps
end

---Record the work tree before a Bash call.
---@param cwd string
---@return table|nil snap { top, head, stash, untracked = { [relpath] = stat_key } }
function M.snapshot(cwd)
  local top = M.toplevel(cwd)
  return top and snapshot_all({ top })[1] or nil
end

---The repositories one level below `dir`, in name order.
---@param dir string
---@return string[]
local function repos_below(dir)
  local tops = {}
  for name in vim.fs.dir(dir) do
    local path = dir .. "/" .. name
    if uv.fs_stat(path .. "/.git") then
      tops[#tops + 1] = uv.fs_realpath(path) or path
    end
  end
  table.sort(tops)
  return tops
end

---The worktrees of `tops` that are not among them: Claude may `cd` into one outside the project, where
---Claude Code does not keep the shell, so the hooks still stand in the project. Those the command names
---come first.
---@param tops string[]
---@param command string|nil The Bash command
---@return string[] named Worktrees whose path is in the command
---@return string[] others
local function worktrees_of(tops, command)
  local seen, named, others = {}, {}, {}
  for _, top in ipairs(tops) do
    seen[top] = true
  end
  for _, top in ipairs(tops) do
    for _, tree in ipairs(repo.worktrees(top)) do
      if not seen[tree] then
        seen[tree] = true
        local in_command = command
          and (command:find(tree, 1, true) or command:find(vim.fn.fnamemodify(tree, ":~"), 1, true))
        table.insert(in_command and named or others, tree)
      end
    end
  end
  return named, others
end

---Record the work trees a Bash call can touch: the repository around `cwd`; when the project root is
---no repository but a folder that holds several, each repository one level below it; and the
---worktrees of all of them.
---@param cwd string
---@param project string|nil Where Claude was started; `cwd` when unknown
---@param command string|nil The Bash command: the worktrees it names are snapshotted first
---@return table[] snaps As M.snapshot gives them; a repository git could not snapshot is left out
function M.snapshots(cwd, project, command)
  local root = project and project ~= "" and project or cwd
  local top = M.toplevel(cwd)
  local below = {}
  if not (root == cwd and top or M.toplevel(root)) then
    for _, path in ipairs(repos_below(root)) do
      if path ~= top then
        below[#below + 1] = path
      end
    end
  end
  local named, others = worktrees_of(vim.list_extend(top and { top } or {}, below), command)
  local tops = top and { top } or {}
  vim.list_extend(tops, named)
  vim.list_extend(tops, below)
  vim.list_extend(tops, others)
  local count = math.min(#tops, M.MAX_REPOS)
  local taken = snapshot_all(vim.list_slice(tops, 1, count))
  local snaps = {}
  for i = 1, count do
    snaps[#snaps + 1] = taken[i]
  end
  return snaps
end

local SNIFF_BYTES = 8000

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function head_of(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read(SNIFF_BYTES)
  f:close()
  return data
end

---Git keeps a file that it checks out with CRLF (`eol=crlf`, `core.autocrlf`) as LF in its objects,
---so the blob is not the text that was on disk before the call. Ask git what a checkout of the blob
---writes: that is the old file. Where git converts nothing, it answers with the blob itself.
---@param top string
---@param rev string The commit the blob comes from: the snapshot or the new HEAD
---@param rel string
---@param blob string|nil
---@return string|nil
local function checkout_text(top, rev, rel, blob)
  if not blob or blob:find("\r", 1, true) then
    return blob
  end
  local head = head_of(top .. "/" .. rel)
  if not head or not head:find("\r\n", 1, true) then
    return blob
  end
  -- Checking out a Git LFS pointer would fetch the object it points to.
  if blob:find("^version https://git%-lfs") then
    return blob
  end
  return run(top, { "cat-file", "--filters", rev .. ":" .. rel }) or blob
end

---Paths that differ between two trees, or between a tree and the work tree with one argument.
---@return table<string, true>|nil
local function differing(top, ...)
  local out = run(top, { "diff", "--name-only", "-z", "--no-renames", ... })
  if not out then
    return nil
  end
  local set = {}
  for _, rel in ipairs(split_z(out)) do
    set[rel] = true
  end
  return set
end

---A call that moved HEAD (switch, pull, rebase, reset) had git rewrite files. Which of them matched
---the old HEAD before the call, and which differ from the new HEAD after it.
---@param snap table From M.snapshot
---@param head string HEAD now
---@return { head: string, dirty_before: table<string, true>, dirty_after: table<string, true> }|nil
local function head_move(snap, head)
  if not snap.head or snap.head == "" or head == "" or head == snap.head then
    return nil
  end
  local dirty_before = differing(snap.top, snap.head, snap.stash)
  local dirty_after = differing(snap.top, head)
  if not dirty_before or not dirty_after then
    return nil
  end
  return { head = head, dirty_before = dirty_before, dirty_after = dirty_after }
end

---@param snap table From M.snapshot
---@param head string HEAD now
---@param diff_out string|nil What `git diff --name-only` against the snapshot printed
---@param untracked_out string|nil What `ls-files --others` printed
---@return table changes As M.changes gives them
local function changes_of(snap, head, diff_out, untracked_out)
  local top, stash = snap.top, snap.stash
  local changes = { tracked = {}, checked_out = {}, created = {}, untracked_changed = {} }

  local move = head_move(snap, head)
  for _, rel in ipairs(split_z(diff_out)) do
    local list, from = changes.tracked, stash
    if move and not move.dirty_before[rel] then
      if move.dirty_after[rel] then
        -- Claude edited what git checked out: the base is the text of the new HEAD.
        from = move.head
      else
        -- Git checked the file out, Claude did not touch it.
        list = changes.checked_out
      end
    end
    -- Missing from the tree means the file was added to the index meanwhile: new.
    local blob = run(top, { "cat-file", "blob", from .. ":" .. rel })
    -- After a move the base of this file is dealt with here, and matches the new HEAD.
    list[#list + 1] =
      { path = top .. "/" .. rel, text = checkout_text(top, from, rel, blob), head = move and move.head }
  end

  local before = snap.untracked or {}
  local copies = snap.copies or {}
  -- An untracked file copied before the call comes up as a tracked one would, the copy its base.
  -- Of the others only the path goes to the editor, whose buffer may hold the old text.
  local function untracked_change(rel)
    local text = copies[rel] and read_file(copies[rel])
    if text then
      changes.tracked[#changes.tracked + 1] = { path = top .. "/" .. rel, text = text }
    else
      changes.untracked_changed[#changes.untracked_changed + 1] = top .. "/" .. rel
    end
  end
  local now = {}
  for _, rel in ipairs(untracked_files(untracked_out)) do
    now[rel] = true
    if before[rel] == nil then
      changes.created[#changes.created + 1] = top .. "/" .. rel
    elseif before[rel] ~= "" and stat_key(top .. "/" .. rel) ~= before[rel] then
      untracked_change(rel)
    end
  end
  for rel in pairs(before) do
    if not now[rel] and not uv.fs_stat(top .. "/" .. rel) then
      untracked_change(rel)
    end
  end
  table.sort(changes.created)
  table.sort(changes.untracked_changed)
  return changes
end

---What a Bash call changed since `snaps`, in all of their repositories together.
---@param snaps table[] From M.snapshots
---@return table changes As M.changes gives them
function M.changes_all(snaps)
  local tops = vim.tbl_map(function(snap)
    return snap.top
  end, snaps)
  local head_jobs, untracked_jobs = start_each(tops, HEAD), start_each(tops, UNTRACKED)
  local diff_jobs = start_each(tops, function(i)
    return { "diff", "--name-only", "-z", "--no-renames", snaps[i].stash }
  end)
  local heads, diffs, untracked = finish_each(head_jobs), finish_each(diff_jobs), finish_each(untracked_jobs)
  local all = { tracked = {}, checked_out = {}, created = {}, untracked_changed = {} }
  for i, snap in ipairs(snaps) do
    for key, list in pairs(changes_of(snap, trim(heads[i]), diffs[i], untracked[i])) do
      vim.list_extend(all[key], list)
    end
  end
  return all
end

---What a Bash call changed since `snap`. A change in a repository whose HEAD the call moved carries
---the new HEAD as `head`.
---@param snap table From M.snapshot
---@return table changes { tracked = { {path, text|nil, head|nil} }, checked_out = { {path, text|nil, head|nil} }, created = {path}, untracked_changed = {path} }
function M.changes(snap)
  return M.changes_all({ snap })
end

return M
