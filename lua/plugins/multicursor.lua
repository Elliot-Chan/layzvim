return {
    "jake-stewart/multicursor.nvim",
    branch = "1.0",

    config = function()
        local mc = require("multicursor-nvim")
        mc.setup()

        local wk = require("which-key")

        wk.add({
            -- 按行加 / 跳过光标
            {
                "<leader>Ck",
                function()
                    mc.lineAddCursor(-1)
                end,
                mode = { "n", "x" },
                desc = "MC add cursor above",
            },
            {
                "<leader>Cj",
                function()
                    mc.lineAddCursor(1)
                end,
                mode = { "n", "x" },
                desc = "MC add cursor below",
            },
            {
                "<leader>C<up>",
                function()
                    mc.lineSkipCursor(-1)
                end,
                mode = { "n", "x" },
                desc = "MC skip above",
            },
            {
                "<leader>C<down>",
                function()
                    mc.lineSkipCursor(1)
                end,
                mode = { "n", "x" },
                desc = "MC skip below",
            },

            -- 按匹配加 / 跳过光标
            {
                "<leader>Cn",
                function()
                    mc.matchAddCursor(1)
                end,
                mode = { "n", "x" },
                desc = "MC add next match",
            },
            {
                "<leader>Cs",
                function()
                    mc.matchSkipCursor(1)
                end,
                mode = { "n", "x" },
                desc = "MC skip next match",
            },
            {
                "<leader>CN",
                function()
                    mc.matchAddCursor(-1)
                end,
                mode = { "n", "x" },
                desc = "MC add prev match",
            },
            {
                "<leader>CS",
                function()
                    mc.matchSkipCursor(-1)
                end,
                mode = { "n", "x" },
                desc = "MC skip prev match",
            },
        })

        -- 下面这些你也可以顺手一起改成 wk.add（或者保持 keymap.set 也行）
        vim.keymap.set("n", "<c-leftmouse>", mc.handleMouse)
        vim.keymap.set("n", "<c-leftdrag>", mc.handleMouseDrag)
        vim.keymap.set("n", "<c-leftrelease>", mc.handleMouseRelease)

        vim.keymap.set({ "n", "x" }, "<c-q>", mc.toggleCursor)

        mc.addKeymapLayer(function(layerSet)
            layerSet({ "n", "x" }, "<left>", mc.prevCursor)
            layerSet({ "n", "x" }, "<right>", mc.nextCursor)
            layerSet({ "n", "x" }, "<leader>Cx", mc.deleteCursor)
            layerSet("n", "<esc>", function()
                if not mc.cursorsEnabled() then
                    mc.enableCursors()
                else
                    mc.clearCursors()
                end
            end)
        end)

        local hl = vim.api.nvim_set_hl
        hl(0, "MultiCursorCursor", { reverse = true })
        hl(0, "MultiCursorVisual", { link = "Visual" })
        hl(0, "MultiCursorSign", { link = "SignColumn" })
        hl(0, "MultiCursorMatchPreview", { link = "Search" })
        hl(0, "MultiCursorDisabledCursor", { reverse = true })
        hl(0, "MultiCursorDisabledVisual", { link = "Visual" })
        hl(0, "MultiCursorDisabledSign", { link = "SignColumn" })
    end,
}
