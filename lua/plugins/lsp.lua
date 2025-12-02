local util = require("lspconfig.util")

return {
    "neovim/nvim-lspconfig",
    event = { "BufReadPost", "BufNewFile" },

    opts = {
        servers = {
            pyright = {},
            ruff = {},
            ruff_lsp = {},
            stylua = {},

            clangd = {
                cmd = { "clangd", "--background-index", "--clang-tidy" },
                filetypes = { "c", "cpp", "objc", "objcpp" },
                root_dir = function(fname)
                    return util.root_pattern("compile_commands.json", "compile_flags.txt", ".git")(fname) or vim.fn.getcwd()
                end,
            },

            copilot = {
                filetypes = { "c", "cpp", "lua", "python", "markdown", "Cangjie" },
                keys = {
                    {
                        "<leader>a]",
                        function()
                            vim.lsp.inline_completion.select({ count = 1 })
                        end,
                        desc = "Next Copilot Suggestion",
                        mode = { "i", "n" },
                    },
                    {
                        "<leader>a[",
                        function()
                            vim.lsp.inline_completion.select({ count = -1 })
                        end,
                        desc = "Prev Copilot Suggestion",
                        mode = { "i", "n" },
                    },
                },
            },

            -- 🔥 重点：ltex_plus 正确写在 opts.servers 下面
            ltex_plus = {
                filetypes = { "markdown", "gitcommit", "text" },
                settings = {
                    ltex = {
                        language = "zh-CN",
                        motherTongue = "zh-CN",
                        checkFrequency = "save",
                        enabled = { "markdown", "gitcommit", "text" },
                        diagnosticSeverity = "information",
                        additionalRules = {
                            enablePickyRules = true,
                            motherTongue = "zh-CN",
                        },
                        disabledRules = {
                            -- ["en-US"] = { "MORFOLOGIK_RULE_EN_US" },
                        },
                    },
                },
            },

            marksman = {},
        },

        setup = {
            -- 这里是改 marksman 的 handler，保持你原来的逻辑
            marksman = function(_, opts)
                opts.handlers = opts.handlers or {}
                opts.handlers["textDocument/publishDiagnostics"] = function() end
                return false
            end,
        },
    },
}
