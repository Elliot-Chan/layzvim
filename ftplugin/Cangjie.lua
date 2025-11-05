vim.bo.shiftwidth = 4
vim.bo.tabstop = 4
vim.bo.expandtab = true
-- 只在 Cangjie 生效
vim.bo.cindent = false
vim.bo.smartindent = false
vim.bo.indentexpr = ""
vim.lsp.enable("cangjie_lsp")
-- vim.b.undo_ftplugin = (vim.b.undo_ftplugin or "") .. "|setl sw< ts< et<"
