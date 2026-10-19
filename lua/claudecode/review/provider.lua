---@brief [[
--- Review before write (Manual mode): Claude's proposal opens in place of the file, drawn by
--- the same engine as review after write. When no hunk is left, the kept text goes to Claude;
--- if you reverted every hunk, Claude gets a rejection. `:w` accepts what is left as is.
---@brief ]]
---@module 'claudecode.review.provider'

local engine = require("claudecode.review")
local store_mod = require("claudecode.review.store")
local text = require("claudecode.review.text")

local M = {}

---@class ClaudeCodeProposal
---@field ctx ClaudeCodeDiffContext
---@field path string
---@field buf integer
---@field win integer
---@field prev_buf integer|nil
---@field view table|nil
---@field winbar string
---@field base_text string
---@field base_lines string[]
---@field eol boolean
---@field dos boolean
---@field proposed_lines string[]
---@field reverts ClaudeCodeRevertRecord[]
---@field from_zen boolean
---@field done boolean

local sessions = {} ---@type table<string, ClaudeCodeProposal>

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function editor_window()
  local find = require("claudecode.diff")._find_main_editor_window
  local win = find and find()
  if win and vim.api.nvim_win_is_valid(win) then
    return win
  end
  -- Only Claude is on screen: give the proposal a window left of it.
  vim.cmd("topleft vsplit")
  return vim.api.nvim_get_current_win()
end

local function restore(session)
  if engine.is_attached(session.buf) then
    engine.detach(session.buf)
  end
  -- Its text already went to Claude (or was refused): nothing in it is left to save.
  if vim.api.nvim_buf_is_valid(session.buf) then
    vim.bo[session.buf].modified = false
  end
  if vim.api.nvim_win_is_valid(session.win) and vim.api.nvim_win_get_buf(session.win) == session.buf then
    if session.prev_buf and vim.api.nvim_buf_is_valid(session.prev_buf) then
      vim.api.nvim_win_set_buf(session.win, session.prev_buf)
      if session.view then
        vim.api.nvim_win_call(session.win, function()
          vim.fn.winrestview(session.view)
        end)
      end
    else
      vim.api.nvim_win_call(session.win, function()
        vim.cmd("enew")
      end)
    end
    vim.wo[session.win].winbar = session.winbar
  end
  if vim.api.nvim_buf_is_valid(session.buf) then
    pcall(vim.api.nvim_buf_delete, session.buf, { force = true })
  end
  if session.from_zen and next(sessions) == nil then
    local zen = package.loaded["claudecode.zen"]
    if zen then
      vim.schedule(function()
        zen.enter()
      end)
    end
  end
end

---The text you settled on becomes the base: review after write must not show it again (DESIGN p. 10).
---A base from an earlier, still unreviewed edit stays: those hunks have not been reviewed yet.
local function mark_reviewed(session, content)
  local store = require("claudecode.review.controller").store()
  if not store then
    return
  end
  local base = store:get(session.path)
  if base and base.text == session.base_text then
    store:set(session.path, content)
  end
end

---@param lines string[]
---@return boolean
local function is_blank_line(lines)
  return #lines == 1 and lines[1] == ""
end

local function finish(session)
  if session.done then
    return
  end
  session.done = true
  sessions[session.ctx.tab_name] = nil

  local lines = vim.api.nvim_buf_get_lines(session.buf, 0, -1, false)
  -- A buffer cannot tell an empty file from one empty line. Take it for an empty file unless that
  -- single empty line is what the file or Claude's proposal really holds.
  if
    #lines == 1
    and lines[1] == ""
    and not is_blank_line(session.base_lines)
    and not is_blank_line(session.proposed_lines)
  then
    lines = {}
  end
  if vim.deep_equal(lines, session.base_lines) then
    session.ctx.reject()
  else
    local content = text.to_text(lines, session.eol, session.dos)
    mark_reviewed(session, content)
    local store = require("claudecode.review.controller").store()
    if store then
      for _, rec in ipairs(session.reverts) do
        store:append_revert(rec)
      end
    end
    session.ctx.accept(content)
  end
  restore(session)
end

---@param ctx ClaudeCodeDiffContext
function M.open(ctx)
  local zen = package.loaded["claudecode.zen"]
  local from_zen = zen ~= nil and zen.is_active()
  if from_zen then
    zen.leave()
  end

  local base_text = read_file(ctx.old_file_path) or ""
  local dos = base_text:find("\r\n", 1, true) ~= nil
  local base_lines = text.to_lines(base_text, dos)
  local lines, eol = text.to_lines(ctx.new_file_contents, dos)
  if ctx.new_file_contents == "" then
    eol = base_text == "" or base_text:sub(-1) == "\n"
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, "claudecode-proposal://" .. ctx.new_file_path)
  local ft = vim.filetype.match({ filename = ctx.new_file_path, buf = buf })
  if ft then
    vim.bo[buf].filetype = ft
  end
  vim.bo[buf].modified = false
  vim.b[buf].claudecode_diff_tab_name = ctx.tab_name
  vim.b[buf].claudecode_proposal = true

  local win = editor_window()
  local session = {
    ctx = ctx,
    path = store_mod.normalize(ctx.old_file_path),
    buf = buf,
    win = win,
    prev_buf = vim.api.nvim_win_get_buf(win),
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
    winbar = vim.wo[win].winbar,
    base_text = base_text,
    base_lines = base_lines,
    eol = eol,
    dos = dos,
    proposed_lines = lines,
    reverts = {},
    from_zen = from_zen,
    done = false,
  }
  sessions[ctx.tab_name] = session

  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].winbar = "%#ClaudeCodeReviewHint# Claude proposes changes to "
    .. vim.fn.fnamemodify(ctx.new_file_path, ":~:.")
    .. " · :w accepts the rest %*"
  local ok, main = pcall(require, "claudecode")
  local diff_opts = ok and main.state and main.state.config and main.state.config.diff_opts or {}
  if not diff_opts.keep_terminal_focus then
    vim.api.nvim_set_current_win(win)
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      finish(session)
    end,
  })

  engine.attach(buf, base_lines, {
    write_on_revert = false,
    on_revert = function(rec)
      rec.path = session.path
      session.reverts[#session.reverts + 1] = rec
    end,
    on_done = function(reason)
      if reason == "resolved" then
        vim.schedule(function()
          finish(session)
        end)
      end
    end,
  })
end

---:ClaudeCodeDiffAccept in the proposal: accept what is there now.
---@param ctx ClaudeCodeDiffContext
function M.accept_command(ctx)
  local session = sessions[ctx.tab_name]
  if session then
    finish(session)
  else
    ctx.accept(ctx.new_file_contents)
  end
end

---Called once per diff by the plugin: after Claude closes the tab, on disconnect, on failure.
---@param ctx ClaudeCodeDiffContext
---@param _reason string
function M.close(ctx, _reason)
  local session = sessions[ctx.tab_name]
  if not session then
    return
  end
  sessions[ctx.tab_name] = nil
  session.done = true
  restore(session)
end

return M
