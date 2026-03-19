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
    [753] = true,
    [781] = true,
}

local function get_docs_index()
    return assert(dofile(vim.fn.stdpath("config") .. "/lua/cangjie_docs_index.lua"))
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

local function get_blink()
    local ok, blink = pcall(require, "blink.cmp")
    if ok and blink then
        return blink
    end
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
        local debug = docs.debug_hover_symbol_context and docs.debug_hover_symbol_context(lines, {
            context = docs.current_cursor_context and docs.current_cursor_context() or nil,
        }) or nil
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

    local has_member_access = docs.cursor_has_member_access and docs.cursor_has_member_access() or false
    local should_try_hover = has_member_access or docs.should_try_lsp_hover()
    append_debug_log("[K] member_access=" .. tostring(has_member_access) .. " should_try_hover=" .. tostring(should_try_hover))

    if should_try_hover then
        local hover_sym, hover_lines = docs_from_current_hover()
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

local function show_completion_or_notify()
    local blink = get_blink()
    if blink and blink.show then
        blink.show({ providers = { "lsp", "buffer", "path" } })
        return
    end
    vim.notify("blink.cmp 不可用，无法手动触发补全", vim.log.levels.WARN, { title = "Cangjie" })
end

local function trigger_completion_after_dot()
    local blink = get_blink()
    if blink and blink.show then
        vim.schedule(function()
            blink.show({ providers = { "lsp", "buffer", "path" } })
        end)
    end
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
    map("n", "<leader>co", live("_codex_open_docs_in_browser"), "Open Cangjie docs in browser")
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
    cmd = { server },
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
    },

    on_attach = function(client, bufnr)
        vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(bufnr) then
                return
            end
            map_cangjie_keys(bufnr)
        end)
    end,

    _codex_debug_docs_resolution = debug_docs_resolution,
    _codex_debug_hover_docs_resolution = debug_hover_docs_resolution,
    _codex_debug_snapshot = debug_snapshot,
    _codex_hover_or_local_docs = hover_or_local_docs,
    _codex_signature_help_or_notify = signature_help_or_notify,
    _codex_open_docs_in_browser = open_docs_in_browser,
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
