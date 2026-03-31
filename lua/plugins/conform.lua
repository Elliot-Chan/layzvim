return {
    "stevearc/conform.nvim",
    opts = function(_, opts)
        opts = opts or {}
        opts.formatters = opts.formatters or {}
        opts.formatters_by_ft = opts.formatters_by_ft or {}

        -- 1) 解析 cjfmt 可执行路径：优先 CANGJIE_SDK_PATH/tools/bin/cjfmt，找不到就用 PATH 里的 cjfmt
        local sdk = vim.env.CANGJIE_SDK_PATH
        local cjfmt_cmd = (sdk and (sdk .. "/tools/bin/cjfmt")) or "cjfmt"

        -- 2) 语言 -> formatter 绑定（注意：这里不要再写 ["*"] = { "lsp" } 了）
        opts.formatters_by_ft = vim.tbl_deep_extend("force", opts.formatters_by_ft, {
            lua = { "stylua" },
            zsh = { "shfmt" },
            javascript = { "prettierd", "prettier" },
            typescript = { "prettierd", "prettier" },
            json = { "prettierd", "jq" },
            css = { "prettierd" },
            html = { "prettierd" },
            markdown = { "prettierd" },
            python = { "ruff_format", "black" },
            sh = { "shfmt" },
            yaml = { "yamlfmt", "prettierd" },
            toml = { "taplo" },
            c = { "clang_format" },
            cpp = { "clang_format" },
            go = { "gofumpt" },
            Cangjie = { "cangjiefmt" },
        })

        opts.lsp_format = "fallback"
        opts.notify_on_error = true

        opts.formatters = vim.tbl_deep_extend("force", opts.formatters, {
            stylua = {
                prepend_args = { "--syntax", "Lua52" },
            },

            cangjiefmt = {
                command = cjfmt_cmd,
                stdin = false,
                args = function(ctx)
                    local args = { "-f", "$FILENAME" }

                    local cfg = nil
                    if vim.fs and ctx and ctx.filename then
                        cfg = vim.fs.find({ "cangjie-format.toml", ".cangjie-format.toml" }, { upward = true, type = "file", path = vim.fs.dirname(ctx.filename) })[1]
                    end
                    if cfg then
                        vim.list_extend(args, { "-c", cfg })
                    end

                    if ctx.range then
                        local srow = ctx.range.start[1]
                        local erow = ctx.range["end"][1]
                        vim.list_extend(args, { "-l", string.format("%d:%d", srow, erow) })
                    end

                    -- 让 cjfmt 把结果写回临时文件
                    vim.list_extend(args, { "-o", "$FILENAME" })
                    return args
                end,
                exit_codes = { 0 },
            },
        })

        return opts
    end,
}
