local util = require("lspconfig.util")

return {
    "neovim/nvim-lspconfig",
    event = { "BufReadPost", "BufNewFile" },
    servers = {
        pyright = {},
        ruff = {},
        ruff_lsp = {},
        clangd = {
            cmd = { "clangd", "--background-index", "--clang-tidy" },
            filetypes = { "c", "cpp", "objc", "objcpp" },
            root_dir = function(fname)
                return util.root_pattern("compile_commands.json", "compile_flags.txt", ".git")(fname) or vim.fn.getcwd()
            end,
        },

        copilot = {
            filetypes = { "c", "cpp", "lua", "python", "Cangjie" },
        },
    },
}
