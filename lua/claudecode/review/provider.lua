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
---@field base_text string The bytes of the file, as the base in the store holds them
---@field base_lines string[] The same, as the lines of a UTF-8 buffer
---@field eol boolean
---@field dos boolean
---@field bomb boolean The text handed to Claude starts with a byte order mark
---@field proposed_lines string[]
---@field reverts ClaudeCodeRevertRecord[]
---@field reason string|nil The reason of the revert `cr` is making now
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

---How the file is encoded: as its buffer says if one holds it, else as `:edit` would find out.
---@param path string
---@param bytes string The bytes of the file
---@return string fileencoding
---@return boolean bomb
local function file_encoding(path, bytes)
  local target = store_mod.normalize(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and store_mod.normalize(name) == target then
        return vim.bo[buf].fileencoding, vim.bo[buf].bomb
      end
    end
  end
  return text.detect(bytes)
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

local reason_ns = vim.api.nvim_create_namespace("claudecode_review_reason")

---`cr` in a proposal: a box for the reason, and Enter reverts the hunks on those lines with it.
---@param session ClaudeCodeProposal
---@param bufnr integer
---@param first integer
---@param last integer
local function ask_reason(session, bufnr, first, last)
  local win = vim.fn.win_findbuf(bufnr)[1]
  if not win then
    return
  end
  local name = vim.fn.fnamemodify(session.path, ":t")
  require("claudecode.review.note_box").open(win, last, {
    ns = reason_ns,
    title = " reason · " .. name .. ":" .. (first == last and first or (first .. "-" .. last)) .. " ",
    footer = " ⏎ revert with this reason · esc cancel ",
    keys = {
      ["<CR>"] = function(reason)
        if reason == "" then
          return
        end
        session.reason = reason
        local reverted = engine.revert_lines(bufnr, first, last)
        session.reason = nil
        if not reverted then
          vim.notify("claudecode: Claude changed nothing on these lines", vim.log.levels.INFO)
        end
      end,
      ["<Esc>"] = function() end,
    },
  })
end

---The reasons of the reverts, as one line for Claude's dialog.
---@param session ClaudeCodeProposal
---@return string|nil
local function reasons_of(session)
  local parts = {}
  for _, rec in ipairs(session.reverts) do
    if rec.reason then
      parts[#parts + 1] = { line = rec.line, text = (rec.reason:gsub("%s*\n%s*", " ")) }
    end
  end
  if #parts == 0 then
    return nil
  end
  if #parts == 1 then
    return parts[1].text
  end
  return table.concat(
    vim.tbl_map(function(part)
      return ("line %d: %s"):format(part.line, part.text)
    end, parts),
    "; "
  )
end

---You reverted every hunk and gave reasons: answer "No, and tell Claude what to do differently" in
---Claude's own dialog, so that Claude goes on with your words. Where that cannot be done, reject
---through openDiff and leave the reasons in the clipboard.
---@param session ClaudeCodeProposal
---@param reasons string
local function reject_with(session, reasons)
  local function fallback()
    session.ctx.reject()
    pcall(vim.fn.setreg, "+", reasons)
    vim.fn.setreg('"', reasons)
    vim.notify(
      "claudecode: could not tell Claude your reason; the edit is rejected and the reason is in the clipboard",
      vim.log.levels.WARN
    )
  end
  local terminal = require("claudecode.terminal")
  local term = terminal.get_active_terminal_bufnr()
  if not (term and vim.api.nvim_buf_is_valid(term)) then
    return fallback()
  end
  require("claudecode.review.dialog").answer_no(term, reasons, function(ok)
    if not ok then
      fallback()
    end
  end)
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
  local reasons = reasons_of(session)
  if vim.deep_equal(lines, session.base_lines) and reasons then
    reject_with(session, reasons)
  elseif vim.deep_equal(lines, session.base_lines) then
    session.ctx.reject()
  else
    local content = text.to_text(lines, session.eol, session.dos)
    -- Claude writes what it is given: UTF-8, and a file that had a mark keeps it.
    if session.bomb and content ~= "" then
      content = text.BOM .. content
    end
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

  -- Claude's text is UTF-8 without a byte order mark; the file may be neither. Compare like with like.
  local file_bytes = read_file(ctx.old_file_path) or ""
  local fenc, bomb = file_encoding(ctx.old_file_path, file_bytes)
  local base_text = text.decode_as(file_bytes, fenc, bomb)
  local dos = base_text:find("\r\n", 1, true) ~= nil
  local base_lines = text.to_lines(base_text, dos)
  local proposal = ctx.new_file_contents
  if proposal:sub(1, #text.BOM) == text.BOM then
    proposal = proposal:sub(#text.BOM + 1)
    bomb = true
  end
  local lines, eol = text.to_lines(proposal, dos)
  if proposal == "" then
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
    base_text = file_bytes,
    base_lines = base_lines,
    eol = eol,
    dos = dos,
    bomb = bomb,
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
    -- Claude waits for an answer here, so a note is no note for later: cr reverts the hunk and
    -- the reason goes to Claude with the answer.
    note = function(bufnr, first, last)
      ask_reason(session, bufnr, first, last)
    end,
    on_revert = function(rec)
      rec.path = session.path
      rec.reason = session.reason
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

---Claude closed the tab, or a new diff took its name: refuse all of the proposal, whatever hunks
---you kept, and give the window back to your file at once.
---@param ctx ClaudeCodeDiffContext
function M.reject_command(ctx)
  local session = sessions[ctx.tab_name]
  if not session then
    return
  end
  sessions[ctx.tab_name] = nil
  session.done = true
  ctx.reject()
  restore(session)
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
