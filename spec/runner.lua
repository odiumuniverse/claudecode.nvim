-- Busted runner inside headless Neovim: `nvim --headless --clean -l spec/runner.lua [busted args]`.
-- The specs need the real editor (vim.text.diff, extmarks, nvim_buf_attach), which the
-- LuaJIT-with-mock-vim suite behind `mise run test` cannot provide.

local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")

local rocks = root .. "/.luarocks"
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/spec/?.lua",
  rocks .. "/share/lua/5.1/?.lua",
  rocks .. "/share/lua/5.1/?/init.lua",
  package.path,
}, ";")
package.cpath = rocks .. "/lib/lua/5.1/?.so;" .. package.cpath

-- Neovim quits with status 0 when a y/n prompt has no terminal to answer it, which would pass a
-- run that was cut off. fork/test-nvim.sh hands over a path; the file exists only once busted is done.
local function mark_done()
  local path = vim.env.CLAUDECODE_SPEC_DONE
  if path and path ~= "" then
    io.open(path, "w"):close()
  end
end

-- Busted may end the run with os.exit itself (failed specs); the run is complete then too.
local exit = os.exit
os.exit = function(...) -- luacheck: ignore 122
  mark_done()
  return exit(...)
end

-- On LuaJIT busted reports failed specs by throwing an empty error(); turn that into exit status 1.
local ok, err = pcall(require("busted.runner"), { standalone = false })
mark_done()
if not ok then
  if err ~= nil then
    io.stderr:write(tostring(err) .. "\n")
  end
  os.exit(1)
end
