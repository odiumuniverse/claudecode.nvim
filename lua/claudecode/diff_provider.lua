--- Custom diff UI: `diff_opts.provider` takes over openDiff from the built-in views.
local M = {}

---@class ClaudeCodeDiffProvider
---@field open fun(ctx: ClaudeCodeDiffContext) Show the proposal; answer later with ctx.accept or ctx.reject
---@field close fun(ctx: ClaudeCodeDiffContext, reason: string) Remove the UI; called once per diff, also when open failed
---@field accept_command? fun(ctx: ClaudeCodeDiffContext) What :ClaudeCodeDiffAccept does; default accepts the proposal

---@class ClaudeCodeDiffContext
---@field tab_name string
---@field old_file_path string
---@field new_file_path string
---@field new_file_contents string Claude's proposed text
---@field is_new_file boolean
---@field accept fun(content: string) Claude writes `content` to the file
---@field reject fun() The file stays as it is

---Hand a proposed change to the provider and register it as a pending diff.
---@param provider ClaudeCodeDiffProvider
---@param params table Diff parameters (old_file_path, new_file_path, new_file_contents, tab_name, client_id)
---@param resolution_callback function Resumes the blocked openDiff call with its MCP result
function M.setup(provider, params, resolution_callback)
  local diff = require("claudecode.diff")

  local ctx = {
    tab_name = params.tab_name,
    old_file_path = params.old_file_path,
    new_file_path = params.new_file_path,
    new_file_contents = params.new_file_contents,
    is_new_file = vim.fn.filereadable(params.old_file_path) ~= 1,
  }

  local state = {
    layout = "provider",
    provider = provider,
    ctx = ctx,
    old_file_path = params.old_file_path,
    new_file_path = params.new_file_path,
    is_new_file = ctx.is_new_file,
    client_id = params.client_id,
    created_at = vim.fn.localtime(),
    status = "pending",
    resolution_callback = resolution_callback,
    result_content = nil,
  }

  -- Claude gets one answer per diff: later accept/reject calls are ignored.
  local function resolve(status, result)
    if state.status ~= "pending" then
      return
    end
    state.status = status
    state.result_content = result
    resolution_callback(result)
  end

  ---Accept the proposal; Claude writes `content` to the file.
  ---@param content string
  function ctx.accept(content)
    resolve("saved", {
      content = {
        { type = "text", text = "FILE_SAVED" },
        -- Claude Code (2.1.303) drops one trailing "\n" before writing; give it one to drop.
        { type = "text", text = content .. "\n" },
      },
    })
  end

  ---Reject the proposal; the file stays as it is.
  function ctx.reject()
    resolve("rejected", {
      content = {
        { type = "text", text = "DIFF_REJECTED" },
        { type = "text", text = params.tab_name },
      },
    })
  end

  diff._register_diff_state(params.tab_name, state)
  provider.open(ctx)
  -- Same event as the built-in views, so zen and user configs see a proposal arrive.
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "ClaudeCodeDiffOpened",
    modeline = false,
    data = {
      tab_name = params.tab_name,
      file_path = params.old_file_path,
      new_file_path = params.new_file_path,
      is_new_file = ctx.is_new_file,
      layout = "provider",
    },
  })
end

---:ClaudeCodeDiffAccept on a provider diff. The provider knows what "accept" means for its UI
---(e.g. only the hunks you kept); without a handler Claude's proposal is accepted as is.
---@param diff_data table The diff state registered by M.setup
function M.accept_command(diff_data)
  if type(diff_data.provider.accept_command) == "function" then
    diff_data.provider.accept_command(diff_data.ctx)
  else
    diff_data.ctx.accept(diff_data.ctx.new_file_contents)
  end
end

---Tear down the provider's UI for a diff that is being removed.
---@param diff_data table The diff state registered by M.setup
---@param reason string Human-readable reason
function M.cleanup(diff_data, reason)
  -- A failing close must not keep the diff registered or mask the error that led here.
  local ok, err = pcall(diff_data.provider.close, diff_data.ctx, reason)
  if not ok then
    require("claudecode.logger").warn("diff", "Diff provider close failed for", diff_data.ctx.tab_name, err)
  end
end

return M
