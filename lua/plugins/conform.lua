return {
    "stevearc/conform.nvim",
    opts = function(_, opts)
        opts = opts or {}
        opts.formatters = opts.formatters or {}
        opts.formatters_by_ft = opts.formatters_by_ft or {}

        local function markdown_check_ci_root()
            return vim.env.MARKDOWN_CHECK_CI_ROOT or "/home/elliot/Code/cangjie-ci"
        end

        local function lint_md_config()
            return markdown_check_ci_root() .. "/scripts/cangjie/pipeline/markdownlint/conf/lint_md_config.json"
        end

        local function lint_md_cmd()
            local cmd = vim.fn.exepath("lint-md")
            if cmd ~= "" then
                return cmd
            end
            if vim.fn.executable("/usr/bin/lint-md") == 1 then
                return "/usr/bin/lint-md"
            end
            return "lint-md"
        end

        local function lint_md_available()
            return (vim.fn.executable(lint_md_cmd()) == 1) and (vim.fn.filereadable(lint_md_config()) == 1)
        end

        -- 1) 解析 cjfmt 可执行路径：优先 CANGJIE_SDK_PATH/tools/bin/cjfmt，找不到就用 PATH 里的 cjfmt
        local sdk = vim.env.CANGJIE_SDK_PATH
        local cjfmt_cmd = (sdk and (sdk .. "/tools/bin/cjfmt")) or "cjfmt"

        local function git_root(filename)
            if not filename or filename == "" then
                return nil
            end
            local git_dir = vim.fs.find(".git", { path = vim.fs.dirname(filename), upward = true })[1]
            return git_dir and vim.fs.dirname(git_dir) or nil
        end

        local function relative_path(root, filename)
            root = vim.fs.normalize(root)
            filename = vim.fs.normalize(filename)
            if filename:sub(1, #root + 1) == root .. "/" then
                return filename:sub(#root + 2)
            end
            return vim.fn.fnamemodify(filename, ":t")
        end

        local function git_head_text(filename)
            local root = git_root(filename)
            if not root then
                return ""
            end

            local result = vim.system({ "git", "-C", root, "show", "--textconv", "HEAD:" .. relative_path(root, filename) }, { text = true }):wait()
            if result.code == 0 then
                return result.stdout or ""
            end
            return ""
        end

        local function buffer_text(bufnr)
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local text = table.concat(lines, "\n")
            if vim.bo[bufnr].eol then
                text = text .. "\n"
            end
            return text
        end

        local function merge_ranges(ranges)
            table.sort(ranges, function(a, b)
                return a.start < b.start
            end)

            local merged = {}
            for _, range in ipairs(ranges) do
                local previous = merged[#merged]
                if previous and range.start <= previous.finish + 1 then
                    previous.finish = math.max(previous.finish, range.finish)
                else
                    table.insert(merged, range)
                end
            end
            return merged
        end

        local function modified_cangjie_ranges(bufnr)
            local filename = vim.api.nvim_buf_get_name(bufnr)
            local line_count = vim.api.nvim_buf_line_count(bufnr)
            local indices = vim.diff(git_head_text(filename), buffer_text(bufnr), {
                result_type = "indices",
                algorithm = "histogram",
                ctxlen = 0,
            }) or {}
            local ranges = {}

            for _, item in ipairs(indices) do
                local start = item[3]
                local count = item[4]
                if count > 0 then
                    table.insert(ranges, {
                        start = math.max(1, start),
                        finish = math.min(line_count, start + count - 1),
                    })
                end
            end

            return merge_ranges(ranges)
        end

        local function explicit_range(ctx)
            if not ctx.range then
                return nil
            end
            return {
                {
                    start = ctx.range.start[1],
                    finish = ctx.range["end"][1],
                },
            }
        end

        local function cangjie_format_scope(bufnr)
            local scope = vim.b[bufnr].cangjie_format_scope or vim.g.cangjie_format_scope
            return scope == "file" and "file" or "changed"
        end

        local function cangjie_format_config(ctx)
            local cfg = nil
            if vim.fs and ctx and ctx.filename then
                cfg = vim.fs.find({ "cangjie-format.toml", ".cangjie-format.toml" }, { upward = true, type = "file", path = vim.fs.dirname(ctx.filename) })[1]
            end
            return cfg or ""
        end

        local cangjie_format_script = table.concat({
            "mode=$1",
            "fmt=$2",
            "cfg=$3",
            "file=$4",
            "shift 4",
            "run_cjfmt() {",
            '  if [ -n "$cfg" ]; then',
            '    "$fmt" -f "$file" -c "$cfg" "$@" -o "$file"',
            "  else",
            '    "$fmt" -f "$file" "$@" -o "$file"',
            "  fi",
            "}",
            'if [ "$mode" = "file" ]; then',
            "  run_cjfmt",
            "  exit $?",
            "fi",
            "[ $# -eq 0 ] && exit 0",
            'for range in "$@"; do',
            '  run_cjfmt -l "$range" || exit $?',
            "done",
        }, "\n")

        local function cangjie_format_args(ctx, mode, ranges)
            mode = mode or cangjie_format_scope(ctx.buf)
            if mode == "changed" then
                ranges = ranges or modified_cangjie_ranges(ctx.buf)
            elseif mode == "range" then
                ranges = ranges or {}
            else
                ranges = {}
            end

            table.sort(ranges, function(a, b)
                return a.start > b.start
            end)

            local args = {
                "-lc",
                cangjie_format_script,
                "cangjiefmt",
                mode,
                cjfmt_cmd,
                cangjie_format_config(ctx),
                "$FILENAME",
            }
            for _, range in ipairs(ranges) do
                table.insert(args, string.format("%d:%d", range.start, range.finish))
            end
            return args
        end

        -- 2) 语言 -> formatter 绑定（注意：这里不要再写 ["*"] = { "lsp" } 了）
        opts.formatters_by_ft = vim.tbl_deep_extend("force", opts.formatters_by_ft, {
            lua = { "stylua" },
            zsh = { "shfmt" },
            javascript = { "prettierd", "prettier" },
            typescript = { "prettierd", "prettier" },
            json = { "prettierd", "jq" },
            css = { "prettierd" },
            html = { "prettierd" },
            markdown = { "prettierd", "lint_md" },
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

            lint_md = {
                command = lint_md_cmd,
                args = function()
                    return { "-c", lint_md_config(), "--fix", "$FILENAME" }
                end,
                stdin = false,
                exit_codes = { 0 },
                condition = function()
                    return lint_md_available()
                end,
            },

            cangjiefmt = {
                command = "bash",
                stdin = false,
                args = function(_, ctx)
                    return cangjie_format_args(ctx)
                end,
                range_args = function(_, ctx)
                    return cangjie_format_args(ctx, "range", explicit_range(ctx))
                end,
                condition = function()
                    return vim.fn.executable("bash") == 1 and vim.fn.executable(cjfmt_cmd) == 1
                end,
                exit_codes = { 0 },
            },
        })

        return opts
    end,
}
