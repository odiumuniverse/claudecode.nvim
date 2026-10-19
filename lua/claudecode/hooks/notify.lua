---@brief [[
--- Fire-and-forget message from a hook process to the running editor. A hook must never
--- wait for the editor: Neovim may sit at a hit-enter prompt and not answer RPC for minutes.
---@brief ]]
---@module 'claudecode.hooks.notify'

local uv = vim.uv or vim.loop

local M = {}

-- Runs inside the editor. pcall keeps an editor without the fork's modules quiet.
local RECEIVER = "local ok, bridge = pcall(require, 'claudecode.review.bridge') "
  .. "if ok and type(bridge.on_hook) == 'function' then bridge.on_hook(...) end"

M.TIMEOUT_MS = 500

---Send `payload` to `require("claudecode.review.bridge").on_hook` in the editor at `addr`.
---@param addr string|nil Server address: a socket path or host:port
---@param payload table
---@return boolean sent
function M.send(addr, payload)
  if not addr or addr == "" then
    return false
  end
  -- msgpack-rpc notification: [2, method, params]; Neovim runs it when its loop gets to it.
  local message = vim.mpack.encode({ 2, "nvim_exec_lua", { RECEIVER, { payload } } })

  local host, port = addr:match("^([^/]+):(%d+)$")
  local handle = host and uv.new_tcp() or uv.new_pipe(false)
  local done, sent = false, false

  local function finish(ok)
    sent = ok
    done = true
  end

  local function on_connect(err)
    if err then
      return finish(false)
    end
    handle:write(message, function(write_err)
      finish(not write_err)
    end)
  end

  local ok = pcall(function()
    if host then
      handle:connect(host, tonumber(port), on_connect)
    else
      handle:connect(addr, on_connect)
    end
  end)
  if not ok then
    finish(false)
  end

  vim.wait(M.TIMEOUT_MS, function()
    return done
  end, 5)
  if not handle:is_closing() then
    handle:close()
  end
  return sent
end

return M
