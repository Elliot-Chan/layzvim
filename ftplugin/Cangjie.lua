vim.bo.shiftwidth = 4
vim.bo.tabstop = 4
vim.bo.expandtab = true
-- 只在 Cangjie 生效
vim.bo.cindent = false
vim.bo.smartindent = false
vim.bo.indentexpr = ""
vim.b.autoformat = false
vim.lsp.enable("cangjie_lsp")

local map = vim.keymap.set
local opts = { buffer = 0, silent = true }

map("n", "<localleader>jf", "<cmd>CangjieFormat<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Format" }))
map("n", "<localleader>ja", "<cmd>CangjieLocalAuto toggle<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Local Auto" }))
map("n", "<localleader>jh", "<cmd>CangjieInlayHints toggle<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Inlay Hints" }))
map("n", "<localleader>jm", "<cmd>CangjieCompletionDocs toggle<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Completion Docs" }))
map("n", "<localleader>ji", "<cmd>CangjieLspInfo<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie LSP Info" }))
map("n", "<localleader>jc", "<cmd>CangjieLspCaps<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie LSP Capabilities" }))
map("n", "<localleader>jd", "<cmd>CangjieDocs<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Docs" }))
map("n", "<localleader>js", "<cmd>CangjieDocsSync<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Docs Sync" }))
map("n", "<localleader>jI", "<cmd>CangjieDocsInfo<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Docs Info" }))
map("n", "<localleader>jx", "<cmd>CangjieDocsDebug toggle<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Docs Debug" }))
map("n", "<localleader>jL", "<cmd>CangjieDocsDebugLog<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Docs Debug Log" }))
map("n", "<localleader>jS", "<cmd>CangjieDocsDebugInfo<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Docs Debug Snapshot" }))

local ok, wk = pcall(require, "which-key")
if ok then
    wk.add({
        { "<localleader>j", group = "Cangjie", buffer = 0 },
    })
end
-- vim.b.undo_ftplugin = (vim.b.undo_ftplugin or "") .. "|setl sw< ts< et<"
