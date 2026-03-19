return {
    {
        "anirudhsundar/codex.nvim",
        keys = {
            {
                "<leader>aa",
                function()
                    require("codex").ask()
                end,
                desc = "Ask Codex",
                mode = { "n", "x" },
            },
            {
                "<leader>aA",
                function()
                    require("codex").ask("@this: ", { submit = true })
                end,
                desc = "Ask About This",
                mode = { "n", "x" },
            },
            {
                "<leader>as",
                function()
                    require("codex").select()
                end,
                desc = "Select Action",
            },
            {
                "<leader>at",
                function()
                    require("codex").toggle()
                end,
                desc = "Toggle Session",
            },
            {
                "<leader>ad",
                function()
                    require("codex").toggle_output_details()
                end,
                desc = "Toggle Output Details",
            },
            {
                "<leader>an",
                function()
                    require("codex").command("thread.new")
                end,
                desc = "New Thread",
            },
            {
                "<leader>ai",
                function()
                    require("codex").command("turn.interrupt")
                end,
                desc = "Interrupt Turn",
            },
        },
        init = function()
            vim.o.autoread = true

            ---@type codex.Opts
            vim.g.codex_opts = vim.tbl_deep_extend("force", vim.g.codex_opts or {}, {
                ask = {
                    prompt = "Codex: ",
                },
                output = {
                    auto_open = true,
                    width = math.max(48, math.floor(vim.o.columns * 0.35)),
                    show_details = false,
                    append_history = true,
                },
                prompts = {
                    review = {
                        prompt = "Review @this for correctness, regressions, and missing tests.",
                        submit = true,
                    },
                    fix = {
                        prompt = "Fix @diagnostics in @this with minimal changes.",
                        submit = true,
                    },
                },
            })
        end,
    },
}
