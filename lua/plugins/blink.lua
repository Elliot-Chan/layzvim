return {
    {
        "saghen/blink.cmp",
        optional = true,
        opts = function(_, opts)
            local function cangjie_docs_active(bufnr)
                bufnr = bufnr or vim.api.nvim_get_current_buf()
                return vim.g.cangjie_completion_docs == true or vim.b[bufnr].cangjie_completion_docs_manual == true
            end

            local function is_cangjie_ctx(ctx)
                local bufnr = ctx and ctx.bufnr
                if type(bufnr) ~= "number" or bufnr == 0 then
                    bufnr = vim.api.nvim_get_current_buf()
                end
                return vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "Cangjie"
            end

            if not vim.g.cangjie_blink_docs_guard then
                vim.g.cangjie_blink_docs_guard = true
                vim.schedule(function()
                    local ok_docs, docs = pcall(require, "blink.cmp.completion.windows.documentation")
                    local ok_sources, sources = pcall(require, "blink.cmp.sources.lib")
                    local ok_menu, menu = pcall(require, "blink.cmp.completion.windows.menu")
                    if ok_docs and ok_sources and ok_menu and docs and sources and menu and type(docs.show_item) == "function" then
                        docs.show_item = function(context, item)
                            local bufnr = context and context.bufnr or vim.api.nvim_get_current_buf()
                            if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "Cangjie" and not cangjie_docs_active(bufnr) then
                                return docs.close()
                            end
                            docs.auto_show_timer:stop()
                            if item == nil or not menu.win:is_open() then
                                if vim.api.nvim_buf_is_valid(bufnr) then
                                    vim.b[bufnr].cangjie_completion_docs_manual = false
                                end
                                return docs.close()
                            end

                            sources
                                .resolve(context, item)
                                :map(function(resolved_item)
                                    if resolved_item == nil then
                                        docs.close()
                                        return
                                    end
                                    if resolved_item.documentation == nil and resolved_item.detail == nil then
                                        docs.close()
                                        return
                                    end

                                    if docs.shown_item ~= resolved_item then
                                        local docs_buf = docs.win:get_buf()
                                        local default_render_opts = {
                                            bufnr = docs_buf,
                                            detail = resolved_item.detail,
                                            documentation = resolved_item.documentation,
                                            max_width = docs.win.config.max_width,
                                            use_treesitter_highlighting = require("blink.cmp.config").completion.documentation.treesitter_highlighting,
                                        }
                                        local default_impl = function(render_opts)
                                            require("blink.cmp.lib.window.docs").render_detail_and_documentation(
                                                vim.tbl_extend("force", default_render_opts, render_opts or {})
                                            )
                                        end

                                        local draw = resolved_item.documentation and resolved_item.documentation.draw
                                            or require("blink.cmp.config").completion.documentation.draw
                                        vim.api.nvim_set_option_value("modifiable", true, { buf = docs_buf })
                                        draw({
                                            item = resolved_item,
                                            window = docs.win,
                                            config = require("blink.cmp.config").completion.documentation,
                                            default_implementation = default_impl,
                                        })
                                        vim.api.nvim_set_option_value("modifiable", false, { buf = docs_buf })
                                    end
                                    docs.shown_item = resolved_item

                                    if menu.win:get_win() then
                                        docs.win:open()
                                        docs.win:set_cursor({ 1, 0 })
                                        docs.update_position()
                                    end
                                end)
                                :catch(function()
                                    docs.close()
                                end)
                        end
                    end
                end)
            end

            opts.sources = opts.sources or {}
            opts.sources.per_filetype = opts.sources.per_filetype or {}
            opts.sources.providers = opts.sources.providers or {}

            local cangjie_sources = {
                inherit_defaults = true,
                "lsp",
                "buffer",
                "path",
                "snippets",
            }
            if vim.g.cangjie_completion_docs == true then
                table.insert(cangjie_sources, 2, "cangjie_docs")
            end
            opts.sources.per_filetype.Cangjie = cangjie_sources

            local lsp = opts.sources.providers.lsp or {}
            local original_lsp_fallbacks = lsp.fallbacks
            local original_lsp_override = lsp.override or {}
            lsp.min_keyword_length = function(ctx)
                if ctx.trigger and ctx.trigger.initial_kind == "manual" then
                    return 0
                end
                if is_cangjie_ctx(ctx) then
                    return 2
                end
                return 0
            end
            lsp.async = function(ctx)
                if is_cangjie_ctx(ctx) then
                    return true
                end
                return false
            end
            lsp.timeout_ms = function(ctx)
                if is_cangjie_ctx(ctx) then
                    return 80
                end
                return 2000
            end
            lsp.fallbacks = function(ctx, enabled_sources)
                if is_cangjie_ctx(ctx) then
                    return {}
                end
                if type(original_lsp_fallbacks) == "function" then
                    return original_lsp_fallbacks(ctx, enabled_sources)
                end
                return original_lsp_fallbacks or { "buffer" }
            end
            lsp.override = vim.tbl_extend("force", original_lsp_override, {
                resolve = function(self, item, callback)
                    return self:resolve(item, function(resolved_item)
                        resolved_item = resolved_item or item
                        local bufnr = vim.api.nvim_get_current_buf()
                        if vim.bo.filetype == "Cangjie" and cangjie_docs_active(bufnr) then
                            local docs = assert(dofile(vim.fn.stdpath("config") .. "/lua/cangjie_docs_index.lua"))
                            local matched_sym = docs.find_symbol_for_completion_item(resolved_item)
                            if matched_sym then
                                resolved_item = vim.deepcopy(resolved_item)
                                resolved_item.data = vim.tbl_extend("force", resolved_item.data or {}, {
                                    docs_index_id = matched_sym.id,
                                    docs_index_fqname = matched_sym.fqname,
                                })
                                if not resolved_item.detail then
                                    resolved_item.detail = matched_sym.signature_short
                                        or matched_sym.signature
                                        or matched_sym.fqname
                                        or matched_sym.display
                                end
                            end
                            local documentation, resolved_sym = docs.documentation_for_completion_item(resolved_item)
                            if documentation then
                                resolved_item = vim.deepcopy(resolved_item)
                                resolved_item.documentation = documentation
                                if not resolved_item.detail and resolved_sym then
                                    resolved_item.detail = resolved_sym.signature_short
                                        or resolved_sym.signature
                                        or resolved_sym.fqname
                                        or resolved_sym.display
                                end
                            end
                        end
                        callback(resolved_item)
                    end)
                end,
            })
            opts.sources.providers.lsp = lsp

            opts.sources.providers.cangjie_docs = {
                name = "Cangjie Docs",
                module = "cangjie_blink_source",
                enabled = function()
                    return vim.bo.filetype == "Cangjie"
                end,
                score_offset = -1,
            }

            local buffer = opts.sources.providers.buffer or {}
            buffer.min_keyword_length = function(ctx)
                if ctx.trigger and ctx.trigger.initial_kind == "manual" then
                    return 0
                end
                if is_cangjie_ctx(ctx) then
                    return 4
                end
                return 0
            end
            opts.sources.providers.buffer = buffer

            local path = opts.sources.providers.path or {}
            path.min_keyword_length = function(ctx)
                if ctx.trigger and ctx.trigger.initial_kind == "manual" then
                    return 0
                end
                if is_cangjie_ctx(ctx) then
                    return 99
                end
                return 0
            end
            opts.sources.providers.path = path

            local snippets = opts.sources.providers.snippets or {}
            snippets.min_keyword_length = function(ctx)
                if ctx.trigger and ctx.trigger.initial_kind == "manual" then
                    return 0
                end
                if is_cangjie_ctx(ctx) then
                    return 99
                end
                return 0
            end
            opts.sources.providers.snippets = snippets

            opts.completion = opts.completion or {}
            opts.completion.trigger = opts.completion.trigger or {}
            opts.completion.trigger.show_on_keyword = true
            opts.completion.trigger.show_on_trigger_character = true
            opts.completion.trigger.show_on_blocked_trigger_characters = function(ctx)
                local blocked = { " ", "\n", "\t" }
                if is_cangjie_ctx(ctx) then
                    blocked[#blocked + 1] = "."
                    blocked[#blocked + 1] = "("
                    blocked[#blocked + 1] = ":"
                end
                return blocked
            end
            opts.completion.menu = opts.completion.menu or {}
            opts.completion.menu.auto_show_delay_ms = function(ctx, _)
                if is_cangjie_ctx(ctx) then
                    return 120
                end
                return 0
            end
            opts.completion.documentation = opts.completion.documentation or {}
            opts.completion.documentation.auto_show = true
            opts.completion.documentation.auto_show_delay_ms = 200
        end,
    },
}
