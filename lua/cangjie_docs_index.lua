local M = {}

local state = {
    loaded = false,
    index = nil,
    by_key = {},
    by_source = {},
    by_diagnostic = {},
    symbols = {},
    metadata = {},
}

local extract_symbol_context
local cursor_identifier
local looks_like_api_symbol

local function debug_enabled()
    return vim.g.cangjie_docs_debug == true
end

local function append_debug_log(message)
    if not debug_enabled() then
        return
    end
    local ok, fd = pcall(io.open, "/tmp/cangjie_docs.log", "a")
    if not ok or not fd then
        return
    end
    fd:write(os.date("%H:%M:%S "), message, "\n")
    fd:close()
end

local function set_preview_state(bufnr, winid)
    vim.g.cangjie_docs_preview_buf = bufnr
    vim.g.cangjie_docs_preview_win = winid
end

local function get_preview_state()
    return vim.g.cangjie_docs_preview_buf, vim.g.cangjie_docs_preview_win
end

local function read_file(path)
    local fd = io.open(path, "r")
    if not fd then
        return nil
    end
    local text = fd:read("*a")
    fd:close()
    return text
end

local function write_file(path, text)
    local fd = io.open(path, "w")
    if not fd then
        return false
    end
    fd:write(text)
    fd:close()
    return true
end

local function normalize(s)
    if type(s) ~= "string" then
        return nil
    end
    return s:lower()
end

local function as_string(value)
    if type(value) == "string" then
        return value
    end
    return nil
end

local function as_table(value)
    if type(value) == "table" then
        return value
    end
    return nil
end

local function as_list(value)
    return as_table(value) or {}
end

local function trim(value)
    value = as_string(value)
    if not value then
        return nil
    end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return nil
    end
    return value
end

local function push_text(parts, value)
    value = as_string(value)
    if value and value ~= "" then
        table.insert(parts, value)
    end
end

local function push_unique(list, value)
    if not value then
        return
    end
    for _, existing in ipairs(list) do
        if existing == value then
            return
        end
    end
    table.insert(list, value)
end

local function flatten_lines(lines)
    local out = {}
    for _, line in ipairs(lines or {}) do
        line = as_string(line) or ""
        local start = 1
        while true do
            local nl = line:find("\n", start, true)
            if not nl then
                table.insert(out, line:sub(start))
                break
            end
            table.insert(out, line:sub(start, nl - 1))
            start = nl + 1
        end
    end
    return out
end

local function normalize_path(path)
    path = as_string(path)
    if not path or path == "" then
        return nil
    end
    return path:gsub("\\", "/")
end

local function default_index_path()
    return vim.fn.stdpath("cache") .. "/cangjie/docs-index.json"
end

local function configured_index_path()
    return vim.g.cangjie_doc_index or vim.env.CANGJIE_DOC_INDEX or (vim.fn.stdpath("config") .. "/cangjie-docs.json")
end

local function configured_sync_path()
    return vim.g.cangjie_doc_index or vim.env.CANGJIE_DOC_INDEX or default_index_path()
end

local function configured_source_url()
    return vim.g.cangjie_doc_index_url or vim.env.CANGJIE_DOC_INDEX_URL or nil
end

local function add_key(tbl, key, sym)
    key = as_string(key)
    if not key or key == "" then
        return
    end
    tbl[key] = tbl[key] or {}
    table.insert(tbl[key], sym)
    local nk = normalize(key)
    if nk then
        tbl[nk] = tbl[nk] or {}
        if tbl[nk] ~= tbl[key] then
            table.insert(tbl[nk], sym)
        end
    end
end

local function index_symbol(sym, by_key)
    add_key(by_key, sym.id, sym)
    add_key(by_key, sym.fqname, sym)
    add_key(by_key, sym.display, sym)
    add_key(by_key, sym.name, sym)
    add_key(by_key, sym.qualified_title, sym)
    add_key(by_key, sym.page_title, sym)

    local container = as_string(sym.container) or as_string(sym.module)
    local name = as_string(sym.display) or as_string(sym.name)
    if container and name then
        add_key(by_key, container .. "." .. name, sym)
    end

    for _, a in ipairs(as_list(sym.aliases)) do
        add_key(by_key, a, sym)
    end

    for _, k in ipairs(as_list(sym.search_keys)) do
        add_key(by_key, k, sym)
    end

    for _, k in ipairs(as_list(sym.search_keys_normalized)) do
        add_key(by_key, k, sym)
    end
end

local function index_symbol_source(sym, by_source)
    local source = as_table(sym.source)
    if not source then
        return
    end

    local file = normalize_path(source.file)
    if not file or file == "" then
        return
    end

    by_source[file] = by_source[file] or {}
    table.insert(by_source[file], sym)
end

local function build_search_text(sym)
    if as_string(sym.search_text) then
        return sym.search_text
    end

    local parts = {}
    push_text(parts, sym.id)
    push_text(parts, sym.fqname)
    push_text(parts, sym.display)
    push_text(parts, sym.name)
    push_text(parts, sym.package)
    push_text(parts, sym.module)
    push_text(parts, sym.container)
    push_text(parts, sym.qualified_title)
    push_text(parts, sym.page_title)
    push_text(parts, sym.signature)
    push_text(parts, sym.signature_short)
    push_text(parts, sym.summary_short_md)
    push_text(parts, sym.summary_md)
    push_text(parts, sym.details_md)
    push_text(parts, sym.notes_md)
    push_text(parts, sym.exceptions_md)
    push_text(parts, sym.see_also_md)

    for _, alias in ipairs(as_list(sym.aliases)) do
        push_text(parts, alias)
    end

    for _, key in ipairs(as_list(sym.search_keys)) do
        push_text(parts, key)
    end

    for _, key in ipairs(as_list(sym.search_keys_normalized)) do
        push_text(parts, key)
    end

    local callable = as_table(sym.callable)
    if callable then
        push_text(parts, callable.return_type)
        for _, p in ipairs(as_list(callable.params)) do
            p = as_table(p) or {}
            push_text(parts, p.label)
            push_text(parts, p.type)
            push_text(parts, p.doc_md)
        end
    end

    return table.concat(parts, "\n")
end

local function diagnostic_key(code, source)
    code = tostring(code or "")
    source = normalize(source or "") or ""
    if code == "" then
        return nil
    end
    return code .. "::" .. source
end

local function index_diagnostic(diag, by_diagnostic)
    diag = as_table(diag)
    if not diag then
        return
    end
    local key = diagnostic_key(diag.code, diag.source)
    if key then
        by_diagnostic[key] = diag
    end
end

local function load_index()
    if state.loaded then
        return state.index
    end

    local path = configured_index_path()

    local text = read_file(path)
    if not text then
        vim.notify("找不到 Cangjie 文档索引: " .. path, vim.log.levels.WARN, { title = "Cangjie Docs" })
        state.loaded = true
        return nil
    end

    local ok, data = pcall(vim.json.decode, text)
    if not ok or type(data) ~= "table" then
        vim.notify("Cangjie 文档索引 JSON 解析失败", vim.log.levels.ERROR, { title = "Cangjie Docs" })
        state.loaded = true
        return nil
    end

    state.index = data
    state.by_key = {}
    state.by_source = {}
    state.by_diagnostic = {}
    state.symbols = {}

    state.metadata = {
        format = data.format,
        generated_at = data.generated_at,
        source = data.source,
        symbol_count = data.symbol_count,
        diagnostics = as_list(data.diagnostics),
    }

    local symbols = as_table(data.symbols) or as_table(data.records) or {}
    for _, sym in ipairs(symbols) do
        sym.search_text = build_search_text(sym)
        table.insert(state.symbols, sym)
        index_symbol(sym, state.by_key)
        index_symbol_source(sym, state.by_source)
    end

    for _, diag in ipairs(as_list(data.diagnostics)) do
        index_diagnostic(diag, state.by_diagnostic)
    end

    state.loaded = true
    return state.index
end

local function symbol_url(sym)
    if not sym then
        return nil
    end
    local url = sym.page_url or sym.doc_url
    url = as_string(url)
    if not url or url == "" then
        return nil
    end
    local anchor = as_string(sym.anchor)
    if anchor and anchor ~= "" then
        url = url .. "#" .. anchor
    end
    return url
end

local function symbol_name(sym)
    return as_string(sym.display) or as_string(sym.name)
end

local function symbol_qualified_names(sym)
    local names = {}
    local container = as_string(sym.container) or as_string(sym.module)
    local name = symbol_name(sym)
    local fqname = as_string(sym.fqname)

    push_unique(names, fqname)
    push_unique(names, as_string(sym.qualified_title))
    if container and name then
        push_unique(names, container .. "." .. name)
    end
    push_unique(names, name)

    for _, alias in ipairs(as_list(sym.aliases)) do
        push_unique(names, as_string(alias))
    end

    return names
end

local function score_symbol_match(sym, query)
    query = as_string(query)
    if not query or query == "" then
        return 0
    end

    local normalized_query = normalize(query) or query
    local score = 0

    for _, candidate in ipairs(symbol_qualified_names(sym)) do
        local normalized_candidate = normalize(candidate)
        if normalized_candidate then
            if normalized_candidate == normalized_query then
                if candidate == sym.id or candidate == sym.fqname then
                    score = math.max(score, 120)
                elseif candidate == sym.qualified_title then
                    score = math.max(score, 115)
                elseif candidate == ((as_string(sym.container) or as_string(sym.module) or "") .. "." .. (symbol_name(sym) or "")) then
                    score = math.max(score, 110)
                else
                    score = math.max(score, 100)
                end
            elseif normalized_candidate:sub(-#normalized_query) == normalized_query then
                score = math.max(score, 70 + #normalized_query)
            elseif normalized_candidate:find(normalized_query, 1, true) then
                score = math.max(score, 30 + #normalized_query)
            end
        end
    end

    if score > 0 then
        local container = as_string(sym.container)
        local module_name = as_string(sym.module)
        if container and normalize(container) == normalized_query then
            score = score + 5
        end
        if module_name and normalize(module_name) == normalized_query then
            score = score + 3
        end
        local kind = normalize(as_string(sym.kind) or "")
        if not query:find("%.", 1, true) and kind ~= "" then
            if kind == "prop" or kind == "property" or kind == "field" then
                score = score + 12
            elseif kind == "method" or kind == "function" or kind == "func" then
                score = score + 4
            end
        end
    end

    return score
end

local function rank_symbols(symbols, query)
    local ranked = {}
    for _, sym in ipairs(symbols or {}) do
        table.insert(ranked, {
            sym = sym,
            score = score_symbol_match(sym, query),
            fqname = as_string(sym.fqname) or as_string(sym.id) or "",
        })
    end

    table.sort(ranked, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.fqname < b.fqname
    end)

    return ranked
end

local function best_symbol_for_query(query)
    local matches = state.by_key[query] or state.by_key[normalize(query)]
    if type(matches) ~= "table" or #matches == 0 then
        return nil
    end

    local ranked = rank_symbols(matches, query)
    return ranked[1] and ranked[1].sym or nil
end

local function symbol_container(sym)
    return as_string(sym.container) or as_string(sym.module)
end

local function find_exact_symbol(fields)
    load_index()
    fields = as_table(fields) or {}

    local package_name = normalize(as_string(fields.package))
    local module_name = normalize(as_string(fields.module))
    local container_name = normalize(as_string(fields.container))
    local member_name = normalize(as_string(fields.member))
    local kind_name = normalize(as_string(fields.kind))

    local candidates = {}
    for _, sym in ipairs(state.symbols or {}) do
        local name = normalize(symbol_name(sym))
        local container = normalize(symbol_container(sym))
        local package = normalize(as_string(sym.package))
        local module = normalize(as_string(sym.module))
        local kind = normalize(as_string(sym.kind))

        if member_name and name ~= member_name then
            goto continue
        end
        if container_name and container ~= container_name then
            goto continue
        end
        if package_name and package ~= package_name then
            goto continue
        end
        if module_name and module ~= module_name then
            goto continue
        end
        if kind_name then
            local matches_kind = false
            if kind_name == "variable" then
                matches_kind = kind == "prop" or kind == "property" or kind == "field" or kind == "var" or kind == "let"
            elseif kind_name == "func" then
                matches_kind = kind == "func" or kind == "function" or kind == "method"
            else
                matches_kind = kind == kind_name
            end
            if not matches_kind then
                goto continue
            end
        end

        table.insert(candidates, sym)
        ::continue::
    end

    if #candidates == 0 then
        return nil
    end

    table.sort(candidates, function(a, b)
        return (as_string(a.fqname) or as_string(a.id) or "") < (as_string(b.fqname) or as_string(b.id) or "")
    end)

    return candidates[1]
end

local function find_exact_symbols(fields)
    load_index()
    fields = as_table(fields) or {}

    local package_name = normalize(as_string(fields.package))
    local module_name = normalize(as_string(fields.module))
    local container_name = normalize(as_string(fields.container))
    local member_name = normalize(as_string(fields.member))
    local kind_name = normalize(as_string(fields.kind))

    local candidates = {}
    for _, sym in ipairs(state.symbols or {}) do
        local name = normalize(symbol_name(sym))
        local container = normalize(symbol_container(sym))
        local package = normalize(as_string(sym.package))
        local module = normalize(as_string(sym.module))
        local kind = normalize(as_string(sym.kind))

        if member_name and name ~= member_name then
            goto continue
        end
        if container_name and container ~= container_name then
            goto continue
        end
        if package_name and package ~= package_name then
            goto continue
        end
        if module_name and module ~= module_name then
            goto continue
        end
        if kind_name then
            local matches_kind = false
            if kind_name == "variable" then
                matches_kind = kind == "prop" or kind == "property" or kind == "field" or kind == "var" or kind == "let"
            elseif kind_name == "func" then
                matches_kind = kind == "func" or kind == "function" or kind == "method"
            else
                matches_kind = kind == kind_name
            end
            if not matches_kind then
                goto continue
            end
        end

        table.insert(candidates, sym)
        ::continue::
    end

    table.sort(candidates, function(a, b)
        return (as_string(a.fqname) or as_string(a.id) or "") < (as_string(b.fqname) or as_string(b.id) or "")
    end)

    return candidates
end

local function normalize_hover_member_kind(kind_name)
    kind_name = normalize(as_string(kind_name))
    if not kind_name or kind_name == "" then
        return nil
    end
    if kind_name == "let" or kind_name == "var" or kind_name == "variable" then
        return "variable"
    end
    if kind_name == "prop" or kind_name == "property" or kind_name == "field" then
        return "property"
    end
    if kind_name == "func" or kind_name == "function" or kind_name == "method" then
        return "func"
    end
    return kind_name
end

local function normalize_signature_text(text)
    text = as_string(text)
    if not text or text == "" then
        return nil
    end
    text = text:gsub("^```[%w_]*", "")
    text = text:gsub("```$", "")
    text = text:gsub("%b[]", "")
    text = text:gsub("^%b()", "")
    text = text:gsub("`", "")
    text = text:gsub("%s+", "")
    return text:lower()
end

local function extract_hover_signature_hint(lines, member_name)
    member_name = as_string(member_name)
    for _, raw in ipairs(lines or {}) do
        local line = as_string(raw)
        if line and line ~= "" then
            local hint = normalize_signature_text(line)
            if hint and member_name and hint:find(member_name:lower(), 1, true) then
                return hint
            end
        end
    end
    return nil
end

local function score_overload_candidate(sym, signature_hint)
    signature_hint = normalize_signature_text(signature_hint)
    if not signature_hint then
        return 0
    end

    local candidates = {
        normalize_signature_text(sym.signature_short),
        normalize_signature_text(sym.signature),
        normalize_signature_text(sym.qualified_title),
        normalize_signature_text(sym.page_title),
    }

    local score = 0
    for _, candidate in ipairs(candidates) do
        if candidate then
            if candidate == signature_hint then
                score = math.max(score, 100)
            elseif candidate:find(signature_hint, 1, true) or signature_hint:find(candidate, 1, true) then
                score = math.max(score, 70)
            end

            local hint_has_generic = signature_hint:find("<", 1, true) ~= nil
            local cand_has_generic = candidate:find("<", 1, true) ~= nil
            if hint_has_generic == cand_has_generic then
                score = score + 5
            end

            local hint_has_any = signature_hint:find("any", 1, true) ~= nil
            local cand_has_any = candidate:find("any", 1, true) ~= nil
            if hint_has_any == cand_has_any then
                score = score + 5
            end
        end
    end

    return score
end

local function choose_best_overload(candidates, lines, member_name)
    if #candidates <= 1 then
        return candidates[1]
    end

    local signature_hint = extract_hover_signature_hint(lines, member_name)
    if not signature_hint then
        return candidates[1]
    end

    table.sort(candidates, function(a, b)
        local sa = score_overload_candidate(a, signature_hint)
        local sb = score_overload_candidate(b, signature_hint)
        if sa ~= sb then
            return sa > sb
        end
        return (as_string(a.fqname) or as_string(a.id) or "") < (as_string(b.fqname) or as_string(b.id) or "")
    end)

    return candidates[1]
end

local sanitize_type_name

local function find_member_on_type(type_name, member)
    type_name = sanitize_type_name(type_name)
    member = as_string(member)
    if not type_name or not member or member == "" then
        return nil
    end

    local visited = {}
    local queue = { type_name }

    while #queue > 0 do
        local current = table.remove(queue, 1)
        current = sanitize_type_name(current)
        if current and not visited[current] then
            visited[current] = true

            local direct = best_symbol_for_query(current .. "." .. member)
            if direct then
                return direct
            end

            local type_sym = best_symbol_for_query(current)
            local type_info = type_sym and as_table(type_sym.type_info) or nil
            if type_info then
                for _, base in ipairs(as_list(type_info.bases)) do
                    local name = sanitize_type_name(base)
                    if name and not visited[name] then
                        table.insert(queue, name)
                    end
                end
                for _, impl in ipairs(as_list(type_info.implements)) do
                    local name = sanitize_type_name(impl)
                    if name and not visited[name] then
                        table.insert(queue, name)
                    end
                end
            end
        end
    end
end

local function deprecated_info(sym)
    local deprecated = as_table(sym.deprecated)
    if deprecated then
        return deprecated.is_deprecated, as_string(deprecated.message_md), deprecated
    end
    return sym.deprecated == true, as_string(sym.deprecated_message_md), nil
end

local function add_section(lines, title, value)
    value = trim(value)
    if not value then
        return
    end
    table.insert(lines, "**" .. title .. "：**")
    table.insert(lines, value)
    table.insert(lines, "")
end

local function code_fence(lines, text)
    text = trim(text)
    if not text then
        return
    end
    table.insert(lines, "```cangjie")
    table.insert(lines, text)
    table.insert(lines, "```")
    table.insert(lines, "")
end

local function format_link(title, url)
    title = trim(title)
    url = trim(url)
    if not title or not url then
        return nil
    end
    return ("[%s](%s)"):format(title, url)
end

local function append_deprecated(lines, sym)
    local is_deprecated, deprecated_message, deprecated = deprecated_info(sym)
    if not is_deprecated then
        return
    end
    local msg = deprecated_message or "已弃用。"
    table.insert(lines, "**Deprecated：** " .. msg)

    deprecated = as_table(deprecated)
    local extras = {}
    local replacement_fqname = deprecated and trim(deprecated.replacement_fqname) or nil
    local replacement_url = deprecated and trim(deprecated.replacement_url) or nil
    local deprecated_since = deprecated and trim(deprecated.since) or nil
    if replacement_fqname then
        table.insert(extras, "替代符号：`" .. replacement_fqname .. "`")
    end
    if replacement_url then
        local link = format_link("替代文档", replacement_url)
        table.insert(extras, link or ("替代文档：`" .. replacement_url .. "`"))
    end
    if deprecated_since then
        table.insert(extras, "弃用版本：`" .. deprecated_since .. "`")
    end
    for _, extra in ipairs(extras) do
        table.insert(lines, "- " .. extra)
    end
    table.insert(lines, "")
end

local function append_availability(lines, sym)
    local availability = as_table(sym.availability)
    if not availability then
        return
    end

    local bits = {}
    local supported = as_list(availability.supported_platforms)
    local unsupported = as_list(availability.unsupported_platforms)
    if #supported > 0 then
        table.insert(bits, "支持平台：`" .. table.concat(supported, ", ") .. "`")
    end
    if #unsupported > 0 then
        table.insert(bits, "不支持平台：`" .. table.concat(unsupported, ", ") .. "`")
    end
    if #bits > 0 then
        table.insert(lines, "**可用性：**")
        for _, bit in ipairs(bits) do
            table.insert(lines, "- " .. bit)
        end
        table.insert(lines, "")
    end
end

local function append_extension_info(lines, sym)
    local extension = as_table(sym.extension_info)
    if not extension then
        return
    end

    local bits = {}
    local target = trim(extension.target_display) or trim(extension.target)
    local impl = trim(extension.implements_display) or trim(extension.implements)
    local kind = trim(extension.extension_kind)
    if target then
        table.insert(bits, "目标：`" .. target .. "`")
    end
    if impl then
        table.insert(bits, "实现：`" .. impl .. "`")
    end
    if kind then
        table.insert(bits, "类型：`" .. kind .. "`")
    end
    if #bits > 0 then
        table.insert(lines, "**扩展实现：** " .. table.concat(bits, " · "))
        table.insert(lines, "")
    end
end

local function append_examples_short(lines, sym)
    local snippets = as_list(sym.example_snippets_short)
    if #snippets == 0 then
        return
    end
    table.insert(lines, "**示例：**")
    for _, snippet in ipairs(snippets) do
        local text = trim(snippet)
        if text then
            table.insert(lines, "- `" .. text .. "`")
        end
    end
    table.insert(lines, "")
end

local function clean_markdown_section_body(value, title)
    value = trim(value)
    title = trim(title)
    if not value then
        return nil
    end

    if title then
        local escaped = vim.pesc(title)
        value = value:gsub("^%*%*%s*" .. escaped .. "%s*：%s*%**\n?", "")
        value = value:gsub("^%*%*%s*" .. escaped .. "%s*:%s*%**\n?", "")
        value = value:gsub("^" .. escaped .. "%s*：\n?", "")
        value = value:gsub("^" .. escaped .. "%s*:\n?", "")
    end

    return trim(value)
end

local function append_see_also(lines, sym)
    local see_also = clean_markdown_section_body(sym.see_also_md, "相关")
    local related_links = as_list(sym.related_links)
    if not see_also and #related_links == 0 then
        return
    end

    local example_title_set = {}
    for _, title in ipairs(as_list(sym.example_titles)) do
        title = trim(title)
        if title then
            example_title_set[title] = true
        end
    end

    local section = {}
    if see_also then
        table.insert(section, see_also)
    end
    for _, link in ipairs(related_links) do
        link = as_table(link) or {}
        local title = trim(link.title) or trim(link.kind) or "链接"
        local url = trim(link.url)
        local md = format_link(title, url)
        if md and not example_title_set[title] then
            table.insert(section, "- " .. md)
        end
    end

    if #section == 0 then
        return
    end

    table.insert(lines, "**相关：**")
    for _, line in ipairs(section) do
        table.insert(lines, line)
    end
    table.insert(lines, "")
end

local function get_callable(sym)
    local callable = as_table(sym.callable)
    if callable then
        return callable
    end
    return {
        params = as_list(sym.params),
        return_type = sym.return_type,
        throws = as_list(sym.throws),
    }
end

local function strip_markdown_section(text, patterns)
    text = as_string(text)
    if not text or text == "" then
        return text
    end

    for _, pattern in ipairs(patterns or {}) do
        text = text:gsub(pattern, "")
    end

    text = text:gsub("\n\n\n+", "\n\n")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function normalize_section_heading(line)
    line = as_string(line)
    if not line then
        return nil
    end
    line = line:gsub("%*%*", ""):gsub("%s+", "")
    line = line:gsub("：$", ""):gsub(":$", "")
    return line ~= "" and line or nil
end

local function strip_markdown_sections_by_heading(text, headings)
    text = as_string(text)
    if not text or text == "" then
        return text
    end

    local heading_set = {}
    for _, heading in ipairs(headings or {}) do
        heading_set[heading] = true
    end

    local lines = vim.split(text, "\n", { plain = true })
    local out = {}
    local skipping = false

    for _, line in ipairs(lines) do
        local trimmed = line:match("^%s*(.-)%s*$")
        local heading = normalize_section_heading(trimmed)

        if heading and heading_set[heading] then
            skipping = true
        elseif skipping then
            local starts_new_section = heading and trimmed:match("：$") ~= nil
            local is_list = trimmed:match("^[-*]") ~= nil
                or trimmed:match("^%d+%.") ~= nil
                or trimmed:match("^%[") ~= nil
            if trimmed == "" then
                -- keep skipping through blank separators inside the removed section
            elseif starts_new_section and not heading_set[heading] then
                skipping = false
                table.insert(out, line)
            elseif not is_list and heading == nil then
                skipping = false
                table.insert(out, line)
            end
        else
            table.insert(out, line)
        end
    end

    local cleaned = table.concat(out, "\n")
    cleaned = cleaned:gsub("\n\n\n+", "\n\n")
    cleaned = cleaned:gsub("^%s+", "")
    cleaned = cleaned:gsub("%s+$", "")
    return cleaned
end

local function dedupe_details_md(sym, callable)
    local details_md = as_string(sym.details_md)
    if not details_md or details_md == "" then
        return nil
    end

    local patterns = {}

    if as_list(callable.params)[1] ~= nil then
        table.insert(patterns, "\n?参数：\n[\t ]*.-\n\n")
        table.insert(patterns, "\n?**参数：**\n[\t ]*.-\n\n")
    end

    if as_string(sym.returns_md) or as_string(callable.return_type) then
        table.insert(patterns, "\n?返回值：\n[\t ]*.-\n\n")
        table.insert(patterns, "\n?返回：\n[\t ]*.-\n\n")
        table.insert(patterns, "\n?**返回值：**.-\n\n")
        table.insert(patterns, "\n?**返回类型：**.-\n\n")
    end

    if as_list(callable.throws)[1] ~= nil then
        table.insert(patterns, "\n?异常：\n[\t ]*.-\n\n")
        table.insert(patterns, "\n?**异常：**\n[\t ]*.-\n\n")
        table.insert(patterns, "\n?可能抛出：\n[\t ]*.-\n\n")
        table.insert(patterns, "\n?**可能抛出：**\n[\t ]*.-\n\n")
    end

    details_md = strip_markdown_section(details_md, patterns)

    local headings = {}
    if as_list(callable.params)[1] ~= nil then
        table.insert(headings, "参数")
    end
    if as_string(sym.returns_md) or as_string(callable.return_type) then
        table.insert(headings, "返回")
        table.insert(headings, "返回值")
        table.insert(headings, "返回类型")
    end
    if as_list(callable.throws)[1] ~= nil then
        table.insert(headings, "异常")
        table.insert(headings, "可能抛出")
    end

    return strip_markdown_sections_by_heading(details_md, headings)
end

local function is_callable_kind(kind)
    kind = normalize(kind)
    return kind == "func" or kind == "function" or kind == "method" or kind == "constructor"
end

local function is_property_kind(kind)
    kind = normalize(kind)
    return kind == "prop" or kind == "property" or kind == "field" or kind == "let" or kind == "var" or kind == "variable"
end

local function is_type_kind(kind)
    kind = normalize(kind)
    return kind == "class" or kind == "struct" or kind == "interface" or kind == "enum" or kind == "type"
end

local function append_examples(lines, sym)
    local examples_md = as_list(sym.examples_md)
    local titles = as_list(sym.example_titles)
    if #examples_md == 0 and #titles == 0 then
        return
    end
    table.insert(lines, "**示例：**")
    table.insert(lines, "")
    if #examples_md == 0 then
        for _, title in ipairs(titles) do
            title = trim(title)
            if title then
                table.insert(lines, "- " .. title)
            end
        end
    end
    for _, example in ipairs(examples_md) do
        local text = as_string(example)
        if text and text ~= "" then
            table.insert(lines, text)
            table.insert(lines, "")
        end
    end
end

local function append_type_summary(lines, sym)
    local type_info = as_table(sym.type_info)
    if not type_info then
        return
    end

    local bits = {}
    local type_params = {}
    local bases = {}
    local implements = {}
    for _, value in ipairs(as_list(type_info.type_params)) do
        push_text(type_params, value)
    end
    for _, value in ipairs(as_list(type_info.bases)) do
        push_text(bases, value)
    end
    for _, value in ipairs(as_list(type_info.implements)) do
        push_text(implements, value)
    end
    if #type_params > 0 then
        table.insert(bits, "type params: `" .. table.concat(type_params, ", ") .. "`")
    end
    if #bases > 0 then
        table.insert(bits, "bases: `" .. table.concat(bases, ", ") .. "`")
    end
    if #implements > 0 then
        table.insert(bits, "implements: `" .. table.concat(implements, ", ") .. "`")
    end
    if #bits > 0 then
        table.insert(lines, table.concat(bits, " · "))
        table.insert(lines, "")
    end
end

local function append_property_summary(lines, sym, callable)
    local value_info = as_table(sym.value_info)
    local return_type = as_string(callable.return_type)
    local value_type = value_info and as_string(value_info.value_type) or nil
    local prop_type = value_type or return_type
    if prop_type and prop_type ~= "" then
        table.insert(lines, "**类型：** `" .. prop_type .. "`")
        table.insert(lines, "")
    end

    if value_info and value_info.mutable ~= nil then
        table.insert(lines, value_info.mutable and "**可变：** `true`" or "**只读：** `true`")
        table.insert(lines, "")
    end
end

local function append_callable_summary(lines, sym, callable)
    local returns_md = as_string(sym.returns_md)
    local return_type = as_string(callable.return_type)
    if returns_md and returns_md ~= "" then
        table.insert(lines, "**返回值：** " .. returns_md)
        table.insert(lines, "")
    elseif return_type and return_type ~= "" then
        table.insert(lines, "**返回类型：** `" .. return_type .. "`")
        table.insert(lines, "")
    end

    local params = as_list(callable.params)
    if #params > 0 then
        table.insert(lines, "**参数：**")
        for _, p in ipairs(params) do
            p = as_table(p) or {}
            local flags = {}
            if p.is_named then
                table.insert(flags, "named")
            end
            if p.is_optional then
                table.insert(flags, "optional")
            end
            if p.has_default then
                table.insert(flags, "default")
            end
            local flag_text = #flags > 0 and (" [" .. table.concat(flags, ", ") .. "]") or ""
            local default_text = as_string(p.default_value_md)
            if default_text and default_text ~= "" then
                default_text = " = " .. default_text
            else
                default_text = ""
            end
            table.insert(lines, string.format(
                "- `%s: %s%s`%s — %s",
                as_string(p.label) or "?",
                as_string(p.type) or "?",
                default_text,
                flag_text,
                as_string(p.doc_md) or ""
            ))
        end
        table.insert(lines, "")
    end

    local throws = as_list(callable.throws)
    if #throws > 0 then
        table.insert(lines, "**可能抛出：**")
        for _, e in ipairs(throws) do
            e = as_table(e) or {}
            local exc_name = as_string(e.type) or "Exception"
            local exc_doc = as_string(e.doc_md) or ""
            local exc_url = as_string(e.url)
            if exc_url and exc_url ~= "" then
                table.insert(lines, string.format("- [%s](%s) — %s", exc_name, exc_url, exc_doc))
            else
                table.insert(lines, string.format("- `%s` — %s", exc_name, exc_doc))
            end
        end
        table.insert(lines, "")
    end
end

local function build_hover_markdown(sym)
    local lines = {}
    local callable = get_callable(sym)
    local kind = as_string(sym.kind)

    code_fence(lines, as_string(sym.signature) or as_string(sym.signature_short))
    append_deprecated(lines, sym)
    append_availability(lines, sym)
    append_extension_info(lines, sym)
    add_section(lines, "摘要", sym.summary_short_md)
    if trim(sym.summary_md) and trim(sym.summary_md) ~= trim(sym.summary_short_md) then
        add_section(lines, "说明", sym.summary_md)
    end

    local meta = {}
    local module_name = as_string(sym.module)
    if module_name and module_name ~= "" then
        table.insert(meta, "module: `" .. module_name .. "`")
    end
    local since = as_string(sym.since)
    if since and since ~= "" then
        table.insert(meta, "since: `" .. since .. "`")
    end
    if #meta > 0 then
        table.insert(lines, table.concat(meta, " · "))
        table.insert(lines, "")
    end

    local details_md = dedupe_details_md(sym, callable)
    local notes_md = clean_markdown_section_body(sym.notes_md, "备注")
    local exceptions_md = clean_markdown_section_body(sym.exceptions_md, "异常")
    if exceptions_md and as_list(callable.throws)[1] ~= nil then
        exceptions_md = nil
    end

    if is_callable_kind(kind) then
        append_callable_summary(lines, sym, callable)
    elseif is_property_kind(kind) then
        append_property_summary(lines, sym, callable)
    elseif is_type_kind(kind) then
        append_type_summary(lines, sym)
    end

    add_section(lines, "详情", details_md)
    add_section(lines, "备注", notes_md)
    add_section(lines, "异常", exceptions_md)
    append_see_also(lines, sym)

    append_examples(lines, sym)

    local url = symbol_url(sym)
    local doc_link = format_link("查看文档", url)
    if doc_link then
        table.insert(lines, doc_link)
        table.insert(lines, "")
    end

    return lines
end

local function build_completion_markdown(sym)
    local lines = {}
    code_fence(lines, as_string(sym.signature_short) or as_string(sym.signature))
    append_deprecated(lines, sym)
    add_section(lines, "摘要", sym.summary_short_md or sym.summary_md)
    append_examples_short(lines, sym)
    return lines
end

local function build_signature_help(sym)
    if not sym or not is_callable_kind(sym.kind) then
        return nil
    end

    local callable = get_callable(sym)
    local params = {}
    for _, param in ipairs(as_list(callable.params)) do
        param = as_table(param) or {}
        local docs = {}
        local ptype = trim(param.type)
        local pdoc = trim(param.doc_md)
        local pdefault = trim(param.default_value_md)
        if ptype then
            table.insert(docs, "`" .. ptype .. "`")
        end
        if pdoc then
            table.insert(docs, pdoc)
        end
        if pdefault then
            table.insert(docs, "default: " .. pdefault)
        end
        table.insert(params, {
            label = trim(param.label) or "?",
            documentation = #docs > 0 and {
                kind = "markdown",
                value = table.concat(docs, "\n\n"),
            } or nil,
        })
    end

    local doc_parts = {}
    if trim(sym.summary_short_md) then
        table.insert(doc_parts, trim(sym.summary_short_md))
    end
    local returns_md = trim(sym.returns_md) or trim(callable.return_type)
    if returns_md then
        table.insert(doc_parts, "**返回：** " .. returns_md)
    end

    return {
        signatures = {
            {
                label = trim(sym.signature) or trim(sym.signature_short) or trim(sym.display) or "?",
                documentation = #doc_parts > 0 and {
                    kind = "markdown",
                    value = table.concat(doc_parts, "\n\n"),
                } or nil,
                parameters = params,
            },
        },
        activeSignature = 0,
        activeParameter = 0,
    }
end

function M.find_symbol(name)
    load_index()
    if not name or name == "" then
        return nil
    end
    return best_symbol_for_query(name)
end

local function parse_hover_symbol_context(lines, opts)
    opts = as_table(opts) or {}
    local module_name
    local container_name
    local member_name
    local member_kind

    for _, raw in ipairs(lines) do
        local line = as_string(raw)
        if line and line ~= "" then
            module_name = module_name or line:match("Package info:%s*([%w_%.]+)")
            container_name = container_name
                or line:match("In%s+class%s+([%w_%.]+)")
                or line:match("In%s+struct%s+([%w_%.]+)")
                or line:match("In%s+interface%s+([%w_%.]+)")
                or line:match("In%s+enum%s+([%w_%.]+)")
                or line:match("In%s+type%s+([%w_%.]+)")
                or line:match("%(class%)%s+.-%f[%w_]class%s+([%w_%.]+)")
                or line:match("%(struct%)%s+.-%f[%w_]struct%s+([%w_%.]+)")
                or line:match("%(interface%)%s+.-%f[%w_]interface%s+([%w_%.]+)")
                or line:match("%(enum%)%s+.-%f[%w_]enum%s+([%w_%.]+)")
                or line:match("%(type%)%s+.-%f[%w_]type%s+([%w_%.]+)")
                or (line:find("(class)", 1, true) and line:match("class%s+([%w_%.]+)"))
                or (line:find("(struct)", 1, true) and line:match("struct%s+([%w_%.]+)"))
                or (line:find("(interface)", 1, true) and line:match("interface%s+([%w_%.]+)"))
                or (line:find("(enum)", 1, true) and line:match("enum%s+([%w_%.]+)"))
                or (line:find("(type)", 1, true) and line:match("type%s+([%w_%.]+)"))

            local kind, name = line:match("%)%s+.-%f[%w_](let|var)%s+([%w_]+)")
            member_kind = member_kind or normalize_hover_member_kind(kind)
            member_name = member_name or name
            local prop_kind, prop_name = line:match("%)%s+.-%f[%w_](prop)%s+([%w_]+)")
            member_kind = member_kind or normalize_hover_member_kind(prop_kind)
            member_name = member_name or prop_name
            local func_kind, func_name = line:match("%)%s+.-%f[%w_](func)%s+([%w_]+)")
            member_kind = member_kind or normalize_hover_member_kind(func_kind)
            member_name = member_name or func_name
            member_name = member_name or line:match("%)%s+.-%f[%w_][%w_]+%s+([%w_]+)%s*:")
            if not member_name and line:match("%)%s+.-%f[%w_](init)%f[^%w_]") then
                member_kind = member_kind or normalize_hover_member_kind("init")
                member_name = "init"
            end
        end
    end

    local ctx = as_table(opts.context) or extract_symbol_context()
    local expr = as_string(ctx and ctx.expr) or nil
    local cursor_ident = as_string(ctx and ctx.cursor_ident) or cursor_identifier() or vim.fn.expand("<cword>")

    if not member_name then
        if expr and expr:find(".", 1, true) then
            local parts = vim.split(expr, ".", { plain = true, trimempty = true })
            member_name = parts[#parts]
        elseif cursor_ident and (not container_name or cursor_ident ~= container_name) then
            member_name = cursor_ident
        end
    end

    if container_name and member_name and cursor_ident == container_name then
        if not expr or expr == container_name or expr:find(".", 1, true) == nil then
            member_name = nil
        end
    end

    return {
        module_name = module_name,
        container_name = container_name,
        member_name = member_name,
        member_kind = member_kind,
        expr = expr,
        cursor_ident = cursor_ident,
        line_text = as_string(ctx and ctx.line_text) or nil,
        cursor_col0 = ctx and ctx.cursor_col0 or nil,
    }
end

function M.find_symbol_for_hover_lines(lines, opts)
    load_index()
    if type(lines) ~= "table" or #lines == 0 then
        return nil
    end

    local parsed = parse_hover_symbol_context(lines, opts)
    local module_name = parsed.module_name
    local container_name = parsed.container_name
    local member_name = parsed.member_name
    local member_kind = parsed.member_kind

    append_debug_log(
        ("[hover_parse] expr=%s ident=%s module=%s container=%s member=%s kind=%s"):format(
            tostring(parsed.expr),
            tostring(parsed.cursor_ident),
            tostring(module_name),
            tostring(container_name),
            tostring(member_name),
            tostring(member_kind)
        )
    )

    if not container_name and member_name and parsed.cursor_ident == member_name and looks_like_api_symbol(member_name) then
        local direct_type = nil
        if module_name and module_name ~= "" then
            direct_type = M.find_symbol(module_name .. "." .. member_name)
            append_debug_log("[hover_type_direct] module_ident=" .. tostring(direct_type and (direct_type.fqname or direct_type.id) or nil))
        end
        if not direct_type then
            direct_type = M.find_symbol(member_name)
            append_debug_log("[hover_type_direct] ident=" .. tostring(direct_type and (direct_type.fqname or direct_type.id) or nil))
        end
        if direct_type then
            return direct_type
        end
    end

    if container_name and not member_name then
        append_debug_log(
            ("[hover_type] module=%s container=%s cursor_ident=%s"):format(
                tostring(module_name),
                tostring(container_name),
                tostring(parsed.cursor_ident)
            )
        )
        local type_sym = find_exact_symbol({
            module = module_name,
            member = container_name,
        }) or find_exact_symbol({
            member = container_name,
        })
        if type_sym then
            append_debug_log("[hover_type] exact=" .. tostring(type_sym.fqname or type_sym.id))
            return type_sym
        end

        local queries = {}
        if module_name and module_name ~= "" then
            table.insert(queries, module_name .. "." .. container_name)
        end
        table.insert(queries, container_name)
        table.insert(queries, parsed.cursor_ident)

        for _, query in ipairs(queries) do
            query = as_string(query)
            local sym = query and M.find_symbol(query) or nil
            append_debug_log(
                ("[hover_type] query=%s -> %s"):format(
                    tostring(query),
                    tostring(sym and (sym.fqname or sym.id) or nil)
                )
            )
            if sym then
                return sym
            end
        end

        local ranked = {}
        for _, sym in ipairs(state.symbols or {}) do
            local display = normalize(symbol_name(sym) or "")
            local fqname = normalize(as_string(sym.fqname) or "")
            local module = normalize(as_string(sym.module) or "")
            local aliases = as_list(sym.aliases)
            local target_display = normalize(container_name or "")
            local target_module = normalize(module_name or "")

            local alias_match = false
            for _, alias in ipairs(aliases) do
                if normalize(alias or "") == target_display or normalize(alias or "") == (target_module ~= "" and (target_module .. "." .. target_display) or "") then
                    alias_match = true
                    break
                end
            end

            if display == target_display or fqname == (target_module ~= "" and (target_module .. "." .. target_display) or "") or alias_match then
                local score = 0
                if fqname == (target_module ~= "" and (target_module .. "." .. target_display) or "") then
                    score = score + 120
                end
                if module ~= "" and module == target_module then
                    score = score + 60
                end
                if display == target_display then
                    score = score + 40
                end
                table.insert(ranked, {
                    sym = sym,
                    score = score,
                    fqname = as_string(sym.fqname) or as_string(sym.id) or "",
                })
            end
        end

        table.sort(ranked, function(a, b)
            if a.score ~= b.score then
                return a.score > b.score
            end
            return a.fqname < b.fqname
        end)

        if ranked[1] then
            append_debug_log("[hover_type] ranked=" .. tostring(ranked[1].sym and (ranked[1].sym.fqname or ranked[1].sym.id) or nil))
            return ranked[1].sym
        end

        local fallback_by_ident = parsed.cursor_ident and M.find_symbol(parsed.cursor_ident) or nil
        append_debug_log("[hover_type] cursor_ident_fallback=" .. tostring(fallback_by_ident and (fallback_by_ident.fqname or fallback_by_ident.id) or nil))
        if fallback_by_ident then
            return fallback_by_ident
        end

        append_debug_log("[hover_type] no_match")
    end

    if container_name and member_name then
        local exact_candidates = find_exact_symbols({
            module = module_name,
            container = container_name,
            member = member_name,
            kind = member_kind,
        })
        if #exact_candidates == 0 then
            exact_candidates = find_exact_symbols({
                module = module_name,
                container = container_name,
                member = member_name,
            })
        end
        if #exact_candidates == 0 then
            exact_candidates = find_exact_symbols({
                container = container_name,
                member = member_name,
                kind = member_kind,
            })
        end
        if #exact_candidates == 0 then
            exact_candidates = find_exact_symbols({
                container = container_name,
                member = member_name,
            })
        end

        local exact_sym = choose_best_overload(exact_candidates, lines, member_name) or find_exact_symbol({
            module = module_name,
            container = container_name,
            member = member_name,
        })
        if exact_sym then
            return exact_sym
        end

        local queries = {}
        if module_name and module_name ~= "" then
            table.insert(queries, module_name .. "." .. container_name .. "." .. member_name)
        end
        table.insert(queries, container_name .. "." .. member_name)

        for _, query in ipairs(queries) do
            local sym = M.find_symbol(query)
            if sym then
                return sym
            end
        end
    end
end

function M.debug_hover_symbol_context(lines, opts)
    load_index()
    local parsed = parse_hover_symbol_context(lines, opts)
    local sym = M.find_symbol_for_hover_lines(lines, opts)
    return {
        module_name = parsed.module_name,
        container_name = parsed.container_name,
        member_name = parsed.member_name,
        member_kind = parsed.member_kind,
        expr = parsed.expr,
        cursor_ident = parsed.cursor_ident,
        line_text = parsed.line_text,
        cursor_col0 = parsed.cursor_col0,
        symbol = sym and (sym.fqname or sym.id) or nil,
    }
end

function M.current_cursor_context()
    local ctx = extract_symbol_context()
    local pos = vim.api.nvim_win_get_cursor(0)
    return {
        expr = as_string(ctx and ctx.expr) or nil,
        cursor_ident = cursor_identifier() or vim.fn.expand("<cword>"),
        line_text = vim.api.nvim_get_current_line(),
        cursor_col0 = pos and pos[2] or nil,
    }
end

local function completion_receiver_context()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2] + 1
    local left = line:sub(1, col)
    local receiver = left:match("([%w_%.]+)%.%w*$")
    if not receiver or receiver == "" then
        return nil
    end

    local tail = left:match("([%w_]*)$")
    local receiver_end_col1 = #left - #tail - 1
    if receiver_end_col1 < 1 then
        receiver_end_col1 = #receiver
    end

    return {
        receiver = receiver,
        receiver_end_col1 = receiver_end_col1,
    }
end

function M.find_symbol_for_location(location)
    load_index()
    if type(location) ~= "table" then
        return nil
    end

    local uri = location.targetUri or location.uri
    local range = location.targetSelectionRange or location.targetRange or location.range
    if not uri or type(range) ~= "table" or type(range.start) ~= "table" then
        return nil
    end

    local path = normalize_path(vim.uri_to_fname(uri))
    if not path then
        return nil
    end

    local line1 = (range.start.line or 0) + 1
    local candidates = {}

    for source_file, symbols in pairs(state.by_source or {}) do
        if source_file == path or path:sub(-#source_file) == source_file or source_file:sub(-#path) == path then
            for _, sym in ipairs(symbols) do
                table.insert(candidates, sym)
            end
        end
    end

    if #candidates == 0 then
        return nil
    end

    table.sort(candidates, function(a, b)
        local sa = as_table(a.source) or {}
        local sb = as_table(b.source) or {}
        local la = math.abs((tonumber(sa.line) or 1) - line1)
        local lb = math.abs((tonumber(sb.line) or 1) - line1)
        if la ~= lb then
            return la < lb
        end
        local ca = tonumber(sa.column) or 1
        local cb = tonumber(sb.column) or 1
        if ca ~= cb then
            return ca < cb
        end
        return (as_string(a.fqname) or as_string(a.id) or "") < (as_string(b.fqname) or as_string(b.id) or "")
    end)

    return candidates[1]
end

function M.all_symbols()
    load_index()
    return state.symbols
end

extract_symbol_context = function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2] + 1
    local len = #line
    if col < 1 or col > len + 1 then
        return nil
    end

    local function is_ident_char(ch)
        return ch and ch ~= "" and ch:match("[%w_]")
    end

    local function skip_spaces_left(i)
        while i >= 1 and line:sub(i, i):match("%s") do
            i = i - 1
        end
        return i
    end

    local function skip_spaces_right(i)
        while i <= len and line:sub(i, i):match("%s") do
            i = i + 1
        end
        return i
    end

    local start_col = math.min(col, len)
    if start_col < 1 then
        return nil
    end

    if not is_ident_char(line:sub(start_col, start_col)) and start_col > 1 then
        start_col = start_col - 1
    end

    while start_col >= 1 and not is_ident_char(line:sub(start_col, start_col)) do
        start_col = start_col - 1
    end

    if start_col < 1 then
        return nil
    end

    local ident_start = start_col
    while ident_start > 1 and is_ident_char(line:sub(ident_start - 1, ident_start - 1)) do
        ident_start = ident_start - 1
    end

    local ident_end = start_col
    while ident_end < len and is_ident_char(line:sub(ident_end + 1, ident_end + 1)) do
        ident_end = ident_end + 1
    end

    local parts = { line:sub(ident_start, ident_end) }
    local scan = skip_spaces_left(ident_start - 1)
    while scan >= 1 and line:sub(scan, scan) == "." do
        scan = skip_spaces_left(scan - 1)
        if scan < 1 or not is_ident_char(line:sub(scan, scan)) then
            break
        end

        local prev_end = scan
        local prev_start = prev_end
        while prev_start > 1 and is_ident_char(line:sub(prev_start - 1, prev_start - 1)) do
            prev_start = prev_start - 1
        end

        table.insert(parts, 1, line:sub(prev_start, prev_end))
        scan = skip_spaces_left(prev_start - 1)
    end

    local expr = table.concat(parts, ".")
    return {
        expr = expr,
        start_col = ident_start,
        cursor_col = col,
    }
end

local function extract_symbol_candidates()
    local ctx = extract_symbol_context()
    local expr = ctx and ctx.expr or nil
    if not expr or expr == "" then
        return {}
    end

    local parts = vim.split(expr, ".", { plain = true, trimempty = true })
    local candidates = {}

    for i = 1, #parts do
        local candidate = table.concat(parts, ".", i, #parts)
        table.insert(candidates, candidate)
    end

    return candidates
end

cursor_identifier = function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2] + 1
    local left = line:sub(1, col)
    local right = line:sub(col + 1)

    local left_ident = left:match("([%w_]+)$") or ""
    local right_ident = right:match("^([%w_]+)") or ""
    local ident = left_ident .. right_ident
    if ident == "" then
        return nil
    end
    return ident
end

local function cursor_in_local_binding_position()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2] + 1
    local left = line:sub(1, col)

    return left:match("%f[%w_](let|var|const)%f[^%w_]%s+[%w_]*$")
        or left:match("%f[%w_](for)%f[^%w_]%s+[%w_]*$")
        or left:match("%f[%w_](catch)%f[^%w_]%s+[%w_]*$")
end

looks_like_api_symbol = function(name)
    name = as_string(name)
    if not name or name == "" then
        return false
    end
    return name:find("%.", 1, true) ~= nil or name:match("^[A-Z]") ~= nil
end

local function infer_type_from_rhs(rhs)
    rhs = as_string(rhs)
    if not rhs or rhs == "" then
        return nil
    end

    rhs = rhs:gsub("%s+", "")

    local direct_type = rhs:match("^([%w_%.]+)$")
    if direct_type and direct_type:match("^[A-Z]") then
        return sanitize_type_name(direct_type)
    end

    local callee = rhs:match("^([%w_%.]+)%b()$")
    if callee then
        local sym = best_symbol_for_query(callee)
        if sym then
            local callable = get_callable(sym)
            local return_type = as_string(callable.return_type) or as_string(sym.return_type)
            if return_type and return_type ~= "" then
                return sanitize_type_name(return_type)
            end
        end
    end

    return nil
end

sanitize_type_name = function(type_name)
    type_name = as_string(type_name)
    if not type_name or type_name == "" then
        return nil
    end

    type_name = type_name:gsub("[`%s]", "")
    type_name = type_name:gsub("<.*>$", "")
    type_name = type_name:gsub("[%?%!%[%]]+$", "")
    type_name = type_name:match("([%w_%.]+)$") or type_name
    return type_name ~= "" and type_name or nil
end

local function extract_type_from_hover_lines(lines)
    for _, line in ipairs(lines or {}) do
        local text = as_string(line)
        if text and text ~= "" then
            local candidates = {
                text:match(":%s*([%w_%.<>%[%]%?!]+)"),
                text:match("%-%>%s*([%w_%.<>%[%]%?!]+)"),
                text:match("[Tt]ype%s*:%s*([%w_%.<>%[%]%?!]+)"),
                text:match("([A-Z][%w_%.<>%[%]%?!]+)"),
            }
            for _, candidate in ipairs(candidates) do
                local type_name = sanitize_type_name(candidate)
                if type_name then
                    return type_name
                end
            end
        end
    end
end

local function lsp_hover_lines_at(line_nr, col0)
    local params = {
        textDocument = vim.lsp.util.make_text_document_params(),
        position = { line = line_nr, character = col0 },
    }
    local results = vim.lsp.buf_request_sync(0, "textDocument/hover", params, 500)
    if not results then
        return nil
    end

    for _, res in pairs(results) do
        local result = res and res.result or nil
        if result and result.contents then
            local ok, markdown_lines = pcall(vim.lsp.util.convert_input_to_markdown_lines, result.contents)
            if ok and type(markdown_lines) == "table" then
                markdown_lines = vim.lsp.util.trim_empty_lines(markdown_lines)
                if #markdown_lines > 0 then
                    return markdown_lines
                end
            end
        end
    end
end

local function infer_receiver_type_from_lsp(receiver, receiver_end_col1)
    receiver = as_string(receiver)
    if not receiver or receiver == "" or not receiver_end_col1 then
        return nil
    end

    local line_nr = vim.api.nvim_win_get_cursor(0)[1] - 1
    local hover_lines = lsp_hover_lines_at(line_nr, math.max(receiver_end_col1 - 1, 0))
    local type_name = extract_type_from_hover_lines(hover_lines)
    if not type_name then
        return nil
    end

    if best_symbol_for_query(type_name) then
        return type_name
    end

    local tail = type_name:match("([A-Z][%w_]*)$")
    if tail and best_symbol_for_query(tail) then
        return tail
    end
end

local function infer_local_variable_type(varname)
    varname = as_string(varname)
    if not varname or varname == "" then
        return nil
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local current_line = vim.api.nvim_win_get_cursor(0)[1]

    for line_nr = current_line, 1, -1 do
        local line = vim.api.nvim_buf_get_lines(bufnr, line_nr - 1, line_nr, false)[1] or ""

        local typed_pattern = "%f[%w_](let|var|const)%f[^%w_]%s+" .. vim.pesc(varname) .. "%s*:%s*([%w_%.]+)"
        local declared_type = line:match(typed_pattern)
        if declared_type and declared_type ~= "" then
            return sanitize_type_name(declared_type)
        end

        local assign_pattern = "%f[%w_](let|var|const)%f[^%w_]%s+" .. vim.pesc(varname) .. "%s*=%s*(.+)$"
        local rhs = line:match(assign_pattern)
        if rhs then
            local inferred = infer_type_from_rhs(rhs)
            if inferred then
                return inferred
            end
        end
    end

    return nil
end

local function find_symbol_from_receiver_context()
    local ctx = extract_symbol_context()
    local expr = ctx and ctx.expr or nil
    if not expr or not expr:find(".", 1, true) then
        return nil
    end

    local parts = vim.split(expr, ".", { plain = true, trimempty = true })
    if #parts < 2 then
        return nil
    end

    local member = parts[#parts]
    local receiver = table.concat(parts, ".", 1, #parts - 1)

    local receiver_type = nil
    if looks_like_api_symbol(receiver) then
        receiver_type = receiver
    else
        local receiver_end_col1 = (ctx and ctx.start_col or 1) + #receiver - 1
        receiver_type = infer_receiver_type_from_lsp(receiver, receiver_end_col1)
    end

    if not receiver_type or receiver_type == "" then
        receiver_type = infer_local_variable_type(receiver)
    end

    if not receiver_type or receiver_type == "" then
        return nil
    end

    return find_member_on_type(receiver_type, member)
end

function M.debug_receiver_context()
    local ctx = extract_symbol_context()
    local expr = ctx and ctx.expr or nil
    if not expr or not expr:find(".", 1, true) then
        vim.notify(
            table.concat({
                ("expr=%s"):format(expr or "nil"),
                ("cursor_ident=%s"):format(cursor_identifier() or "nil"),
                "当前不是成员访问表达式",
            }, "\n"),
            vim.log.levels.INFO,
            { title = "Cangjie Docs" }
        )
        return
    end

    local parts = vim.split(expr, ".", { plain = true, trimempty = true })
    local member = parts[#parts]
    local receiver = table.concat(parts, ".", 1, #parts - 1)
    local receiver_end_col1 = (ctx and ctx.start_col or 1) + #receiver - 1
    local lsp_type = nil
    if not looks_like_api_symbol(receiver) then
        lsp_type = infer_receiver_type_from_lsp(receiver, receiver_end_col1)
    end
    local local_type = infer_local_variable_type(receiver)
    local chosen_type = looks_like_api_symbol(receiver) and receiver or lsp_type or local_type
    local resolved = chosen_type and find_member_on_type(chosen_type, member) or nil

    vim.notify(
        table.concat({
            ("expr=%s"):format(expr),
            ("receiver=%s"):format(receiver),
            ("member=%s"):format(member),
            ("lsp_type=%s"):format(lsp_type or "nil"),
            ("local_type=%s"):format(local_type or "nil"),
            ("chosen_type=%s"):format(chosen_type or "nil"),
            ("resolved=%s"):format((resolved and (resolved.fqname or resolved.id)) or "nil"),
        }, "\n"),
        vim.log.levels.INFO,
        { title = "Cangjie Docs" }
    )
end

function M.find_symbol_for_cursor()
    local contextual = find_symbol_from_receiver_context()
    if contextual then
        return contextual
    end

    local candidates = extract_symbol_candidates()
    for index, candidate in ipairs(candidates) do
        if looks_like_api_symbol(candidate) or index > 1 then
            local sym = M.find_symbol(candidate)
            if sym then
                return sym
            end
        end
    end

    if cursor_in_local_binding_position() then
        return nil
    end

    local ident = cursor_identifier() or vim.fn.expand("<cword>")
    if not looks_like_api_symbol(ident) then
        return nil
    end

    local sym = M.find_symbol(ident)
    if sym then
        return sym
    end

    return nil
end

function M.cursor_has_member_access()
    local ctx = extract_symbol_context()
    local expr = ctx and ctx.expr or nil
    return expr ~= nil and expr:find(".", 1, true) ~= nil
end

function M.should_try_lsp_hover()
    local candidates = extract_symbol_candidates()
    for _, candidate in ipairs(candidates) do
        if looks_like_api_symbol(candidate) then
            return true
        end
    end

    if cursor_in_local_binding_position() then
        return false
    end

    local ident = cursor_identifier() or vim.fn.expand("<cword>")
    return looks_like_api_symbol(ident)
end

local function format_symbol_item(sym)
    local display = as_string(sym.display) or as_string(sym.name) or as_string(sym.fqname) or as_string(sym.id) or "?"
    local signature = as_string(sym.signature_short) or as_string(sym.signature) or ""
    local summary = as_string(sym.summary_short_md) or as_string(sym.summary_md) or ""
    if #summary > 48 then
        summary = summary:sub(1, 45) .. "..."
    end
    local meta = table.concat(vim.tbl_filter(function(v)
        return v and v ~= ""
    end, {
        as_string(sym.kind),
        as_string(sym.module),
    }), " · ")

    local parts = { display }
    if meta ~= "" then
        table.insert(parts, "[" .. meta .. "]")
    end
    if signature ~= "" then
        table.insert(parts, signature)
    end
    if summary ~= "" then
        table.insert(parts, summary)
    end
    return table.concat(parts, " — ")
end

local function make_preview(sym)
    return {
        text = table.concat(build_markdown(sym), "\n"),
        ft = "markdown",
    }
end

local function select_with_snacks(symbols)
    local ok, picker_select = pcall(require, "snacks.picker.select")
    if not ok then
        return false
    end

    local items = vim.tbl_map(function(sym)
        return setmetatable({
            preview = make_preview(sym),
        }, { __index = sym })
    end, symbols)

    picker_select.select(items, {
        prompt = "Cangjie Docs",
        format_item = function(item)
            return format_symbol_item(item)
        end,
        snacks = {
            preview = "preview",
            layout = {
                preset = "ivy",
                layout = {
                    box = "horizontal",
                    width = 0.95,
                    min_width = 120,
                    height = 0.9,
                    {
                        box = "vertical",
                        border = "rounded",
                        title = "{title} {live} {flags}",
                        { win = "input", height = 1, border = "bottom" },
                        { win = "list", border = "none" },
                    },
                    {
                        win = "preview",
                        title = "{preview}",
                        width = 0.55,
                        border = "rounded",
                    },
                },
            },
        },
    }, function(choice)
        if choice then
            M.show_symbol(choice)
        end
    end)
    return true
end

function M.select_symbol()
    local symbols = M.all_symbols()
    if not symbols or #symbols == 0 then
        vim.notify("没有可用的 Cangjie 文档索引", vim.log.levels.WARN, { title = "Cangjie Docs" })
        return
    end

    vim.ui.input({ prompt = "Cangjie Docs Query: " }, function(query)
        if query == nil then
            return
        end

        local q = normalize(query or "")
        local filtered = symbols
        if q and q ~= "" then
            filtered = vim.tbl_filter(function(sym)
                local haystack = table.concat(vim.tbl_filter(function(v)
                    return type(v) == "string" and v ~= ""
                end, {
                    as_string(sym.id),
                    as_string(sym.name),
                    as_string(sym.display),
                    as_string(sym.fqname),
                    as_string(sym.module),
                    as_string(sym.signature),
                    as_string(sym.summary_short_md),
                    as_string(sym.summary_md),
                    as_string(sym.details_md),
                    as_string(sym.search_text),
                }), "\n"):lower()
                return haystack:find(q, 1, true) ~= nil
            end, symbols)
        end

        if #filtered == 0 then
            vim.notify("没有匹配的 Cangjie 文档", vim.log.levels.INFO, { title = "Cangjie Docs" })
            return
        end

        table.sort(filtered, function(a, b)
            local ak = as_string(a.fqname) or as_string(a.display) or as_string(a.id) or ""
            local bk = as_string(b.fqname) or as_string(b.display) or as_string(b.id) or ""
            return ak < bk
        end)

        if select_with_snacks(filtered) then
            return
        end

        vim.ui.select(filtered, {
            prompt = "Cangjie Docs",
            format_item = format_symbol_item,
        }, function(choice)
            if choice then
                M.show_symbol(choice)
            end
        end)
    end)
end

function M.show_symbol(sym)
    if not sym then
        vim.notify("没有找到对应的 Cangjie 文档", vim.log.levels.INFO, { title = "Cangjie Docs" })
        return
    end

    local lines = flatten_lines(build_hover_markdown(sym))
    local bufnr, winid = vim.lsp.util.open_floating_preview(lines, "markdown", {
        border = "rounded",
        max_width = 100,
        max_height = 30,
    })
    set_preview_state(bufnr, winid)
end

function M.scroll_preview(key)
    key = as_string(key)
    local _, win = get_preview_state()
    if not key or not win or not vim.api.nvim_win_is_valid(win) then
        set_preview_state(nil, nil)
        return false
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local line_count = vim.api.nvim_buf_line_count(buf)
    local height = vim.api.nvim_win_get_height(win)
    local info = vim.fn.getwininfo(win)
    local topline = (type(info) == "table" and info[1] and info[1].topline) or 1
    local cursor = vim.api.nvim_win_get_cursor(win)
    local step
    if key == "<C-f>" then
        step = math.max(1, height - 2)
    elseif key == "<C-b>" then
        step = -math.max(1, height - 2)
    elseif key == "<C-d>" then
        step = math.max(1, math.floor(height / 2))
    elseif key == "<C-u>" then
        step = -math.max(1, math.floor(height / 2))
    else
        return false
    end

    local new_topline = math.max(1, math.min(line_count, topline + step))
    local new_cursor = math.max(1, math.min(line_count, cursor[1] + step))
    local ok = pcall(function()
        vim.fn.win_execute(
            win,
            string.format("call winrestview({'topline': %d, 'lnum': %d, 'col': 0})", new_topline, new_cursor)
        )
        vim.api.nvim_win_set_cursor(win, { new_cursor, 0 })
    end)
    if not ok then
        return false
    end
    return true
end

function M.find_symbol_for_completion_item(item)
    load_index()
    item = as_table(item) or {}

    local data = as_table(item.data)
    local docs_index_id = trim(data and data.docs_index_id)
    local docs_index_fqname = trim(data and data.docs_index_fqname)
    if docs_index_id then
        local by_id = best_symbol_for_query(docs_index_id)
        if by_id then
            return by_id
        end
    end
    if docs_index_fqname then
        local by_fqname = best_symbol_for_query(docs_index_fqname)
        if by_fqname then
            return by_fqname
        end
    end

    local label = as_string(item.label)
        or as_string(item.insertText)
        or as_string(item.newText)
    if not label or label == "" then
        return nil
    end

    label = label:match("^([%w_%.]+)") or label
    if label == "" then
        return nil
    end

    local receiver_ctx = completion_receiver_context()
    if receiver_ctx then
        local receiver = receiver_ctx.receiver
        local receiver_type
        if looks_like_api_symbol(receiver) then
            receiver_type = receiver
        else
            receiver_type = infer_receiver_type_from_lsp(receiver, receiver_ctx.receiver_end_col1)
                or infer_local_variable_type(receiver)
        end
        if receiver_type then
            local member_sym = find_member_on_type(receiver_type, label)
            if member_sym then
                return member_sym
            end
        end
    end

    local sym = best_symbol_for_query(label)
    if sym then
        return sym
    end

    local detail = as_string(item.detail)
    if detail then
        local type_name = sanitize_type_name(detail)
        if type_name then
            return best_symbol_for_query(type_name)
        end
    end

    return nil
end

function M.documentation_for_completion_item(item)
    local sym = M.find_symbol_for_completion_item(item)
    if not sym then
        return nil, nil
    end
    return {
        kind = "markdown",
        value = table.concat(flatten_lines(build_completion_markdown(sym)), "\n"),
    }, sym
end

function M.hover_markdown_for_symbol(sym)
    if not sym then
        return nil
    end
    return {
        kind = "markdown",
        value = table.concat(flatten_lines(build_hover_markdown(sym)), "\n"),
    }
end

function M.signature_help_for_symbol(sym)
    return build_signature_help(sym)
end

function M.find_diagnostic_doc(code, source)
    load_index()
    local key = diagnostic_key(code, source)
    if not key then
        return nil
    end
    return state.by_diagnostic[key]
end

function M.find_diagnostic_url(code, source)
    local diag = M.find_diagnostic_doc(code, source)
    return diag and trim(diag.page_url) or nil
end

function M.index_path()
    return configured_index_path()
end

function M.index_source_url()
    return configured_source_url()
end

function M.reload()
    state.loaded = false
    state.index = nil
    state.by_key = {}
    state.by_source = {}
    state.by_diagnostic = {}
    state.symbols = {}
    state.metadata = {}
    return load_index()
end

function M.sync_index(opts, callback)
    opts = as_table(opts) or {}
    local url = trim(opts.url) or trim(configured_source_url())
    if not url then
        if callback then
            callback(false, "未配置 Cangjie docs URL，请设置 vim.g.cangjie_doc_index_url 或 CANGJIE_DOC_INDEX_URL")
            return
        end
        return false, "未配置 Cangjie docs URL，请设置 vim.g.cangjie_doc_index_url 或 CANGJIE_DOC_INDEX_URL"
    end

    local target = normalize_path(trim(opts.path) or configured_sync_path())
    if not target then
        if callback then
            callback(false, "未配置 Cangjie docs 本地路径")
            return
        end
        return false, "未配置 Cangjie docs 本地路径"
    end

    local target_dir = vim.fs.dirname(target)
    if target_dir and target_dir ~= "" then
        vim.fn.mkdir(target_dir, "p")
    end

    local tmp = target .. ".tmp"
    local cmd = { "curl", "-fsSL", url, "-o", tmp }
    if callback then
        vim.system(cmd, { text = true }, function(result)
            vim.schedule(function()
                if result.code ~= 0 then
                    os.remove(tmp)
                    local err = trim(result.stderr) or trim(result.stdout) or ("curl failed: " .. tostring(result.code))
                    callback(false, err)
                    return
                end

                local text = read_file(tmp)
                if not text then
                    os.remove(tmp)
                    callback(false, "下载完成但无法读取临时文件")
                    return
                end

                local ok, data = pcall(vim.json.decode, text)
                if not ok or type(data) ~= "table" or type(data.symbols) ~= "table" then
                    os.remove(tmp)
                    callback(false, "下载的 docs-index.json 不是有效的 format=4 索引")
                    return
                end

                if not write_file(target, text) then
                    os.remove(tmp)
                    callback(false, "无法写入本地 docs-index 缓存: " .. target)
                    return
                end
                os.remove(tmp)

                vim.g.cangjie_doc_index = target
                M.reload()
                callback(true, target)
            end)
        end)
        return
    end

    local result = vim.system(cmd, { text = true }):wait()
    if result.code ~= 0 then
        os.remove(tmp)
        local err = trim(result.stderr) or trim(result.stdout) or ("curl failed: " .. tostring(result.code))
        return false, err
    end

    local text = read_file(tmp)
    if not text then
        os.remove(tmp)
        return false, "下载完成但无法读取临时文件"
    end

    local ok, data = pcall(vim.json.decode, text)
    if not ok or type(data) ~= "table" or type(data.symbols) ~= "table" then
        os.remove(tmp)
        return false, "下载的 docs-index.json 不是有效的 format=4 索引"
    end

    if not write_file(target, text) then
        os.remove(tmp)
        return false, "无法写入本地 docs-index 缓存: " .. target
    end
    os.remove(tmp)

    vim.g.cangjie_doc_index = target
    M.reload()
    return true, target
end

function M.set_debug(enabled)
    vim.g.cangjie_docs_debug = enabled == true
end

function M.debug_enabled()
    return debug_enabled()
end

function M.debug_log_path()
    return "/tmp/cangjie_docs.log"
end

function M.clear_debug_log()
    if vim.fn.filereadable(M.debug_log_path()) == 1 then
        os.remove(M.debug_log_path())
    end
end

function M.read_debug_log()
    return read_file(M.debug_log_path()) or ""
end

function M.show_cursor_symbol()
    M.show_symbol(M.find_symbol_for_cursor())
end

function M.open_cursor_symbol_in_browser()
    local sym = M.find_symbol_for_cursor()
    if not sym then
        vim.notify("没有找到对应的 Cangjie 文档", vim.log.levels.INFO, { title = "Cangjie Docs" })
        return
    end

    local url = symbol_url(sym)
    if not url then
        vim.notify("该符号没有文档 URL", vim.log.levels.WARN, { title = "Cangjie Docs" })
        return
    end

    local base = vim.g.cangjie_doc_base_url or ""
    local full = url
    if base ~= "" then
        full = base:gsub("/$", "") .. "/" .. url:gsub("^/", "")
    end

    vim.notify("打开文档: " .. full, vim.log.levels.INFO, { title = "Cangjie Docs" })
    vim.ui.open(full)
end

return M
