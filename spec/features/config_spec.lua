--- Tests for the feature options: defaults, validation and the hint built from your keys.
local features = require("claudecode.features")

describe("feature options", function()
  local function config_error(user)
    local ok, err = pcall(features.config, user)
    assert.is_false(ok)
    return err
  end

  it("turns review and zen on by default", function()
    local config = features.config(nil)

    assert.is_true(config.review.enabled)
    assert.equal("cs", config.review.keymaps.keep)
    assert.equal("<leader>ak", config.review.files_keymap)
    assert.is_true(config.zen.enabled)
    assert.equal("<M-z>", config.zen.keymap)
  end)

  it("merges your keys over the defaults", function()
    local config = features.config({ review = { keymaps = { keep = "<leader>y", revert_all = false } } })

    assert.equal("<leader>y", config.review.keymaps.keep)
    assert.is_false(config.review.keymaps.revert_all)
    assert.equal("cx", config.review.keymaps.revert)
  end)

  it("starts every default key with one that waits for a second key anyway", function()
    -- `ko` made every `k` wait for 'timeoutlen' in a buffer under review, and `KO` did the same to
    -- `K`. Neovim waits after these prefixes in any case, so a mapping on them delays nothing.
    local prefixes = { "<leader>", "<localleader>", "]", "[", "g", "z" }
    -- After an operator only a key that is neither a motion nor a text object is free: `ca` would
    -- swallow `caw`, `cw` would swallow the change of a word.
    local motions = "aiwWbBeEfFtTgGhjklnNHMLvV"
    local function delays_nothing(lhs)
      for _, prefix in ipairs(prefixes) do
        if vim.startswith(lhs, prefix) then
          return true
        end
      end
      if lhs:match("^<[MACD]%-.>$") then
        return true
      end
      local operator, second = lhs:match("^([cdy])(%a)$")
      return operator ~= nil and second ~= operator and not motions:find(second, 1, true)
    end

    local config = features.config(nil)
    local keys = vim.tbl_values(config.review.keymaps)
    vim.list_extend(keys, {
      config.review.files_keymap,
      config.zen.keymap,
      config.review.notes.send_keymap,
      config.review.notes.list_keymap,
    })
    for _, lhs in ipairs(keys) do
      assert(delays_nothing(lhs), lhs .. " makes a key you press on its own wait")
    end
    assert.is_false(delays_nothing("ko"))
    assert.is_false(delays_nothing("ca"))
  end)

  it("names the wrong option in the error", function()
    assert.matches("review.enabled must be a boolean", config_error({ review = { enabled = "yes" } }))
    assert.matches("review.keymaps.keep must be a key", config_error({ review = { keymaps = { keep = 1 } } }))
    assert.matches("review.keymaps.oops is not a review key", config_error({ review = { keymaps = { oops = "x" } } }))
    assert.matches("review.picker must be", config_error({ review = { picker = "telescope" } }))
    assert.matches("zen.keymap must be", config_error({ zen = { keymap = "" } }))
  end)

  it("finds cswap on PATH unless you name it", function()
    assert.equal("cswap", features.config(nil).cswap.cmd)
    assert.equal("/opt/cswap", features.config({ cswap = { cmd = "/opt/cswap" } }).cswap.cmd)
    assert.matches("cswap.cmd must be a non%-empty string", config_error({ cswap = { cmd = "" } }))
  end)

  it("builds the hint from your keys", function()
    assert.equal("cs keep · cx revert", features.hint_text(features.config(nil).review))
    assert.equal(
      "gy keep",
      features.hint_text(features.config({ review = { keymaps = { keep = "gy", revert = false } } }).review)
    )
    assert.is_false(features.hint_text(features.config({ review = { hint = false } }).review))
    assert.equal("custom", features.hint_text(features.config({ review = { hint = "custom" } }).review))
  end)

  it("moves on to the next hunk after a decision, and lets ]k cross files, by default", function()
    local review = features.config(nil).review

    assert.equal("hunk", review.advance)
    assert.is_true(review.cross_files)
    assert.equal("file", features.config({ review = { advance = "file" } }).review.advance)
    assert.is_false(features.config({ review = { advance = false } }).review.advance)
    assert.matches("review.advance must be", config_error({ review = { advance = "files" } }))
    assert.matches("review.cross_files must be a boolean", config_error({ review = { cross_files = "yes" } }))
  end)

  it("lets you leave notes on Claude's changes and send them in one go, by default", function()
    local review = features.config(nil).review

    assert.equal("cr", review.keymaps.note)
    assert.equal("<leader>an", review.keymaps.note_range)
    assert.same(
      { enabled = true, send = "batch", advance = true, send_keymap = "cR", list_keymap = "<leader>an" },
      review.notes
    )
    assert.equal("enter", features.config({ review = { notes = { send = "enter" } } }).review.notes.send)
    assert.matches("review.notes.send must be", config_error({ review = { notes = { send = "now" } } }))
    assert.matches("review.notes.advance must be a boolean", config_error({ review = { notes = { advance = 1 } } }))
    assert.matches("review.notes.send_keymap must be", config_error({ review = { notes = { send_keymap = "" } } }))
    assert.matches("review.notes.list_keymap must be", config_error({ review = { notes = { list_keymap = 1 } } }))
    assert.matches("review.notes.enabled must be a boolean", config_error({ review = { notes = { enabled = "no" } } }))
  end)
end)
