-- ~/.config/nvim/lsp/cangjie.lua
local util = require("lspconfig.util") -- 只是借它的 root 工具函数，不会触发 lspconfig.configs

-- 解析 LSPServer 路径（优先环境变量）
local sdk = vim.env.CANGJIE_SDK_PATH or os.getenv("CANGJIE_SDK_PATH") or ""
local server = (sdk ~= "" and vim.fs.joinpath(sdk, "tools", "bin", "LSPServer")) or "LSPServer"

local capabilities = vim.lsp.protocol.make_client_capabilities()
pcall(function()
    capabilities = require("cmp_nvim_lsp").default_capabilities(capabilities)
end)

local function root_dir(fname)
    return util.root_pattern("cjpm.toml")(fname) or vim.fn.getcwd()
end

return {
    cmd = { server },
    filetypes = { "Cangjie" },
    root_markers = { "cjpm.toml", "main.cj", ".git" },
    root_dir = vim.fn.getcwd(),
    capabilities = capabilities,
    on_attach = function(client, bufnr)
        local ft = vim.bo[bufnr].filetype
        if ft == "cangjie" or ft == "Cangjie" then
            vim.notify(("Cangjie LSP 已启动 (id=%s)"):format(client.id), vim.log.levels.INFO, { title = "Cangjie" })
        end
    end,
}
