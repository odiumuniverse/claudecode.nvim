--- Tests for what Neovim does with a hook's message: Claude's notifications here.
local bridge = require("claudecode.review.bridge")
local terminal = require("claudecode.terminal")

describe("hook bridge", function()
  local notify, active, shown, claude_buf

  before_each(function()
    notify, active, shown = vim.notify, terminal.get_active_terminal_bufnr, {}
    vim.notify = function(msg, level, opts)
      shown[#shown + 1] = { msg = msg, level = level, title = opts and opts.title }
    end
    claude_buf = vim.api.nvim_create_buf(false, true)
    terminal.get_active_terminal_bufnr = function()
      return claude_buf
    end
    bridge.enabled = true
  end)

  after_each(function()
    vim.notify, terminal.get_active_terminal_bufnr = notify, active
    bridge.enabled = false
    vim.cmd("silent! %bwipeout!")
  end)

  local function notification()
    bridge.on_hook({
      event = "Notification",
      message = "Claude is waiting for your input",
      title = "Claude Code",
      notification_type = "idle_prompt",
    })
    vim.wait(100, function()
      return #shown > 0
    end)
  end

  it("shows Claude's notification with vim.notify while you work in another window", function()
    notification()

    assert.same({ { msg = "Claude is waiting for your input", level = vim.log.levels.INFO, title = "Claude" } }, shown)
  end)

  it("keeps quiet while the cursor is in Claude's terminal", function()
    vim.api.nvim_set_current_buf(claude_buf)

    notification()

    assert.same({}, shown)
  end)
end)
