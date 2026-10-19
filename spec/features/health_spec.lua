--- Smoke test for :checkhealth claudecode: our sections join upstream's report.
-- :checkhealth finds health modules on 'runtimepath', which the spec runner leaves alone.
local root = vim.fn.fnamemodify(package.searchpath("claudecode.features", package.path), ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)

describe(":checkhealth claudecode", function()
  local plugin = require("claudecode")
  local features = require("claudecode.features")
  local saved

  local function run_health(plugin_name)
    vim.cmd("checkhealth " .. (plugin_name or "claudecode"))
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.cmd("bwipeout!")
    return text
  end

  before_each(function()
    -- Upstream's report stops early without setup(); pretend it ran, with the default options.
    saved = { initialized = plugin.state.initialized, config = plugin.state.config, features = features.state.config }
    plugin.state.initialized = true
    plugin.state.config = require("claudecode.config").defaults
  end)

  after_each(function()
    plugin.state.initialized = saved.initialized
    plugin.state.config = saved.config
    features.state.config = saved.features
  end)

  it("reports the review and zen sections after setup", function()
    features.state.config = features.config({})

    local text = run_health()

    assert.matches("claudecode.nvim", text)
    assert.matches("Hunk review", text)
    assert.matches("Zen", text)
    assert.is_nil(text:find("Failed to run healthcheck", 1, true))
  end)

  it("asks for setup when the features did not start", function()
    features.state.config = nil

    assert.matches("setup%(%) has not run yet", run_health())
  end)

  it("leaves no health check of its own for the features", function()
    assert.matches("No healthcheck found", run_health("claudecode.features"))
  end)

  describe("on a Neovim older than 0.11", function()
    local original_has, original_health, reports

    before_each(function()
      reports = {}
      original_has, original_health = vim.fn.has, vim.health
      vim.fn.has = function(feature)
        return feature == "nvim-0.11" and 0 or original_has(feature)
      end
      vim.health = setmetatable({}, {
        __index = function(_, level)
          return function(msg)
            reports[#reports + 1] = level .. ": " .. msg
          end
        end,
      })
    end)

    after_each(function()
      vim.fn.has, vim.health = original_has, original_health
    end)

    it("warns that review and zen are off and stops there", function()
      features.state.config = nil

      require("claudecode.features.checks").check()

      assert.same({
        "start: Neovim for review and zen",
        "warn: Hunk review and zen need Neovim 0.11 or newer; the plugin falls back to upstream behavior",
      }, reports)
    end)
  end)
end)
