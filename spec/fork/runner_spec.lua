--- Tests for fork/test-nvim.sh: its exit status and message tell a failing run from a cut-off one.
local root = vim.fn.fnamemodify(package.searchpath("claudecode.features", package.path), ":p:h:h:h:h")

describe("fork/test-nvim.sh", function()
  local dir

  local function run(body)
    local spec = dir .. "/sample_spec.lua"
    vim.fn.writefile({ 'describe("sample", function() it("runs", function() ' .. body .. " end) end)" }, spec)
    return vim.system({ root .. "/fork/test-nvim.sh", spec }, { text = true }):wait()
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("exits 0 when every spec passes", function()
    assert.equal(0, run("assert.equal(1, 1)").code)
  end)

  it("exits 1 on a failing spec without claiming that Neovim quit early", function()
    local res = run("assert.equal(1, 2)")

    assert.equal(1, res.code)
    assert.is_nil(res.stderr:find("quit before busted finished", 1, true))
  end)

  it("exits 2 and says so when Neovim quits in the middle of the run", function()
    local res = run('vim.cmd("qa!")')

    assert.equal(2, res.code)
    assert.matches("quit before busted finished", res.stderr)
  end)
end)
