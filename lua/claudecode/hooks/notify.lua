---@brief [[
--- Message from a hook process to the running editor. A hook must not wait for the editor for
--- long: Neovim may sit at a hit-enter prompt and not answer RPC for minutes. It cannot hang up
--- at once either: a busy Neovim (a Claude TUI redrawing its terminal) drops what a client sent
--- if the client is gone before Neovim got to it. So the hook asks, and waits for the answer up
--- to TIMEOUT_MS.
---@brief ]]
---@module 'claudecode.hooks.notify'

local uv = vim.uv or vim.loop

local M = {}

-- Runs inside the editor. pcall keeps an editor without the review modules quiet.
local RECEIVER = "local ok, bridge = pcall(require, 'claudecode.review.bridge') "
  .. "if ok and type(bridge.on_hook) == 'function' then bridge.on_hook(...) end"

M.TIMEOUT_MS = 500

---Send `payload` to `require("claudecode.review.bridge").on_hook` in the editor at `addr`.
---@param addr string|nil Server address: a socket path or host:port
---@param payload table
---@return boolean delivered The editor answered: the bridge has the payload
function M.send(addr, payload)
  if not addr or addr == "" then
    return false
  end
  -- msgpack-rpc request: [0, msgid, method, params]. Neovim answers once it has run the code, and
  -- the bridge only schedules its work, so the answer comes at once.
  local message = vim.mpack.encode({ 0, 1, "nvim_exec_lua", { RECEIVER, { payload } } })

  local host, port = addr:match("^([^/]+):(%d+)$")
  local done, sent = false, false
  local handles = {}

  -- The first outcome counts: the answer and the end of the connection may come together.
  local function finish(ok)
    if not done then
      sent = ok
      done = true
    end
  end

  ---One try on a handle of its own. `connect(handle, on_connect)` starts it; `on_failure` runs when
  ---the connection cannot be made.
  local function attempt(connect, on_failure)
    local handle = host and uv.new_tcp() or uv.new_pipe(false)
    handles[#handles + 1] = handle
    local function on_connect(err)
      if err then
        return on_failure()
      end
      -- Nothing else comes over this connection: any bytes are the answer.
      handle:read_start(function(read_err, data)
        finish(not read_err and data ~= nil)
      end)
      handle:write(message, function(write_err)
        if write_err then
          finish(false)
        end
      end)
    end
    local ok, started = pcall(connect, handle, on_connect)
    if not ok or not started then
      on_failure()
    end
  end

  if not host then
    attempt(function(handle, on_connect)
      return handle:connect(addr, on_connect)
    end, function()
      finish(false)
    end)
  else
    -- libuv connects to an address, not to a name: `nvim --listen localhost:6666` needs the name
    -- resolved, and `[::1]:6666` its brackets taken off. Every address is tried until one answers.
    local function try(ips, i)
      if done then
        return
      end
      if i > #ips then
        return finish(false)
      end
      attempt(function(handle, on_connect)
        return handle:connect(ips[i], tonumber(port), on_connect)
      end, function()
        try(ips, i + 1)
      end)
    end
    local resolving = uv.getaddrinfo(host:gsub("^%[(.*)%]$", "%1"), nil, { socktype = "stream" }, function(err, found)
      local ips = {}
      for _, entry in ipairs(not err and found or {}) do
        ips[#ips + 1] = entry.addr
      end
      try(ips, 1)
    end)
    if not resolving then
      finish(false)
    end
  end

  vim.wait(M.TIMEOUT_MS, function()
    return done
  end, 5)
  for _, handle in ipairs(handles) do
    if not handle:is_closing() then
      handle:close()
    end
  end
  return sent
end

return M
