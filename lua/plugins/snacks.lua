return {
    {
        "folke/snacks.nvim",
        opts = function(_, opts)
            local cangjie_ignore = (_G.CangjiePerf and _G.CangjiePerf.ignore) or {}
            local function extend_exclude(source)
                source.exclude = source.exclude or {}
                for _, pattern in ipairs(cangjie_ignore) do
                    if not vim.tbl_contains(source.exclude, pattern) then
                        table.insert(source.exclude, pattern)
                    end
                end
            end

            opts.picker = opts.picker or {}
            opts.picker.sources = opts.picker.sources or {}
            opts.picker.sources.files = opts.picker.sources.files or {}
            opts.picker.sources.grep = opts.picker.sources.grep or {}
            opts.picker.sources.explorer = opts.picker.sources.explorer or {}
            opts.picker.sources.explorer.actions = opts.picker.sources.explorer.actions or {}
            opts.picker.sources.explorer.win = opts.picker.sources.explorer.win or {}
            opts.picker.sources.explorer.win.list = opts.picker.sources.explorer.win.list or {}
            opts.picker.sources.explorer.win.list.keys = opts.picker.sources.explorer.win.list.keys or {}

            extend_exclude(opts.picker.sources.files)
            extend_exclude(opts.picker.sources.grep)
            extend_exclude(opts.picker.sources.explorer)

            opts.picker.sources.explorer.actions.explorer_down = function(picker, item, action)
                if not item then
                    return
                elseif item.dir then
                    picker:set_cwd(item.file)
                    picker:find()
                else
                    require("snacks.explorer.actions").actions.confirm(picker, item, action)
                end
            end

            opts.picker.sources.explorer.win.list.keys["<BS>"] = "explorer_up"
            opts.picker.sources.explorer.win.list.keys["<Left>"] = "explorer_up"
            opts.picker.sources.explorer.win.list.keys["h"] = "explorer_close"
            opts.picker.sources.explorer.win.list.keys["l"] = "explorer_down"
            opts.picker.sources.explorer.win.list.keys["<Right>"] = "explorer_down"
            opts.picker.sources.explorer.win.list.keys["<CR>"] = "explorer_down"
            opts.picker.sources.explorer.win.list.keys["o"] = "explorer_down"
            opts.picker.sources.explorer.win.list.keys["gx"] = "explorer_open"
        end,
    },
}
