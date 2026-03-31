local source = {}

local function append_completion_log(message)
    local ok, fd = pcall(io.open, "/tmp/cangjie_completion.log", "a")
    if not ok or not fd then
        return
    end
    fd:write(os.date("%H:%M:%S "), message, "\n")
    fd:close()
end

function source.new()
    return setmetatable({}, { __index = source })
end

function source:get_trigger_characters()
    return { "." }
end

function source:get_completions(_, callback)
    callback = vim.schedule_wrap(callback)
    append_completion_log(
        ("[docs_source] start ft=%s line=%s"):format(
            tostring(vim.bo.filetype),
            tostring(vim.api.nvim_get_current_line())
        )
    )

    if vim.bo.filetype ~= "Cangjie" then
        append_completion_log("[docs_source] skip non-cangjie")
        callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
        return
    end

    local ok, docs = pcall(require, "cangjie_docs_index")
    if not ok or not docs or type(docs.completion_items_for_current_context) ~= "function" then
        append_completion_log(
            ("[docs_source] docs_unavailable ok=%s has_fn=%s"):format(
                tostring(ok),
                tostring(ok and docs and type(docs.completion_items_for_current_context) == "function")
            )
        )
        callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
        return
    end

    local ok_items, items = pcall(docs.completion_items_for_current_context)
    if not ok_items or type(items) ~= "table" then
        append_completion_log(
            ("[docs_source] items_error ok=%s type=%s err=%s"):format(
                tostring(ok_items),
                tostring(type(items)),
                tostring(items)
            )
        )
        callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
        return
    end

    append_completion_log(("[docs_source] items=%d"):format(#items))
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
end

function source:resolve(item, callback)
    local ok, docs = pcall(require, "cangjie_docs_index")
    if not ok or not docs or type(docs.documentation_for_completion_item) ~= "function" then
        append_completion_log("[docs_source] resolve docs_unavailable")
        callback(item)
        return
    end

    local documentation, resolved_sym = docs.documentation_for_completion_item(item, { omit_signature = true })
    if not documentation then
        append_completion_log("[docs_source] resolve no_documentation")
        callback(item)
        return
    end

    local resolved_item = vim.deepcopy(item)
    resolved_item.documentation = documentation
    resolved_item.detail = nil
    append_completion_log(
        ("[docs_source] resolve documentation=%s"):format(
            tostring(resolved_sym and (resolved_sym.fqname or resolved_sym.id) or nil)
        )
    )
    callback(resolved_item)
end

return source
