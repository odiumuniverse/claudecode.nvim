--- Tests for the git snapshots taken around a Bash call.
local git = require("claudecode.hooks.git")

local function write_file(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function sh(cwd, cmd)
  local res = vim.system({ "sh", "-c", cmd }, { cwd = cwd, text = true }):wait()
  assert(res.code == 0, res.stderr)
  return res.stdout
end

describe("hook git snapshots", function()
  local work

  before_each(function()
    work = vim.fn.tempname()
    vim.fn.mkdir(work, "p")
    work = vim.uv.fs_realpath(work)
    sh(work, "git init -q && git config user.email t@example.com && git config user.name t")
    write_file(work .. "/f.txt", "one\n")
    write_file(work .. "/g.txt", "keep\n")
    sh(work, "git add -A && git commit -qm init")
  end)

  after_each(function()
    vim.fn.delete(work, "rf")
  end)

  it("reports nothing for a Bash call that changed nothing, whatever you have in the work tree", function()
    write_file(work .. "/f.txt", "one, and my work in progress\n")

    local snap = git.snapshot(work)
    local changes = snap and git.changes(snap)

    assert.is_not_nil(snap)
    assert.same({}, changes.tracked)
  end)

  it("takes no snapshot, instead of a wrong one, when git cannot take it", function()
    write_file(work .. "/f.txt", "one, and my work in progress\n")
    -- another git process (a parallel hook, your commit) holds the index
    write_file(work .. "/.git/index.lock", "")

    local snap = git.snapshot(work)
    vim.uv.fs_unlink(work .. "/.git/index.lock")

    -- A snapshot of HEAD would make all of your uncommitted work look like Claude's change.
    assert.is_nil(snap)
  end)

  it("still snapshots a repository without commits", function()
    local fresh = vim.fn.tempname()
    vim.fn.mkdir(fresh, "p")
    fresh = vim.uv.fs_realpath(fresh)
    sh(fresh, "git init -q")
    write_file(fresh .. "/new.txt", "x\n")

    local snap = git.snapshot(fresh)
    vim.fn.delete(fresh, "rf")

    assert.is_not_nil(snap)
  end)
end)
