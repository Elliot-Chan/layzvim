-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
vim.api.nvim_set_keymap("v", ";y", '"+y', { noremap = true, silent = true })
vim.api.nvim_set_keymap("v", "<leader>c", '"+y', { noremap = true, silent = true })

vim.api.nvim_set_keymap("n", ";y", '"+yy', { noremap = true, silent = true })

vim.api.nvim_set_keymap("n", ";p", '"+p', { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "<leader>v", '"+p', { noremap = true, silent = true })

vim.api.nvim_set_keymap("i", ";p", "<C-r>+", { noremap = true, silent = true })
