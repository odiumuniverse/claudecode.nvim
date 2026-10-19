-- LazyVim spec for this fork: LazyVim's ai.claudecode keys plus review and zen.
-- Link it into your config instead of the extra:
--   ln -s ~/src/claudecode.nvim/fork/lazyvim/claudecode.lua ~/.config/nvim/lua/plugins/claudecode.lua
return {
  "odiumuniverse/claudecode.nvim",
  dir = vim.fn.expand("~/src/claudecode.nvim"),
  name = "claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  -- Not lazy on keys: a file Claude edited before a restart must come back under review as you open it.
  event = "VeryLazy",
  opts = {},
  keys = {
    { "<leader>a", "", desc = "+ai", mode = { "n", "v" } },
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
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
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
    -- Fork: the review list and zen also get their keys from the plugin itself;
    -- listing them here lets which-key show them before the plugin loads.
    { "<leader>ak", "<cmd>ClaudeCodeReview<cr>", desc = "Files waiting for review" },
    { "<M-z>", "<cmd>ClaudeCodeZen<cr>", desc = "Claude zen" },
  },
}
