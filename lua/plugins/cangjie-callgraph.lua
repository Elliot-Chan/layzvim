return {
    {
        dir = "/home/elliot/Code/cangjie-callgraph.nvim",
        name = "cangjie-callgraph.nvim",
        ft = { "Cangjie", "cangjie" },
        cmd = { "CangjieCallGraph", "CangjieCallGraphPreview", "CangjieCallGraphDebug" },
        keys = {
            { "<leader>cg", "<cmd>CangjieCallGraph<cr>", desc = "Cangjie Call Graph" },
            { "<leader>cP", "<cmd>CangjieCallGraphPreview<cr>", desc = "Cangjie Call Graph Preview" },
            { "<leader>cG", "<cmd>CangjieCallGraphDebug<cr>", desc = "Cangjie Call Graph Debug" },
        },
        opts = {
            backend = "auto",
            view = "mermaid",
            preview = "buffer",
            image_viewer_cmd = "swayimg",
            image_viewer_args = { "--class", "cangjie-callgraph-preview", "--viewer", "--size", "1400,900" },
            image_viewer_scroll_center = true,
            image_viewer_scroll_match = '[app_id="cangjie-callgraph-preview"]',
            image_viewer_scroll_command = "resize set 1400 900, move position center",
            mermaid_scale = 3,
            depth = 2,
            max_nodes = 80,
            max_files = 2000,
            open_cmd = "vsplit",
        },
    },
}
