return {
    {
        "nvim-lualine/lualine.nvim",
        optional = true,
        opts = function(_, opts)
            opts.sections = opts.sections or {}
            opts.sections.lualine_x = opts.sections.lualine_x or {}

            local function diagnostics_state()
                return vim.diagnostic.is_enabled({ bufnr = 0 }) and "diag:on" or "diag:off"
            end

            local function format_state()
                return vim.g.auto_format == false and "fmt:off" or "fmt:on"
            end

            local function formatter_name()
                local ok, conform = pcall(require, "conform")
                if not ok then
                    return "fmt:none"
                end
                local formatters = conform.list_formatters_to_run(0)
                if #formatters == 0 then
                    return "fmt:none"
                end
                local formatter = formatters[1]
                return "fmt:" .. (formatter.name or formatter.id or "unknown")
            end

            local function lsp_count()
                return "lsp:" .. tostring(#vim.lsp.get_clients({ bufnr = 0 }))
            end

            local function codex_state()
                local ok, codex = pcall(require, "codex")
                if not ok then
                    return ""
                end
                return "codex:" .. codex.statusline()
            end

            table.insert(opts.sections.lualine_x, 1, diagnostics_state)
            table.insert(opts.sections.lualine_x, 2, format_state)
            table.insert(opts.sections.lualine_x, 3, formatter_name)
            table.insert(opts.sections.lualine_x, 4, lsp_count)
            table.insert(opts.sections.lualine_x, 5, codex_state)
        end,
    },
}
