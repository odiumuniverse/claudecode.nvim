---@brief [[
--- List of files with hunks you have not reviewed yet (<leader>ak): open one, keep all of it
--- or revert all of it. Uses snacks.picker, then fzf-lua, then vim.ui.select.
---@brief ]]
---@module 'claudecode.review.picker'

local text = require("claudecode.review.text")

local M = {}

local function controller()
  return require("claudecode.review.controller")
end

local function engine()
  return require("claudecode.review")
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function loaded_buf(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end
  return nil
end

---@class ClaudeCodeReviewItem
---@field path string
---@field rel string Path relative to the cwd
---@field added integer Lines Claude added
---@field removed integer Lines Claude removed
---@field new_file boolean
---@field diff string Unified diff, base → file

---@return ClaudeCodeReviewItem[]
function M.items()
  local store = controller().store()
  local items = {}
  if not store then
    return items
  end
  for _, path in ipairs(controller().refresh_pending()) do
    local base = store:get(path)
    if base then
      local current = read_file(path) or ""
      local hunks = require("claudecode.review.hunks").compute((text.to_lines(base.text)), (text.to_lines(current)))
      local added, removed = 0, 0
      for _, hunk in ipairs(hunks) do
        added = added + hunk.cur_count
        removed = removed + hunk.base_count
      end
      items[#items + 1] = {
        path = path,
        rel = vim.fn.fnamemodify(path, ":~:."),
        added = added,
        removed = removed,
        new_file = base.new_file,
        diff = vim.text.diff(base.text, current, { ctxlen = 3 }) or "",
      }
    end
  end
  return items
end

---Open the file at its first hunk.
---@param path string
function M.open(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local hunks = engine().is_attached(buf) and engine().hunks(buf) or {}
  if hunks[1] then
    local row = require("claudecode.review.hunks").anchor(hunks[1], vim.api.nvim_buf_line_count(buf))
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end
end

---Accept everything Claude changed in the file.
---@param path string
function M.keep_all(path)
  local buf = loaded_buf(path)
  if buf and engine().is_attached(buf) then
    engine().keep_all(buf)
  else
    controller().store():remove(path)
  end
  controller().refresh_pending()
end

---Undo everything Claude changed in the file and tell Claude about it.
---@param path string
function M.revert_all(path)
  local buf = loaded_buf(path)
  if buf and engine().is_attached(buf) then
    engine().revert_all(buf)
    controller().refresh_pending()
    return
  end
  if buf and vim.bo[buf].modified then
    vim.notify(
      "claudecode: " .. vim.fn.fnamemodify(path, ":~:.") .. " has unsaved edits; save or drop them first",
      vim.log.levels.WARN
    )
    return
  end
  local store = controller().store()
  local base = store:get(path)
  if not base then
    return
  end
  local current = read_file(path) or ""
  local base_lines = text.to_lines(base.text)
  local hunks = require("claudecode.review.hunks").compute(base_lines, (text.to_lines(current)))
  -- After the revert the file is the base, so base coordinates are file coordinates.
  for _, hunk in ipairs(hunks) do
    store:append_revert({
      path = path,
      line = hunk.base_count > 0 and hunk.base_start or hunk.base_start + 1,
      base_lines = hunk.base_lines,
      claude_lines = hunk.cur_lines,
      time = os.time(),
    })
  end
  if base.new_file then
    vim.fn.delete(path)
    if buf then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  else
    local f = assert(io.open(path, "wb"))
    f:write(base.text)
    f:close()
    if buf then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent! edit")
      end)
    end
  end
  store:remove(path)
  controller().refresh_pending()
end

local function label(item)
  local tag = item.new_file and " (new)" or ""
  return string.format("%s%s  +%d -%d", item.rel, tag, item.added, item.removed)
end

local function show_snacks(items)
  local Snacks = rawget(_G, "Snacks")
  local picker_items = {}
  for i, item in ipairs(items) do
    picker_items[i] = { idx = i, text = label(item), file = item.path, review = item }
  end
  Snacks.picker.pick({
    title = "Claude review",
    items = picker_items,
    format = "text",
    preview = function(ctx)
      ctx.preview:reset()
      ctx.preview:set_lines(vim.split(ctx.item.review.diff, "\n", { plain = true }))
      ctx.preview:highlight({ ft = "diff" })
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(function()
          M.open(item.review.path)
        end)
      end
    end,
    actions = {
      review_keep_all = function(picker, item)
        picker:close()
        if item then
          M.keep_all(item.review.path)
        end
      end,
      review_revert_all = function(picker, item)
        picker:close()
        if item then
          M.revert_all(item.review.path)
        end
      end,
    },
    win = {
      input = {
        keys = {
          ["<a-o>"] = { "review_keep_all", mode = { "n", "i" }, desc = "keep all" },
          ["<a-x>"] = { "review_revert_all", mode = { "n", "i" }, desc = "revert all" },
        },
      },
    },
  })
end

local function show_fzf(items)
  local by_label = {}
  local entries = {}
  for _, item in ipairs(items) do
    local entry = label(item)
    by_label[entry] = item
    entries[#entries + 1] = entry
  end
  local function act(fn)
    return function(selected)
      local item = selected and by_label[selected[1]]
      if item then
        fn(item.path)
      end
    end
  end
  require("fzf-lua").fzf_exec(entries, {
    prompt = "Claude review> ",
    actions = {
      ["default"] = act(M.open),
      ["alt-o"] = act(M.keep_all),
      ["alt-x"] = act(M.revert_all),
    },
  })
end

local function show_select(items)
  vim.ui.select(items, { prompt = "Claude review", format_item = label }, function(item)
    if not item then
      return
    end
    local actions = { "open", "keep all", "revert all" }
    vim.ui.select(actions, { prompt = item.rel }, function(choice)
      if choice == "open" then
        M.open(item.path)
      elseif choice == "keep all" then
        M.keep_all(item.path)
      elseif choice == "revert all" then
        M.revert_all(item.path)
      end
    end)
  end)
end

---@param backend "auto"|"snacks"|"fzf"|"select"|nil
---@return "snacks"|"fzf"|"select"
function M.backend(backend)
  if backend and backend ~= "auto" then
    return backend
  end
  local Snacks = rawget(_G, "Snacks")
  if Snacks and Snacks.picker and type(Snacks.picker.pick) == "function" then
    return "snacks"
  end
  if pcall(require, "fzf-lua") then
    return "fzf"
  end
  return "select"
end

---Show the files waiting for review.
---@param backend "auto"|"snacks"|"fzf"|"select"|nil
function M.show(backend)
  local items = M.items()
  if #items == 0 then
    vim.notify("claudecode: nothing waits for review")
    return
  end
  local chosen = M.backend(backend)
  if chosen == "snacks" then
    show_snacks(items)
  elseif chosen == "fzf" then
    show_fzf(items)
  else
    show_select(items)
  end
end

return M
