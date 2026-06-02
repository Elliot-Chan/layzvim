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

local function append_unique(list, value)
    for _, item in ipairs(list) do
        if item == value then
            return list
        end
    end
    table.insert(list, value)
    return list
end

return {
    "mfussenegger/nvim-lint",
    opts = function(_, opts)
        opts = opts or {}
        opts.linters_by_ft = opts.linters_by_ft or {}
        opts.linters = opts.linters or {}

        local markdown_linters = opts.linters_by_ft.markdown or {}
        append_unique(markdown_linters, "markdownlint-cli2")
        append_unique(markdown_linters, "lint_md")
        opts.linters_by_ft.markdown = markdown_linters

        opts.linters.lint_md = {
            cmd = "bash",
            args = {
                "-lc",
                [[tmp=$(mktemp /tmp/nvim-lint-md.XXXXXX); "$0" -c "$1" "$2" >"$tmp" 2>&1; cat "$tmp"; rm -f "$tmp"; exit 0]],
                lint_md_cmd,
                lint_md_config,
                function()
                    return vim.api.nvim_buf_get_name(0)
                end,
            },
            stdin = false,
            append_fname = false,
            ignore_exitcode = true,
            stream = "stdout",
            condition = function(ctx)
                return lint_md_available() and vim.fn.filereadable(ctx.filename) == 1
            end,
            parser = require("lint.parser").from_pattern(
                "^%s*(%d+):(%d+)%s+(%w+)%s+(.-)%s+([%w%-]+)%s*$",
                { "lnum", "col", "severity", "message", "code" },
                {
                    error = vim.diagnostic.severity.ERROR,
                    warning = vim.diagnostic.severity.WARN,
                },
                { source = "lint-md" }
            ),
        }

        return opts
    end,
}
