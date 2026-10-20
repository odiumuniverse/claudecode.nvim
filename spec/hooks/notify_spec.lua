--- Tests for the message a hook sends the editor. A fake editor listens in this process:
--- vim.wait inside notify.send runs the same loop, so the server answers while the hook waits.
local notify = require("claudecode.hooks.notify")

describe("hook message to the editor", function()
  local server, addr, got, hung_up, client_closed_early

  ---Listen on a fresh socket. `reply_after_ms` nil means the editor never answers.
  local function listen(reply_after_ms)
    addr = vim.fn.tempname()
    got, hung_up, client_closed_early = nil, false, false
    server = assert(vim.uv.new_pipe(false))
    assert(server:bind(addr))
    server:listen(8, function()
      local conn = assert(vim.uv.new_pipe(false))
      server:accept(conn)
      local replied = false
      conn:read_start(function(err, data)
        if err or not data then
          client_closed_early = not replied
          hung_up = true
          conn:close()
          return
        end
        got = vim.mpack.decode(data)
        local id = got[2]
        if reply_after_ms then
          vim.defer_fn(function()
            replied = true
            if not conn:is_closing() then
              conn:write(vim.mpack.encode({ 1, id, vim.NIL, vim.NIL }))
            end
          end, reply_after_ms)
        end
      end)
    end)
  end

  ---Let the fake editor see the end of the connection.
  local function settle()
    vim.wait(1000, function()
      return hung_up
    end, 5)
  end

  after_each(function()
    if server and not server:is_closing() then
      server:close()
    end
    vim.fn.delete(addr)
  end)

  it("asks the editor to run the bridge with the payload", function()
    listen(0)

    assert.is_true(notify.send(addr, { event = "PostToolUse", files = { "/a.txt" } }))
    settle()

    assert.equal(0, got[1]) -- a request: the editor answers once the message has run
    assert.equal("nvim_exec_lua", got[3])
    assert.matches("claudecode.review.bridge", got[4][1])
    assert.same({ { event = "PostToolUse", files = { "/a.txt" } } }, got[4][2])
  end)

  -- A busy Neovim (a Claude TUI redrawing its terminal) drops a message whose client has hung up
  -- before Neovim got to it: 39 of 40 in a live test on 0.12.3.
  it("keeps the connection open until the editor answers", function()
    listen(150)

    assert.is_true(notify.send(addr, { event = "PostToolUse" }))
    settle()

    assert.is_true(hung_up)
    assert.is_false(client_closed_early)
  end)

  it("gives up when the editor does not answer in time, so Claude never waits on it", function()
    listen(nil)
    local start = vim.uv.hrtime()

    assert.is_false(notify.send(addr, { event = "PostToolUse" }))

    local took = (vim.uv.hrtime() - start) / 1e6
    assert.is_true(took >= notify.TIMEOUT_MS - 50 and took < notify.TIMEOUT_MS + 500, tostring(took))
  end)
end)
