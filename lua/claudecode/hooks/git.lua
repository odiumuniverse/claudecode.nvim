---@brief [[
--- Git snapshots around a Bash call. Bash can touch any file, so the hook records the work
--- tree before the call and asks git afterwards what changed.
---@brief ]]
---@module 'claudecode.hooks.git'

local uv = vim.uv or vim.loop

local M = {}

-- `git hash-object -t tree /dev/null`: the tree of a repository with no commits yet.
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

-- Past this many untracked files, skip the per-file stat that spots Bash rewriting one.
local MAX_UNTRACKED_STAT = 5000

local function run(cwd, args)
  local cmd = { "git", "-C", cwd }
  vim.list_extend(cmd, args)
  -- Optional locks off: our read-only calls must not fight your git commands over index.lock.
  local res = vim.system(cmd, { text = false, env = { GIT_OPTIONAL_LOCKS = "0" } }):wait(10000)
  if res.code ~= 0 then
    return nil
  end
  return res.stdout or ""
end

local function split_z(out)
  local items = {}
  for item in (out or ""):gmatch("[^%z]+") do
    items[#items + 1] = item
  end
  return items
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

---Record the work tree before a Bash call.
---@param cwd string
---@return table|nil snap { top, stash, untracked = { [relpath] = stat_key } }
function M.snapshot(cwd)
  local top = M.toplevel(cwd)
  if not top then
    return nil
  end
  local head = (run(top, { "rev-parse", "--verify", "-q", "HEAD" }) or ""):gsub("%s+$", "")
  local stash = EMPTY_TREE
  if head ~= "" then
    -- `stash create` stores the work tree as a dangling commit without touching the stash list;
    -- it prints nothing on a clean tree, where HEAD already is the snapshot.
    local out = run(top, { "stash", "create" })
    for _ = 1, 2 do
      if out ~= nil then
        break
      end
      uv.sleep(100) -- a parallel hook or your own git command usually lets go of the index lock at once
      out = run(top, { "stash", "create" })
    end
    if out == nil then
      -- It takes the index lock, so it fails next to another git process. Falling back to HEAD
      -- would make all of your uncommitted work look like Claude's change: better no snapshot.
      return nil
    end
    stash = out:gsub("%s+$", "")
    if stash == "" then
      stash = head
    end
  end
  local untracked = {}
  local files = split_z(run(top, { "ls-files", "--others", "--exclude-standard", "-z" }))
  for i, rel in ipairs(files) do
    untracked[rel] = i <= MAX_UNTRACKED_STAT and (stat_key(top .. "/" .. rel) or "") or ""
  end
  return { top = top, stash = stash, untracked = untracked }
end

local SNIFF_BYTES = 8000

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
---@param stash string
---@param rel string
---@param blob string|nil
---@return string|nil
local function checkout_text(top, stash, rel, blob)
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
  return run(top, { "cat-file", "--filters", stash .. ":" .. rel }) or blob
end

---What a Bash call changed since `snap`.
---@param snap table From M.snapshot
---@return table changes { tracked = { {path, text|nil} }, created = {path}, untracked_changed = {path} }
function M.changes(snap)
  local top, stash = snap.top, snap.stash
  local changes = { tracked = {}, created = {}, untracked_changed = {} }

  for _, rel in ipairs(split_z(run(top, { "diff", "--name-only", "-z", "--no-renames", stash }))) do
    -- Missing from the snapshot tree means the file was added to the index meanwhile: new.
    local blob = run(top, { "cat-file", "blob", stash .. ":" .. rel })
    changes.tracked[#changes.tracked + 1] = { path = top .. "/" .. rel, text = checkout_text(top, stash, rel, blob) }
  end

  local before = snap.untracked or {}
  local now = {}
  for _, rel in ipairs(split_z(run(top, { "ls-files", "--others", "--exclude-standard", "-z" }))) do
    now[rel] = true
    if before[rel] == nil then
      changes.created[#changes.created + 1] = top .. "/" .. rel
    elseif before[rel] ~= "" and stat_key(top .. "/" .. rel) ~= before[rel] then
      changes.untracked_changed[#changes.untracked_changed + 1] = top .. "/" .. rel
    end
  end
  for rel in pairs(before) do
    if not now[rel] and not uv.fs_stat(top .. "/" .. rel) then
      changes.untracked_changed[#changes.untracked_changed + 1] = top .. "/" .. rel
    end
  end
  table.sort(changes.created)
  table.sort(changes.untracked_changed)
  return changes
end

return M
