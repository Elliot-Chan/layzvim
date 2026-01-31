return {
    "nvim-treesitter/nvim-treesitter",
    branch = "main", -- 将 master 改为 main
    lazy = false,
    opts = { ensure_installed = { "cangjie" } },
    config = function(_, opts)
        vim.api.nvim_create_autocmd("User", {
            pattern = "TSUpdate",
            callback = function()
                require("nvim-treesitter.parsers").cangjie = {
                    install_info = {
                        -- path = "~/temp/tree-sitter-cangjie",
                        path = "~/playground/treesitter",
                        generate = true,
                    },
                }
                vim.treesitter.language.register("cangjie", "Cangjie")
                vim.treesitter.language.register("cangjie", "cangjie")

                local function L(name, target)
                    vim.api.nvim_set_hl(0, name, { link = target })
                end
                L("@keyword", "Keyword")
                L("@keyword.return", "Keyword")
                L("@keyword.operator", "Keyword")
                L("@type", "Type")
                L("@type.builtin", "Type")
                L("@function", "Function")
                L("@function.macro", "Macro")
                L("@property", "Identifier")
                L("@field", "Identifier")
                L("@variable", "Identifier")
                L("@variable.parameter", "Identifier")
                L("@constant", "Constant")
                L("@number", "Number")
                L("@string", "String")
                L("@character", "Character")
                L("@boolean", "Boolean")
                L("@comment", "Comment")
                L("@operator", "Operator")
                L("@punctuation.delimiter", "Delimiter")
                L("@punctuation.bracket", "Delimiter")
            end,
        })
    end,

    -- vim.api.nvim_create_autocmd("FileType", {
    -- pattern = { "Cangjie" },
    -- callback = function(args)
    -- vim.treesitter.start(args.buf, "Cangjie")
    -- end,
    -- }),
}
