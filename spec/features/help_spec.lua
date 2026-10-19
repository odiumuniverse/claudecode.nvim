--- Tests for doc/claudecode.txt: it builds into help tags, the documented tags resolve,
--- and every option of `features.defaults` has its entry.
local features = require("claudecode.features")
local helpers = require("helpers")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local doc_file = root .. "/doc/claudecode.txt"

describe("help", function()
  local scratch = {} ---@type string[] runtime directories to remove again

  ---Copy the help file to a runtime directory of its own and run `:helptags` there. Specs run next to
  ---each other and `doc/tags` is not ours to write in the repository.
  ---@return string rtp_dir
  ---@return table<string, boolean> tags
  local function build()
    local dir = vim.fn.tempname()
    scratch[#scratch + 1] = dir
    vim.fn.mkdir(dir .. "/doc", "p")
    assert(vim.uv.fs_copyfile(doc_file, dir .. "/doc/claudecode.txt"))
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

    assert.is_true(tags["claudecode.txt"])
  end)

  it("answers :help for the sections, commands and topics", function()
    local dir, tags = build()
    vim.opt.runtimepath:prepend(dir)

    -- `:help` falls back to a tag that merely contains the word, so it also needs the exact tag.
    local failed = {}
    for _, tag in ipairs({
      "claudecode",
      "claudecode-review",
      "claudecode-review-keys",
      "claudecode-review-before-write",
      "claudecode-zen",
      "claudecode-options",
      "claudecode-events",
      "claudecode-highlights",
      "claudecode-diff-provider",
      "claudecode-health",
      ":ClaudeCodeReview",
      ":ClaudeCodeZen",
    }) do
      local ok = pcall(vim.cmd, "help " .. tag)
      if not tags[tag] or not ok or vim.bo.filetype ~= "help" then
        failed[#failed + 1] = tag
      end
      helpers.reset()
    end
    vim.opt.runtimepath:remove(dir)

    assert.same({}, failed)
  end)

  ---Every option of the defaults, tables included, as a dotted path: "review", "review.keymaps",
  ---"review.keymaps.keep", ... Sorted, so a failure reads the same on every run.
  ---@param tbl table
  ---@param prefix string
  ---@param out table<string, any> path → default value (a table for a table)
  ---@return table<string, any>
  local function option_paths(tbl, prefix, out)
    for key, value in pairs(tbl) do
      out[prefix .. key] = value
      if type(value) == "table" then
        option_paths(value, prefix .. key .. ".", out)
      end
    end
    return out
  end

  local function sorted_paths()
    local paths = vim.tbl_keys(option_paths(features.defaults, "", {}))
    table.sort(paths)
    return paths
  end

  it("has a tag for every option of the defaults", function()
    local _, tags = build()

    local missing = {}
    for _, path in ipairs(sorted_paths()) do
      if not tags["claudecode-" .. path] then
        missing[#missing + 1] = "claudecode-" .. path
      end
    end

    assert.same({}, missing)
  end)

  it("states the default of every option as the code has it", function()
    local lines = vim.fn.readfile(doc_file)
    local options = option_paths(features.defaults, "", {})

    local wrong = {}
    for _, path in ipairs(sorted_paths()) do
      local value = options[path]
      if type(value) ~= "table" then
        local expected = type(value) == "string" and ('"' .. value .. '"') or tostring(value)
        local documented

        -- The default sits under the option's tag, before the tag of the next entry.
        local found = false
        for _, line in ipairs(lines) do
          if found and line:find("%*claudecode%-[%w_.%-]+%*") then
            break
          end
          if line:find("*claudecode-" .. path .. "*", 1, true) then
            found = true
          elseif found then
            documented = documented or line:match("Default: `([^`]+)`")
          end
        end

        if documented ~= expected then
          wrong[#wrong + 1] = path .. ": the help says " .. tostring(documented) .. ", the code has " .. expected
        end
      end
    end

    assert.same({}, wrong)
  end)
end)
