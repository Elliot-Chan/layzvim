return {
    {
        "SmiteshP/nvim-navic",
        opts = function()
            Snacks.util.lsp.on({ method = "textDocument/documentSymbol" }, function(buffer, client)
                require("nvim-navic").attach(client, buffer)
            end)
            return {
                separator = " ",
                highlight = true,
                depth_limit = 5,
                icons = LazyVim.config.icons.kinds,
                lazy_update_context = true,
            }
        end,
    },
    {
        "nvim-lualine/lualine.nvim",
        optional = true,
        opts = function(_, opts)
            local navic = require("nvim-navic")
            opts.sections = opts.sections or {}
            opts.sections.lualine_c = opts.sections.lualine_c or {}
            table.insert(opts.sections.lualine_c, {
                function()
                    return navic.is_available() and navic.get_location() or ""
                end,
                cond = function()
                    return package.loaded["nvim-navic"]
                end,
            })
        end,
    },
}
