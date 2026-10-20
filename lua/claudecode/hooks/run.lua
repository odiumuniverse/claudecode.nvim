--- Entry point for Claude Code hooks: `nvim --clean --headless -l run.lua <HookEvent>`.
--- Claude Code pipes the hook input JSON to stdin. The script never fails the tool call:
--- every error ends in exit code 0, at worst the review misses one edit.

local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h:h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local event = arg[1]
local dir = os.getenv("CLAUDECODE_REVIEW_DIR")

-- Only sessions started from Neovim carry the state directory.
if not dir or dir == "" then
  return
end

local ok, err = pcall(function()
  local input = vim.json.decode(io.read("*a"))
  local output = require("claudecode.hooks.handlers").handle(event, input, {
    dir = dir,
    nvim = os.getenv("CLAUDECODE_NVIM") or os.getenv("NVIM"),
    before_write = os.getenv("CLAUDECODE_REVIEW_BEFORE_WRITE") == "1",
    -- Claude Code sets it for every hook: the folder Claude was started in.
    project = os.getenv("CLAUDE_PROJECT_DIR"),
  })
  if output then
    io.write(vim.json.encode(output))
  end
end)

if not ok then
  pcall(require("claudecode.hooks.handlers").log, dir, event, err)
end
