--- Tests for answering Claude Code's permission dialog with "No, and tell Claude what to do differently".
--- The screens are the bottom rows of a real Claude Code 2.1.304 terminal.
local dialog = require("claudecode.review.dialog")

local YES_AND_SWITCH =
  "   2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this session (shift+tab)"

local function screen(options, footer)
  local rows = {
    "⏺ Update(/tmp/proj/a.py)",
    " Opened changes in Neovim ⧉",
    " a.py",
    " Do you want to make this edit to a.py?",
  }
  vim.list_extend(rows, options)
  rows[#rows + 1] = footer or " Esc to cancel · Tab to amend"
  return rows
end

describe("Claude's permission dialog", function()
  it("goes down from Yes towards No", function()
    assert.equal("down", dialog.next_step(screen({ " ❯ 1. Yes", YES_AND_SWITCH, "   3. No" })))
  end)

  it("turns No into 'No, and tell Claude' with Tab", function()
    assert.equal("tab", dialog.next_step(screen({ "   1. Yes", YES_AND_SWITCH, " ❯ 3. No" })))
  end)

  it("types the reason once 'No, and tell Claude what to do differently' is chosen", function()
    local rows =
      screen({ "   1. Yes", YES_AND_SWITCH, " ❯ 3. No, and tell Claude what to do differently" }, " Esc to cancel")

    assert.equal("type", dialog.next_step(rows))
  end)

  it("backs off from 'Yes, and tell Claude what to do next': that applies the edit", function()
    local rows =
      screen({ " ❯ 1. Yes, and tell Claude what to do next", YES_AND_SWITCH, "   3. No" }, " Esc to cancel")

    assert.is_nil(dialog.next_step(rows))
  end)

  it("backs off when no dialog is on screen", function()
    assert.is_nil(dialog.next_step({
      "⏺ pong",
      "────────────────",
      "❯ [⧉ In a.py]",
      "────────────────",
      "  ⏸ manual mode on",
    }))
  end)

  it("backs off from a dialog without a No", function()
    assert.is_nil(dialog.next_step(screen({ " ❯ 1. Yes", "   2. Yes, always" })))
  end)

  it("sees the reason in the dialog even when a narrow terminal wraps it", function()
    local rows = screen({
      "   1. Yes",
      " ❯ 3. No, and tell Claude what to do differently",
      "   make it 7, shipping is",
      "   cheaper now",
    }, " Esc to cancel")

    assert.is_true(dialog.shows(rows, "make it 7, shipping is cheaper now"))
    assert.is_false(dialog.shows(rows, "make it 8, shipping is cheaper now"))
  end)
end)
