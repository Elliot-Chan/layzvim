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
map("n", "<leader>uh", "<cmd>CangjieInlayHints toggle<cr>", { desc = "Toggle Inlay Hints" })
map("n", "<leader>ua", "<cmd>CangjieLocalAuto toggle<cr>", { desc = "Toggle Cangjie Local Auto" })
map("n", "<leader>uL", "<cmd>LspInfoLite<cr>", { desc = "LSP Info" })

-- Cangjie LSP entry points.

map("n", "<leader>cf", "<cmd>CangjieFormat<cr>", { desc = "Cangjie Format" })
map("n", "<leader>cI", "<cmd>CangjieLspInfo<cr>", { desc = "Cangjie LSP Info" })
map("n", "<leader>cC", "<cmd>CangjieLspCaps<cr>", { desc = "Cangjie LSP Capabilities" })

-- Cangjie docs.

map("n", "<leader>dc", "<cmd>CangjieDocs<cr>", { desc = "Cangjie API Docs" })
map("n", "<leader>ds", "<cmd>CangjieDocsSync<cr>", { desc = "Cangjie Docs Sync" })
map("n", "<leader>dI", "<cmd>CangjieDocsInfo<cr>", { desc = "Cangjie Docs Info" })
map("n", "<leader>dx", "<cmd>CangjieDocsDebug<cr>", { desc = "Cangjie Docs Debug Toggle" })
map("n", "<leader>dL", "<cmd>CangjieDocsDebugLog<cr>", { desc = "Cangjie Docs Debug Log" })
map("n", "<leader>dS", "<cmd>CangjieDocsDebugInfo<cr>", { desc = "Cangjie Docs Debug Snapshot" })
