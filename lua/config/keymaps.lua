-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
local map = vim.keymap.set

-- Clipboard helpers.

map("v", ";y", '"+y', { noremap = true, silent = true })
map("v", "<leader>y", '"+y', { noremap = true, silent = true })
map("n", ";y", '"+yy', { noremap = true, silent = true })
map("n", ";p", '"+p', { noremap = true, silent = true })
map("n", "<leader>v", '"+p', { noremap = true, silent = true })
map("i", ";p", "<C-r>+", { noremap = true, silent = true })

-- Toggles and lightweight info.

map("n", "<leader>uf", function()
  vim.g.autoformat = not (vim.g.autoformat == nil or vim.g.autoformat)
  vim.notify("Auto format: " .. (vim.g.autoformat and "on" or "off"))
end, { desc = "Toggle Auto Format" })

map("n", "<leader>uF", "<cmd>FormatInfo<cr>", { desc = "Format Info" })
map("n", "<leader>ud", "<cmd>ToggleDiagnostics<cr>", { desc = "Toggle Diagnostics" })
map("n", "<leader>uK", "<cmd>LspInfoLite<cr>", { desc = "LSP Info" })
