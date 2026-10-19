--- Tests for diff_opts.provider: a custom UI that takes over openDiff.
require("tests.busted_setup")
local diff = require("claudecode.diff")

describe("diff_opts.provider", function()
  local file = "/tmp/claudecode_provider_spec.txt"

  -- Provider double that records every call it receives.
  local function recording_provider()
    local provider = { opened = {}, closed = {} }
    provider.open = function(ctx)
      provider.opened[#provider.opened + 1] = ctx
    end
    provider.close = function(ctx, reason)
      provider.closed[#provider.closed + 1] = { ctx = ctx, reason = reason }
    end
    return provider
  end

  -- Open a pending diff and return a handle whose `.result` is set once Claude gets the answer.
  local function open_pending(old_path, tab_name, client_id)
    local handle = { result = nil }
    handle.co = coroutine.create(function()
      handle.result = diff.open_diff_blocking(old_path, file, "line 1\nline 2\nnew line\n", tab_name, client_id)
    end)
    local ok, err = coroutine.resume(handle.co)
    assert.is_true(ok, "diff coroutine should start: " .. tostring(err))
    return handle
  end

  -- Collect the User events whose pattern matches, fired while `action` runs.
  local function capture_user_events(pattern, action)
    local events = {}
    local orig = vim.api.nvim_exec_autocmds
    vim.api.nvim_exec_autocmds = function(event, opts)
      if event == "User" and opts and opts.pattern == pattern then
        events[#events + 1] = opts.data
      end
      if orig then
        return orig(event, opts)
      end
    end
    local ok, err = pcall(action)
    vim.api.nvim_exec_autocmds = orig
    assert(ok, tostring(err))
    return events
  end

  before_each(function()
    local f = io.open(file, "w")
    f:write("line 1\nline 2\n")
    f:close()
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test_cleanup")
    diff.setup({ terminal = {}, diff_opts = {} })
    os.remove(file)
  end)

  it("hands the proposal to provider.open instead of building its own windows", function()
    local provider = recording_provider()
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })
    local wins_before = #vim.api.nvim_list_wins()

    local handle = open_pending(file, "tab-open")

    assert.equal("suspended", coroutine.status(handle.co))
    assert.equal(1, #provider.opened)
    local ctx = provider.opened[1]
    assert.equal("tab-open", ctx.tab_name)
    assert.equal(file, ctx.old_file_path)
    assert.equal(file, ctx.new_file_path)
    assert.equal("line 1\nline 2\nnew line\n", ctx.new_file_contents)
    assert.is_false(ctx.is_new_file)
    assert.equal(wins_before, #vim.api.nvim_list_wins())
  end)

  it("answers FILE_SAVED so that Claude writes exactly the text passed to ctx.accept", function()
    local provider = recording_provider()
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })
    local handle = open_pending(file, "tab-accept")

    provider.opened[1].accept("line 1\nline 2 edited\n")

    assert.equal("dead", coroutine.status(handle.co))
    -- Claude Code 2.1.303 drops one trailing "\n" from the text before writing it.
    assert.same({
      content = {
        { type = "text", text = "FILE_SAVED" },
        { type = "text", text = "line 1\nline 2 edited\n\n" },
      },
    }, handle.result)
  end)

  it("answers DIFF_REJECTED with the tab name on ctx.reject", function()
    local provider = recording_provider()
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })
    local handle = open_pending(file, "tab-reject")

    provider.opened[1].reject()

    assert.equal("dead", coroutine.status(handle.co))
    assert.same({
      content = {
        { type = "text", text = "DIFF_REJECTED" },
        { type = "text", text = "tab-reject" },
      },
    }, handle.result)
  end)

  it("closes the provider UI once when Claude closes the tab after accept", function()
    local provider = recording_provider()
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })
    open_pending(file, "tab-close")
    provider.opened[1].accept("line 1\n")

    local closed_events = capture_user_events("ClaudeCodeDiffClosed", function()
      assert.is_true(diff.close_diff_by_tab_name("tab-close"))
    end)

    assert.equal(1, #provider.closed)
    assert.equal(provider.opened[1], provider.closed[1].ctx)
    assert.is_nil(diff._get_active_diffs()["tab-close"])
    assert.equal(1, #closed_events)
    assert.equal("tab-close", closed_events[1].tab_name)
  end)

  it("rejects a pending diff and closes its UI once when the client disconnects", function()
    local provider = recording_provider()
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })
    local handle = open_pending(file, "tab-gone", "clientA")

    assert.equal(1, diff.close_diffs_for_client("clientA", "disconnect"))

    assert.equal("DIFF_REJECTED", handle.result.content[1].text)
    assert.equal(1, #provider.closed)
    assert.is_nil(diff._get_active_diffs()["tab-gone"])
  end)

  it("rejects and closes the previous diff when a new one reuses its tab name", function()
    local provider = recording_provider()
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })
    local first = open_pending(file, "tab-reused")

    local second = open_pending(file, "tab-reused")

    assert.equal("DIFF_REJECTED", first.result.content[1].text)
    assert.equal(1, #provider.closed)
    assert.equal(provider.opened[1], provider.closed[1].ctx)
    assert.equal(2, #provider.opened)
    assert.equal("suspended", coroutine.status(second.co))
  end)

  it("ignores a late reject after accept, so the accepted diff stays saved", function()
    local provider = recording_provider()
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })
    local handle = open_pending(file, "tab-late", "clientA")
    local ctx = provider.opened[1]

    ctx.accept("line 1\n")
    ctx.reject()

    assert.equal("FILE_SAVED", handle.result.content[1].text)
    assert.equal("saved", diff._get_active_diffs()["tab-late"].status)
    -- Disconnect cleanup only touches pending diffs, so the accepted one survives.
    assert.equal(0, diff.close_diffs_for_client("clientA", "disconnect"))
  end)

  it("reports a failing provider.open to Claude and leaves no diff behind", function()
    local provider = recording_provider()
    provider.open = function()
      error("provider exploded")
    end
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })

    local ok, err
    local co = coroutine.create(function()
      ok, err = pcall(diff.open_diff_blocking, file, file, "line 1\n", "tab-broken")
    end)
    assert.is_true(coroutine.resume(co))

    assert.is_false(ok)
    assert.equal(-32000, err.code)
    assert.matches("provider exploded", err.data)
    assert.is_nil(diff._get_active_diffs()["tab-broken"])
    -- The provider gets a chance to tear down whatever it managed to build.
    assert.equal(1, #provider.closed)
    assert.equal("setup failed", provider.closed[1].reason)
  end)

  it("announces the provider diff with ClaudeCodeDiffOpened", function()
    local provider = recording_provider()
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })

    local opened = capture_user_events("ClaudeCodeDiffOpened", function()
      open_pending(file, "tab-opened")
    end)

    assert.equal(1, #opened)
    assert.equal("tab-opened", opened[1].tab_name)
    assert.equal(file, opened[1].file_path)
    assert.equal("provider", opened[1].layout)
  end)

  it("lets :ClaudeCodeDiffAccept accept through the provider", function()
    local provider = recording_provider()
    provider.accept_command = function(ctx)
      ctx.accept("from the provider\n")
    end
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })
    local handle = open_pending(file, "tab-command")

    diff._resolve_diff_as_saved("tab-command", 0)

    assert.equal("FILE_SAVED", handle.result.content[1].text)
    assert.equal("from the provider\n\n", handle.result.content[2].text)
  end)

  it("accepts Claude's proposal on :ClaudeCodeDiffAccept when the provider has no command handler", function()
    local provider = recording_provider()
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })
    local handle = open_pending(file, "tab-command-default")

    diff._resolve_diff_as_saved("tab-command-default", 0)

    assert.equal("line 1\nline 2\nnew line\n\n", handle.result.content[2].text)
  end)

  it("removes the diff even when provider.close throws", function()
    local provider = recording_provider()
    provider.close = function()
      error("close exploded")
    end
    diff.setup({ terminal = {}, diff_opts = { provider = provider } })
    open_pending(file, "tab-bad-close")
    provider.opened[1].reject()

    assert.is_true(diff.close_diff_by_tab_name("tab-bad-close"))
    assert.is_nil(diff._get_active_diffs()["tab-bad-close"])
  end)
end)

describe("diff_opts.provider config", function()
  local config = require("claudecode.config")

  local function apply_provider(provider)
    return pcall(config.apply, { diff_opts = { provider = provider } })
  end

  it("accepts a table with open and close functions", function()
    local ok, err = apply_provider({ open = function() end, close = function() end })
    assert.is_true(ok, tostring(err))
  end)

  it("rejects a provider that is not a table", function()
    local ok, err = apply_provider("unified")
    assert.is_false(ok)
    assert.matches("diff_opts.provider", tostring(err))
  end)

  it("rejects a provider without a close function", function()
    local ok, err = apply_provider({ open = function() end })
    assert.is_false(ok)
    assert.matches("diff_opts.provider", tostring(err))
  end)
end)
