return {
    {
        "SmiteshP/nvim-navic",
        opts = function()
            Snacks.util.lsp.on({ method = "textDocument/documentSymbol" }, function(buffer, client)
                if vim.bo[buffer].filetype == "Cangjie" and _G.CangjiePerf and _G.CangjiePerf.enabled(buffer) then
                    return
                end
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
                    if _G.CangjiePerf and _G.CangjiePerf.enabled(0) then
                        return ""
                    end
                    return navic.is_available() and navic.get_location() or ""
                end,
                cond = function()
                    return package.loaded["nvim-navic"] and not (_G.CangjiePerf and _G.CangjiePerf.enabled(0))
                end,
            })
        end,
    },
}
