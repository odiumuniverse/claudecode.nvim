--- Tests for the revert summary Claude reads as additionalContext.
local summary = require("claudecode.review.summary")

describe("revert summary", function()
  it("says nothing when nothing was reverted", function()
    assert.is_nil(summary.render({}, "/p"))
  end)

  it("shows the reverted and the restored text with the path relative to the project", function()
    local text = summary.render({
      { path = "/p/src/a.lua", line = 10, base_lines = { "local x = 1" }, claude_lines = { "local x = 2" }, time = 1 },
    }, "/p")

    assert.equal(
      table.concat({
        "The user reviewed your edits in Neovim and reverted some of them.",
        "The files on disk already contain the restored text. Do not reapply these changes unless the user asks.",
        "",
        "src/a.lua, line 10",
        "  your text, reverted:",
        "    | local x = 2",
        "  restored text:",
        "    | local x = 1",
      }, "\n"),
      text
    )
  end)

  it("asks to rework a place the user reverted with a reason, and not to reapply the others", function()
    local text = summary.render({
      { path = "/p/a.lua", line = 1, base_lines = { "x = 1" }, claude_lines = { "x = 2" }, time = 1, reason = "use 3" },
      { path = "/p/a.lua", line = 9, base_lines = { "y = 1" }, claude_lines = { "y = 2" }, time = 2 },
    }, "/p")

    assert.equal(
      table.concat({
        "The user reviewed your edits in Neovim and reverted some of them.",
        "The files on disk already contain the restored text. Rework each place that carries the user's reason"
          .. " as the reason asks; do not reapply the other changes unless the user asks.",
        "",
        "a.lua, line 1",
        "  your text, reverted:",
        "    | x = 2",
        "  restored text:",
        "    | x = 1",
        "  the user's reason:",
        "    use 3",
        "",
        "a.lua, line 9",
        "  your text, reverted:",
        "    | y = 2",
        "  restored text:",
        "    | y = 1",
      }, "\n"),
      text
    )
  end)

  it("names the empty side of a pure insertion or deletion", function()
    local text = summary.render({
      { path = "/p/a.lua", line = 3, base_lines = {}, claude_lines = { "added()" }, time = 1 },
      { path = "/p/a.lua", line = 7, base_lines = { "kept()" }, claude_lines = {}, time = 2 },
    }, "/p")

    assert.matches(
      "a.lua, line 3\n  your text, reverted:\n    | added%(%)\n  restored text: none, your lines were removed",
      text
    )
    assert.matches(
      "a.lua, line 7\n  your text, reverted: none, you had deleted these lines\n  restored text:\n    | kept%(%)",
      text
    )
  end)

  it("keeps a path outside the project absolute", function()
    local text = summary.render(
      { { path = "/etc/x.conf", line = 1, base_lines = { "a" }, claude_lines = { "b" }, time = 1 } },
      "/p"
    )

    assert.matches("\n/etc/x.conf, line 1\n", text)
  end)

  it("cuts a long block and says how many lines it left out", function()
    local long = {}
    for i = 1, 25 do
      long[i] = "line " .. i
    end
    local text =
      summary.render({ { path = "/p/a.lua", line = 1, base_lines = {}, claude_lines = long, time = 1 } }, "/p")

    assert.matches("    | line 20\n    | … 5 more lines", text)
    assert.is_nil(text:find("line 21", 1, true))
  end)

  it("stays under the size limit and lists the files it had no room for", function()
    local records = {}
    for i = 1, 40 do
      local body = {}
      for j = 1, 20 do
        body[j] = string.rep("x", 60) .. j
      end
      records[i] = { path = "/p/f" .. i .. ".lua", line = 1, base_lines = {}, claude_lines = body, time = i }
    end

    local text = summary.render(records, "/p")

    assert.is_true(#text <= summary.MAX_CHARS)
    assert.matches("more reverted changes in: .*f40%.lua", text)
  end)
end)
