---@brief [[
--- Entry point of the hunk review (after and before Claude writes) and zen features.
--- `require("claudecode").setup(opts)` calls `setup(opts)` with the same options table.
---@brief ]]
---@module 'claudecode.features'

local M = {}

---@class ClaudeCodeReviewKeymaps
---@field keep string|false
---@field revert string|false
---@field keep_all string|false
---@field revert_all string|false
---@field next string|false
---@field prev string|false
---@field last string|false
---@field first string|false
---@field note string|false       Note on the line under the cursor
---@field note_range string|false Note on the selected lines (visual mode)

---@class ClaudeCodeReviewNotesConfig
---@field enabled boolean
---@field send "batch"|"enter" "batch": Enter saves, Shift+Enter sends every note; "enter": Enter sends at once
---@field advance boolean A note counts as a decision: the cursor moves on as after `cs`
---@field send_keymap string|false Global key that sends every note to Claude

---@class ClaudeCodeReviewConfig
---@field enabled boolean
---@field notes ClaudeCodeReviewNotesConfig
---@field keymaps ClaudeCodeReviewKeymaps Buffer-local keys while a file is under review
---@field files_keymap string|false Opens the list of files waiting for review
---@field advance "hunk"|"file"|false After keep or revert: the next hunk, then the next file, or stay
---@field cross_files boolean `]k` past the last hunk and `[k` before the first go to the next or previous file
---@field hint boolean|string Hint at the hunk under the cursor; true builds it from the keymaps
---@field word_diff boolean Highlight changed words inside changed lines
---@field before_write boolean Review Claude's proposals before they are written (Manual mode)
---@field picker "auto"|"snacks"|"fzf"|"select"

---@class ClaudeCodeFeaturesConfig
---@field review ClaudeCodeReviewConfig
---@field zen { enabled: boolean, keymap: string|false }
---@field cswap { cmd: string } `:ClaudeCode run [account]` runs Claude through this cswap

---@type ClaudeCodeFeaturesConfig
M.defaults = {
  review = {
    enabled = true,
    keymaps = {
      -- After `c` Neovim waits for a motion anyway, and s, x, S, X are none: no key you press on
      -- its own waits for these (`ko` once made every `k` wait for 'timeoutlen').
      keep = "cs",
      revert = "cx",
      keep_all = "cS",
      revert_all = "cX",
      next = "]k",
      prev = "[k",
      last = "]K",
      first = "[K",
      -- r is no motion either; in visual mode `c` acts at once, so a range note goes on the leader.
      note = "cr",
      note_range = "<leader>an",
    },
    notes = {
      enabled = true,
      send = "batch",
      advance = true,
      send_keymap = "cR",
    },
    files_keymap = "<leader>ak",
    advance = "hunk",
    cross_files = true,
    hint = true,
    word_diff = true,
    before_write = true,
    picker = "auto",
  },
  zen = {
    enabled = true,
    keymap = "<M-z>",
  },
  cswap = {
    cmd = "cswap",
  },
}

local function check(cond, msg)
  if not cond then
    error("claudecode: " .. msg, 0)
  end
end

local function is_key(v)
  return v == false or (type(v) == "string" and v ~= "")
end

---@param config ClaudeCodeFeaturesConfig
function M.validate(config)
  local review, zen = config.review, config.zen
  check(type(review) == "table", "review must be a table")
  check(type(review.enabled) == "boolean", "review.enabled must be a boolean")
  check(type(review.keymaps) == "table", "review.keymaps must be a table")
  for name, key in pairs(review.keymaps) do
    check(M.defaults.review.keymaps[name] ~= nil, "review.keymaps." .. tostring(name) .. " is not a review key")
    check(is_key(key), "review.keymaps." .. name .. " must be a key string or false")
  end
  check(is_key(review.files_keymap), "review.files_keymap must be a key string or false")
  check(
    review.advance == "hunk" or review.advance == "file" or review.advance == false,
    "review.advance must be 'hunk', 'file' or false"
  )
  check(type(review.cross_files) == "boolean", "review.cross_files must be a boolean")
  local notes = review.notes
  check(type(notes) == "table", "review.notes must be a table")
  check(type(notes.enabled) == "boolean", "review.notes.enabled must be a boolean")
  check(notes.send == "batch" or notes.send == "enter", "review.notes.send must be 'batch' or 'enter'")
  check(type(notes.advance) == "boolean", "review.notes.advance must be a boolean")
  check(is_key(notes.send_keymap), "review.notes.send_keymap must be a key string or false")
  check(type(review.hint) == "boolean" or type(review.hint) == "string", "review.hint must be a boolean or a string")
  check(type(review.word_diff) == "boolean", "review.word_diff must be a boolean")
  check(type(review.before_write) == "boolean", "review.before_write must be a boolean")
  check(
    vim.tbl_contains({ "auto", "snacks", "fzf", "select" }, review.picker),
    "review.picker must be 'auto', 'snacks', 'fzf' or 'select'"
  )
  check(type(zen) == "table", "zen must be a table")
  check(type(zen.enabled) == "boolean", "zen.enabled must be a boolean")
  check(is_key(zen.keymap), "zen.keymap must be a key string or false")
  check(type(config.cswap) == "table", "cswap must be a table")
  check(type(config.cswap.cmd) == "string" and config.cswap.cmd ~= "", "cswap.cmd must be a non-empty string")
end

---@param user table|nil The options passed to require("claudecode").setup
---@return ClaudeCodeFeaturesConfig
function M.config(user)
  user = user or {}
  local config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), {
    review = user.review or {},
    zen = user.zen or {},
    cswap = user.cswap or {},
  })
  M.validate(config)
  return config
end

---The hint follows your keys: "cs keep · cx revert" with the defaults.
---@param review ClaudeCodeReviewConfig
---@return string|false
function M.hint_text(review)
  if review.hint ~= true then
    return review.hint
  end
  local parts = {}
  if review.keymaps.keep then
    parts[#parts + 1] = review.keymaps.keep .. " keep"
  end
  if review.keymaps.revert then
    parts[#parts + 1] = review.keymaps.revert .. " revert"
  end
  return #parts > 0 and table.concat(parts, " · ") or false
end

M.state = { config = nil } ---@type { config: ClaudeCodeFeaturesConfig|nil }

---@param user table|nil The options passed to require("claudecode").setup
---@param plugin_config table|nil The plugin's applied config; its diff_opts gets the review provider
function M.setup(user, plugin_config)
  -- The features need vim.text.diff and the 0.11 vim.validate; older editors keep upstream behavior.
  -- Checked first: upstream's unit tests run setup against a minimal vim mock.
  if not (vim.text and vim.text.diff and vim.api.nvim_buf_attach) or vim.fn.has("nvim-0.11") ~= 1 then
    return
  end
  local config = M.config(user)
  M.state.config = config

  if config.review.enabled then
    local notes = config.review.notes
    local notes_mod = require("claudecode.review.notes")
    notes_mod.setup(notes.enabled and {
      send = notes.send,
      advance = notes.advance,
      send_keymap = notes.send_keymap,
    } or {})
    require("claudecode.review").setup({
      keymaps = config.review.keymaps,
      advance = config.review.advance,
      cross_files = config.review.cross_files,
      goto_file = require("claudecode.review.controller").goto_file,
      note = notes.enabled and notes_mod.open or nil,
      noted = notes.enabled and notes.advance and notes_mod.noted or nil,
      hint = M.hint_text(config.review),
      word_diff = config.review.word_diff,
    })
    -- Your own diff_opts.provider shows proposals too, so manual mode asks for it as well.
    local own_provider = plugin_config and plugin_config.diff_opts and plugin_config.diff_opts.provider ~= nil
    require("claudecode.hooks").setup({ before_write = config.review.before_write or own_provider })
    require("claudecode.review.controller").setup()
    require("claudecode.review.bridge").enabled = true
    -- Your own diff_opts.provider wins over ours.
    local diff_opts = plugin_config and plugin_config.diff_opts
    if config.review.before_write and diff_opts and diff_opts.provider == nil then
      diff_opts.provider = require("claudecode.review.provider")
    end

    local function show()
      require("claudecode.review.picker").show(config.review.picker)
    end
    pcall(vim.api.nvim_del_user_command, "ClaudeCodeReview")
    vim.api.nvim_create_user_command("ClaudeCodeReview", show, { desc = "Claude: files waiting for review" })
    if config.review.files_keymap then
      vim.keymap.set("n", config.review.files_keymap, show, { desc = "Claude: files waiting for review" })
    end
  else
    require("claudecode.hooks").disable()
    require("claudecode.review.bridge").enabled = false
  end

  require("claudecode.features.cswap").setup(config.cswap)

  if config.zen.enabled then
    require("claudecode.zen").setup({
      keymap = config.zen.keymap,
      files_key = config.review.enabled and config.review.files_keymap or nil,
    })
  end
end

return M
