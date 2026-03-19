return {
    {
        "luckasRanarison/nvim-devdocs",
        dependencies = {
            "nvim-lua/plenary.nvim",
            "nvim-telescope/telescope.nvim",
            "nvim-treesitter/nvim-treesitter",
        },
        cmd = {
            "DevdocsFetch",
            "DevdocsInstall",
            "DevdocsUninstall",
            "DevdocsOpen",
            "DevdocsOpenFloat",
            "DevdocsOpenCurrent",
            "DevdocsOpenCurrentFloat",
            "DevdocsToggle",
            "DevdocsUpdate",
            "DevdocsUpdateAll",
        },
        keys = {
            { "<leader>dd", "<cmd>DevdocsOpenCurrentFloat<cr>", desc = "Open Current Docs" },
            { "<leader>dD", "<cmd>DevdocsOpen<cr>", desc = "Search Docs" },
            { "<leader>do", "<cmd>DevdocsOpenCurrent<cr>", desc = "Open Current Docs Buffer" },
            { "<leader>di", "<cmd>DevdocsInstall<cr>", desc = "Install Docs" },
            { "<leader>du", "<cmd>DevdocsUpdateAll<cr>", desc = "Update Docs" },
            { "<leader>df", "<cmd>DevdocsFetch<cr>", desc = "Fetch Doc Index" },
        },
        opts = {
            wrap = true,
            float_win = {
                relative = "editor",
                height = 28,
                width = 110,
                border = "rounded",
            },
            filetypes = {
                sh = "bash",
                zsh = "bash",
            },
            after_open = function(bufnr)
                vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = bufnr, silent = true })
                vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = bufnr, silent = true })
            end,
        },
    },
}
