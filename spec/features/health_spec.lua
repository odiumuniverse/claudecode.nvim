--- Smoke test for :checkhealth claudecode.features.
-- :checkhealth finds health modules on 'runtimepath', which the spec runner leaves alone.
local root = vim.fn.fnamemodify(package.searchpath("claudecode.features", package.path), ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)

describe(":checkhealth claudecode.features", function()
  local function run_health()
    vim.cmd("checkhealth claudecode.features")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.cmd("bwipeout!")
    return text
  end

  it("asks for setup before it has run", function()
    require("claudecode.features").state.config = nil

    assert.matches("setup%(%) has not run yet", run_health())
  end)

  it("reports the review and zen sections after setup", function()
    local features = require("claudecode.features")
    features.state.config = features.config({})

    local text = run_health()

    assert.matches("Hunk review", text)
    assert.matches("Zen", text)
    assert.is_nil(text:find("Failed to run healthcheck", 1, true))
  end)
end)
