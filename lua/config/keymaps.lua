-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
vim.api.nvim_set_keymap("v", ";y", '"+y', { noremap = true, silent = true })
vim.api.nvim_set_keymap("v", "<leader>c", '"+y', { noremap = true, silent = true })

vim.api.nvim_set_keymap("n", ";y", '"+yy', { noremap = true, silent = true })

vim.api.nvim_set_keymap("n", ";p", '"+p', { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "<leader>v", '"+p', { noremap = true, silent = true })

vim.api.nvim_set_keymap("i", ";p", "<C-r>+", { noremap = true, silent = true })

vim.keymap.set("n", "<leader>uf", function()
  vim.g.auto_format = not vim.g.auto_format
  vim.notify("Auto format: " .. (vim.g.auto_format and "on" or "off"))
end, { desc = "Toggle Auto Format" })

vim.keymap.set("n", "<leader>uF", "<cmd>FormatInfo<cr>", { desc = "Format Info" })
vim.keymap.set("n", "<leader>ud", "<cmd>ToggleDiagnostics<cr>", { desc = "Toggle Diagnostics" })
vim.keymap.set("n", "<leader>uL", "<cmd>LspInfoLite<cr>", { desc = "LSP Info" })
vim.keymap.set("n", "<leader>cf", "<cmd>CangjieFormat<cr>", { desc = "Cangjie Format" })
vim.keymap.set("n", "<leader>cd", "<cmd>CangjieDocs<cr>", { desc = "Cangjie Docs" })
vim.keymap.set("n", "<leader>cs", "<cmd>CangjieDocsSync<cr>", { desc = "Cangjie Docs Sync" })
vim.keymap.set("n", "<leader>ci", "<cmd>CangjieDocsInfo<cr>", { desc = "Cangjie Docs Info" })
vim.keymap.set("n", "<leader>cI", "<cmd>CangjieLspInfo<cr>", { desc = "Cangjie LSP Info" })
vim.keymap.set("n", "<leader>cD", "<cmd>CangjieDocsDebug<cr>", { desc = "Cangjie Docs Debug Toggle" })
vim.keymap.set("n", "<leader>cL", "<cmd>CangjieDocsDebugLog<cr>", { desc = "Cangjie Docs Debug Log" })
vim.keymap.set("n", "<leader>cS", "<cmd>CangjieDocsDebugInfo<cr>", { desc = "Cangjie Docs Debug Snapshot" })
