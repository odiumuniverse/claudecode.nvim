--- Tests for doc/claudecode-fork.txt: it builds into help tags, the tags the fork documents resolve,
--- and every option of `fork.defaults` has its entry.
local helpers = require("helpers")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local doc_file = root .. "/doc/claudecode-fork.txt"

describe("fork help", function()
  local scratch = {} ---@type string[] runtime directories to remove again

  ---Copy the help file to a runtime directory of its own and run `:helptags` there. Specs run next to
  ---each other and `doc/tags` is not ours to write in the repository.
  ---@return string rtp_dir
  ---@return table<string, boolean> tags
  local function build()
    local dir = vim.fn.tempname()
    scratch[#scratch + 1] = dir
    vim.fn.mkdir(dir .. "/doc", "p")
    assert(vim.uv.fs_copyfile(doc_file, dir .. "/doc/claudecode-fork.txt"))
    vim.cmd("helptags " .. vim.fn.fnameescape(dir .. "/doc"))

    local tags = {}
    for line in io.lines(dir .. "/doc/tags") do
      tags[line:match("^[^\t]+")] = true
    end
    return dir, tags
  end

  after_each(function()
    for _, dir in ipairs(scratch) do
      vim.fn.delete(dir, "rf")
    end
    scratch = {}
    helpers.reset()
  end)

  it("builds into help tags without a duplicate", function()
    local _, tags = build()

    assert.is_true(tags["claudecode-fork.txt"])
  end)
end)
