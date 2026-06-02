return {
    "nvim-treesitter/nvim-treesitter-context",
    opts = {
        enable = true,
        line_numbers = false,
        mode = "cursor",
        separator = nil,
        on_attach = function(bufnr)
            return not (vim.bo[bufnr].filetype == "Cangjie" and _G.CangjiePerf and _G.CangjiePerf.enabled(bufnr))
        end,
    },
}
