vim.filetype.add({
    extension = {
        cj = "Cangjie",
        CJ = "Cangjie",
    },
})
vim.treesitter.language.register("cangjie", "Cangjie")
vim.api.nvim_create_autocmd("FileType", {
    pattern = { "Cangjie" },
    callback = function(args)
        vim.bo[args.buf].filetype = "Cangjie"
        vim.bo[args.buf].commentstring = "/* %s */"
        vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"

        vim.bo.comments = "s1:/**,mb:*,ex:*/,://"
        -- 开启注释智能换行与自动续行星号
        vim.bo.formatoptions = (vim.bo.formatoptions or "") .. "cro"
        vim.treesitter.start(args.buf, "cangjie")
        -- c: 以注释方式自动换行
        -- r: 回车续注释前缀
        -- o: 用 o/O 新起一行续注释
    end,
})
