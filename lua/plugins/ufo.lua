return {
    "kevinhwang91/nvim-ufo",
    dependencies = {
        "kevinhwang91/promise-async",
    },
    opts = {
        provider_selector = function(bufnr, filetype, buftype)
            if filetype == "markdown" then
                -- markdown 用 Tree-sitter（有 folds.scm），不够时回退 indent
                return { "treesitter", "indent" }
            end
            -- 其他文件按 LazyVim 默认（通常 lsp/indent）
            return { "lsp", "indent" }
        end,
    },
}
