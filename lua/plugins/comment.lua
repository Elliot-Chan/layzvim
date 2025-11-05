return {
    {
        "nvim-mini/mini.comment",
        event = "VeryLazy",
        opts = {
            mappings = {
                comment = "gc", -- 操作符
                comment_line = "gcc", -- 当前行
                textobject = "gc",
            },
            options = {
                pad_comment_part = true,
                -- 若用了 ts-context-commentstring，改成 custom_commentstring = function() ... end
            },
        },
    },
}
