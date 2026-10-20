--- Tests for the on-disk review state: bases, revert records and Bash snapshots.
local store_mod = require("claudecode.review.store")

local function write_file(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

describe("review store", function()
  local dir, work, store

  before_each(function()
    dir = vim.fn.tempname()
    work = vim.fn.tempname()
    vim.fn.mkdir(work, "p")
    store = store_mod.new(dir)
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
    vim.fn.delete(work, "rf")
  end)

  it("keeps the file's bytes as its base", function()
    local file = work .. "/a.txt"
    write_file(file, "one\r\ntwo\n")

    assert.is_true(store:snapshot(file))

    local base = store:get(file)
    assert.equal("one\r\ntwo\n", base.text)
    assert.is_false(base.new_file)
    assert.equal(vim.uv.fs_realpath(file), base.path)
  end)

  it("marks a file that does not exist yet as new with an empty base", function()
    local file = work .. "/new.txt"

    assert.is_true(store:snapshot(file))

    local base = store:get(file)
    assert.equal("", base.text)
    assert.is_true(base.new_file)
  end)

  it("keeps the earliest snapshot when Claude edits the file again", function()
    local file = work .. "/a.txt"
    write_file(file, "first\n")
    store:snapshot(file)
    write_file(file, "second\n")

    assert.is_false(store:snapshot(file))
    assert.equal("first\n", store:get(file).text)
  end)

  it("finds the base through a symlinked path", function()
    local file = work .. "/a.txt"
    write_file(file, "x\n")
    local link = work .. "/link.txt"
    assert(vim.uv.fs_symlink(file, link))

    store:snapshot(link)

    assert.equal("x\n", store:get(file).text)
  end)

  it("moves the base forward and removes it", function()
    local file = work .. "/a.txt"
    write_file(file, "old\n")
    store:snapshot(file)

    store:set(file, "kept\n")
    assert.equal("kept\n", store:get(file).text)
    assert.is_false(store:get(file).new_file)

    store:remove(file)
    assert.is_nil(store:get(file))
  end)

  it("lists every base", function()
    write_file(work .. "/a.txt", "a\n")
    store:snapshot(work .. "/a.txt")
    store:snapshot(work .. "/b.txt")

    local paths = vim.tbl_map(function(b)
      return b.path
    end, store:list())
    table.sort(paths)

    assert.same({ store_mod.normalize(work .. "/a.txt"), store_mod.normalize(work .. "/b.txt") }, paths)
  end)

  it("lists nothing before the first snapshot", function()
    assert.same({}, store:list())
  end)

  it("lists the bases on a file system whose directory scan does not say what an entry is", function()
    write_file(work .. "/a.txt", "a\n")
    store:snapshot(work .. "/a.txt")
    -- some file systems (and network mounts) answer with the name only
    local scandir_next = vim.uv.fs_scandir_next
    vim.uv.fs_scandir_next = function(handle)
      local name = scandir_next(handle)
      return name
    end

    local ok, bases = pcall(store.list, store)
    vim.uv.fs_scandir_next = scandir_next

    assert.is_true(ok, bases)
    assert.equal(1, #bases)
    assert.equal(store_mod.normalize(work .. "/a.txt"), bases[1].path)
  end)

  it("keeps the state directory private", function()
    store:snapshot(work .. "/a.txt")

    local mode = vim.uv.fs_stat(dir).mode
    assert.equal(tonumber("700", 8), bit.band(mode, tonumber("777", 8)))
  end)

  it("hands revert records out once, in the order they were added", function()
    store:append_revert({ path = "/p/a.lua", line = 3, base_lines = { "a" }, claude_lines = { "b" }, time = 1 })
    store:append_revert({ path = "/p/b.lua", line = 1, base_lines = {}, claude_lines = { "c" }, time = 2 })

    local taken = store:take_reverts()

    assert.equal(2, #taken)
    assert.equal("/p/a.lua", taken[1].path)
    assert.same({ "c" }, taken[2].claude_lines)
    assert.same({}, store:take_reverts())
  end)

  it("skips a damaged revert record instead of losing the rest", function()
    store:append_revert({ path = "/p/a.lua", line = 1, base_lines = {}, claude_lines = {}, time = 1 })
    local f = assert(io.open(dir .. "/reverts.jsonl", "ab"))
    f:write("{not json\n")
    f:close()

    assert.equal(1, #store:take_reverts())
  end)

  describe("sessions", function()
    local file

    before_each(function()
      file = work .. "/a.txt"
      write_file(file, "old\n")
    end)

    it("remembers the session that made the base", function()
      store:snapshot(file, "s1")

      assert.same({ "s1" }, store:get(file).sessions)
    end)

    it("adds a second session to the base the first made, once, and keeps the earliest text", function()
      store:snapshot(file, "s1")
      write_file(file, "new\n")

      assert.is_false(store:snapshot(file, "s2"))
      store:snapshot(file, "s2")

      local base = store:get(file)
      assert.same({ "s1", "s2" }, base.sessions)
      assert.equal("old\n", base.text)
    end)

    it("keeps the sessions when you keep a hunk and the base moves", function()
      store:snapshot(file, "s1")
      store:snapshot(file, "s2")

      store:set(file, "kept\n")

      local base = store:get(file)
      assert.equal("kept\n", base.text)
      assert.same({ "s1", "s2" }, base.sessions)
    end)

    it("changes the text of a base it reads under the lock, and keeps the sessions", function()
      store:snapshot(file, "s1")
      store:snapshot(file, "s2")

      local changed = store:update(file, function(base)
        assert.equal("old\n", base.text)
        return base.text .. "more\n"
      end)

      assert.is_true(changed)
      local base = store:get(file)
      assert.equal("old\nmore\n", base.text)
      assert.same({ "s1", "s2" }, base.sessions)
    end)

    it("makes no base for a file that has none, such as one you just finished with", function()
      local called = false

      local changed = store:update(file, function()
        called = true
        return "back from the dead\n"
      end)

      assert.is_false(changed)
      assert.is_false(called)
      assert.is_nil(store:get(file))
    end)

    it("leaves the base as it is when the change returns no text", function()
      store:snapshot(file, "s1")

      assert.is_false(store:update(file, function() end))

      assert.equal("old\n", store:get(file).text)
    end)

    it("reads a base made before sessions were tracked as having none", function()
      store:snapshot(file)

      assert.same({}, store:get(file).sessions)
    end)

    it("does not write a session id that is not a plain file name", function()
      store:snapshot(file, "../x")
      store:snapshot(file, "a/b")

      assert.same({}, store:get(file).sessions)
    end)

    it("loses no session when several hook processes record theirs at the same moment", function()
      local procs, files = 8, 40
      local child = vim.fn.tempname() .. ".lua"
      write_file(
        child,
        table.concat({
          "local root, state, work, go, ready, id, files = unpack(arg)",
          'package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path',
          'local store = require("claudecode.review.store").new(state)',
          'io.open(ready, "w"):close()',
          "while not vim.uv.fs_stat(go) do vim.uv.sleep(1) end",
          'for i = 1, tonumber(files) do store:snapshot(work .. "/f" .. i, id) end',
        }, "\n")
      )
      local root = vim.fn.fnamemodify(package.searchpath("claudecode.review.store", package.path), ":p:h:h:h:h")
      for i = 1, files do
        write_file(work .. "/f" .. i, "old\n")
      end
      local go = vim.fn.tempname()
      local ids, running, ready = {}, {}, {}
      for p = 1, procs do
        ids[p] = "s" .. p
        ready[p] = vim.fn.tempname()
        running[p] = vim.system({
          vim.v.progpath,
          "--clean",
          "--headless",
          "-l",
          child,
          root,
          dir,
          work,
          go,
          ready[p],
          ids[p],
          tostring(files),
        }, { text = true })
      end
      assert.is_true(vim.wait(10000, function()
        for p = 1, procs do
          if not vim.uv.fs_stat(ready[p]) then
            return false
          end
        end
        return true
      end, 10))
      write_file(go, "")
      for p = 1, procs do
        local res = running[p]:wait()
        assert.equal(0, res.code, res.stderr)
      end

      for i = 1, files do
        local sessions = store:get(work .. "/f" .. i).sessions
        table.sort(sessions)
        assert.same(ids, sessions, "file f" .. i)
      end
      vim.fn.delete(child)
    end)

    it("loses no session that hooks record while the editor keeps hunks over and over", function()
      local procs, per_proc = 3, 40
      local child = vim.fn.tempname() .. ".lua"
      write_file(
        child,
        table.concat({
          "local root, state, file, id, count = unpack(arg)",
          'package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path',
          'local store = require("claudecode.review.store").new(state)',
          'for i = 1, tonumber(count) do store:add_session(file, id .. "_" .. i) end',
        }, "\n")
      )
      local root = vim.fn.fnamemodify(package.searchpath("claudecode.review.store", package.path), ":p:h:h:h:h")
      store:snapshot(file, "s0")
      local finished, expected = 0, { "s0" }
      for p = 1, procs do
        for i = 1, per_proc do
          expected[#expected + 1] = "p" .. p .. "_" .. i
        end
        vim.system(
          { vim.v.progpath, "--clean", "--headless", "-l", child, root, dir, file, "p" .. p, tostring(per_proc) },
          {
            text = true,
          },
          function(res)
            assert(res.code == 0, res.stderr)
            finished = finished + 1
          end
        )
      end

      local kept = 0
      while finished < procs do
        kept = kept + 1
        store:set(file, "kept " .. kept .. "\n")
        vim.wait(1)
      end

      assert.is_true(kept > 1)
      local sessions = store:get(file).sessions
      table.sort(sessions)
      table.sort(expected)
      assert.same(expected, sessions)
      vim.fn.delete(child)
    end)

    it("does not wait for a lock that a dead hook left behind, and leaves none of its own", function()
      store:snapshot(file, "s1")
      local lock = dir .. "/bases/" .. vim.fn.sha256(store_mod.normalize(file)) .. ".lock"
      assert(vim.uv.fs_mkdir(lock, 448))
      local long_ago = os.time() - 60
      assert(vim.uv.fs_utime(lock, long_ago, long_ago))

      local started = vim.uv.hrtime()
      store:snapshot(file, "s2")

      assert.is_true((vim.uv.hrtime() - started) / 1e6 < 500)
      assert.same({ "s1", "s2" }, store:get(file).sessions)
      assert.is_nil(vim.uv.fs_stat(lock))
    end)

    it("waits for a fresh lock only as long as its store was told to, and leaves the lock alone", function()
      store:snapshot(file, "s1")
      local lock = dir .. "/bases/" .. vim.fn.sha256(store_mod.normalize(file)) .. ".lock"
      assert(vim.uv.fs_mkdir(lock, 448))
      local impatient = store_mod.new(dir, { lock_wait_ms = 30 })

      local started = vim.uv.hrtime()
      impatient:set(file, "kept\n")

      assert.is_true((vim.uv.hrtime() - started) / 1e6 < 500)
      assert.equal("kept\n", store:get(file).text)
      assert.same({ "s1" }, store:get(file).sessions)
      assert.is_not_nil(vim.uv.fs_stat(lock))
    end)

    it("takes only the plain ids from a header it did not write itself", function()
      store:snapshot(file)
      local base_file = dir .. "/bases/" .. vim.fn.sha256(store_mod.normalize(file))
      local header = vim.json.encode({
        path = store_mod.normalize(file),
        new_file = false,
        created_at = 1,
        sessions = { "s1", "../x", 7, "s1" },
      })
      write_file(base_file, header .. "\nold\n")

      assert.same({ "s1" }, store:get(file).sessions)
    end)
  end)

  describe("revert records of several sessions", function()
    local a, b

    local function revert(path, line)
      store:append_revert({ path = path, line = line or 1, base_lines = { "a" }, claude_lines = { "b" }, time = 1 })
    end

    before_each(function()
      a, b = work .. "/a.txt", work .. "/b.txt"
      write_file(a, "x\n")
      write_file(b, "y\n")
    end)

    it("gives a revert only to the session that edited the file", function()
      store:snapshot(a, "sA")
      store:snapshot(b, "sB")
      revert(a)
      revert(b)

      local for_a, for_b = store:take_reverts("sA"), store:take_reverts("sB")

      assert.equal(1, #for_a)
      assert.equal(a, for_a[1].path)
      assert.equal(1, #for_b)
      assert.equal(b, for_b[1].path)
    end)

    it("gives a revert to every session that edited the file", function()
      store:snapshot(a, "sA")
      store:snapshot(a, "sB")
      revert(a)

      assert.equal(1, #store:take_reverts("sA"))
      assert.equal(1, #store:take_reverts("sB"))
      assert.same({}, store:take_reverts("sA"))
    end)

    it("puts a revert of a base without sessions where any session takes it, once", function()
      store:snapshot(a)
      revert(a)

      assert.equal(1, #store:take_reverts("sA"))
      assert.same({}, store:take_reverts("sB"))
    end)

    it("hands the common file to a session that has no id, and leaves the sessions' files", function()
      store:snapshot(a, "sA")
      store:snapshot(b)
      revert(a)
      revert(b)

      local taken = store:take_reverts()

      assert.equal(1, #taken)
      assert.equal(b, taken[1].path)
      assert.equal(1, #store:take_reverts("sA"))
    end)

    it("reads no file outside the reverts directory for a session id that is not a plain name", function()
      vim.fn.mkdir(dir .. "/reverts", "p")
      write_file(dir .. "/x.jsonl", vim.json.encode({ path = "/p/x", line = 1 }) .. "\n")
      store:snapshot(b)
      revert(b)

      local taken = store:take_reverts("../x")

      assert.equal(1, #taken)
      assert.equal(b, taken[1].path)
      assert.is_not_nil(read_file(dir .. "/x.jsonl"))
    end)

    it("writes no file outside the reverts directory for a session id in a base", function()
      store:snapshot(a, "../x")
      revert(a)

      assert.is_nil(read_file(dir .. "/x.jsonl"))
      assert.equal(1, #store:take_reverts())
    end)

    it("deletes the file of a session untouched for a week when any session takes its own", function()
      store:snapshot(a, "gone")
      store:snapshot(b, "recent")
      revert(a)
      revert(b)
      local week_and_a_day = os.time() - 8 * 24 * 3600
      assert(vim.uv.fs_utime(dir .. "/reverts/gone.jsonl", week_and_a_day, week_and_a_day))

      assert.same({}, store:take_reverts("other"))

      assert.is_nil(vim.uv.fs_stat(dir .. "/reverts/gone.jsonl"))
      assert.equal(1, #store:take_reverts("recent"))
    end)
  end)

  it("hands a Bash snapshot out once", function()
    store:save_bash("toolu_1", { stash = "abc", untracked = { "x.txt" } })

    assert.same({ stash = "abc", untracked = { "x.txt" } }, store:take_bash("toolu_1"))
    assert.is_nil(store:take_bash("toolu_1"))
  end)

  it("drops Bash snapshots whose call never finished", function()
    store:save_bash("toolu_old", { stash = "a" })
    store:save_bash("toolu_new", { stash = "b" })
    local day_ago = os.time() - 25 * 3600
    vim.uv.fs_utime(dir .. "/bash/toolu_old.json", day_ago, day_ago)

    store:drop_stale_bash(24 * 3600)

    assert.is_nil(store:take_bash("toolu_old"))
    assert.same({ stash = "b" }, store:take_bash("toolu_new"))
  end)

  it("lists the files whose edit has started and not finished", function()
    local file = work .. "/a.txt"
    write_file(file, "x\n")

    assert.is_true(store:begin_edit("toolu_1", file))
    assert.same({ [vim.uv.fs_realpath(file)] = true }, (store:editing(3600)))

    store:end_edit("toolu_1")
    assert.same({}, store:editing(3600))
  end)

  it("forgets an edit that never finished: Claude Code did not get permission to make it", function()
    local file = work .. "/a.txt"
    write_file(file, "x\n")
    store:begin_edit("toolu_old", file)
    local hour_ago = os.time() - 3700
    vim.uv.fs_utime(dir .. "/editing/toolu_old.json", hour_ago, hour_ago)

    local paths, stale = store:editing(3600)

    assert.same({}, paths)
    assert.same({ { path = vim.uv.fs_realpath(file), created = false } }, stale)
    assert.is_nil(vim.uv.fs_stat(dir .. "/editing/toolu_old.json"))
  end)

  it("says whether the forgotten edit had made the base", function()
    local file = work .. "/a.txt"
    write_file(file, "x\n")
    store:begin_edit("toolu_made", file, true)
    local hour_ago = os.time() - 3700
    vim.uv.fs_utime(dir .. "/editing/toolu_made.json", hour_ago, hour_ago)

    local _, stale = store:editing(3600)

    assert.same({ { path = vim.uv.fs_realpath(file), created = true } }, stale)
  end)

  it("ends every note of a path at once", function()
    local file = work .. "/a.txt"
    local other = work .. "/b.txt"
    write_file(file, "x\n")
    write_file(other, "x\n")
    store:begin_edit("toolu_1", file, true)
    store:begin_edit("toolu_2", file, false)
    store:begin_edit("toolu_3", other, false)

    store:end_edit("toolu_2", file)

    assert.same({ [vim.uv.fs_realpath(other)] = true }, (store:editing(3600)))
  end)

  it("ends the notes of a path when only the path is known, as after a Bash call", function()
    local file = work .. "/a.txt"
    write_file(file, "x\n")
    store:begin_edit("toolu_1", file, true)

    store:end_edit(nil, file)

    assert.same({}, (store:editing(3600)))
  end)

  it("tells which tool is editing a file, for as long as its note lives", function()
    local file = work .. "/a.txt"
    local other = work .. "/b.txt"
    write_file(file, "x\n")
    write_file(other, "x\n")
    store:begin_edit("toolu_1", file, false, nil, "Write")
    store:begin_edit("toolu_2", other, false)

    assert.equal("Write", store:edit_tool(file, 3600))
    assert.is_nil(store:edit_tool(other, 3600))
    assert.is_nil(store:edit_tool(work .. "/none.txt", 3600))

    local hour_ago = os.time() - 3700
    vim.uv.fs_utime(dir .. "/editing/toolu_1.json", hour_ago, hour_ago)
    assert.is_nil(store:edit_tool(file, 3600))
  end)

  it("keeps a path with quotes, spaces and Cyrillic in the list of edits", function()
    local file = work .. "/it's a 'тест'.txt"
    write_file(file, "x\n")

    store:begin_edit("toolu_1", file)

    assert.same({ [vim.uv.fs_realpath(file)] = true }, (store:editing(3600)))
  end)

  describe("a file in doubt", function()
    local file, stamp

    before_each(function()
      file = work .. "/a.txt"
      write_file(file, "x\n")
      stamp = store_mod.stamp(file)
    end)

    it("is one that changed after PreToolUse made its base, while the edit is under way", function()
      store:begin_edit("toolu_1", file, true, stamp)
      assert.is_false(store:in_doubt(file, 3600))

      write_file(file, "changed\n")

      assert.is_true(store:in_doubt(file, 3600))
    end)

    it("is not one once the edit has finished", function()
      store:begin_edit("toolu_1", file, true, stamp)
      write_file(file, "changed\n")

      store:end_edit("toolu_1", file)

      assert.is_false(store:in_doubt(file, 3600))
    end)

    it("is not one when the note ran out", function()
      store:begin_edit("toolu_1", file, true, stamp)
      write_file(file, "changed\n")
      local hour_ago = os.time() - 3700
      vim.uv.fs_utime(dir .. "/editing/toolu_1.json", hour_ago, hour_ago)

      assert.is_false(store:in_doubt(file, 3600))
    end)

    it("is not one when the base was there before the edit", function()
      store:begin_edit("toolu_1", file, false, stamp)

      write_file(file, "changed\n")

      assert.is_false(store:in_doubt(file, 3600))
    end)

    it("is not one when the note has no stamp", function()
      store:begin_edit("toolu_1", file, true)

      write_file(file, "changed\n")

      assert.is_false(store:in_doubt(file, 3600))
    end)

    it("is a file that was not there when PreToolUse looked", function()
      local new = work .. "/new.txt"
      store:begin_edit("toolu_1", new, true, store_mod.stamp(new))

      write_file(new, "mine\n")

      assert.is_true(store:in_doubt(new, 3600))
    end)

    it("makes the base and note of an earlier edit go when the file changed since", function()
      store:snapshot(file)
      store:begin_edit("toolu_1", file, true, stamp)
      write_file(file, "changed\n")

      assert.is_true(store:forget_refused(file, store_mod.stamp(file)))

      assert.is_nil(store:get(file))
      assert.same({}, (store:editing(3600)))
    end)

    it("keeps the base of an earlier edit when the file is as that edit found it", function()
      store:snapshot(file)
      store:begin_edit("toolu_1", file, true, stamp)

      assert.is_false(store:forget_refused(file, store_mod.stamp(file)))

      assert.equal("x\n", store:get(file).text)
    end)

    it("keeps a base that an earlier edit did not make", function()
      store:snapshot(file)
      store:begin_edit("toolu_1", file, false, stamp)
      write_file(file, "changed\n")

      assert.is_false(store:forget_refused(file, store_mod.stamp(file)))

      assert.equal("x\n", store:get(file).text)
    end)
  end)

  it("rejects an edit id that would escape the state directory", function()
    assert.is_false(store:begin_edit("../evil", work .. "/a.txt"))
    assert.is_nil(read_file(dir .. "/evil.json"))
  end)

  it("rejects a tool_use_id that would escape the state directory", function()
    assert.is_false(store:save_bash("../evil", { stash = "abc" }))
    assert.is_nil(read_file(dir .. "/evil.json"))
  end)
end)
