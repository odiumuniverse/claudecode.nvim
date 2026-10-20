---@brief [[
--- Claude Code asks for permission in its terminal while the proposal is open in Neovim, and its
--- dialog has an answer the IDE protocol lacks: "No, and tell Claude what to do differently". The
--- model then gets the rejection with your words and goes on in the same turn. A rejection through
--- openDiff carries no text and ends the turn (docs/DESIGN.md, "What openDiff taught us").
--- The dialog is Claude Code's own screen, so every key is pressed only after the screen shows what
--- the next one needs; anything unexpected backs off and leaves the answer to the caller.
---@brief ]]
---@module 'claudecode.review.dialog'

local M = {}

local KEYS = { down = "\27[B", tab = "\t" }

-- Rows from the bottom of the Claude terminal that the dialog fits in.
local SCREEN_ROWS = 20
-- How long one step may wait for the screen to follow, and how many steps the answer may take.
M.STEP_MS = 150
M.MAX_STEPS = 16

---The next step on the way to "No, and tell Claude what to do differently".
---@param lines string[] The bottom rows of the Claude terminal
---@return "down"|"tab"|"type"|nil step Nil: no such dialog on screen, back off
function M.next_step(lines)
  local start
  for i = #lines, 1, -1 do
    if lines[i]:find("Do you want to", 1, true) then
      start = i
      break
    end
  end
  if not start then
    return nil
  end
  local chosen, has_no = nil, false
  for i = start + 1, #lines do
    local label = lines[i]:match("%d+%.%s+(.-)%s*$")
    if label then
      has_no = has_no or label:match("^No") ~= nil
      if lines[i]:find("❯", 1, true) then
        chosen = label
      end
    end
  end
  if not chosen or not has_no then
    return nil
  end
  if chosen:match("^No, and tell Claude") then
    return "type"
  end
  if chosen:match("^No") then
    return "tab"
  end
  -- Tab on a Yes turns into "Yes, and tell Claude what to do next", which applies the edit.
  if chosen:find("tell Claude", 1, true) then
    return nil
  end
  return "down"
end

---@param bufnr integer
---@return string[]
local function screen(bufnr)
  local rows = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match("%S") then
      table.insert(rows, 1, lines[i])
      if #rows == SCREEN_ROWS then
        break
      end
    end
  end
  return rows
end

---Answer the dialog in Claude's terminal: No, and tell Claude `text`.
---@param bufnr integer The Claude terminal
---@param text string One line
---@param done fun(ok: boolean) Called once: true when Enter went out with `text` in the dialog
function M.answer_no(bufnr, text, done)
  local chan = vim.bo[bufnr].channel
  local steps, typed = 0, false
  local function step()
    steps = steps + 1
    if steps > M.MAX_STEPS or not vim.api.nvim_buf_is_valid(bufnr) then
      return done(false)
    end
    local rows = screen(bufnr)
    if typed then
      -- Enter answers the dialog only once the text has arrived in it.
      if table.concat(rows, "\n"):find(text:sub(1, 30), 1, true) then
        vim.fn.chansend(chan, "\r")
        return done(true)
      end
    else
      local next_step = M.next_step(rows)
      if next_step == nil then
        return done(false)
      elseif next_step == "type" then
        vim.fn.chansend(chan, text)
        typed = true
      else
        vim.fn.chansend(chan, KEYS[next_step])
      end
    end
    vim.defer_fn(step, M.STEP_MS)
  end
  step()
end

return M
