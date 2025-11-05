return {
    "stevearc/conform.nvim",
    opts = function(_, opts)
        opts = opts or {}
        opts.formatters = opts.formatters or {}
        opts.formatters_by_ft = opts.formatters_by_ft or {}

        -- 1) 解析 cjfmt 可执行路径：优先 CANGJIE_SDK_PATH/tools/bin/cjfmt，找不到就用 PATH 里的 cjfmt
        local sdk = vim.env.CANGJIE_SDK_PATH
        local cjfmt_cmd = (sdk and (sdk .. "/tools/bin/cjfmt")) or "cjfmt"

        opts.formatters_by_ft = vim.tbl_deep_extend("force", opts.formatters_by_ft or {}, {
            lua = { "stylua" },
            javascript = { "prettierd", "prettier" },
            typescript = { "prettierd", "prettier" },
            json = { "prettierd", "jq" },
            css = { "prettierd" },
            html = { "prettierd" },
            markdown = { "prettierd" },
            python = { "ruff_format", "black" }, -- 用 ruff_format 或 black
            sh = { "shfmt" },
            yaml = { "yamlfmt", "prettierd" },
            toml = { "taplo" },
            c = { "clang_format" },
            cpp = { "clang_format" },
            go = { "gofumpt" }, -- 或 "gofmt"
            cangjie = { "cjfmt" },
            ["*"] = { "lsp" },
        })
        -- 2) 自定义 formatter：使用临时文件，-f 读同一个临时文件，-o 再写回同一个临时文件
        opts.formatters.cangjiefmt = {
            command = cjfmt_cmd,
            stdin = false,
            args = function(ctx)
                local args = { "-f", "$FILENAME" }

                -- 如果项目里有专用配置，自动带上 -c
                local cfg = nil
                if vim.fs and ctx and ctx.filename then
                    cfg = vim.fs.find({ "cangjie-format.toml", "cangjie.toml", ".cangjie-format.toml" }, { upward = true, type = "file", path = vim.fs.dirname(ctx.filename) })[1]
                end
                if cfg then
                    vim.list_extend(args, { "-c", cfg })
                end

                -- 选区格式化：Conform 会把可视选区传进来（行号从 1 开始），cjfmt 需要 -l start:end
                if ctx.range then
                    local srow = ctx.range.start[1]
                    local erow = ctx.range["end"][1]
                    vim.list_extend(args, { "-l", string.format("%d:%d", srow, erow) })
                end

                -- 让 cjfmt 把结果“写回同一个临时文件”
                vim.list_extend(args, { "-o", "$FILENAME" })
                return args
            end,
            exit_codes = { 0 },
        }

        -- 3) 把 Cangjie 绑定到我们的 cangjiefmt（不走 LSP 回退，避免风格漂移）
        opts.formatters_by_ft.Cangjie = { "cangjiefmt" }
        opts.formatters_by_ft.cangjie = { "cangjiefmt" }

        -- 只对 Cangjie 禁掉 LSP fallback；其他语言保持你原来的策略
        -- local orig = opts.format_on_save
        -- opts.format_on_save = function(bufnr)
        --     local ft = vim.bo[bufnr].filetype
        --     if ft == "Cangjie" or ft == "cangjie" then
        --         return { timeout_ms = 6000, lsp_fallback = false }
        --     end
        --     return type(orig) == "function" and orig(bufnr) or { timeout_ms = 6000, lsp_fallback = true }
        -- end
        --
        return opts
    end,
}
