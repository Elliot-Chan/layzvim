-- ~/.config/nvim/lsp/cangjie.lua
local util = require("lspconfig.util")

local sdk = vim.env.CANGJIE_SDK_PATH or os.getenv("CANGJIE_SDK_PATH") or ""
local server = (sdk ~= "" and vim.fs.joinpath(sdk, "tools", "bin", "LSPServer")) or "LSPServer"

local function make_capabilities()
    local capabilities = vim.lsp.protocol.make_client_capabilities()

    local ok_blink, blink = pcall(require, "blink.cmp")
    if ok_blink and blink and blink.get_lsp_capabilities then
        return blink.get_lsp_capabilities(capabilities)
    end

    local ok_cmp, cmp = pcall(require, "cmp_nvim_lsp")
    if ok_cmp and cmp and cmp.default_capabilities then
        return cmp.default_capabilities(capabilities)
    end

    return capabilities
end

local capabilities = make_capabilities()

local ignore_codes = {
    [162] = true,
    [463] = true,
    [751] = true,
    [753] = true,
    [781] = true,
}

local function get_docs_index()
    return assert(dofile(vim.fn.stdpath("config") .. "/lua/cangjie_docs_index.lua"))
end

local function trim_text(value)
    if type(value) ~= "string" then
        return nil
    end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or nil
end

local function sanitize_lookup_type_name(type_name)
    type_name = trim_text(type_name)
    if not type_name then
        return nil
    end
    type_name = type_name:gsub("[`%s]", "")
    type_name = type_name:gsub("<.*>$", "")
    type_name = type_name:gsub("[%?%!%[%]]+$", "")
    type_name = type_name:match("([%w_%.]+)$") or type_name
    return type_name ~= "" and type_name or nil
end

local function inferred_inner_type(type_name)
    type_name = trim_text(type_name)
    if not type_name then
        return nil
    end
    local option_inner = type_name:match("^%??Option%s*<%s*(.+)%s*>$")
    if option_inner and option_inner ~= "" then
        return trim_text(option_inner)
    end
    local nullable_inner = type_name:match("^%?%s*(.+)$")
    if nullable_inner and nullable_inner ~= "" then
        return trim_text(nullable_inner)
    end
    return nil
end

local function inferred_desugared_type(type_name)
    type_name = trim_text(type_name)
    if not type_name then
        return nil
    end
    local nullable_inner = type_name:match("^%?%s*(.+)$")
    if nullable_inner and nullable_inner ~= "" then
        return ("Option<%s>"):format(trim_text(nullable_inner) or nullable_inner)
    end
    return nil
end

local function is_decorated_inferred_type(type_name, base_type)
    type_name = trim_text(type_name)
    base_type = trim_text(base_type)
    if not type_name or not base_type then
        return false
    end
    if type_name ~= base_type then
        return true
    end
    return false
end

local function append_debug_log(message)
    local docs = get_docs_index()
    if not docs.debug_enabled or not docs.debug_enabled() then
        return
    end
    local ok, fd = pcall(io.open, "/tmp/cangjie_docs.log", "a")
    if not ok or not fd then
        return
    end
    fd:write(os.date("%H:%M:%S "), message, "\n")
    fd:close()
end

local function append_rename_log(message)
    local ok, fd = pcall(io.open, "/tmp/cangjie_rename.log", "a")
    if not ok or not fd then
        return
    end
    fd:write(os.date("%H:%M:%S "), message, "\n")
    fd:close()
end

local function append_hierarchy_log(message)
    local ok, fd = pcall(io.open, "/tmp/cangjie_hierarchy.log", "a")
    if not ok or not fd then
        return
    end
    fd:write(os.date("%H:%M:%S "), message, "\n")
    fd:close()
end

local function append_completion_log(message)
    local ok, fd = pcall(io.open, "/tmp/cangjie_completion.log", "a")
    if not ok or not fd then
        return
    end
    fd:write(os.date("%H:%M:%S "), message, "\n")
    fd:close()
end

local function get_blink()
    local ok, blink = pcall(require, "blink.cmp")
    if ok and blink then
        return blink
    end
end

local function ensure_cangjie_blink_signature_guard()
    if vim.g.cangjie_blink_signature_guard then
        return
    end

    local ok, trigger = pcall(require, "blink.cmp.signature.trigger")
    if not ok or not trigger then
        return
    end

    vim.g.cangjie_blink_signature_guard = true

    local original_show = trigger.show
    local original_show_if = trigger.show_if_on_trigger_character

    if type(original_show) == "function" then
        trigger.show = function(opts)
            if vim.bo.filetype == "Cangjie" and not (type(opts) == "table" and opts.force) then
                append_completion_log("[signature_guard] skip trigger.show for Cangjie")
                return
            end
            return original_show(opts)
        end
    end

    if type(original_show_if) == "function" then
        trigger.show_if_on_trigger_character = function(...)
            if vim.bo.filetype == "Cangjie" then
                append_completion_log("[signature_guard] skip show_if_on_trigger_character for Cangjie")
                return
            end
            return original_show_if(...)
        end
    end
end

local function get_telescope_builtin()
    local ok, builtin = pcall(require, "telescope.builtin")
    if ok and builtin then
        return builtin
    end
end

local function set_qflist_from_locations(title, items)
    vim.fn.setqflist({}, " ", {
        title = title,
        items = items,
    })
    vim.cmd("copen")
end

local function pseudo_inlay_hints()
    return require("cangjie_inlay_hints")
end

local function inlay_hints_api()
    return vim.lsp.inlay_hint
end

local function client_supports_inlay_hints(client, bufnr)
    local ih = inlay_hints_api()
    if not ih or not client then
        return false
    end
    return client.supports_method and client.supports_method("textDocument/inlayHint", bufnr)
end

local function cangjie_inlay_enabled()
    return vim.g.cangjie_inlay_hints ~= false
end

local function cangjie_inlay_hide_in_insert()
    return vim.g.cangjie_inlay_hints_hide_in_insert ~= false
end

local function cangjie_local_auto_features_enabled()
    return vim.g.cangjie_local_auto_features ~= false
end

local function any_cangjie_client_supports_inlay(bufnr)
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = "cangjie_lsp" })) do
        if client_supports_inlay_hints(client, bufnr) then
            return true
        end
    end
    return false
end

local function set_cangjie_inlay_hints(bufnr, enabled)
    local ih = inlay_hints_api()
    if not ih or not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    if not any_cangjie_client_supports_inlay(bufnr) then
        return false
    end
    ih.enable(enabled, { bufnr = bufnr })
    vim.b[bufnr].cangjie_inlay_hints_enabled = enabled == true
    return true
end

local function refresh_cangjie_inlay_hints(bufnr)
    local ih = inlay_hints_api()
    if not ih or not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    if not any_cangjie_client_supports_inlay(bufnr) then
        return false
    end

    local enabled = ih.is_enabled and ih.is_enabled({ bufnr = bufnr }) or vim.b[bufnr].cangjie_inlay_hints_enabled == true
    if not enabled then
        return false
    end

    ih.enable(false, { bufnr = bufnr })
    ih.enable(true, { bufnr = bufnr })
    vim.b[bufnr].cangjie_inlay_hints_enabled = true
    return true
end

local function ensure_cangjie_inlay_autocmds(bufnr)
    if vim.b[bufnr].cangjie_inlay_autocmds_ready then
        return
    end

    local group = vim.api.nvim_create_augroup("cangjie_inlay_hints_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd("InsertEnter", {
        group = group,
        buffer = bufnr,
        callback = function()
            if cangjie_inlay_hide_in_insert() then
                set_cangjie_inlay_hints(bufnr, false)
            end
        end,
    })
    vim.api.nvim_create_autocmd("InsertLeave", {
        group = group,
        buffer = bufnr,
        callback = function()
            if cangjie_inlay_enabled() then
                set_cangjie_inlay_hints(bufnr, true)
            end
        end,
    })
    vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged" }, {
        group = group,
        buffer = bufnr,
        callback = function()
            if cangjie_inlay_enabled() and not vim.api.nvim_get_mode().mode:match("^i") then
                refresh_cangjie_inlay_hints(bufnr)
            end
        end,
    })
    vim.api.nvim_create_autocmd("LspDetach", {
        group = group,
        buffer = bufnr,
        callback = function()
            pcall(vim.api.nvim_del_augroup_by_id, group)
        end,
    })

    vim.b[bufnr].cangjie_inlay_autocmds_ready = true
end

local function setup_cangjie_inlay_hints(client, bufnr)
    if not client_supports_inlay_hints(client, bufnr) then
        pseudo_inlay_hints().setup(bufnr)
        return
    end

    ensure_cangjie_inlay_autocmds(bufnr)

    if cangjie_inlay_enabled() and not vim.api.nvim_get_mode().mode:match("^i") then
        set_cangjie_inlay_hints(bufnr, true)
    end
end

local function ensure_cangjie_document_highlight_autocmds(client, bufnr)
    if not (client and client.supports_method and client.supports_method("textDocument/documentHighlight", bufnr)) then
        return
    end
    if vim.b[bufnr].cangjie_document_highlight_ready then
        return
    end

    local group = vim.api.nvim_create_augroup("cangjie_document_highlight_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd("CursorHold", {
        group = group,
        buffer = bufnr,
        callback = function()
            if vim.api.nvim_get_mode().mode:match("^i") then
                return
            end
            vim.lsp.buf.document_highlight()
        end,
    })
    vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
        group = group,
        buffer = bufnr,
        callback = function()
            vim.lsp.buf.clear_references()
        end,
    })
    vim.api.nvim_create_autocmd("LspDetach", {
        group = group,
        buffer = bufnr,
        callback = function()
            vim.lsp.buf.clear_references()
            pcall(vim.api.nvim_del_augroup_by_id, group)
        end,
    })

    vim.b[bufnr].cangjie_document_highlight_ready = true
end

local function resolve_root_dir(bufnr)
    local fname = vim.api.nvim_buf_get_name(bufnr)
    local project_root = util.root_pattern("cjpm.toml")(fname)
    if project_root then
        return project_root
    end

    local dir = vim.fs.dirname(fname)
    if dir and vim.fs.basename(fname) == "main.cj" then
        return dir
    end

    return dir or vim.fn.getcwd()
end

local function hover_markdown_lines(result)
    if not result or not result.contents then
        return {}
    end
    local ok, lines = pcall(vim.lsp.util.convert_input_to_markdown_lines, result.contents)
    if not ok or type(lines) ~= "table" then
        return {}
    end
    lines = vim.lsp.util.trim_empty_lines(lines)
    return lines
end

local function flatten_locations(results)
    local locations = {}
    if not results then
        return locations
    end

    for _, res in pairs(results) do
        local result = res and res.result or nil
        if type(result) == "table" then
            if result.uri or result.targetUri then
                table.insert(locations, result)
            else
                for _, item in ipairs(result) do
                    if type(item) == "table" and (item.uri or item.targetUri) then
                        table.insert(locations, item)
                    end
                end
            end
        end
    end

    return locations
end

local function current_clients_supporting(method)
    local supported = {}
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
        if client.supports_method and client.supports_method(method, 0) then
            table.insert(supported, client)
        end
    end
    return supported
end

local function cangjie_supports(method)
    return #current_clients_supporting(method) > 0
end

local function make_position_params()
    local clients = vim.lsp.get_clients({ bufnr = 0 })
    local encoding = clients[1] and clients[1].offset_encoding or "utf-16"
    return vim.lsp.util.make_position_params(0, encoding)
end

local function docs_from_lsp_locations(method)
    if #current_clients_supporting(method) == 0 then
        return nil
    end
    local docs = get_docs_index()
    local params = make_position_params()
    local results = vim.lsp.buf_request_sync(0, method, params, 500)
    for _, location in ipairs(flatten_locations(results)) do
        local sym = docs.find_symbol_for_location(location)
        if sym then
            return sym
        end
    end
end

local function source_lines_for_path(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local current = vim.api.nvim_buf_get_name(0)
    if current ~= "" and vim.fs.normalize(current) == vim.fs.normalize(path) then
        return vim.api.nvim_buf_get_lines(0, 0, -1, false)
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok and type(lines) == "table" then
        return lines
    end
end

local function strip_doc_comment_line(line)
    line = type(line) == "string" and line or ""
    line = line:gsub("^%s*///?%s?", "")
    line = line:gsub("^%s*/%*+%s?", "")
    line = line:gsub("^%s*%*%s?", "")
    line = line:gsub("%s*%*/%s*$", "")
    line = line:gsub("^/%s*$", "")
    return trim_text(line) or ""
end

local function clean_source_signature_line(line)
    line = trim_text(line)
    if not line then
        return nil
    end
    line = line:gsub("%s*{%s*$", "")
    return trim_text(line)
end

local function looks_like_source_declaration(line)
    line = trim_text(line)
    if not line then
        return false
    end

    if line:match("^@[A-Za-z_]") then
        return true
    end

    local declaration = line
    local stripped = line
    local modifiers = {
        "public",
        "private",
        "protected",
        "internal",
        "open",
        "sealed",
        "abstract",
        "override",
        "static",
        "mut",
        "foreign",
        "unsafe",
    }
    while true do
        local next_stripped = stripped
        for _, modifier in ipairs(modifiers) do
            local candidate = next_stripped:gsub("^" .. modifier .. "%s+", "", 1)
            if candidate ~= next_stripped then
                next_stripped = candidate
                break
            end
        end
        if next_stripped == stripped then
            break
        end
        stripped = next_stripped
    end
    declaration = trim_text(stripped) or line

    local matched = declaration:match("^func%s+")
        or declaration:match("^init%s*%(")
        or declaration:match("^class%s+")
        or declaration:match("^struct%s+")
        or declaration:match("^interface%s+")
        or declaration:match("^enum%s+")
        or declaration:match("^type%s+")
        or declaration:match("^prop%s+")
        or declaration:match("^var%s+")
        or declaration:match("^let%s+")
        or declaration:match("^const%s+")
    append_debug_log(
        ("[source_doc] declaration_check raw=%s stripped=%s matched=%s"):format(
            tostring(line),
            tostring(declaration),
            tostring(matched ~= nil)
        )
    )
    return matched ~= nil
end

local function render_source_doc_lines(signature, docs)
    local out = {}
    local param_count = 0
    local throws_count = 0
    if signature then
        table.insert(out, "```cangjie")
        table.insert(out, signature)
        table.insert(out, "```")
        table.insert(out, "")
    end

    local in_params = false
    local in_throws = false
    local function ensure_blank()
        if #out > 0 and out[#out] ~= "" then
            table.insert(out, "")
        end
    end

    for _, raw in ipairs(docs or {}) do
        local line = trim_text(raw) or ""
        if line == "" then
            if #out > 0 and out[#out] ~= "" then
                table.insert(out, "")
            end
            in_params = false
            in_throws = false
        else
            local param_name, param_desc = line:match("^@param%s+([%w_]+)%s+(.*)$")
            local throws_name, throws_desc = line:match("^@throws%s+([%w_%.]+)%s+(.*)$")
            if param_name then
                if not in_params then
                    ensure_blank()
                    table.insert(out, "**参数：**")
                    in_params = true
                    in_throws = false
                end
                param_count = param_count + 1
                table.insert(out, ("- `%s` — %s"):format(param_name, trim_text(param_desc) or ""))
            elseif throws_name then
                if not in_throws then
                    ensure_blank()
                    table.insert(out, "**可能抛出：**")
                    in_throws = true
                    in_params = false
                end
                throws_count = throws_count + 1
                table.insert(out, ("- `%s` — %s"):format(throws_name, trim_text(throws_desc) or ""))
            else
                in_params = false
                in_throws = false
                table.insert(out, line)
            end
        end
    end

    while #out > 0 and out[#out] == "" do
        table.remove(out)
    end
    append_debug_log(
        ("[source_doc] render signature=%s lines=%d params=%d throws=%d"):format(
            tostring(signature),
            #out,
            param_count,
            throws_count
        )
    )
    return out
end

local function source_doc_lines_from_path(path, line0)
    local lines = source_lines_for_path(path)
    if type(lines) ~= "table" then
        append_debug_log("[source_doc] path_unreadable=" .. tostring(path))
        return nil
    end

    local target = lines[(line0 or 0) + 1]
    local signature = clean_source_signature_line(target)
    if signature and not looks_like_source_declaration(signature) then
        append_debug_log(
            ("[source_doc] skip_non_declaration path=%s line=%d signature=%s"):format(
                tostring(path),
                (line0 or 0) + 1,
                tostring(signature)
            )
        )
        return nil
    end
    local idx = (line0 or 0)
    if idx < 1 then
        return nil
    end

    local docs = {}
    local prev = lines[idx] or ""
    if prev:match("^%s*//") then
        append_debug_log(("[source_doc] style=line path=%s line=%d"):format(tostring(path), (line0 or 0) + 1))
        while idx >= 1 do
            local raw = lines[idx] or ""
            if not raw:match("^%s*//") then
                break
            end
            table.insert(docs, 1, strip_doc_comment_line(raw))
            idx = idx - 1
        end
    elseif prev:match("%*/%s*$") then
        append_debug_log(("[source_doc] style=block path=%s line=%d"):format(tostring(path), (line0 or 0) + 1))
        local block = {}
        while idx >= 1 do
            local raw = lines[idx] or ""
            table.insert(block, 1, strip_doc_comment_line(raw))
            if raw:match("/%*") then
                docs = block
                break
            end
            idx = idx - 1
        end
    end

    local has_content = false
    for _, line in ipairs(docs) do
        if type(line) == "string" and trim_text(line) then
            has_content = true
            break
        end
    end
    if not has_content then
        append_debug_log(
            ("[source_doc] empty path=%s line=%d signature=%s"):format(
                tostring(path),
                (line0 or 0) + 1,
                tostring(signature)
            )
        )
        return nil
    end
    append_debug_log(
        ("[source_doc] extracted path=%s line=%d signature=%s raw_lines=%d"):format(
            tostring(path),
            (line0 or 0) + 1,
            tostring(signature),
            #docs
        )
    )
    return render_source_doc_lines(signature, docs)
end

local function source_doc_lines_from_locations(method)
    if #current_clients_supporting(method) == 0 then
        return nil
    end

    local params = make_position_params()
    local results = vim.lsp.buf_request_sync(0, method, params, 500)
    for _, location in ipairs(flatten_locations(results)) do
        local uri = location.targetUri or location.uri
        local range = location.targetSelectionRange or location.targetRange or location.range or {}
        local start = range.start or {}
        if uri and start.line then
            local path = vim.uri_to_fname(uri)
            local lines = source_doc_lines_from_path(path, start.line)
            if lines then
                append_debug_log("[K] source_doc_location=" .. tostring(path) .. ":" .. tostring(start.line + 1))
                return lines
            end
        end
    end
end

local function source_doc_lines_for_cursor()
    local path = vim.api.nvim_buf_get_name(0)
    if path == "" then
        return nil
    end
    local line0 = vim.api.nvim_win_get_cursor(0)[1] - 1
    local lines = source_doc_lines_from_path(path, line0)
    if lines then
        append_debug_log("[K] source_doc_cursor=" .. tostring(path) .. ":" .. tostring(line0 + 1))
    end
    return lines
end

local function docs_debug_from_lsp_locations(method)
    local lines = { ("method=%s"):format(method) }
    if #current_clients_supporting(method) == 0 then
        table.insert(lines, "supported=false")
        return lines
    end

    local docs = get_docs_index()
    local params = make_position_params()
    local results = vim.lsp.buf_request_sync(0, method, params, 500)
    local locations = flatten_locations(results)
    table.insert(lines, ("locations=%d"):format(#locations))

    for i, location in ipairs(locations) do
        local uri = location.targetUri or location.uri or "nil"
        local range = location.targetSelectionRange or location.targetRange or location.range or {}
        local start = range.start or {}
        local sym = docs.find_symbol_for_location(location)
        table.insert(lines, ("location[%d].uri=%s"):format(i, uri))
        table.insert(lines, ("location[%d].line=%s"):format(i, tostring((start.line or 0) + 1)))
        table.insert(lines, ("location[%d].char=%s"):format(i, tostring((start.character or 0) + 1)))
        table.insert(lines, ("location[%d].symbol=%s"):format(i, (sym and (sym.fqname or sym.id)) or "nil"))
    end

    return lines
end

local function debug_docs_resolution()
    local lines = {}
    vim.list_extend(lines, docs_debug_from_lsp_locations("textDocument/declaration"))
    vim.list_extend(lines, docs_debug_from_lsp_locations("textDocument/definition"))
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Cangjie Docs" })
end

local function debug_hover_docs_resolution()
    local docs = get_docs_index()
    local lines = {}
    local context = docs.current_cursor_context and docs.current_cursor_context() or nil
    local params = make_position_params()
    local results = vim.lsp.buf_request_sync(0, "textDocument/hover", params, 500)
    if not results then
        vim.notify("hover results=nil", vim.log.levels.INFO, { title = "Cangjie Hover" })
        return
    end

    for _, res in pairs(results) do
        local hover_lines = hover_markdown_lines(res and res.result or nil)
        table.insert(lines, ("hover_lines=%d"):format(#hover_lines))
        for i, line in ipairs(hover_lines) do
            table.insert(lines, ("hover[%d]=%s"):format(i, line))
        end
        local debug = docs.debug_hover_symbol_context and docs.debug_hover_symbol_context(hover_lines, { context = context }) or nil
        if debug then
            table.insert(lines, ("line=%s"):format(debug.line_text or "nil"))
            table.insert(lines, ("cursor_col0=%s"):format(debug.cursor_col0 ~= nil and tostring(debug.cursor_col0) or "nil"))
            table.insert(lines, ("expr=%s"):format(debug.expr or "nil"))
            table.insert(lines, ("cursor_ident=%s"):format(debug.cursor_ident or "nil"))
            table.insert(lines, ("module=%s"):format(debug.module_name or "nil"))
            table.insert(lines, ("container=%s"):format(debug.container_name or "nil"))
            table.insert(lines, ("member=%s"):format(debug.member_name or "nil"))
            table.insert(lines, ("member_kind=%s"):format(debug.member_kind or "nil"))
            table.insert(lines, ("hover_symbol=%s"):format(debug.symbol or "nil"))
        else
            local sym = docs.find_symbol_for_hover_lines(hover_lines)
            table.insert(lines, ("hover_symbol=%s"):format((sym and (sym.fqname or sym.id)) or "nil"))
        end
        break
    end

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Cangjie Hover" })
end

local function debug_snapshot()
    local docs = get_docs_index()
    local parts = {
        ("debug=%s"):format(tostring(docs.debug_enabled and docs.debug_enabled() or false)),
        ("log=%s"):format(docs.debug_log_path and docs.debug_log_path() or "/tmp/cangjie_docs.log"),
    }

    local ok_ctx, ctx = pcall(function()
        return docs.current_cursor_context and docs.current_cursor_context() or nil
    end)
    if ok_ctx and ctx then
        table.insert(parts, ("expr=%s"):format(ctx.expr or "nil"))
        table.insert(parts, ("cursor_ident=%s"):format(ctx.cursor_ident or "nil"))
        table.insert(parts, ("line=%s"):format(ctx.line_text or "nil"))
        table.insert(parts, ("cursor_col0=%s"):format(ctx.cursor_col0 ~= nil and tostring(ctx.cursor_col0) or "nil"))
    end

    local ok_lsp, lines = pcall(function()
        local params = make_position_params()
        local results = vim.lsp.buf_request_sync(0, "textDocument/hover", params, 500)
        if not results then
            return {}
        end
        for _, res in pairs(results) do
            local hover_lines = hover_markdown_lines(res and res.result or nil)
            if #hover_lines > 0 then
                return hover_lines
            end
        end
        return {}
    end)
    if ok_lsp then
        table.insert(parts, ("hover_lines=%d"):format(#lines))
        for i, line in ipairs(lines) do
            table.insert(parts, ("hover[%d]=%s"):format(i, line))
        end
        local debug = docs.debug_hover_symbol_context
                and docs.debug_hover_symbol_context(lines, {
                    context = docs.current_cursor_context and docs.current_cursor_context() or nil,
                })
            or nil
        if debug then
            table.insert(parts, ("module=%s"):format(debug.module_name or "nil"))
            table.insert(parts, ("container=%s"):format(debug.container_name or "nil"))
            table.insert(parts, ("member=%s"):format(debug.member_name or "nil"))
            table.insert(parts, ("member_kind=%s"):format(debug.member_kind or "nil"))
            table.insert(parts, ("hover_symbol=%s"):format(debug.symbol or "nil"))
        end
    end

    vim.notify(table.concat(parts, "\n"), vim.log.levels.INFO, { title = "Cangjie Docs Debug" })
end

local function current_cangjie_client()
    local clients = vim.lsp.get_clients({ bufnr = 0, name = "cangjie_lsp" })
    return clients[1]
end

local function capability_lines(client, title, methods)
    local lines = { title }
    for _, entry in ipairs(methods) do
        local method = type(entry) == "table" and entry.method or entry
        local label = type(entry) == "table" and (entry.label or entry.method) or entry
        local note = type(entry) == "table" and entry.note or nil
        local supported = client.supports_method and client.supports_method(method, 0) or false
        if note then
            lines[#lines + 1] = ("- %s = %s (%s)"):format(label, tostring(supported), note)
        else
            lines[#lines + 1] = ("- %s = %s"):format(label, tostring(supported))
        end
    end
    return lines
end

local function probe_params_for_method(method)
    if method == "workspace/symbol" then
        return { query = "" }
    end
    if method == "workspace/executeCommand" then
        return { command = "", arguments = {} }
    end
    if method == "textDocument/documentSymbol" or method == "textDocument/codeLens" or method == "textDocument/documentLink" or method == "textDocument/semanticTokens/full" then
        return { textDocument = vim.lsp.util.make_text_document_params(0) }
    end
    if method == "textDocument/references" then
        local params = make_position_params()
        params.context = { includeDeclaration = true }
        return params
    end
    if
        method == "textDocument/completion"
        or method == "textDocument/hover"
        or method == "textDocument/definition"
        or method == "textDocument/documentHighlight"
        or method == "textDocument/prepareRename"
        or method == "textDocument/signatureHelp"
        or method == "textDocument/prepareCallHierarchy"
        or method == "textDocument/prepareTypeHierarchy"
    then
        return make_position_params()
    end
    if method == "callHierarchy/outgoingCalls" then
        return { item = nil }
    end
    if method == "callHierarchy/incomingCalls" then
        return { item = nil }
    end
    if method == "typeHierarchy/supertypes" or method == "typeHierarchy/subtypes" then
        return { item = nil }
    end
    return nil
end

local function is_private_probe_method(method)
    return method == "textDocument/trackCompletion"
        or method == "textDocument/crossLanguageDefinition"
        or method == "textDocument/findFileReferences"
        or method == "textDocument/exportsName"
        or method == "textDocument/fileRefactor"
        or method == "textDocument/breakpoints"
        or method == "codeGenerator/overrideMethods"
end

local function cangjie_lsp_probe(method)
    local client = current_cangjie_client()
    if not client then
        vim.notify("Current buffer has no cangjie_lsp client", vim.log.levels.WARN, { title = "Cangjie" })
        return
    end

    method = trim_text(method or "")
    if not method then
        vim.notify("Usage: :CangjieLspProbe <method>", vim.log.levels.WARN, { title = "Cangjie" })
        return
    end

    local params = probe_params_for_method(method)
    if params == nil then
        if is_private_probe_method(method) then
            vim.notify("Probe schema for " .. method .. " is unknown; request suppressed to avoid crashing LSPServer", vim.log.levels.WARN, {
                title = "Cangjie Probe",
            })
            return
        end
        vim.notify("No probe params available for " .. method, vim.log.levels.WARN, { title = "Cangjie Probe" })
        return
    end
    if params.item == nil and (method == "callHierarchy/outgoingCalls" or method == "typeHierarchy/supertypes" or method == "typeHierarchy/subtypes") then
        vim.notify("Probe " .. method .. " requires a prepared hierarchy item first", vim.log.levels.WARN, { title = "Cangjie Probe" })
        return
    end

    local results = vim.lsp.buf_request_sync(0, method, params, 800)
    local lines = {
        ("method=%s"):format(method),
        ("declared=%s"):format(tostring(client.supports_method and client.supports_method(method, 0) or false)),
    }

    if not results then
        lines[#lines + 1] = "request=nil"
        vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN, { title = "Cangjie Probe" })
        return
    end

    local response_count = 0
    for _, res in pairs(results) do
        response_count = response_count + 1
        local err = res and res.err or nil
        local result = res and res.result or nil
        lines[#lines + 1] = ("responses=%d"):format(response_count)
        if err then
            lines[#lines + 1] = ("error.code=%s"):format(tostring(err.code))
            lines[#lines + 1] = ("error.message=%s"):format(tostring(err.message))
        else
            lines[#lines + 1] = ("result.type=%s"):format(type(result))
            if type(result) == "table" then
                local size = vim.tbl_islist(result) and #result or vim.tbl_count(result)
                lines[#lines + 1] = ("result.size=%s"):format(tostring(size))
            else
                lines[#lines + 1] = ("result=%s"):format(vim.inspect(result))
            end
        end
        break
    end

    if response_count == 0 then
        lines[#lines + 1] = "responses=0"
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Cangjie Probe" })
end

local function cangjie_lsp_capabilities_info()
    local client = current_cangjie_client()
    if not client then
        vim.notify("Current buffer has no cangjie_lsp client", vim.log.levels.WARN, { title = "Cangjie" })
        return
    end

    local standard = {
        "textDocument/hover",
        "textDocument/definition",
        "textDocument/references",
        "textDocument/documentHighlight",
        "textDocument/documentSymbol",
        "textDocument/prepareRename",
        "textDocument/rename",
        "textDocument/signatureHelp",
        "textDocument/completion",
        { method = "textDocument/documentLink", note = "declared but currently returns empty" },
        "textDocument/prepareTypeHierarchy",
        "typeHierarchy/supertypes",
        "typeHierarchy/subtypes",
        "textDocument/prepareCallHierarchy",
        "callHierarchy/outgoingCalls",
        "callHierarchy/incomingCalls",
        "textDocument/codeLens",
        "textDocument/semanticTokens/full",
        "workspace/symbol",
        "workspace/didChangeWatchedFiles",
    }
    local conditional = {
        "workspace/executeCommand",
        "textDocument/codeAction",
        "textDocument/declaration",
        "textDocument/typeDefinition",
        "textDocument/implementation",
        "textDocument/inlayHint",
    }
    local private = {
        "textDocument/trackCompletion",
        "textDocument/breakpoints",
        "textDocument/crossLanguageDefinition",
        "textDocument/findFileReferences",
        "textDocument/exportsName",
        "textDocument/crossLanguageRegister",
        "textDocument/fileRefactor",
        "codeGenerator/overrideMethods",
    }

    local lines = { ("client=%s"):format(client.name or "cangjie_lsp"), "" }
    vim.list_extend(lines, capability_lines(client, "[Standard]", standard))
    lines[#lines + 1] = ""
    vim.list_extend(lines, capability_lines(client, "[Private]", private))
    lines[#lines + 1] = ""
    vim.list_extend(lines, capability_lines(client, "[Conditional/Unsupported]", conditional))

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Cangjie LSP Capabilities" })
end

local function debug_completion_probe()
    local client = current_cangjie_client()
    if not client then
        vim.notify("Current buffer has no cangjie_lsp client", vim.log.levels.WARN, { title = "Cangjie Completion" })
        return
    end

    local params = make_position_params()
    params.context = {
        triggerKind = vim.lsp.protocol.CompletionTriggerKind.TriggerCharacter,
        triggerCharacter = ".",
    }

    local results = vim.lsp.buf_request_sync(0, "textDocument/completion", params, 1000)
    local lines = {
        ("declared=%s"):format(tostring(client.supports_method and client.supports_method("textDocument/completion", 0) or false)),
        ("params=%s"):format(vim.inspect(params)),
    }

    if not results then
        lines[#lines + 1] = "request=nil"
        vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN, { title = "Cangjie Completion" })
        return
    end

    for _, res in pairs(results) do
        local err = res and res.err or nil
        local result = res and res.result or nil
        if err then
            lines[#lines + 1] = ("error.code=%s"):format(tostring(err.code))
            lines[#lines + 1] = ("error.message=%s"):format(tostring(err.message))
        else
            lines[#lines + 1] = ("result.type=%s"):format(type(result))
            if type(result) == "table" then
                local items = vim.tbl_islist(result) and result or result.items
                local count = type(items) == "table" and #items or 0
                lines[#lines + 1] = ("items=%d"):format(count)
                if count > 0 then
                    local first = items[1]
                    lines[#lines + 1] = ("first.label=%s"):format(tostring(first and first.label or nil))
                    lines[#lines + 1] = ("first.kind=%s"):format(tostring(first and first.kind or nil))
                    lines[#lines + 1] = ("first.detail=%s"):format(tostring(first and first.detail or nil))
                end
            else
                lines[#lines + 1] = ("result=%s"):format(vim.inspect(result))
            end
        end
        break
    end

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Cangjie Completion" })
end

local function docs_from_current_hover()
    local docs = get_docs_index()
    local context = docs.current_cursor_context and docs.current_cursor_context() or nil
    append_debug_log("[hover] context expr=" .. tostring(context and context.expr) .. " ident=" .. tostring(context and context.cursor_ident))
    local params = make_position_params()
    local results = vim.lsp.buf_request_sync(0, "textDocument/hover", params, 500)
    if not results then
        append_debug_log("[hover] results=nil")
        return nil, nil
    end

    for _, res in pairs(results) do
        local lines = hover_markdown_lines(res and res.result or nil)
        append_debug_log("[hover] lines=" .. tostring(#lines))
        if #lines > 0 then
            local hover_sym = docs.find_symbol_for_hover_lines(lines, { context = context })
            append_debug_log("[hover] symbol=" .. tostring(hover_sym and (hover_sym.fqname or hover_sym.id) or nil))
            return hover_sym, lines
        end
    end

    append_debug_log("[hover] no_nonempty_lines")
    return nil, nil
end

local function hover_or_local_docs()
    local docs = get_docs_index()
    append_debug_log("[K] start")
    local local_sym = docs_from_lsp_locations("textDocument/declaration") or docs_from_lsp_locations("textDocument/definition")
    append_debug_log("[K] lsp_locations=" .. tostring(local_sym and (local_sym.fqname or local_sym.id) or nil))
    if local_sym then
        docs.show_symbol(local_sym)
        return
    end

    local inferred_type = docs.inferred_type_for_cursor and docs.inferred_type_for_cursor() or nil
    append_debug_log("[K] inferred_type=" .. tostring(inferred_type))

    local_sym = docs.find_symbol_for_cursor()
    append_debug_log("[K] local_cursor_pre=" .. tostring(local_sym and (local_sym.fqname or local_sym.id) or nil))
    if local_sym and not inferred_type then
        docs.show_symbol(local_sym)
        return
    end

    if inferred_type then
        local inferred_base = sanitize_lookup_type_name(inferred_type)
        local inferred_desugared = inferred_desugared_type(inferred_type)
        local inferred_inner = inferred_inner_type(inferred_type)
        local inferred_inner_sym = nil
        append_debug_log("[K] inferred_type_base=" .. tostring(inferred_base))
        append_debug_log("[K] inferred_type_desugared=" .. tostring(inferred_desugared))
        local inferred_sym = nil
        if inferred_base then
            inferred_sym = docs.find_symbol and docs.find_symbol(inferred_base) or nil
        elseif docs.find_symbol then
            inferred_sym = docs.find_symbol(inferred_type) or nil
        end
        if inferred_inner then
            inferred_inner_sym = docs.find_symbol and docs.find_symbol(inferred_inner) or nil
            if not inferred_inner_sym then
                local inferred_inner_base = sanitize_lookup_type_name(inferred_inner)
                append_debug_log("[K] inferred_type_inner_base=" .. tostring(inferred_inner_base))
                if inferred_inner_base then
                    inferred_inner_sym = docs.find_symbol and docs.find_symbol(inferred_inner_base) or nil
                end
            end
        end
        append_debug_log("[K] inferred_type_inner=" .. tostring(inferred_inner))
        append_debug_log("[K] inferred_type_inner_symbol=" .. tostring(inferred_inner_sym and (inferred_inner_sym.fqname or inferred_inner_sym.id) or nil))
        append_debug_log("[K] inferred_type_lookup_symbol=" .. tostring(inferred_sym and (inferred_sym.fqname or inferred_sym.id) or nil))
        if inferred_sym then
            local render_lines = docs.hover_markdown_for_symbol and docs.hover_markdown_for_symbol(inferred_sym) or nil
            append_debug_log("[K] inferred_type_render_lines=" .. tostring(type(render_lines) == "table" and #render_lines or nil))
            if render_lines and is_decorated_inferred_type(inferred_type, inferred_base) then
                local header = {
                    "```cangjie",
                    tostring(vim.fn.expand("<cword>")) .. ": " .. inferred_type,
                    "```",
                    "",
                }
                if inferred_desugared and inferred_desugared ~= inferred_type then
                    header[#header + 1] = ("desugars to: `%s`"):format(inferred_desugared)
                end
                if inferred_inner then
                    header[#header + 1] = ("value type when Some: `%s`"):format(inferred_inner)
                    if inferred_inner_sym then
                        header[#header + 1] = "Press `<CR>` to open inner type docs."
                    end
                end
                if inferred_desugared or inferred_inner then
                    header[#header + 1] = ""
                end
                for _, line in ipairs(render_lines) do
                    header[#header + 1] = line
                end
                append_debug_log("[K] inferred_type_preview_lines=" .. tostring(#header))
                if docs.open_preview then
                    docs.open_preview(header, inferred_inner_sym and { action = { sym = inferred_inner_sym } } or nil)
                else
                    vim.lsp.util.open_floating_preview(header, "markdown", {
                        border = "rounded",
                        max_width = 100,
                        max_height = 30,
                    })
                end
            else
                docs.show_symbol(inferred_sym)
            end
            return
        end

        local preview_lines = {
            "```cangjie",
            tostring(vim.fn.expand("<cword>")) .. ": " .. inferred_type,
            "```",
            "",
        }
        if inferred_desugared and inferred_desugared ~= inferred_type then
            preview_lines[#preview_lines + 1] = ("desugars to: `%s`"):format(inferred_desugared)
        end
        if inferred_inner then
            preview_lines[#preview_lines + 1] = ("value type when Some: `%s`"):format(inferred_inner)
            if inferred_inner_sym then
                preview_lines[#preview_lines + 1] = "Press `<CR>` to open inner type docs."
            end
        end
        if inferred_desugared or inferred_inner then
            preview_lines[#preview_lines + 1] = ""
        end
        preview_lines[#preview_lines + 1] = "本地类型推断结果。"
        if docs.open_preview then
            docs.open_preview(preview_lines, inferred_inner_sym and { action = { sym = inferred_inner_sym } } or nil)
        else
            vim.lsp.util.open_floating_preview(preview_lines, "markdown", {
                border = "rounded",
                max_width = 100,
                max_height = 30,
            })
        end
        return
    end

    if local_sym then
        docs.show_symbol(local_sym)
        return
    end

    local source_lines = source_doc_lines_from_locations("textDocument/declaration")
        or source_doc_lines_from_locations("textDocument/definition")
        or source_doc_lines_for_cursor()
    if source_lines then
        vim.lsp.util.open_floating_preview(source_lines, "markdown", {
            border = "rounded",
            max_width = 100,
            max_height = 30,
        })
        return
    end

    if docs.cursor_in_local_like_position and docs.cursor_in_local_like_position() then
        append_debug_log("[K] local_like_position_no_hover")
        append_debug_log("[K] no_result")
        return
    end

    local hover_sym, hover_lines = docs_from_current_hover()
    append_debug_log("[K] hover_pre=" .. tostring(hover_sym and (hover_sym.fqname or hover_sym.id) or nil))
    if hover_sym then
        docs.show_symbol(hover_sym)
        return
    end

    local has_member_access = docs.cursor_has_member_access and docs.cursor_has_member_access() or false
    local should_try_hover = has_member_access or docs.should_try_lsp_hover()
    append_debug_log("[K] member_access=" .. tostring(has_member_access) .. " should_try_hover=" .. tostring(should_try_hover))

    if should_try_hover then
        if hover_sym then
            append_debug_log("[K] show_hover_symbol=" .. tostring(hover_sym and (hover_sym.fqname or hover_sym.id) or nil))
            docs.show_symbol(hover_sym)
            return
        end
        if hover_lines and #hover_lines > 0 then
            append_debug_log("[K] fallback_raw_hover")
            vim.lsp.util.open_floating_preview(hover_lines, "markdown", {
                border = "rounded",
            })
            return
        end
    end

    if docs.cursor_has_member_access and docs.cursor_has_member_access() then
        append_debug_log("[K] member_access_no_fallback")
        return
    end

    local_sym = docs.find_symbol_for_cursor()
    append_debug_log("[K] local_cursor=" .. tostring(local_sym and (local_sym.fqname or local_sym.id) or nil))
    if local_sym then
        docs.show_symbol(local_sym)
        return
    end

    append_debug_log("[K] no_result")
end

local function signature_help_or_notify()
    local docs = get_docs_index()
    local sym = docs.find_symbol_for_cursor()
    local result = docs.signature_help_for_symbol and docs.signature_help_for_symbol(sym) or nil
    if result and result.signatures and #result.signatures > 0 then
        local contents = {}
        local sig = result.signatures[1]
        if sig.label then
            table.insert(contents, "```cangjie")
            table.insert(contents, sig.label)
            table.insert(contents, "```")
            table.insert(contents, "")
        end
        if sig.documentation then
            local doc = sig.documentation.value or sig.documentation
            if type(doc) == "string" and doc ~= "" then
                table.insert(contents, doc)
                table.insert(contents, "")
            end
        end
        if sig.parameters and #sig.parameters > 0 then
            table.insert(contents, "**参数：**")
            for _, param in ipairs(sig.parameters) do
                local pdoc = param.documentation and (param.documentation.value or param.documentation) or nil
                table.insert(contents, ("- `%s`%s"):format(param.label or "?", pdoc and (" — " .. pdoc:gsub("\n+", " ")) or ""))
            end
            table.insert(contents, "")
        end
        vim.lsp.util.open_floating_preview(contents, "markdown", { border = "rounded" })
        return
    end

    local params = make_position_params()
    local results = vim.lsp.buf_request_sync(0, "textDocument/signatureHelp", params, 500)
    if results then
        for _, res in pairs(results) do
            local lsp_result = res and res.result or nil
            if lsp_result and lsp_result.signatures and #lsp_result.signatures > 0 then
                vim.lsp.buf.signature_help()
                return
            end
        end
    end

    vim.notify("当前位置没有可用的 signature help", vim.log.levels.INFO, { title = "Cangjie" })
end

local function open_docs_in_browser()
    get_docs_index().open_cursor_symbol_in_browser()
end

local function cangjie_inlay_hints_status(bufnr)
    local ih = inlay_hints_api()
    local supported = any_cangjie_client_supports_inlay(bufnr)
    local enabled = ih and ih.is_enabled and ih.is_enabled({ bufnr = bufnr }) or false
    return {
        supported = supported,
        enabled = enabled,
        hide_in_insert = cangjie_inlay_hide_in_insert(),
        local_auto_features = cangjie_local_auto_features_enabled(),
    }
end

local function manage_cangjie_inlay_hints(action)
    local bufnr = vim.api.nvim_get_current_buf()
    local status = cangjie_inlay_hints_status(bufnr)
    if not status.supported then
        pseudo_inlay_hints().manage(action)
        return
    end

    if action == "toggle" then
        local enabled = not status.enabled
        vim.g.cangjie_inlay_hints = enabled
        set_cangjie_inlay_hints(bufnr, enabled)
        vim.notify("Cangjie inlay hints: " .. (enabled and "on" or "off"), vim.log.levels.INFO, { title = "Cangjie" })
        return
    end

    if action == "on" then
        vim.g.cangjie_inlay_hints = true
        set_cangjie_inlay_hints(bufnr, true)
        vim.notify("Cangjie inlay hints: on", vim.log.levels.INFO, { title = "Cangjie" })
        return
    end

    if action == "off" then
        vim.g.cangjie_inlay_hints = false
        set_cangjie_inlay_hints(bufnr, false)
        vim.notify("Cangjie inlay hints: off", vim.log.levels.INFO, { title = "Cangjie" })
        return
    end

    if action == "refresh" then
        if refresh_cangjie_inlay_hints(bufnr) then
            vim.notify("Cangjie inlay hints refreshed", vim.log.levels.INFO, { title = "Cangjie" })
        else
            vim.notify("Cangjie inlay hints 未启用或无需刷新", vim.log.levels.INFO, { title = "Cangjie" })
        end
        return
    end

    if action == "status" then
        vim.notify(
            table.concat({
                ("supported=%s"):format(tostring(status.supported)),
                ("enabled=%s"):format(tostring(status.enabled)),
                ("hide_in_insert=%s"):format(tostring(status.hide_in_insert)),
                ("local_auto_features=%s"):format(tostring(status.local_auto_features)),
            }, "\n"),
            vim.log.levels.INFO,
            { title = "Cangjie Inlay Hints" }
        )
    end
end

local function show_completion_or_notify()
    append_completion_log(("[manual] ft=%s line=%s"):format(tostring(vim.bo.filetype), tostring(vim.api.nvim_get_current_line())))
    local blink = get_blink()
    if blink and blink.show then
        append_completion_log("[manual] blink.show")
        blink.show({ providers = { "lsp", "cangjie_docs", "buffer", "path" } })
        return
    end
    append_completion_log("[manual] blink_unavailable")
    vim.notify("blink.cmp 不可用，无法触发补全", vim.log.levels.WARN, { title = "Cangjie" })
end

local function trigger_completion_after_dot()
    if not cangjie_local_auto_features_enabled() then
        append_completion_log("[dot] skipped local_auto_features=off")
        return
    end
    append_completion_log(
        ("[dot] scheduled ft=%s line=%s col=%s"):format(tostring(vim.bo.filetype), tostring(vim.api.nvim_get_current_line()), tostring(vim.api.nvim_win_get_cursor(0)[2]))
    )
    local blink = get_blink()
    if blink and blink.show then
        vim.schedule(function()
            append_completion_log(
                ("[dot] blink.show ft=%s line=%s col=%s"):format(tostring(vim.bo.filetype), tostring(vim.api.nvim_get_current_line()), tostring(vim.api.nvim_win_get_cursor(0)[2]))
            )
            blink.show({ providers = { "lsp", "cangjie_docs", "buffer", "path" } })
        end)
        return
    end
    append_completion_log("[dot] blink_unavailable")
end

local function manage_cangjie_local_auto_features(action)
    if action == "toggle" then
        vim.g.cangjie_local_auto_features = not cangjie_local_auto_features_enabled()
    elseif action == "on" then
        vim.g.cangjie_local_auto_features = true
    elseif action == "off" then
        vim.g.cangjie_local_auto_features = false
    elseif action == "status" then
        vim.notify(
            table.concat({
                ("enabled=%s"):format(tostring(cangjie_local_auto_features_enabled())),
                ("pseudo_inlay=%s"):format(tostring(vim.g.cangjie_pseudo_inlay_hints ~= false)),
                ("dot_completion=%s"):format(tostring(cangjie_local_auto_features_enabled())),
            }, "\n"),
            vim.log.levels.INFO,
            { title = "Cangjie Local Auto Features" }
        )
        return
    else
        vim.notify("Usage: :CangjieLocalAuto [toggle|on|off|status]", vim.log.levels.WARN, { title = "Cangjie" })
        return
    end

    if not cangjie_local_auto_features_enabled() then
        pseudo_inlay_hints().clear(0)
    else
        pseudo_inlay_hints().render(0, { cursor_only = false })
    end

    vim.notify("Cangjie local auto features: " .. (cangjie_local_auto_features_enabled() and "on" or "off"), vim.log.levels.INFO, { title = "Cangjie" })
end

local function cangjie_document_symbols()
    local builtin = get_telescope_builtin()
    if builtin and builtin.lsp_document_symbols then
        builtin.lsp_document_symbols()
        return
    end
    vim.lsp.buf.document_symbol()
end

local function cangjie_references()
    local builtin = get_telescope_builtin()
    if builtin and builtin.lsp_references then
        builtin.lsp_references()
        return
    end
    vim.lsp.buf.references()
end

local function sanitize_workspace_edit_for_cangjie(edit)
    if type(edit) ~= "table" then
        append_rename_log("rename result is not table: " .. type(edit))
        return nil
    end

    -- cangjie_lsp rename returns a WorkspaceEdit-like object whose primary payload
    -- is documentChanges (TextDocumentEdit[]). When the server has no rename edits,
    -- it serializes documentChanges as JSON null, which Neovim decodes as vim.NIL.
    local sanitized = vim.deepcopy(edit)
    local document_changes = sanitized.documentChanges
    if document_changes ~= nil then
        if document_changes == vim.NIL or type(document_changes) == "userdata" then
            sanitized.documentChanges = nil
        elseif type(document_changes) ~= "table" then
            sanitized.documentChanges = nil
        elseif not vim.islist(document_changes) then
            sanitized.documentChanges = nil
        else
            for _, change in ipairs(document_changes) do
                if type(change) == "table" and type(change.textDocument) == "table" then
                    if change.textDocument.version == vim.NIL or type(change.textDocument.version) == "userdata" then
                        change.textDocument.version = nil
                    end
                end
            end
        end
    end

    if sanitized.changes ~= nil and type(sanitized.changes) ~= "table" then
        sanitized.changes = nil
    end

    local has_document_changes = type(sanitized.documentChanges) == "table" and not vim.tbl_isempty(sanitized.documentChanges)
    local has_changes = type(sanitized.changes) == "table" and not vim.tbl_isempty(sanitized.changes)
    if not has_document_changes and not has_changes then
        append_rename_log("rename raw result=" .. vim.inspect(edit))
        append_rename_log(("rename shapes: documentChanges=%s changes=%s"):format(type(edit.documentChanges), type(edit.changes)))
        if edit.documentChanges == vim.NIL and edit.changes == nil then
            return false
        end
        return nil
    end
    return sanitized
end

local function notify_cangjie_rename_result(edit)
    if edit == false then
        vim.notify("cangjie_lsp accepted rename target but returned null edits", vim.log.levels.INFO, { title = "Cangjie" })
        return false
    end
    if not edit then
        vim.notify("cangjie_lsp returned an unsupported rename edit shape", vim.log.levels.WARN, {
            title = "Cangjie",
        })
        return false
    end
    return true
end

local function handle_cangjie_rename_result(client, result)
    local edit = sanitize_workspace_edit_for_cangjie(result)
    if not notify_cangjie_rename_result(edit) then
        return
    end
    vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding or "utf-16")
end

local function request_cangjie_rename(client, new_name, params, bufnr)
    params = vim.deepcopy(params or {})
    params.newName = new_name
    append_rename_log("rename request params=" .. vim.inspect(params))
    client:request("textDocument/rename", params, function(err, result)
        if err then
            vim.notify("Rename failed: " .. (err.message or tostring(err)), vim.log.levels.WARN, { title = "Cangjie" })
            return
        end
        handle_cangjie_rename_result(client, result)
    end, bufnr or 0)
end

local function prompt_cangjie_rename(client, default_name, params, bufnr)
    vim.ui.input({
        prompt = "New Name: ",
        default = default_name,
    }, function(input)
        if input and input ~= "" then
            request_cangjie_rename(client, input, params, bufnr)
        end
    end)
end

local function cangjie_rename()
    local winid = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local clients = vim.lsp.get_clients({ bufnr = 0, name = "cangjie_lsp" })
    local client = clients[1]
    if not client or not client.supports_method or not client.supports_method("textDocument/rename", 0) then
        vim.notify("Rename is not supported by cangjie_lsp", vim.log.levels.INFO, { title = "Cangjie" })
        return
    end

    local cword = vim.fn.expand("<cword>")
    local base_params = vim.lsp.util.make_position_params(winid, client.offset_encoding or "utf-16")
    if client.supports_method("textDocument/prepareRename", 0) then
        append_rename_log("prepareRename params=" .. vim.inspect(base_params))
        client:request("textDocument/prepareRename", base_params, function(err, result)
            if err or result == nil then
                local msg = err and ("Error on prepareRename: " .. (err.message or "")) or "Nothing to rename"
                vim.notify(msg, vim.log.levels.INFO, { title = "Cangjie" })
                return
            end
            append_rename_log("prepareRename result=" .. vim.inspect(result))
            local default_name = cword
            if type(result) == "table" and type(result.placeholder) == "string" and result.placeholder ~= "" then
                default_name = result.placeholder
            end
            prompt_cangjie_rename(client, default_name, base_params, bufnr)
        end, bufnr)
        return
    end

    prompt_cangjie_rename(client, cword, base_params, bufnr)
end

local function prepare_hierarchy_item(method)
    local params = make_position_params()
    append_hierarchy_log(method .. " params=" .. vim.inspect(params))
    local results = vim.lsp.buf_request_sync(0, method, params, 800)
    if not results then
        append_hierarchy_log(method .. " results=nil")
        return nil, "request=nil"
    end
    append_hierarchy_log(method .. " results=" .. vim.inspect(results))

    local items = {}
    for _, res in pairs(results) do
        local result = res and res.result or nil
        if type(result) == "table" then
            if result.uri then
                items[#items + 1] = result
            else
                for _, item in ipairs(result) do
                    if type(item) == "table" and item.uri then
                        items[#items + 1] = item
                    end
                end
            end
        end
    end
    if #items == 0 then
        return nil, "empty"
    end
    return items[1], nil
end

local function prepare_call_hierarchy_item()
    return prepare_hierarchy_item("textDocument/prepareCallHierarchy")
end

local function prepare_type_hierarchy_item()
    return prepare_hierarchy_item("textDocument/prepareTypeHierarchy")
end

local function hierarchy_results(method, item)
    local results = vim.lsp.buf_request_sync(0, method, { item = item }, 800)
    if not results then
        append_hierarchy_log(method .. " item=" .. vim.inspect(item))
        append_hierarchy_log(method .. " results=nil")
        return nil, "request=nil"
    end
    append_hierarchy_log(method .. " item=" .. vim.inspect(item))
    append_hierarchy_log(method .. " results=" .. vim.inspect(results))
    return results, nil
end

local function hierarchy_qf_items(results, extractor)
    local qf_items = {}
    local saw_response = false
    local saw_result_field = false

    for _, res in pairs(results) do
        if type(res) == "table" then
            saw_response = true
            if res.result ~= nil then
                saw_result_field = true
            end
        end
        local entries = res and res.result or nil
        if type(entries) == "table" then
            for _, entry in ipairs(entries) do
                local target = extractor(entry)
                local range = target and (target.selectionRange or target.range) or nil
                local uri = target and target.uri or nil
                local name = target and target.name or "?"
                if uri and range and range.start then
                    qf_items[#qf_items + 1] = {
                        filename = vim.uri_to_fname(uri),
                        lnum = (range.start.line or 0) + 1,
                        col = (range.start.character or 0) + 1,
                        text = name,
                    }
                end
            end
        end
    end

    return qf_items, saw_response, saw_result_field
end

local function cangjie_call_hierarchy(direction)
    if not cangjie_supports("textDocument/prepareCallHierarchy") then
        vim.notify("cangjie_lsp does not declare prepareCallHierarchy", vim.log.levels.INFO, { title = "Cangjie" })
        return
    end
    local method = direction == "incoming" and "callHierarchy/incomingCalls" or "callHierarchy/outgoingCalls"
    if not cangjie_supports(method) then
        vim.notify("cangjie_lsp does not declare " .. method, vim.log.levels.INFO, { title = "Cangjie" })
        return
    end

    local item, reason = prepare_call_hierarchy_item()
    if not item then
        local message = reason == "request=nil" and "prepareCallHierarchy request returned nil" or "prepareCallHierarchy returned no item at cursor"
        vim.notify(message, vim.log.levels.INFO, { title = "Cangjie" })
        return
    end
    local results = hierarchy_results(method, item)
    if not results then
        vim.notify(method .. " request=nil", vim.log.levels.WARN, { title = "Cangjie" })
        return
    end
    local qf_items, saw_response, saw_result_field = hierarchy_qf_items(results, function(call)
        return direction == "incoming" and call.from or call.to
    end)

    if #qf_items == 0 then
        if saw_response and not saw_result_field then
            vim.notify(method .. " returned no result payload", vim.log.levels.INFO, { title = "Cangjie" })
            return
        end
        vim.notify("No " .. direction .. " calls", vim.log.levels.INFO, { title = "Cangjie" })
        return
    end

    set_qflist_from_locations("Cangjie " .. direction .. " calls", qf_items)
end

local function cangjie_type_hierarchy(direction)
    if not cangjie_supports("textDocument/prepareTypeHierarchy") then
        vim.notify("cangjie_lsp does not declare prepareTypeHierarchy", vim.log.levels.INFO, { title = "Cangjie" })
        return
    end
    local method = direction == "subtypes" and "typeHierarchy/subtypes" or "typeHierarchy/supertypes"
    if not cangjie_supports(method) then
        vim.notify("cangjie_lsp does not declare " .. method, vim.log.levels.INFO, { title = "Cangjie" })
        return
    end

    local item, reason = prepare_type_hierarchy_item()
    if not item then
        local message = reason == "request=nil" and "prepareTypeHierarchy request returned nil" or "prepareTypeHierarchy returned no item at cursor"
        vim.notify(message, vim.log.levels.INFO, { title = "Cangjie" })
        return
    end
    local results = hierarchy_results(method, item)
    if not results then
        vim.notify(method .. " request=nil", vim.log.levels.WARN, { title = "Cangjie" })
        return
    end
    local qf_items, saw_response, saw_result_field = hierarchy_qf_items(results, function(target)
        return target
    end)

    if #qf_items == 0 then
        if saw_response and not saw_result_field then
            vim.notify(method .. " returned no result payload", vim.log.levels.INFO, { title = "Cangjie" })
            return
        end
        vim.notify("No " .. direction .. " found", vim.log.levels.INFO, { title = "Cangjie" })
        return
    end

    set_qflist_from_locations("Cangjie " .. direction, qf_items)
end

local function cangjie_workspace_symbols(query)
    query = trim_text(query or "") or nil
    local builtin = get_telescope_builtin()
    if builtin and builtin.lsp_dynamic_workspace_symbols then
        builtin.lsp_dynamic_workspace_symbols({ query = query or "" })
        return
    end
    vim.lsp.buf.workspace_symbol(query or vim.fn.input("Workspace symbol query: "))
end

local function cangjie_codelens(action)
    local cl = vim.lsp.codelens
    if not cl then
        vim.notify("Neovim codelens API is not available", vim.log.levels.WARN, { title = "Cangjie" })
        return
    end

    if action == "refresh" then
        cl.refresh()
        vim.notify("Cangjie code lens refreshed", vim.log.levels.INFO, { title = "Cangjie" })
        return
    end

    cl.run()
end

local function scroll_docs_or_fallback(key)
    local blink = get_blink()
    if blink and blink.is_documentation_visible and blink.is_documentation_visible() then
        local used_blink = false
        if key == "<C-f>" then
            used_blink = blink.scroll_documentation_down and blink.scroll_documentation_down(12) or false
        elseif key == "<C-b>" then
            used_blink = blink.scroll_documentation_up and blink.scroll_documentation_up(12) or false
        elseif key == "<C-d>" then
            used_blink = blink.scroll_documentation_down and blink.scroll_documentation_down(6) or false
        elseif key == "<C-u>" then
            used_blink = blink.scroll_documentation_up and blink.scroll_documentation_up(6) or false
        end
        if used_blink then
            return
        end
    end

    local docs = get_docs_index()
    if docs.scroll_preview and docs.scroll_preview(key) then
        return
    end
    vim.cmd("normal! " .. key)
end

local function notify_unsupported_lsp_feature(feature)
    vim.notify(feature .. " is not supported by cangjie_lsp", vim.log.levels.INFO, { title = "Cangjie" })
end

local function map_cangjie_keys(bufnr)
    local function map(mode, lhs, rhs, desc, extra)
        local opts = vim.tbl_extend("force", {
            buffer = bufnr,
            desc = desc,
        }, extra or {})
        vim.keymap.set(mode, lhs, rhs, opts)
    end

    local function live(method_name)
        return function(...)
            local cfg = assert(dofile(vim.fn.stdpath("config") .. "/lsp/cangjie_lsp.lua"))
            local fn = cfg and cfg[method_name]
            if type(fn) ~= "function" then
                vim.notify("Cangjie LSP 动作不可用: " .. method_name, vim.log.levels.ERROR, { title = "Cangjie" })
                return
            end
            return fn(...)
        end
    end

    map("n", "K", live("_codex_hover_or_local_docs"), "Cangjie Docs")
    map("n", "gK", live("_codex_signature_help_or_notify"), "Cangjie Signature Help")
    map("n", "gr", live("_codex_references"), "Cangjie References")
    map("n", "<leader>cr", live("_codex_rename"), "Cangjie Rename")
    map("n", "<leader>cR", live("_codex_references"), "Cangjie References")
    map("n", "<leader>cu", live("_codex_incoming_calls"), "Cangjie Incoming Calls")
    map("n", "<leader>cU", live("_codex_outgoing_calls"), "Cangjie Outgoing Calls")
    map("n", "<leader>ct", live("_codex_supertypes"), "Cangjie Supertypes")
    map("n", "<leader>cT", live("_codex_subtypes"), "Cangjie Subtypes")
    map("n", "gD", function()
        notify_unsupported_lsp_feature("Declaration")
    end, "Declaration Unsupported")
    map("n", "gi", function()
        notify_unsupported_lsp_feature("Implementation")
    end, "Implementation Unsupported")
    map("n", "gy", function()
        notify_unsupported_lsp_feature("Type Definition")
    end, "Type Definition Unsupported")
    map("n", "<leader>co", live("_codex_open_docs_in_browser"), "Open Cangjie docs in browser")
    map("n", "<leader>cj", live("_codex_document_symbols"), "Cangjie Document Symbols")
    map("n", "<leader>cW", live("_codex_workspace_symbols"), "Cangjie Workspace Symbols")
    map("n", "<leader>cc", live("_codex_run_codelens"), "Run Cangjie CodeLens (Optional)")
    map("n", "<leader>cK", live("_codex_refresh_codelens"), "Refresh Cangjie CodeLens (Optional)")
    map({ "i", "n" }, "<C-Space>", live("_codex_show_completion_or_notify"), "Trigger Cangjie Completion")
    map({ "n", "i" }, "<C-f>", live("_codex_scroll_docs_page_down"), "Scroll Cangjie Docs Page Down")
    map({ "n", "i" }, "<C-b>", live("_codex_scroll_docs_page_up"), "Scroll Cangjie Docs Page Up")
    map({ "n", "i" }, "<C-d>", live("_codex_scroll_docs_half_down"), "Scroll Cangjie Docs Half Down")
    map({ "n", "i" }, "<C-u>", live("_codex_scroll_docs_half_up"), "Scroll Cangjie Docs Half Up")
    map("i", ".", function()
        live("_codex_trigger_completion_after_dot")()
        return "."
    end, "Insert . and trigger completion", { expr = true })
end

return {
    cmd = { server, "--test", "--enable-log=true", "--log-path=/tmp/" },
    filetypes = { "Cangjie" },
    root_dir = function(bufnr, on_dir)
        on_dir(resolve_root_dir(bufnr))
    end,
    capabilities = capabilities,

    handlers = {
        ["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
            if result and result.diagnostics then
                result.diagnostics = vim.tbl_filter(function(d)
                    local code = tonumber(d.code)
                    return not ignore_codes[code]
                end, result.diagnostics)

                local docs = get_docs_index()
                for _, diagnostic in ipairs(result.diagnostics) do
                    local href = docs.find_diagnostic_url(diagnostic.code, diagnostic.source)
                    if href then
                        diagnostic.codeDescription = vim.tbl_extend("force", diagnostic.codeDescription or {}, {
                            href = href,
                        })
                    end
                end
            end

            return vim.lsp.diagnostic.on_publish_diagnostics(err, result, ctx, config)
        end,
        ["textDocument/rename"] = function(err, result, ctx)
            if err then
                vim.notify("Rename failed: " .. (err.message or tostring(err)), vim.log.levels.WARN, { title = "Cangjie" })
                return
            end
            if not result then
                vim.notify("Language server couldn't provide rename result", vim.log.levels.INFO, { title = "Cangjie" })
                return
            end

            local client = assert(vim.lsp.get_client_by_id(ctx.client_id))
            handle_cangjie_rename_result(client, result)
        end,
    },

    on_attach = function(client, bufnr)
        vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(bufnr) then
                return
            end
            ensure_cangjie_blink_signature_guard()
            map_cangjie_keys(bufnr)
            ensure_cangjie_document_highlight_autocmds(client, bufnr)
            setup_cangjie_inlay_hints(client, bufnr)
        end)
        vim.notify("Cangjie LSP start success", vim.log.levels.INFO)
    end,

    _codex_debug_docs_resolution = debug_docs_resolution,
    _codex_debug_hover_docs_resolution = debug_hover_docs_resolution,
    _codex_debug_snapshot = debug_snapshot,
    _codex_debug_completion_probe = debug_completion_probe,
    _codex_lsp_capabilities_info = cangjie_lsp_capabilities_info,
    _codex_lsp_probe = cangjie_lsp_probe,
    _codex_hover_or_local_docs = hover_or_local_docs,
    _codex_signature_help_or_notify = signature_help_or_notify,
    _codex_open_docs_in_browser = open_docs_in_browser,
    _codex_manage_inlay_hints = manage_cangjie_inlay_hints,
    _codex_manage_local_auto_features = manage_cangjie_local_auto_features,
    _codex_document_symbols = cangjie_document_symbols,
    _codex_references = cangjie_references,
    _codex_rename = cangjie_rename,
    _codex_incoming_calls = function()
        cangjie_call_hierarchy("incoming")
    end,
    _codex_outgoing_calls = function()
        cangjie_call_hierarchy("outgoing")
    end,
    _codex_supertypes = function()
        cangjie_type_hierarchy("supertypes")
    end,
    _codex_subtypes = function()
        cangjie_type_hierarchy("subtypes")
    end,
    _codex_workspace_symbols = function(query)
        cangjie_workspace_symbols(query)
    end,
    _codex_run_codelens = function()
        cangjie_codelens("run")
    end,
    _codex_refresh_codelens = function()
        cangjie_codelens("refresh")
    end,
    _codex_show_completion_or_notify = show_completion_or_notify,
    _codex_trigger_completion_after_dot = trigger_completion_after_dot,
    _codex_scroll_docs_page_down = function()
        scroll_docs_or_fallback("<C-f>")
    end,
    _codex_scroll_docs_page_up = function()
        scroll_docs_or_fallback("<C-b>")
    end,
    _codex_scroll_docs_half_down = function()
        scroll_docs_or_fallback("<C-d>")
    end,
    _codex_scroll_docs_half_up = function()
        scroll_docs_or_fallback("<C-u>")
    end,
}
