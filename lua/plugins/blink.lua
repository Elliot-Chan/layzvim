return {
    {
        "saghen/blink.cmp",
        optional = true,
        opts = function(_, opts)
            opts.sources = opts.sources or {}
            opts.sources.per_filetype = opts.sources.per_filetype or {}
            opts.sources.providers = opts.sources.providers or {}

            opts.sources.per_filetype.Cangjie = {
                inherit_defaults = true,
                "lsp",
                "buffer",
                "path",
                "snippets",
            }

            local lsp = opts.sources.providers.lsp or {}
            local original_lsp_fallbacks = lsp.fallbacks
            local original_lsp_override = lsp.override or {}
            lsp.min_keyword_length = function(ctx)
                if vim.bo[ctx.bufnr].filetype == "Cangjie" then
                    return 0
                end
                return 0
            end
            lsp.fallbacks = function(ctx, enabled_sources)
                if vim.bo[ctx.bufnr].filetype == "Cangjie" then
                    return { "buffer", "path" }
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
                        if vim.bo.filetype == "Cangjie" then
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

            local buffer = opts.sources.providers.buffer or {}
            buffer.min_keyword_length = function(ctx)
                if vim.bo[ctx.bufnr].filetype == "Cangjie" then
                    return 2
                end
                return 0
            end
            opts.sources.providers.buffer = buffer

            opts.completion = opts.completion or {}
            opts.completion.trigger = opts.completion.trigger or {}
            opts.completion.trigger.show_on_keyword = true
            opts.completion.trigger.show_on_trigger_character = true
            opts.completion.documentation = opts.completion.documentation or {}
            opts.completion.documentation.auto_show = true
            opts.completion.documentation.auto_show_delay_ms = 200
        end,
    },
}
