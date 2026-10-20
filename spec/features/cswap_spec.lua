--- Tests for `:ClaudeCode run [account]`: Claude run as a cswap (claude-swap) account.
local cswap = require("claudecode.features.cswap")
local hooks = require("claudecode.hooks")
local terminal = require("claudecode.terminal")

describe("cswap accounts", function()
  local dir, fake_cswap, provider, notes, real_notify

  -- A terminal provider that runs `sleep` in place of Claude and keeps every command it was given.
  local function fake_provider()
    local fake = { opened = {}, buf = nil }
    local function valid()
      return fake.buf and vim.api.nvim_buf_is_valid(fake.buf)
    end
    function fake.setup() end
    function fake.is_available()
      return true
    end
    function fake.open(cmd)
      if valid() then
        return
      end
      fake.opened[#fake.opened + 1] = cmd
      vim.cmd("botright vsplit")
      vim.cmd("enew")
      fake.buf = vim.api.nvim_get_current_buf()
      vim.fn.jobstart({ "sleep", "30" }, { term = true })
    end
    fake.simple_toggle = fake.open
    fake.focus_toggle = fake.open
    function fake.close() end
    function fake.get_active_bufnr()
      return valid() and fake.buf or nil
    end
    return fake
  end

  local function launched()
    return provider.opened[#provider.opened]
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    fake_cswap = dir .. "/cswap"
    local accounts = vim.json.encode({
      schemaVersion = 1,
      accounts = {
        { number = 1, email = "one@example.com", alias = "work" },
        { number = 2, email = "two@example.com" },
      },
    })
    vim.fn.writefile({
      "#!/bin/sh",
      'if [ "$1" = list ] && [ "$2" = --json ]; then',
      "  cat <<'EOF'",
      accounts,
      "EOF",
      "  exit 0",
      "fi",
      "exit 2",
    }, fake_cswap)
    vim.fn.setfperm(fake_cswap, "rwx------")

    provider = fake_provider()
    terminal.setup({ provider = provider }, nil, {})
    hooks.disable()
    cswap.setup({ cmd = fake_cswap })

    notes = {}
    real_notify = vim.notify
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
  end)

  after_each(function()
    vim.notify = real_notify
    cswap.reset()
    if provider.buf and vim.api.nvim_buf_is_valid(provider.buf) then
      vim.api.nvim_buf_delete(provider.buf, { force = true })
    end
    vim.cmd("silent! only!")
    hooks.disable()
    vim.fn.delete(dir, "rf")
  end)

  local function run_line(account, rest)
    return vim.fn.shellescape(fake_cswap) .. " run " .. vim.fn.shellescape(account) .. " --" .. (rest or "")
  end

  it("runs Claude as the account you name, with Claude's own arguments after --", function()
    cswap.run("1 --resume")

    assert.equal(run_line("1", " --resume"), launched())
  end)

  it("takes an alias or an email as well as a number", function()
    cswap.run("work")
    assert.equal(run_line("work"), launched())

    cswap.run("two@example.com")
    assert.equal(run_line("two@example.com"), launched())
  end)

  it("puts the review hooks after -- too, so cswap hands them to Claude", function()
    hooks.setup({ state_root = dir .. "/state" })

    cswap.run("2")

    assert.matches("^" .. vim.pesc(run_line("2")) .. " %-%-settings ", launched())
  end)

  it("lets cswap pick the account by the directory's mapping when you name none", function()
    cswap.run("")
    assert.equal(vim.fn.shellescape(fake_cswap) .. " run --", launched())

    cswap.run("--continue")
    assert.equal(vim.fn.shellescape(fake_cswap) .. " run -- --continue", launched())
  end)

  it("replaces a Claude that is already running", function()
    cswap.run("1")
    local first = provider.buf
    local job = vim.bo[first].channel

    cswap.run("2")

    assert.is_false(vim.api.nvim_buf_is_valid(first))
    assert.are_not.equal(-1, vim.fn.jobwait({ job }, 1000)[1]) -- -1: still running after a second
    assert.equal(run_line("2"), launched())
    assert.equal(2, #provider.opened)
  end)

  it("keeps the account for every later launch", function()
    cswap.run("work")
    vim.api.nvim_buf_delete(provider.buf, { force = true }) -- Claude exited

    terminal.simple_toggle()

    assert.equal(run_line("work"), launched())
  end)

  it("leaves a running Claude alone when cswap has no such account", function()
    cswap.run("1")
    local first = provider.buf

    cswap.run("9")

    assert.is_true(vim.api.nvim_buf_is_valid(first))
    assert.equal(1, #provider.opened)
    assert.matches("no account 9", notes[#notes].msg)
    assert.equal(vim.log.levels.ERROR, notes[#notes].level)
  end)

  it("says so when cswap is not installed, and starts nothing", function()
    cswap.setup({ cmd = dir .. "/missing-cswap" })

    cswap.run("1")

    assert.equal(0, #provider.opened)
    assert.matches("not found", notes[#notes].msg)
  end)

  describe(":ClaudeCode", function()
    before_each(function()
      require("claudecode")._create_commands()
    end)

    it("hands `run` to the accounts and other arguments to Claude as before", function()
      vim.cmd("ClaudeCode run 2 --resume")
      assert.equal(run_line("2", " --resume"), launched())
    end)

    it("completes the accounts", function()
      assert.same({ "1", "2", "work" }, vim.fn.getcompletion("ClaudeCode run ", "cmdline"))
    end)
  end)

  describe("completion", function()
    it("offers run as the first argument", function()
      assert.same({ "run" }, cswap.complete("r", "ClaudeCode r"))
      assert.same({}, cswap.complete("x", "ClaudeCode x"))
    end)

    it("offers the account numbers and aliases after run", function()
      assert.same({ "1", "2", "work" }, cswap.complete("", "ClaudeCode run "))
      assert.same({ "work" }, cswap.complete("w", "ClaudeCode run w"))
    end)

    it("offers nothing for Claude's own arguments", function()
      assert.same({}, cswap.complete("", "ClaudeCode run 1 "))
    end)
  end)
end)
