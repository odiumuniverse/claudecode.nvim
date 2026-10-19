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

require("busted.runner")({ standalone = false })
