--- Tests for what the plugin reads about a git repository from its files, without running git.
local repo = require("claudecode.review.repo")

local function git(cwd, ...)
  local res = vim.system({ "git", "-C", cwd, ... }, { text = true, env = { GIT_CONFIG_GLOBAL = "/dev/null" } }):wait()
  assert(res.code == 0, res.stderr)
  return vim.trim(res.stdout)
end

local function write_file(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

describe("review repo", function()
  local root, main

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/main", "p")
    root = vim.uv.fs_realpath(root)
    main = root .. "/main"
    git(main, "init", "-q", "-b", "trunk")
    git(main, "config", "user.email", "t@example.com")
    git(main, "config", "user.name", "t")
    write_file(main .. "/a.txt", "a\n")
    git(main, "add", "a.txt")
    git(main, "commit", "-qm", "init")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("finds the work tree of a file, also of one that does not exist yet", function()
    assert.equal(main, repo.top_of(main .. "/a.txt"))
    assert.equal(main, repo.top_of(main .. "/not/yet/b.txt"))
    assert.is_nil(repo.top_of(root))
  end)

  it("reads HEAD and its branch, packed or loose, and a detached HEAD", function()
    local sha = git(main, "rev-parse", "HEAD")
    assert.same({ head = sha, branch = "trunk" }, repo.head(main))

    git(main, "pack-refs", "--all")
    assert.same({ head = sha, branch = "trunk" }, repo.head(main))

    git(main, "checkout", "-q", "--detach")
    assert.same({ head = sha }, repo.head(main))
  end)

  it("knows a repository without commits has no HEAD yet", function()
    vim.fn.mkdir(root .. "/empty", "p")
    git(root .. "/empty", "init", "-q")

    assert.is_nil(repo.head(root .. "/empty"))
  end)

  it("lists the other work trees and reads the HEAD of a linked one", function()
    git(main, "worktree", "add", "-q", root .. "/feat", "-b", "feat")
    git(main, "worktree", "add", "-q", main .. "/.claude/worktrees/x", "-b", "x")
    write_file(root .. "/feat/a.txt", "on feat\n")
    git(root .. "/feat", "commit", "-qam", "feat")

    assert.same({ root .. "/feat", main .. "/.claude/worktrees/x" }, repo.worktrees(main))
    assert.same({ main, main .. "/.claude/worktrees/x" }, repo.worktrees(root .. "/feat"))
    assert.same({ head = git(root .. "/feat", "rev-parse", "HEAD"), branch = "feat" }, repo.head(root .. "/feat"))
    assert.is_true(repo.is_linked(root .. "/feat"))
    assert.is_false(repo.is_linked(main))
  end)

  it("leaves out a worktree that is gone, and the work tree of a bare repository", function()
    git(root, "clone", "-q", "--bare", main, root .. "/container/.bare")
    write_file(root .. "/container/.git", "gitdir: ./.bare\n")
    git(root .. "/container", "worktree", "add", "-q", root .. "/container/trunk", "trunk")
    git(main, "worktree", "add", "-q", root .. "/gone", "-b", "gone")
    vim.fn.delete(root .. "/gone", "rf")

    assert.same({}, repo.worktrees(root .. "/container/trunk"))
    assert.same({}, repo.worktrees(main))
  end)
end)
