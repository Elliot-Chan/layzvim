return {
    "folke/which-key.nvim",
    dependencies = {
        "nvim-mini/mini.icons", -- 依赖 mini.icons 插件
    },
    opts = function(_, opts)
        local wk = require("which-key")

        -- 给 <leader>x 新建一个层级
        wk.add({
            {
                "<leader>C",
                "Cursor", -- 新层级显示的名字
                icon = "I",
            },
        })
    end,
}
