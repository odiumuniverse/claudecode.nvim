---@brief [[
--- On-disk review state shared by the hook scripts and the editor: the base text of every
--- file Claude touched, revert records waiting to be told to Claude, and Bash snapshots.
--- Runs both inside the editor and inside `nvim --clean -l` hook processes, so it only
--- relies on vim.uv, vim.fn and vim.json.
---@brief ]]
---@module 'claudecode.review.store'

local uv = vim.uv or vim.loop

local M = {}

---@class ClaudeCodeReviewBase
---@field path string Normalized absolute path
---@field text string File bytes before Claude's first edit
---@field new_file boolean The file did not exist before Claude's first edit
---@field created_at integer os.time() of the snapshot
---@field sessions string[] Claude sessions that edited the file; empty for a base made before sessions were tracked

---@class ClaudeCodeReviewStore
---@field dir string
---@field lock_wait_ms integer
local Store = {}
Store.__index = Store

local DIR_MODE = 448 -- 0700: bases are copies of source files
local FILE_MODE = 384 -- 0600

---Resolve symlinks so /tmp/x and /private/tmp/x share one base.
---@param path string
---@return string
function M.normalize(path)
  local real = uv.fs_realpath(path)
  if real then
    return real
  end
  -- New files have no realpath yet: resolve the directory instead.
  local parent = vim.fn.fnamemodify(path, ":h")
  local real_parent = uv.fs_realpath(parent)
  if real_parent then
    return real_parent .. "/" .. vim.fn.fnamemodify(path, ":t")
  end
  return path
end

---@class ClaudeCodeFileStamp
---@field exists boolean
---@field size integer|nil
---@field sec integer|nil
---@field nsec integer|nil

---What the file at `path` looks like on disk: whether it is there, its size and modification time.
---@param path string
---@return ClaudeCodeFileStamp
function M.stamp(path)
  local stat = uv.fs_stat(path)
  if not stat then
    return { exists = false }
  end
  return { exists = true, size = stat.size, sec = stat.mtime.sec, nsec = stat.mtime.nsec }
end

---@param a ClaudeCodeFileStamp
---@param b ClaudeCodeFileStamp
---@return boolean
function M.same_stamp(a, b)
  return a.exists == b.exists and a.size == b.size and a.sec == b.sec and a.nsec == b.nsec
end

local function read_all(path)
  local fd = uv.fs_open(path, "r", FILE_MODE)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  return data
end

local function write_all(path, data)
  local fd, err = uv.fs_open(path, "w", FILE_MODE)
  if not fd then
    return nil, err
  end
  local ok, write_err = uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  if not ok then
    return nil, write_err
  end
  return true
end

local tmp_counter = 0

---A temp name unique across processes, in the same directory so rename/link stay atomic.
local function tmp_name(final)
  tmp_counter = tmp_counter + 1
  return string.format("%s.tmp.%d.%d.%d", final, uv.os_getpid(), uv.hrtime(), tmp_counter)
end

local function ensure_dir(path)
  if vim.fn.isdirectory(path) == 0 then
    -- Another hook may make the directory between the check and mkdir: E739.
    pcall(vim.fn.mkdir, path, "p")
  end
  uv.fs_chmod(path, DIR_MODE)
end

-- Changing the header of a base means reading it and writing it back: two hooks doing that at the
-- same moment would lose one change, so each such change takes the lock of its base.
M.LOCK_WAIT_MS = 2000
local LOCK_STALE_S = 10

---Run `fn` while holding the lock of the base file `final`. A lock is a directory next to the base:
---mkdir either makes it or fails. A hook that died holding the lock is not waited for past
---LOCK_STALE_S, and `fn` runs without the lock after `wait_ms`: Claude must never hang on us.
---@generic T
---@param final string
---@param wait_ms integer
---@param fn fun(): T
---@return T
local function with_lock(final, wait_ms, fn)
  local lock = final .. ".lock"
  local deadline = uv.hrtime() + wait_ms * 1e6
  local held = false
  while true do
    local made, _, name = uv.fs_mkdir(lock, DIR_MODE)
    if made then
      held = true
      break
    end
    if name ~= "EEXIST" then
      break -- no bases directory yet, so nothing to race with
    end
    local stat = uv.fs_stat(lock)
    if stat and stat.mtime.sec < os.time() - LOCK_STALE_S then
      uv.fs_rmdir(lock)
    elseif uv.hrtime() >= deadline then
      break
    else
      uv.sleep(2)
    end
  end
  local ok, result = pcall(fn)
  if held then
    uv.fs_rmdir(lock)
  end
  if not ok then
    error(result, 0)
  end
  return result
end

---@class ClaudeCodeReviewStoreOpts
---@field lock_wait_ms integer|nil How long a change waits for the lock of a base before it goes on
---  without. A hook can wait for a lock that was left behind; the editor's one thread cannot.

---@param dir string Project state directory
---@param opts ClaudeCodeReviewStoreOpts|nil
---@return ClaudeCodeReviewStore
function M.new(dir, opts)
  return setmetatable({ dir = dir, lock_wait_ms = opts and opts.lock_wait_ms or M.LOCK_WAIT_MS }, Store)
end

function Store:_base_file(path)
  return self.dir .. "/bases/" .. vim.fn.sha256(path)
end

---session_id and tool_use_id come from Claude's hook input: keep them to a plain file name.
---@param id any
---@return boolean
local function valid_id(id)
  return type(id) == "string" and id:match("^[%w_-]+$") ~= nil
end

---The ids in `list` that are safe to use as file names, without repeats.
---@param list any
---@return string[]
local function clean_ids(list)
  local ids, seen = {}, {}
  if type(list) == "table" then
    for _, id in ipairs(list) do
      if valid_id(id) and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
      end
    end
  end
  return ids
end

---A base file is one JSON header line followed by the raw bytes, so it is created by a single
---atomic link and readers never see a header without its text.
local function encode_base(base)
  local header = {
    path = base.path,
    new_file = base.new_file,
    created_at = base.created_at,
    -- an empty list would encode as an object; a base without sessions stays as it always was
    sessions = base.sessions and #base.sessions > 0 and base.sessions or nil,
  }
  return vim.json.encode(header) .. "\n" .. base.text
end

local function decode_base(data)
  local nl = data:find("\n", 1, true)
  if not nl then
    return nil
  end
  local ok, header = pcall(vim.json.decode, data:sub(1, nl - 1))
  if not ok or type(header) ~= "table" or type(header.path) ~= "string" then
    return nil
  end
  return {
    path = header.path,
    new_file = header.new_file == true,
    created_at = tonumber(header.created_at) or 0,
    sessions = clean_ids(header.sessions),
    text = data:sub(nl + 1),
  }
end

---Replace the file of a base in one step.
---@return boolean
local function replace_base(final, base)
  local tmp = tmp_name(final)
  if not write_all(tmp, encode_base(base)) then
    uv.fs_unlink(tmp)
    return false
  end
  return uv.fs_rename(tmp, final) == true
end

---Create the base for `path` from `text` unless one exists: the earliest snapshot wins.
---@param path string
---@param text string
---@param new_file boolean
---@param session_id string|nil The Claude session that is editing the file
---@return boolean created
function Store:snapshot_text(path, text, new_file, session_id)
  path = M.normalize(path)
  ensure_dir(self.dir)
  ensure_dir(self.dir .. "/bases")
  local final = self:_base_file(path)
  local tmp = tmp_name(final)
  local base = {
    path = path,
    text = text,
    new_file = new_file,
    created_at = os.time(),
    sessions = clean_ids({ session_id }),
  }
  if not write_all(tmp, encode_base(base)) then
    uv.fs_unlink(tmp)
    return false
  end
  -- link fails with EEXIST when another snapshot got there first, unlike rename.
  local linked = uv.fs_link(tmp, final)
  uv.fs_unlink(tmp)
  if not linked and session_id then
    self:add_session(path, session_id)
  end
  return linked == true
end

---Write down in the header of the base of `path` that `session_id` edited the file. Nothing happens
---when there is no base.
---@param path string
---@param session_id string|nil
---@return boolean added The session is in the header now
function Store:add_session(path, session_id)
  if not valid_id(session_id) then
    return false
  end
  local final = self:_base_file(M.normalize(path))
  local function current()
    local data = read_all(final)
    return data and decode_base(data)
  end
  -- Every later hook of the same session finds itself written down: no lock for that.
  local base = current()
  if not base then
    return false
  end
  if vim.list_contains(base.sessions, session_id) then
    return true
  end
  return with_lock(final, self.lock_wait_ms, function()
    base = current() -- it may have changed while we waited
    if not base then
      return false
    end
    if not vim.list_contains(base.sessions, session_id) then
      base.sessions[#base.sessions + 1] = session_id
      return replace_base(final, base)
    end
    return true
  end)
end

---Create the base for `path` from the file on disk, or mark it new if it does not exist.
---@param path string
---@param session_id string|nil The Claude session that is editing the file
---@return boolean created
function Store:snapshot(path, session_id)
  local text = read_all(path)
  return self:snapshot_text(path, text or "", text == nil, session_id)
end

---@param path string
---@return ClaudeCodeReviewBase|nil
function Store:get(path)
  local data = read_all(self:_base_file(M.normalize(path)))
  return data and decode_base(data) or nil
end

---Replace the base for `path`: you kept a hunk, so its text is reviewed.
---@param path string
---@param text string
---@param new_file boolean|nil Keep the base marked new (default: no longer new)
function Store:set(path, text, new_file)
  path = M.normalize(path)
  ensure_dir(self.dir)
  ensure_dir(self.dir .. "/bases")
  local final = self:_base_file(path)
  with_lock(final, self.lock_wait_ms, function()
    local old = self:get(path)
    replace_base(final, {
      path = path,
      text = text,
      new_file = new_file == true,
      created_at = old and old.created_at or os.time(),
      sessions = old and old.sessions or {},
    })
  end)
end

---@param path string
function Store:remove(path)
  local final = self:_base_file(M.normalize(path))
  with_lock(final, self.lock_wait_ms, function()
    uv.fs_unlink(final)
  end)
end

---@return ClaudeCodeReviewBase[]
function Store:list()
  local bases = {}
  local handle = uv.fs_scandir(self.dir .. "/bases")
  if not handle then
    return bases
  end
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    -- Some file systems leave the type out of the scan: ask for it.
    if kind == nil then
      local stat = uv.fs_stat(self.dir .. "/bases/" .. name)
      kind = stat and stat.type
    end
    -- Skip in-flight temp files: their names carry a ".tmp." suffix, base names are bare hashes.
    if kind == "file" and not name:find(".", 1, true) then
      local data = read_all(self.dir .. "/bases/" .. name)
      local base = data and decode_base(data)
      if base then
        bases[#bases + 1] = base
      end
    end
  end
  return bases
end

-- A session that stays away this long will not come back for its reverts.
local REVERTS_MAX_AGE_S = 7 * 24 * 3600

---Tell Claude about a revert: every session that edited the file hears of it, from its own file in
---`reverts/`. A file whose base knows no session (made before sessions were tracked) goes to
---`reverts.jsonl`, which any session takes.
---@param rec ClaudeCodeRevertRecord
function Store:append_revert(rec)
  ensure_dir(self.dir)
  local base = type(rec.path) == "string" and self:get(rec.path) or nil
  local files = {}
  for _, id in ipairs(base and base.sessions or {}) do
    files[#files + 1] = self.dir .. "/reverts/" .. id .. ".jsonl"
  end
  if #files > 0 then
    ensure_dir(self.dir .. "/reverts")
  else
    files[1] = self.dir .. "/reverts.jsonl"
  end
  local line = vim.json.encode(rec) .. "\n"
  for _, file in ipairs(files) do
    -- One write per record on an O_APPEND descriptor keeps concurrent appends whole.
    local fd = uv.fs_open(file, "a", FILE_MODE)
    if fd then
      uv.fs_write(fd, line, -1)
      uv.fs_close(fd)
    end
  end
end

---Read and clear one file of revert records. A record appended meanwhile lands in a fresh file.
---@param log string
---@return ClaudeCodeRevertRecord[]
local function take_file(log)
  local taking = tmp_name(log)
  if not uv.fs_rename(log, taking) then
    return {}
  end
  local data = read_all(taking) or ""
  uv.fs_unlink(taking)
  local records = {}
  for line in data:gmatch("[^\n]+") do
    local ok, rec = pcall(vim.json.decode, line)
    if ok and type(rec) == "table" then
      records[#records + 1] = rec
    end
  end
  return records
end

---The files of sessions that never came back for them go after a week.
function Store:_drop_stale_reverts()
  local handle = uv.fs_scandir(self.dir .. "/reverts")
  local cutoff = os.time() - REVERTS_MAX_AGE_S
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local path = self.dir .. "/reverts/" .. name
    local stat = uv.fs_stat(path)
    if stat and stat.mtime.sec < cutoff then
      uv.fs_unlink(path)
    end
  end
end

---Read and clear the revert records of a session, and those in the common file.
---@param session_id string|nil Without a usable id only the common file is taken
---@return ClaudeCodeRevertRecord[]
function Store:take_reverts(session_id)
  local records = {}
  if valid_id(session_id) then
    records = take_file(self.dir .. "/reverts/" .. session_id .. ".jsonl")
  end
  vim.list_extend(records, take_file(self.dir .. "/reverts.jsonl"))
  self:_drop_stale_reverts()
  return records
end

local function id_file(self, subdir, id)
  if not valid_id(id) then
    return nil
  end
  return self.dir .. "/" .. subdir .. "/" .. id .. ".json"
end

local function bash_file(self, id)
  return id_file(self, "bash", id)
end

-- An accepted edit whose PostToolUse never came (the call failed) leaves its file behind.
local STALE_BEFORE_S = 24 * 3600

---Keep the file text from before an edit that needs no review, until its PostToolUse.
---@param id string tool_use_id of the edit
---@param text string
---@return boolean saved
function Store:save_before(id, text)
  local file = id_file(self, "accepting", id)
  if not file then
    return false
  end
  ensure_dir(self.dir)
  ensure_dir(self.dir .. "/accepting")
  local handle = uv.fs_scandir(self.dir .. "/accepting")
  local cutoff = os.time() - STALE_BEFORE_S
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local stat = uv.fs_stat(self.dir .. "/accepting/" .. name)
    if stat and stat.mtime.sec < cutoff then
      uv.fs_unlink(self.dir .. "/accepting/" .. name)
    end
  end
  local tmp = tmp_name(file)
  if not write_all(tmp, text) then
    uv.fs_unlink(tmp)
    return false
  end
  return uv.fs_rename(tmp, file) == true
end

---@param id string
---@return string|nil text The file before the edit, once
function Store:take_before(id)
  local file = id_file(self, "accepting", id)
  local text = file and read_all(file)
  if file then
    uv.fs_unlink(file)
  end
  return text or nil
end

---@param id string tool_use_id of the Bash call
---@param snap table
---@return boolean saved
function Store:save_bash(id, snap)
  local file = bash_file(self, id)
  if not file then
    return false
  end
  ensure_dir(self.dir)
  ensure_dir(self.dir .. "/bash")
  local tmp = tmp_name(file)
  if not write_all(tmp, vim.json.encode(snap)) then
    uv.fs_unlink(tmp)
    return false
  end
  return uv.fs_rename(tmp, file) == true
end

---A Bash call that Claude Code refused or that failed never reaches PostToolUse: its snapshot
---would stay forever.
---@param max_age integer Seconds
function Store:drop_stale_bash(max_age)
  local handle = uv.fs_scandir(self.dir .. "/bash")
  if not handle then
    return
  end
  local cutoff = os.time() - max_age
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local path = self.dir .. "/bash/" .. name
    local stat = uv.fs_stat(path)
    if stat and stat.mtime.sec < cutoff then
      uv.fs_unlink(path)
    end
  end
end

---PreToolUse announces that Claude is about to edit `path`; PostToolUse takes the note back. Until
---then the base of that path equals the file and must not be mistaken for a leftover.
---@param id string tool_use_id of the edit
---@param path string
---@param created boolean|nil This PreToolUse created the base (it did not exist before)
---@param stamp ClaudeCodeFileStamp|nil The file as PreToolUse found it. Once it differs, the file is
---  either Claude's write on its way to PostToolUse, or yours.
---@param tool string|nil Claude's tool, such as "Edit" or "Write": openDiff does not name it
---@return boolean saved
function Store:begin_edit(id, path, created, stamp, tool)
  local file = id_file(self, "editing", id)
  if not file then
    return false
  end
  ensure_dir(self.dir)
  ensure_dir(self.dir .. "/editing")
  local tmp = tmp_name(file)
  local note = { path = M.normalize(path), created = created == true, stamp = stamp, tool = tool }
  if not write_all(tmp, vim.json.encode(note)) then
    uv.fs_unlink(tmp)
    return false
  end
  return uv.fs_rename(tmp, file) == true
end

---Has PreToolUse noted this edit and PostToolUse not taken the note back yet?
---@param id string|nil tool_use_id of the edit
---@return boolean
function Store:is_editing(id)
  local file = id_file(self, "editing", id)
  return file ~= nil and uv.fs_stat(file) ~= nil
end

---The edit is done. Notes of earlier edits of the same path go too: whatever became of them, the
---base now serves this edit, and a base is only forgotten for an edit that nothing followed.
---@param id string|nil tool_use_id of the edit
---@param path string|nil
function Store:end_edit(id, path)
  local file = id_file(self, "editing", id)
  if file then
    uv.fs_unlink(file)
  end
  if not path then
    return
  end
  path = M.normalize(path)
  local handle = uv.fs_scandir(self.dir .. "/editing")
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local note = self.dir .. "/editing/" .. name
    local ok, rec = pcall(vim.json.decode, read_all(note) or "")
    if ok and type(rec) == "table" and rec.path == path then
      uv.fs_unlink(note)
    end
  end
end

---@class ClaudeCodeReviewEditNote
---@field file string Where the note lives
---@field valid boolean
---@field mtime integer|nil Modification time of the note file, in seconds
---@field path string|nil
---@field created boolean The base was made by that edit's PreToolUse
---@field stamp ClaudeCodeFileStamp|nil
---@field tool string|nil

---@return ClaudeCodeReviewEditNote[]
local function read_notes(self)
  local notes = {}
  local handle = uv.fs_scandir(self.dir .. "/editing")
  while handle do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local file = self.dir .. "/editing/" .. name
    local stat = uv.fs_stat(file)
    local ok, rec = pcall(vim.json.decode, read_all(file) or "")
    local valid = name:match("%.json$") and ok and type(rec) == "table" and type(rec.path) == "string"
    notes[#notes + 1] = {
      file = file,
      valid = valid and true or false,
      mtime = stat and stat.mtime.sec or nil,
      path = valid and rec.path or nil,
      created = valid and rec.created == true or false,
      stamp = valid and type(rec.stamp) == "table" and rec.stamp or nil,
      tool = valid and type(rec.tool) == "string" and rec.tool or nil,
    }
  end
  return notes
end

---Which of Claude's tools is editing `path`, as its PreToolUse noted. Claude asks before an edit
---after that hook, so a proposal Claude sends to the editor finds the note in place.
---@param path string
---@param max_age integer Seconds after which a note no longer counts
---@return string|nil tool
function Store:edit_tool(path, max_age)
  path = M.normalize(path)
  local cutoff = os.time() - max_age
  local newest
  for _, note in ipairs(read_notes(self)) do
    local live = note.mtime == nil or note.mtime >= cutoff
    if note.valid and live and note.path == path and note.tool then
      if not newest or (note.mtime or 0) > (newest.mtime or 0) then
        newest = note
      end
    end
  end
  return newest and newest.tool
end

---@class ClaudeCodeReviewStaleEdit
---@field path string
---@field created boolean The base was made by that edit's PreToolUse
---@field stamp ClaudeCodeFileStamp|nil

---Paths of the edits that have started and not finished. An edit that Claude Code was not allowed
---to make never finishes: a note older than `max_age` seconds is dropped and handed back, so the
---caller can forget the base it made.
---@param max_age integer
---@return table<string, true> paths
---@return ClaudeCodeReviewStaleEdit[] stale
function Store:editing(max_age)
  local paths, stale = {}, {}
  local cutoff = os.time() - max_age
  for _, note in ipairs(read_notes(self)) do
    if note.mtime and note.mtime < cutoff then
      uv.fs_unlink(note.file)
      if note.valid then
        stale[#stale + 1] = { path = note.path, created = note.created, stamp = note.stamp }
      end
    elseif note.valid then
      paths[note.path] = true
    end
  end
  return paths, stale
end

---Is `path` a file whose base an unfinished edit made, and which is no longer as that edit found it?
---Then it is either Claude's write, not yet reported by PostToolUse, or a file you made after Claude
---Code refused the edit. Nothing tells the two apart until PostToolUse comes or the note runs out, so
---until then the file is not Claude's to review, and certainly not Claude's to delete.
---@param path string
---@param max_age integer Seconds after which a note no longer counts
---@return boolean
function Store:in_doubt(path, max_age)
  path = M.normalize(path)
  local cutoff = os.time() - max_age
  local current
  for _, note in ipairs(read_notes(self)) do
    local live = note.mtime == nil or note.mtime >= cutoff
    if note.valid and live and note.path == path and note.created and note.stamp then
      current = current or M.stamp(path)
      if not M.same_stamp(note.stamp, current) then
        return true
      end
    end
  end
  return false
end

---Claude Code refused an earlier edit of `path`: it never reported back, and the base that edit made
---holds the file as it was then. Forget that base and the note when the file has changed since, so
---the next base is taken from the file as it is. Whatever changed it in between was not Claude.
---@param path string
---@param stamp ClaudeCodeFileStamp|nil The file now. Without it every such note counts, as after a Bash
---  call, which changes the file itself.
---@return boolean forgot
function Store:forget_refused(path, stamp)
  path = M.normalize(path)
  local forgot = false
  for _, note in ipairs(read_notes(self)) do
    if note.valid and note.path == path and note.created then
      if stamp == nil or (note.stamp and not M.same_stamp(note.stamp, stamp)) then
        uv.fs_unlink(note.file)
        forgot = true
      end
    end
  end
  if forgot then
    self:remove(path)
  end
  return forgot
end

---@param id string
---@return table|nil
function Store:take_bash(id)
  local file = bash_file(self, id)
  local data = file and read_all(file)
  if not data then
    return nil
  end
  uv.fs_unlink(file)
  local ok, snap = pcall(vim.json.decode, data)
  return ok and snap or nil
end

return M
