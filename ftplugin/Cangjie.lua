vim.bo.shiftwidth = 4
vim.bo.tabstop = 4
vim.bo.expandtab = true
-- 只在 Cangjie 生效
vim.bo.cindent = false
vim.bo.smartindent = false
vim.bo.indentexpr = ""
vim.b.autoformat = false
if _G.CangjiePerf then
    _G.CangjiePerf.refresh(0)
end
local cangjie_perf_active = _G.CangjiePerf and _G.CangjiePerf.enabled(0)
if cangjie_perf_active and vim.g.cangjie_perf_lsp_auto_start ~= true then
    vim.b.cangjie_lsp_auto_start_skipped = true
else
    vim.lsp.enable("cangjie_lsp")
end

vim.api.nvim_buf_create_user_command(0, "CangjieLspStart", function()
    vim.b.cangjie_lsp_auto_start_skipped = false
    vim.lsp.enable("cangjie_lsp")
    vim.notify("Cangjie LSP start requested", vim.log.levels.INFO, { title = "Cangjie" })
end, { desc = "Start Cangjie LSP for this buffer" })

local map = vim.keymap.set
local opts = { buffer = 0, silent = true }
local function cangjie_live_lsp_action(method_name)
    return function(...)
        local path = vim.fn.stdpath("config") .. "/lsp/cangjie_lsp.lua"
        local ok, cfg = pcall(dofile, path)
        if not ok then
            vim.notify(cfg, vim.log.levels.ERROR, { title = "Cangjie" })
            return
        end
        local fn = cfg and cfg[method_name]
        if type(fn) ~= "function" then
            vim.notify("Cangjie LSP 动作不可用: " .. method_name, vim.log.levels.ERROR, { title = "Cangjie" })
            return
        end
        return fn(...)
    end
end

map("n", "K", cangjie_live_lsp_action("_codex_hover_or_local_docs"), vim.tbl_extend("force", opts, { desc = "Cangjie Docs" }))
map("n", "<localleader>jf", "<cmd>CangjieFormat<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Format" }))
map("x", "<localleader>jf", ":CangjieFormat<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Format Selection" }))
map("n", "<localleader>jF", "<cmd>CangjieFormatScope toggle<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Format Scope" }))
map("n", "<localleader>ja", "<cmd>CangjieLocalAuto toggle<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Local Auto" }))
map("n", "<localleader>jh", "<cmd>CangjieInlayHints toggle<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Inlay Hints" }))
map("n", "<localleader>jm", "<cmd>CangjieCompletionDocs toggle<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Completion Docs" }))
map("n", "<localleader>ji", "<cmd>CangjieLspInfo<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie LSP Info" }))
map("n", "<localleader>jv", "<cmd>CangjieLspStart<cr>", vim.tbl_extend("force", opts, { desc = "Start Cangjie LSP" }))
map("n", "<localleader>jc", "<cmd>CangjieLspCaps<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie LSP Capabilities" }))
map("n", "<localleader>jd", "<cmd>CangjieDocs<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Docs" }))
map("n", "<localleader>js", "<cmd>CangjieDocsSync<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Docs Sync" }))
map("n", "<localleader>jI", "<cmd>CangjieDocsInfo<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Docs Info" }))
map("n", "<localleader>jx", "<cmd>CangjieDocsDebug toggle<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Docs Debug" }))
map("n", "<localleader>jL", "<cmd>CangjieDocsDebugLog<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Docs Debug Log" }))
map("n", "<localleader>jS", "<cmd>CangjieDocsDebugInfo<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Docs Debug Snapshot" }))
map("n", "<localleader>jp", "<cmd>CangjiePerfMode status<cr>", vim.tbl_extend("force", opts, { desc = "Cangjie Perf Mode" }))
map("n", "<localleader>jP", "<cmd>CangjiePerfMode toggle<cr>", vim.tbl_extend("force", opts, { desc = "Toggle Cangjie Perf Mode" }))

local ok, wk = pcall(require, "which-key")
if ok then
    wk.add({
        { "<localleader>j", group = "Cangjie", buffer = 0 },
    })
end
-- vim.b.undo_ftplugin = (vim.b.undo_ftplugin or "") .. "|setl sw< ts< et<"
