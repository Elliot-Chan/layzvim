-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
--
vim.api.nvim_create_autocmd("FileType", {
  pattern = "Cangjie",
  callback = function()
    vim.bo.shiftwidth = 4
    vim.bo.tabstop = 4
    vim.bo.expandtab = true
    vim.o.autoindent = true
    vim.o.smartindent = false
    vim.o.cindent = true
  end,
})
