--- Tests for the fork's options: defaults, validation and the hint built from your keys.
local fork = require("claudecode.fork")

describe("fork options", function()
  local function config_error(user)
    local ok, err = pcall(fork.config, user)
    assert.is_false(ok)
    return err
  end

  it("turns review and zen on by default", function()
    local config = fork.config(nil)

    assert.is_true(config.review.enabled)
    assert.equal("ko", config.review.keymaps.keep)
    assert.equal("<leader>ak", config.review.files_keymap)
    assert.is_true(config.zen.enabled)
    assert.equal("<M-z>", config.zen.keymap)
  end)

  it("merges your keys over the defaults", function()
    local config = fork.config({ review = { keymaps = { keep = "<leader>y", revert_all = false } } })

    assert.equal("<leader>y", config.review.keymaps.keep)
    assert.is_false(config.review.keymaps.revert_all)
    assert.equal("kx", config.review.keymaps.revert)
  end)

  it("names the wrong option in the error", function()
    assert.matches("review.enabled must be a boolean", config_error({ review = { enabled = "yes" } }))
    assert.matches("review.keymaps.keep must be a key", config_error({ review = { keymaps = { keep = 1 } } }))
    assert.matches("review.keymaps.oops is not a review key", config_error({ review = { keymaps = { oops = "x" } } }))
    assert.matches("review.picker must be", config_error({ review = { picker = "telescope" } }))
    assert.matches("zen.keymap must be", config_error({ zen = { keymap = "" } }))
  end)

  it("builds the hint from your keys", function()
    assert.equal("ko keep · kx revert", fork.hint_text(fork.config(nil).review))
    assert.equal(
      "gy keep",
      fork.hint_text(fork.config({ review = { keymaps = { keep = "gy", revert = false } } }).review)
    )
    assert.is_false(fork.hint_text(fork.config({ review = { hint = false } }).review))
    assert.equal("custom", fork.hint_text(fork.config({ review = { hint = "custom" } }).review))
  end)
end)
