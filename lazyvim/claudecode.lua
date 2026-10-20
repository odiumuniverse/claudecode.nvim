-- LazyVim spec: LazyVim's ai.claudecode keys plus review and zen. Use it instead of the extra:
-- copy it to ~/.config/nvim/lua/plugins/claudecode.lua.
-- Toggle Claude sits on <leader>at rather than the extra's <leader>ac.
-- To run the plugin from a clone, add dir = "<path to the clone>".
return {
  {
    "odiumuniverse/claudecode.nvim",
    name = "claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    -- Not lazy on keys: a file Claude edited before a restart must come back under review as you open it.
    event = "VeryLazy",
    opts = {},
    keys = {
      { "<leader>a", "", desc = "+ai", mode = { "n", "v" } },
      { "<leader>at", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
      -- Manual mode reviews every edit before Claude writes it (:help claudecode-modes).
      { "<leader>am", "<cmd>ClaudeCode --permission-mode manual<cr>", desc = "Claude in Manual mode" },
      { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
      { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
      { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
      { "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
      { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
      {
        "<leader>as",
        "<cmd>ClaudeCodeTreeAdd<cr>",
        desc = "Add file",
        ft = { "NvimTree", "neo-tree", "oil" },
      },
      -- No "Accept diff" / "Deny diff": a proposal is decided with cs, cx, cS, cX and :w.
      -- The review list and zen also get their keys from the plugin itself;
      -- listing them here lets which-key show them before the plugin loads.
      { "<leader>ak", "<cmd>ClaudeCodeReview<cr>", desc = "Files waiting for review" },
      { "<leader>an", "<cmd>ClaudeCodeReviewNotes<cr>", desc = "Notes for Claude" },
      { "<M-z>", "<cmd>ClaudeCodeZen<cr>", desc = "Claude zen" },
    },
  },
  -- The files waiting for review in the statusline, "review: 2 files"; gone when none wait.
  {
    "nvim-lualine/lualine.nvim",
    optional = true,
    opts = function(_, opts)
      table.insert(opts.sections.lualine_x, 1, {
        function()
          -- A copy of this spec may meet a plugin older than status().
          local status = require("claudecode.review.controller").status
          return status and status() or ""
        end,
        cond = function()
          return package.loaded["claudecode.review.controller"] ~= nil
        end,
        color = "ClaudeCodeReviewCount",
      })
    end,
  },
}
