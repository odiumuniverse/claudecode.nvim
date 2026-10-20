--- Tests for what each hook does with the files Claude touches.
local handlers = require("claudecode.hooks.handlers")
local store_mod = require("claudecode.review.store")

local function write_file(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

describe("hook handlers", function()
  local work, dir, store

  local function edit_input(file, id)
    return { tool_name = "Write", tool_use_id = id or "toolu_1", cwd = work, tool_input = { file_path = file } }
  end

  -- Paths the hook opened while `action` ran.
  local function opened_during(action)
    local opened = {}
    local fs_open = vim.uv.fs_open
    vim.uv.fs_open = function(path, ...)
      opened[#opened + 1] = path
      return fs_open(path, ...)
    end
    local ok, err = pcall(action)
    vim.uv.fs_open = fs_open
    assert(ok, tostring(err))
    return opened
  end

  before_each(function()
    work = vim.fn.tempname()
    vim.fn.mkdir(work, "p")
    work = vim.uv.fs_realpath(work)
    dir = vim.fn.tempname()
    store = store_mod.new(dir)
  end)

  after_each(function()
    vim.fn.delete(work, "rf")
    vim.fn.delete(dir, "rf")
  end)

  it("passes Claude's notification on to Neovim and answers nothing", function()
    local notify = require("claudecode.hooks.notify")
    local send, got = notify.send, {}
    notify.send = function(addr, payload)
      got[#got + 1] = { addr, payload }
      return true
    end
    local input = {
      hook_event_name = "Notification",
      session_id = "s1",
      message = "Claude needs your permission to use Bash",
      title = "Claude Code",
      notification_type = "permission_prompt",
    }

    local ok, output = pcall(handlers.handle, "Notification", input, { dir = dir, nvim = "/tmp/nvim.sock" })
    notify.send = send

    assert(ok, tostring(output))
    assert.is_nil(output)
    assert.same({
      {
        "/tmp/nvim.sock",
        {
          event = "Notification",
          message = "Claude needs your permission to use Bash",
          title = "Claude Code",
          notification_type = "permission_prompt",
        },
      },
    }, got)
  end)

  describe("a file bigger than MAX_BYTES", function()
    local max

    before_each(function()
      max = handlers.MAX_BYTES
      handlers.MAX_BYTES = 100
    end)

    after_each(function()
      handlers.MAX_BYTES = max
    end)

    it("is not read before an edit, and gets no base", function()
      local file = work .. "/big.txt"
      write_file(file, string.rep("x", 1000))

      local opened = opened_during(function()
        handlers.handle("PreToolUse", edit_input(file), { dir = dir })
      end)

      assert.same(
        {},
        vim.tbl_filter(function(path)
          return path == file
        end, opened)
      )
      assert.is_nil(store:get(file))
    end)

    it("is not read after an edit either, and the base of an empty file stays", function()
      local file = work .. "/grows.txt"
      write_file(file, "")
      handlers.handle("PreToolUse", edit_input(file), { dir = dir })
      write_file(file, string.rep("x", 1000))

      local opened = opened_during(function()
        handlers.handle("PostToolUse", edit_input(file), { dir = dir })
      end)

      assert.same(
        {},
        vim.tbl_filter(function(path)
          return path == file
        end, opened)
      )
      assert.equal("", store:get(file).text)
    end)
  end)
end)
