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
local sanitize_type_name
local get_callable
local extract_type_from_hover_lines
local infer_local_variable_type
local infer_receiver_type_from_lsp
local split_top_level_csv

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

local function set_preview_state(bufnr, winid, action)
    vim.g.cangjie_docs_preview_buf = bufnr
    vim.g.cangjie_docs_preview_win = winid
    vim.g.cangjie_docs_preview_action = action
end

local function get_preview_state()
    return vim.g.cangjie_docs_preview_buf, vim.g.cangjie_docs_preview_win, vim.g.cangjie_docs_preview_action
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

split_top_level_csv = function(text)
    text = type(text) == "string" and text or nil
    if not text or text == "" then
        return {}
    end

    local parts = {}
    local current = {}
    local angle, paren, bracket, brace = 0, 0, 0, 0

    for i = 1, #text do
        local ch = text:sub(i, i)
        if ch == "<" then
            angle = angle + 1
        elseif ch == ">" and angle > 0 then
            angle = angle - 1
        elseif ch == "(" then
            paren = paren + 1
        elseif ch == ")" and paren > 0 then
            paren = paren - 1
        elseif ch == "[" then
            bracket = bracket + 1
        elseif ch == "]" and bracket > 0 then
            bracket = bracket - 1
        elseif ch == "{" then
            brace = brace + 1
        elseif ch == "}" and brace > 0 then
            brace = brace - 1
        end

        if ch == "," and angle == 0 and paren == 0 and bracket == 0 and brace == 0 then
            table.insert(parts, table.concat(current))
            current = {}
        else
            current[#current + 1] = ch
        end
    end

    if #current > 0 then
        table.insert(parts, table.concat(current))
    end
    return parts
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

local function ensure_string_list(value)
    if type(value) == "string" then
        local item = trim(value)
        return item and { item } or {}
    end
    if type(value) ~= "table" then
        return {}
    end

    local out = {}
    for _, item in ipairs(value) do
        item = trim(item)
        if item then
            table.insert(out, item)
        end
    end
    return out
end

local function configured_source_groups()
    local groups = as_table(vim.g.cangjie_doc_sources)
    return groups or {}
end

local function configured_source_name()
    local selected = trim(vim.g.cangjie_doc_source)
    if selected and configured_source_groups()[selected] then
        return selected
    end
    return nil
end

local function default_index_paths_for_group(name, count)
    local prefix = trim(name) or "source"
    local paths = {}
    for i = 1, math.max(count or 0, 0) do
        if i == 1 then
            paths[i] = vim.fn.stdpath("cache") .. ("/cangjie/%s-docs-index.json"):format(prefix)
        else
            paths[i] = vim.fn.stdpath("cache") .. ("/cangjie/%s-docs-index-%d.json"):format(prefix, i)
        end
    end
    return paths
end

local function source_group_config(name)
    local groups = configured_source_groups()
    local group = as_table(groups[name])
    if not group then
        return nil
    end

    local indexes = ensure_string_list(group.indexes or group.paths or group.index or group.path)
    local urls = ensure_string_list(group.urls or group.source_urls or group.url or group.source_url)
    return {
        name = name,
        indexes = indexes,
        urls = urls,
    }
end

local function configured_index_paths()
    local selected_group = configured_source_name()
    if selected_group then
        local group = source_group_config(selected_group)
        if group and #group.indexes > 0 then
            return group.indexes
        end
        if group and #group.urls > 0 then
            return default_index_paths_for_group(group.name, #group.urls)
        end
    end

    local explicit_many = ensure_string_list(vim.g.cangjie_doc_indexes)
    if #explicit_many > 0 then
        return explicit_many
    end

    local explicit = trim(vim.g.cangjie_doc_index or vim.env.CANGJIE_DOC_INDEX)
    if explicit then
        return { explicit }
    end

    local cache_path = default_index_path()
    if vim.fn.filereadable(cache_path) == 1 then
        return { cache_path }
    end

    return { vim.fn.stdpath("config") .. "/cangjie-docs.json" }
end

local function configured_index_path()
    return configured_index_paths()[1]
end

local function configured_sync_paths()
    local selected_group = configured_source_name()
    if selected_group then
        local group = source_group_config(selected_group)
        if group and #group.indexes > 0 then
            return group.indexes
        end
        if group and #group.urls > 0 then
            return default_index_paths_for_group(group.name, #group.urls)
        end
    end

    local explicit_many = ensure_string_list(vim.g.cangjie_doc_indexes)
    if #explicit_many > 0 then
        return explicit_many
    end

    local explicit = trim(vim.g.cangjie_doc_index or vim.env.CANGJIE_DOC_INDEX)
    if explicit then
        return { explicit }
    end

    return { default_index_path() }
end

local function configured_source_urls()
    local selected_group = configured_source_name()
    if selected_group then
        local group = source_group_config(selected_group)
        if group and #group.urls > 0 then
            return group.urls
        end
    end

    local many = ensure_string_list(vim.g.cangjie_doc_index_urls)
    if #many > 0 then
        return many
    end

    local single = trim(vim.g.cangjie_doc_index_url or vim.env.CANGJIE_DOC_INDEX_URL)
    if single then
        return { single }
    end

    return {}
end

local function configured_source_url()
    return configured_source_urls()[1]
end

local function default_index_path_for_slot(index)
    if index == 1 then
        return default_index_path()
    end
    return vim.fn.stdpath("cache") .. ("/cangjie/docs-index-%d.json"):format(index)
end

local function resolve_sync_targets(urls, opts)
    opts = as_table(opts) or {}
    local explicit_many = ensure_string_list(opts.paths)
    if #explicit_many > 0 then
        return explicit_many
    end

    local explicit_one = trim(opts.path)
    if explicit_one then
        return { explicit_one }
    end

    local configured = configured_sync_paths()
    if #configured >= #urls then
        return configured
    end

    local targets = {}
    for i = 1, #urls do
        targets[i] = configured[i] or default_index_path_for_slot(i)
    end
    return targets
end

local function warn_once_missing_index(path)
    vim.g.cangjie_docs_missing_index_warnings = vim.g.cangjie_docs_missing_index_warnings or {}
    if vim.g.cangjie_docs_missing_index_warnings[path] then
        return
    end
    vim.g.cangjie_docs_missing_index_warnings[path] = true
    vim.notify("找不到 Cangjie 文档索引: " .. path, vim.log.levels.WARN, { title = "Cangjie Docs" })
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

    local paths = configured_index_paths()
    state.by_key = {}
    state.by_source = {}
    state.by_diagnostic = {}
    state.symbols = {}
    state.index = {
        format = nil,
        generated_at = nil,
        source = nil,
        symbol_count = 0,
        diagnostics = {},
        symbols = state.symbols,
        sources = {},
        source_paths = paths,
    }
    state.metadata = {
        format = nil,
        generated_at = nil,
        source = nil,
        symbol_count = 0,
        diagnostics = {},
        sources = {},
        source_paths = paths,
    }

    local loaded_any = false
    for _, path in ipairs(paths) do
        local text = read_file(path)
        if not text then
            warn_once_missing_index(path)
            goto continue
        end

        local ok, data = pcall(vim.json.decode, text)
        if not ok or type(data) ~= "table" then
            vim.notify("Cangjie 文档索引 JSON 解析失败: " .. path, vim.log.levels.ERROR, { title = "Cangjie Docs" })
            goto continue
        end

        loaded_any = true
        state.index.format = state.index.format or data.format
        state.index.generated_at = state.index.generated_at or data.generated_at
        state.index.source = state.index.source or data.source
        state.metadata.format = state.metadata.format or data.format
        state.metadata.generated_at = state.metadata.generated_at or data.generated_at
        state.metadata.source = state.metadata.source or data.source
        table.insert(state.index.sources, {
            path = path,
            generated_at = data.generated_at,
            source = data.source,
            symbol_count = data.symbol_count,
        })
        table.insert(state.metadata.sources, {
            path = path,
            generated_at = data.generated_at,
            source = data.source,
            symbol_count = data.symbol_count,
        })

        local symbols = as_table(data.symbols) or as_table(data.records) or {}
        for _, sym in ipairs(symbols) do
            sym.search_text = build_search_text(sym)
            sym.__doc_index_path = path
            table.insert(state.symbols, sym)
            index_symbol(sym, state.by_key)
            index_symbol_source(sym, state.by_source)
        end

        for _, diag in ipairs(as_list(data.diagnostics)) do
            table.insert(state.index.diagnostics, diag)
            index_diagnostic(diag, state.by_diagnostic)
        end

        ::continue::
    end

    state.index.symbol_count = #state.symbols
    state.metadata.symbol_count = #state.symbols
    state.metadata.diagnostics = state.index.diagnostics

    state.loaded = true
    return loaded_any and state.index or nil
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

local function exact_symbol_for_query(query)
    query = as_string(query)
    if not query or query == "" then
        return nil
    end

    local normalized_query = normalize(query)
    local matches = state.by_key[query] or state.by_key[normalized_query]
    if type(matches) ~= "table" or #matches == 0 then
        return nil
    end

    local exact = {}
    for _, sym in ipairs(matches) do
        for _, candidate in ipairs(symbol_qualified_names(sym)) do
            local normalized_candidate = normalize(candidate)
            if normalized_candidate and normalized_candidate == normalized_query then
                table.insert(exact, sym)
                break
            end
        end
    end

    if #exact == 0 then
        return nil
    end

    local ranked = rank_symbols(exact, query)
    return ranked[1] and ranked[1].sym or nil
end

local function unique_symbol_for_query(query)
    local matches = state.by_key[query] or state.by_key[normalize(query)]
    if type(matches) ~= "table" or #matches == 0 then
        return nil
    end

    local unique = {}
    local seen = {}
    for _, sym in ipairs(matches) do
        local key = as_string(sym.fqname) or as_string(sym.id)
        if key and not seen[key] then
            seen[key] = true
            table.insert(unique, sym)
        end
    end

    return #unique == 1 and unique[1] or nil
end

local function best_type_symbol_for_query(query)
    query = as_string(query)
    if not query or query == "" then
        return nil
    end

    local matches = state.by_key[query] or state.by_key[normalize(query)]
    if type(matches) ~= "table" or #matches == 0 then
        return nil
    end

    local exact = {}
    local normalized_query = normalize(query)
    for _, sym in ipairs(matches) do
        local kind = normalize(as_string(sym.kind))
        if kind == "class" or kind == "struct" or kind == "interface" or kind == "enum" or kind == "type" then
            for _, candidate in ipairs(symbol_qualified_names(sym)) do
                local normalized_candidate = normalize(candidate)
                if normalized_candidate and normalized_candidate == normalized_query then
                    table.insert(exact, sym)
                    break
                end
            end
        end
    end

    if #exact == 0 then
        return nil
    end

    local ranked = rank_symbols(exact, query)
    return ranked[1] and ranked[1].sym or nil
end

local function symbol_container(sym)
    return as_string(sym.container) or as_string(sym.module)
end

local function normalized_container_name(value)
    value = as_string(value)
    if not value or value == "" then
        return nil
    end
    return normalize(sanitize_type_name(value) or value)
end

local function find_exact_symbol(fields)
    load_index()
    fields = as_table(fields) or {}

    local package_name = normalize(as_string(fields.package))
    local module_name = normalize(as_string(fields.module))
    local container_name = normalized_container_name(fields.container)
    local member_name = normalize(as_string(fields.member))
    local kind_name = normalize(as_string(fields.kind))

    local candidates = {}
    for _, sym in ipairs(state.symbols or {}) do
        local name = normalize(symbol_name(sym))
        local container = normalized_container_name(symbol_container(sym))
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
    local container_name = normalized_container_name(fields.container)
    local member_name = normalize(as_string(fields.member))
    local kind_name = normalize(as_string(fields.kind))

    local candidates = {}
    for _, sym in ipairs(state.symbols or {}) do
        local name = normalize(symbol_name(sym))
        local container = normalized_container_name(symbol_container(sym))
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

local function find_constructor_symbol(type_name)
    type_name = sanitize_type_name(type_name)
    if not type_name then
        return nil
    end

    local tail = type_name:match("([%w_]+)$") or type_name
    local candidates = find_exact_symbols({
        container = tail,
        member = "init",
    })
    if #candidates == 0 then
        return nil
    end
    table.sort(candidates, function(a, b)
        return (as_string(a.fqname) or as_string(a.id) or "") < (as_string(b.fqname) or as_string(b.id) or "")
    end)
    return candidates[1]
end

local function prefer_exact_case_candidates(candidates, member_name)
    member_name = as_string(member_name)
    if not member_name or member_name == "" then
        return candidates
    end

    local exact = {}
    for _, sym in ipairs(candidates or {}) do
        if symbol_name(sym) == member_name then
            table.insert(exact, sym)
        end
    end

    return #exact > 0 and exact or candidates
end

local function prefer_top_level_candidates(candidates)
    local top_level = {}
    for _, sym in ipairs(candidates or {}) do
        if trim(as_string(sym.container)) == nil then
            table.insert(top_level, sym)
        end
    end
    return #top_level > 0 and top_level or candidates
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

local function extract_param_types_from_signature(text)
    text = as_string(text)
    if not text or text == "" then
        return {}
    end

    local inside = text:match("%((.*)%)")
    if not inside or inside == "" then
        return {}
    end

    local out = {}
    for part in inside:gmatch("[^,]+") do
        local item = trim(part)
        if item then
            local ptype = trim(item:match(":%s*(.+)$")) or item
            ptype = sanitize_type_name(ptype) or ptype
            if ptype then
                table.insert(out, ptype)
            end
        end
    end
    return out
end

local function extract_return_type_from_signature(text)
    text = as_string(text)
    if not text or text == "" then
        return nil
    end
    local ret = trim(text:match("%)%s*:%s*(.+)$"))
    if not ret then
        return nil
    end
    return sanitize_type_name(ret) or ret
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

local function extract_source_call_hint(parsed, member_name)
    parsed = as_table(parsed) or {}
    local line = as_string(parsed.line_text)
    local col0 = tonumber(parsed.cursor_col0)
    member_name = as_string(member_name)
    if not line or not col0 or not member_name or member_name == "" then
        return nil
    end

    local col1 = col0 + 1
    local member_start = col1
    while member_start > 1 and line:sub(member_start - 1, member_start - 1):match("[%w_]") do
        member_start = member_start - 1
    end
    local member_end = member_start + #member_name - 1
    if line:sub(member_start, member_end) ~= member_name then
        local left = line:sub(1, col1)
        local s, e = left:find(member_name .. "%s*$")
        if not s then
            return nil
        end
        member_start, member_end = s, e
    end

    local i = member_end + 1
    while i <= #line and line:sub(i, i):match("%s") do
        i = i + 1
    end

    local next_char = line:sub(i, i)
    if next_char == "<" then
        return { generic_call = true }
    end
    if next_char == "(" then
        return { generic_call = false }
    end
    return nil
end

local function score_overload_candidate(sym, signature_hint, source_hint)
    signature_hint = normalize_signature_text(signature_hint)
    if not signature_hint then
        signature_hint = nil
    end

    local candidates = {
        normalize_signature_text(sym.signature_short),
        normalize_signature_text(sym.signature),
        normalize_signature_text(sym.qualified_title),
        normalize_signature_text(sym.page_title),
    }

    local score = 0
    local callable = get_callable(sym)
    local candidate_param_types = {}
    for _, p in ipairs(as_list(callable.params)) do
        p = as_table(p) or {}
        local ptype = sanitize_type_name(as_string(p.type))
        if ptype then
            table.insert(candidate_param_types, ptype)
        end
    end
    local hint_param_types = extract_param_types_from_signature(signature_hint)
    local candidate_return_type = sanitize_type_name(as_string(callable.return_type))
        or extract_return_type_from_signature(sym.signature_short)
        or extract_return_type_from_signature(sym.signature)
    local hint_return_type = extract_return_type_from_signature(signature_hint)
    for _, candidate in ipairs(candidates) do
        if candidate then
            if signature_hint and candidate == signature_hint then
                score = math.max(score, 100)
            elseif signature_hint and (candidate:find(signature_hint, 1, true) or signature_hint:find(candidate, 1, true)) then
                score = math.max(score, 70)
            end

            local hint_has_generic = signature_hint and signature_hint:find("<", 1, true) ~= nil or false
            local cand_has_generic = candidate:find("<", 1, true) ~= nil
            if signature_hint and hint_has_generic == cand_has_generic then
                score = score + 5
            end

            local hint_has_any = signature_hint and signature_hint:find("any", 1, true) ~= nil or false
            local cand_has_any = candidate:find("any", 1, true) ~= nil
            if signature_hint and hint_has_any == cand_has_any then
                score = score + 5
            end

            if source_hint and source_hint.generic_call ~= nil then
                if source_hint.generic_call == cand_has_generic then
                    score = score + 30
                else
                    score = score - 15
                end
            end
        end
    end

    if #hint_param_types > 0 or #candidate_param_types > 0 then
        if #hint_param_types == #candidate_param_types then
            score = score + 30
        else
            score = score - math.abs(#hint_param_types - #candidate_param_types) * 10
        end

        for i = 1, math.min(#hint_param_types, #candidate_param_types) do
            if hint_param_types[i] == candidate_param_types[i] then
                score = score + 25
            end
        end
    end

    if hint_return_type and candidate_return_type then
        if hint_return_type == candidate_return_type then
            score = score + 35
        else
            score = score - 25
        end
    end

    return score
end

local function choose_best_overload(candidates, lines, member_name, parsed)
    if #candidates <= 1 then
        return candidates[1]
    end

    local signature_hint = extract_hover_signature_hint(lines, member_name)
    local source_hint = extract_source_call_hint(parsed, member_name)
    if not signature_hint and not source_hint then
        return candidates[1]
    end

    table.sort(candidates, function(a, b)
        local sa = score_overload_candidate(a, signature_hint, source_hint)
        local sb = score_overload_candidate(b, signature_hint, source_hint)
        if sa ~= sb then
            return sa > sb
        end
        return (as_string(a.fqname) or as_string(a.id) or "") < (as_string(b.fqname) or as_string(b.id) or "")
    end)

    return candidates[1]
end

local function choose_best_completion_overload(candidates, item, parsed, receiver_type)
    if #candidates <= 1 then
        return candidates[1]
    end

    item = as_table(item) or {}
    local label = as_string(item.label) or as_string(item.insertText) or as_string(item.newText)
    local signature_hint = as_string(item.detail) or label
    local source_hint = extract_source_call_hint(parsed, label)
    local receiver_tail = receiver_type and ((sanitize_type_name(receiver_type) or receiver_type):match("([%w_]+)$")) or nil
    if not signature_hint and not source_hint then
        return candidates[1]
    end

    local scored = {}
    for _, sym in ipairs(candidates) do
        local score = score_overload_candidate(sym, signature_hint, source_hint)
        if receiver_tail and as_string(sym.container) == receiver_tail then
            score = score + 10
        end
        table.insert(scored, { sym = sym, score = score })
    end

    for i, entry in ipairs(scored) do
        append_debug_log(
            ("[completion] scored_candidate[%d]=%s | %s | score=%s"):format(
                i,
                tostring(entry.sym and (entry.sym.id or entry.sym.fqname) or nil),
                tostring(entry.sym and (entry.sym.signature_short or entry.sym.signature or entry.sym.qualified_title) or nil),
                tostring(entry.score)
            )
        )
    end

    table.sort(scored, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        local af = as_string(a.sym and (a.sym.fqname or a.sym.id) or "") or ""
        local bf = as_string(b.sym and (b.sym.fqname or b.sym.id) or "") or ""
        return af < bf
    end)

    return scored[1] and scored[1].sym or nil
end

local function exact_member_candidates_for_type(type_name, member)
    local sanitized_type = sanitize_type_name(type_name)
    local member_name = as_string(member)
    if not sanitized_type or not member_name or member_name == "" then
        return {}
    end

    local type_tail = sanitized_type:match("([%w_]+)$") or sanitized_type
    local type_module = sanitized_type:match("^(.*)%.([%w_]+)$")
    local candidates = find_exact_symbols({
        module = type_module,
        container = type_tail,
        member = member_name,
    })
    if #candidates == 0 then
        candidates = find_exact_symbols({
            container = type_tail,
            member = member_name,
        })
    end
    return candidates
end

local function member_candidates_on_type_hierarchy(type_name, member)
    type_name = sanitize_type_name(type_name)
    member = as_string(member)
    if not type_name or not member or member == "" then
        return {}
    end

    local visited = {}
    local queue = { type_name }
    local out = {}
    local seen = {}

    while #queue > 0 do
        local current = table.remove(queue, 1)
        current = sanitize_type_name(current)
        if current and not visited[current] then
            visited[current] = true

            for _, sym in ipairs(exact_member_candidates_for_type(current, member)) do
                local sid = as_string(sym.id) or as_string(sym.fqname)
                if sid and not seen[sid] then
                    seen[sid] = true
                    table.insert(out, sym)
                end
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

    return out
end

local function same_module_member_candidates(type_name, member)
    local sanitized_type = sanitize_type_name(type_name)
    member = as_string(member)
    if not sanitized_type or not member or member == "" then
        return {}
    end

    local type_sym = best_symbol_for_query(sanitized_type)
    local module_name = type_sym and as_string(type_sym.module) or sanitized_type:match("^(.*)%.([%w_]+)$")
    if not module_name or module_name == "" then
        return {}
    end

    return find_exact_symbols({
        module = module_name,
        member = member,
    })
end

local function merge_symbol_lists(...)
    local out = {}
    local seen = {}
    for _, list in ipairs({ ... }) do
        for _, sym in ipairs(list or {}) do
            local sid = as_string(sym.id) or as_string(sym.fqname)
            if sid and not seen[sid] then
                seen[sid] = true
                table.insert(out, sym)
            end
        end
    end
    return out
end

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

            local direct_candidates = exact_member_candidates_for_type(current, member)
            local direct = direct_candidates[1]
            if not direct then
                direct = best_symbol_for_query(current .. "." .. member)
            end
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

local function first_sentence(value)
    value = trim(value)
    if not value then
        return nil
    end

    value = value:gsub("\n+", " ")
    local sentence = value:match("^(.-[。！？])") or value:match("^(.-%.)%s") or value:match("^(.-;)%s") or value:match("^(.-；)") or value
    sentence = trim(sentence)
    return sentence ~= "" and sentence or nil
end

local function compact_doc_text(value, max_len)
    local text = first_sentence(value) or trim(value)
    if not text then
        return nil
    end

    max_len = max_len or 72
    if #text > max_len then
        text = trim(text:sub(1, max_len - 1)) .. "…"
    end
    return text
end

local function remove_redundant_summary_prefix(summary_short, summary_full)
    summary_short = trim(summary_short)
    summary_full = trim(summary_full)
    if not summary_short or not summary_full then
        return summary_full
    end

    if summary_full == summary_short then
        return nil
    end

    if vim.startswith(summary_full, summary_short) then
        local rest = trim(summary_full:sub(#summary_short + 1))
        if rest and rest ~= "" then
            return rest
        end
        return nil
    end

    return summary_full
end

local function add_section_compact(lines, title, value, opts)
    value = trim(value)
    if not value then
        return
    end

    opts = as_table(opts) or {}
    local max_len = tonumber(opts.max_len) or 90
    local force_title = opts.force_title == true
    local compact = compact_doc_text(value, max_len)
    local multiline = value:find("\n", 1, true) ~= nil
    local should_inline = not force_title and compact and not multiline and #value <= max_len

    if should_inline then
        table.insert(lines, compact)
        table.insert(lines, "")
        return
    end

    add_section(lines, title, value)
end

local function compact_details_value(value)
    value = trim(value)
    if not value then
        return nil
    end

    local heading, item = value:match("^([^\n：:]+)[：:]%s*\n%s*[-*]%s+(.+)$")
    if heading and item and not item:find("\n", 1, true) then
        return ("%s: %s"):format(trim(heading), trim(item))
    end

    return value
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
    table.insert(lines, "> Deprecated")
    table.insert(lines, ">")
    table.insert(lines, "> " .. msg:gsub("\n", "\n> "))

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
        table.insert(lines, "> - " .. extra)
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
        for _, bit in ipairs(bits) do
            table.insert(lines, "> - " .. bit)
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

    value = value:gsub("^%*%*%s*说明%s*：%s*%**\n?", "")
    value = value:gsub("^%*%*%s*说明%s*:%s*%**\n?", "")
    value = value:gsub("^说明%s*：\n?", "")
    value = value:gsub("^说明%s*:\n?", "")

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

get_callable = function(sym)
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
            local is_list = trimmed:match("^[-*]") ~= nil or trimmed:match("^%d+%.") ~= nil or trimmed:match("^%[") ~= nil
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
        return
    end

    local first_example = trim(as_string(examples_md[1]))
    if first_example then
        table.insert(lines, first_example)
        table.insert(lines, "")
    end

    local remaining = #examples_md - 1
    if remaining > 0 then
        table.insert(lines, ("还有 %d 个示例，建议在浏览器文档中查看。"):format(remaining))
        table.insert(lines, "")
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
        table.insert(lines, "`" .. prop_type .. "`")
        table.insert(lines, "")
    end

    if value_info and value_info.mutable ~= nil then
        table.insert(lines, value_info.mutable and "可变属性" or "只读属性")
        table.insert(lines, "")
    end
end

local function append_callable_summary(lines, sym, callable)
    local returns_md = as_string(sym.returns_md)
    local return_type = as_string(callable.return_type)
    if returns_md and returns_md ~= "" then
        table.insert(lines, "返回: " .. returns_md)
        table.insert(lines, "")
    elseif return_type and return_type ~= "" then
        table.insert(lines, "返回类型: `" .. return_type .. "`")
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
            local pdoc = trim(as_string(p.doc_md))
            if pdoc then
                pdoc = pdoc:gsub("\n+", " ")
            end
            local suffix = pdoc and (" — " .. pdoc) or ""
            table.insert(lines, string.format("- `%s: %s%s`%s%s", as_string(p.label) or "?", as_string(p.type) or "?", default_text, flag_text, suffix))
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
    local summary_short = trim(as_string(sym.summary_short_md))
    if summary_short then
        table.insert(lines, summary_short)
        table.insert(lines, "")
    end
    local summary_full = remove_redundant_summary_prefix(summary_short, as_string(sym.summary_md))
    if summary_full then
        table.insert(lines, summary_full)
        table.insert(lines, "")
    end

    local module_name = trim(as_string(sym.module))
    local meta = {}
    local since = as_string(sym.since)
    if since and since ~= "" then
        table.insert(meta, "since `" .. since .. "`")
    end
    if #meta > 0 then
        table.insert(lines, table.concat(meta, " · "))
        table.insert(lines, "")
    end

    local details_md = dedupe_details_md(sym, callable)
    local notes_md = clean_markdown_section_body(sym.notes_md, "备注")
    local exceptions_md = clean_markdown_section_body(sym.exceptions_md, "异常")
    details_md = clean_markdown_section_body(details_md, "详情")
    if details_md and notes_md and trim(details_md) == trim(notes_md) then
        notes_md = nil
    end
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

    add_section_compact(lines, "详情", compact_details_value(details_md), { max_len = 100 })
    add_section_compact(lines, "备注", notes_md, { max_len = 100 })
    add_section_compact(lines, "异常", exceptions_md, { max_len = 100 })
    append_see_also(lines, sym)

    append_examples(lines, sym)

    if module_name then
        table.insert(lines, "`" .. module_name .. "`")
        table.insert(lines, "")
    end

    local url = symbol_url(sym)
    local doc_link = format_link("查看文档", url)
    if doc_link then
        table.insert(lines, doc_link)
        table.insert(lines, "")
    end

    if #lines == 0 then
        local title = trim(as_string(sym.signature))
            or trim(as_string(sym.signature_short))
            or trim(as_string(sym.qualified_title))
            or trim(as_string(sym.page_title))
            or trim(as_string(sym.display))
            or trim(as_string(sym.fqname))
            or trim(as_string(sym.id))
        if title then
            code_fence(lines, title)
        end
        if module_name then
            table.insert(lines, "`" .. module_name .. "`")
            table.insert(lines, "")
        end
        if doc_link then
            table.insert(lines, doc_link)
            table.insert(lines, "")
        end
        append_debug_log("[hover_doc] fallback title=" .. tostring(title) .. " module=" .. tostring(module_name) .. " link=" .. tostring(doc_link ~= nil))
    end

    return lines
end

local function build_completion_markdown(sym, opts)
    opts = as_table(opts) or {}
    local lines = {}
    local callable = get_callable(sym)
    local kind = as_string(sym.kind)
    if opts.omit_signature ~= true then
        code_fence(lines, as_string(sym.signature_short) or as_string(sym.signature))
    end
    local deprecated = as_table(sym.deprecated)
    if deprecated and deprecated.is_deprecated then
        local dep = trim(as_string(deprecated.message_md)) or "已废弃"
        table.insert(lines, "> Deprecated: " .. dep)
        table.insert(lines, "")
    end
    local summary = trim(as_string(sym.summary_short_md) or as_string(sym.summary_md))
    if summary then
        table.insert(lines, summary)
        table.insert(lines, "")
    end
    if is_callable_kind(kind) then
        local returns_md = as_string(sym.returns_md)
        local return_type = as_string(callable.return_type)
        if returns_md and returns_md ~= "" then
            table.insert(lines, "返回: " .. returns_md)
            table.insert(lines, "")
        elseif return_type and return_type ~= "" then
            table.insert(lines, "返回类型: `" .. return_type .. "`")
            table.insert(lines, "")
        end

        local params = as_list(callable.params)
        if #params > 0 then
            table.insert(lines, "参数:")
            for i = 1, math.min(#params, 3) do
                local p = as_table(params[i]) or {}
                local label = as_string(p.label) or "?"
                local ptype = as_string(p.type) or "?"
                local pdoc = trim(p.doc_md)
                if pdoc then
                    table.insert(lines, string.format("- `%s: %s` — %s", label, ptype, pdoc))
                else
                    table.insert(lines, string.format("- `%s: %s`", label, ptype))
                end
            end
            if #params > 3 then
                table.insert(lines, string.format("- 还有 %d 个参数...", #params - 3))
            end
            table.insert(lines, "")
        end
    elseif is_property_kind(kind) then
        local value_info = as_table(sym.value_info)
        local return_type = as_string(callable.return_type)
        local value_type = value_info and as_string(value_info.value_type) or nil
        local prop_type = value_type or return_type
        if prop_type and prop_type ~= "" then
            table.insert(lines, "类型: `" .. prop_type .. "`")
            table.insert(lines, "")
        end
        local since = as_string(sym.since)
        if since and since ~= "" then
            table.insert(lines, "Since: `" .. since .. "`")
            table.insert(lines, "")
        end
    elseif is_type_kind(kind) then
        local type_info = as_table(sym.type_info)
        if type_info then
            local bases = {}
            local implements = {}
            for _, value in ipairs(as_list(type_info.bases)) do
                push_text(bases, value)
            end
            for _, value in ipairs(as_list(type_info.implements)) do
                push_text(implements, value)
            end
            if #bases > 0 then
                table.insert(lines, "继承: `" .. table.concat(bases, ", ") .. "`")
                table.insert(lines, "")
            end
            if #implements > 0 then
                table.insert(lines, "实现: `" .. table.concat(implements, ", ") .. "`")
                table.insert(lines, "")
            end
        end
        local since = as_string(sym.since)
        if since and since ~= "" then
            table.insert(lines, "Since: `" .. since .. "`")
            table.insert(lines, "")
        end
    end
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
    return exact_symbol_for_query(name)
end

function M.find_symbols(name)
    load_index()
    name = as_string(name)
    if not name or name == "" then
        return {}
    end

    local matches = state.by_key[name] or state.by_key[normalize(name)]
    if type(matches) ~= "table" or #matches == 0 then
        return {}
    end

    local out = {}
    local seen = {}
    for _, sym in ipairs(matches) do
        local key = as_string(sym.id) or as_string(sym.fqname)
        if key and not seen[key] then
            seen[key] = true
            table.insert(out, sym)
        end
    end
    return out
end

function M.find_symbol_for_call(name, arg_count)
    load_index()
    name = as_string(name)
    arg_count = tonumber(arg_count)
    if not name or name == "" then
        return nil
    end

    local matches = state.by_key[name] or state.by_key[normalize(name)]
    if type(matches) ~= "table" or #matches == 0 then
        return nil
    end

    local ranked = {}
    for _, sym in ipairs(matches) do
        local callable = get_callable(sym)
        local params = as_list(callable.params)
        local param_count = #params
        local score = score_symbol_match(sym, name)
        if arg_count ~= nil then
            if param_count == arg_count then
                score = score + 100
            else
                score = score - math.abs(param_count - arg_count) * 10
            end
        end
        table.insert(ranked, {
            sym = sym,
            score = score,
            param_count = param_count,
            fqname = as_string(sym.fqname) or as_string(sym.id) or "",
        })
    end

    table.sort(ranked, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        if arg_count ~= nil and a.param_count ~= b.param_count then
            return math.abs(a.param_count - arg_count) < math.abs(b.param_count - arg_count)
        end
        return a.fqname < b.fqname
    end)

    return ranked[1] and ranked[1].sym or nil
end

function M.resolve_member_on_type(type_name, member)
    load_index()
    return find_member_on_type(type_name, member)
end

local function parse_hover_symbol_context(lines, opts)
    opts = as_table(opts) or {}
    local module_name
    local container_name
    local member_name
    local member_kind

    local function parse_signature_line(line)
        line = trim(line)
        if not line or line == "" then
            return nil
        end
        if line:match("^Package info:") or line:match("^In%s+") then
            return nil
        end

        local type_kind, type_name = line:match("^.-%f[%w_](class|struct|interface|enum)%f[^%w_]%s+([%w_%.]+)")
        if type_kind and type_name then
            return {
                container = type_name,
                kind = type_kind,
            }
        end

        if line:match("^.-%f[%w_](init)%f[^%w_]") then
            return {
                member = "init",
                kind = normalize_hover_member_kind("init"),
            }
        end

        local value_kind, value_name = line:match("^.-%f[%w_](let|var|const|prop)%f[^%w_]%s+([%w_]+)")
        if value_kind and value_name then
            return {
                member = value_name,
                kind = normalize_hover_member_kind(value_kind),
            }
        end

        local _, func_name = line:match("^.-%f[%w_](func)%f[^%w_]%s+([%w_]+)%s*[<%(]")
        if func_name then
            return {
                member = func_name,
                kind = normalize_hover_member_kind("func"),
            }
        end

        return nil
    end

    for _, raw in ipairs(lines) do
        local line = as_string(raw)
        if line and line ~= "" then
            module_name = module_name or line:match("Package info:%s*([%w_%.]+)")
            container_name = container_name
                or line:match("In%s+class%s+([%w_%.<>]+)")
                or line:match("In%s+struct%s+([%w_%.<>]+)")
                or line:match("In%s+interface%s+([%w_%.<>]+)")
                or line:match("In%s+enum%s+([%w_%.<>]+)")
                or line:match("In%s+type%s+([%w_%.<>]+)")
                or line:match("%(class%)%s+.-%f[%w_]class%s+([%w_%.<>]+)")
                or line:match("%(struct%)%s+.-%f[%w_]struct%s+([%w_%.<>]+)")
                or line:match("%(interface%)%s+.-%f[%w_]interface%s+([%w_%.<>]+)")
                or line:match("%(enum%)%s+.-%f[%w_]enum%s+([%w_%.<>]+)")
                or line:match("%(type%)%s+.-%f[%w_]type%s+([%w_%.<>]+)")
                or (line:find("(class)", 1, true) and line:match("class%s+([%w_%.<>]+)"))
                or (line:find("(struct)", 1, true) and line:match("struct%s+([%w_%.<>]+)"))
                or (line:find("(interface)", 1, true) and line:match("interface%s+([%w_%.<>]+)"))
                or (line:find("(enum)", 1, true) and line:match("enum%s+([%w_%.<>]+)"))
                or (line:find("(type)", 1, true) and line:match("type%s+([%w_%.<>]+)"))

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

            local signature = parse_signature_line(line)
            if signature then
                container_name = container_name or signature.container
                member_kind = member_kind or signature.kind
                member_name = member_name or signature.member
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

    if member_kind == "init" then
        member_name = "init"
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

local function extract_declared_type_from_hover_lines(lines, ident)
    ident = as_string(ident)
    for _, raw in ipairs(lines or {}) do
        local line = as_string(raw)
        if line and line ~= "" then
            local target = ident and ident ~= "" and vim.pesc(ident) or "[%w_]+"
            local type_name = line:match("^%s*let%s+" .. target .. "%s*:%s*([%w_%.<>%[%]%?!]+)")
                or line:match("^%s*var%s+" .. target .. "%s*:%s*([%w_%.<>%[%]%?!]+)")
                or line:match("^%s*const%s+" .. target .. "%s*:%s*([%w_%.<>%[%]%?!]+)")
            type_name = sanitize_type_name(type_name)
            if type_name then
                return type_name
            end
        end
    end
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
        append_debug_log(("[hover_type] module=%s container=%s cursor_ident=%s"):format(tostring(module_name), tostring(container_name), tostring(parsed.cursor_ident)))
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
            append_debug_log(("[hover_type] query=%s -> %s"):format(tostring(query), tostring(sym and (sym.fqname or sym.id) or nil)))
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
        exact_candidates = prefer_exact_case_candidates(exact_candidates, member_name)

        local exact_sym = choose_best_overload(exact_candidates, lines, member_name, parsed)
            or find_exact_symbol({
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

    if not container_name and member_name then
        local exact_candidates = find_exact_symbols({
            module = module_name,
            member = member_name,
            kind = member_kind,
        })
        if #exact_candidates == 0 then
            exact_candidates = find_exact_symbols({
                module = module_name,
                member = member_name,
            })
        end
        if #exact_candidates == 0 then
            exact_candidates = find_exact_symbols({
                member = member_name,
                kind = member_kind,
            })
        end
        if #exact_candidates == 0 then
            exact_candidates = find_exact_symbols({
                member = member_name,
            })
        end
        exact_candidates = prefer_top_level_candidates(exact_candidates)
        exact_candidates = prefer_exact_case_candidates(exact_candidates, member_name)

        local exact_sym = choose_best_overload(exact_candidates, lines, member_name, parsed)
        if exact_sym then
            return exact_sym
        end

        local queries = {}
        if module_name and module_name ~= "" then
            table.insert(queries, module_name .. "." .. member_name)
        end
        table.insert(queries, member_name)

        for _, query in ipairs(queries) do
            local sym = M.find_symbol(query)
            if sym then
                return sym
            end
        end

        local hover_type = extract_declared_type_from_hover_lines(lines, parsed.cursor_ident or member_name) or extract_type_from_hover_lines(lines)
        if hover_type then
            local type_sym = best_symbol_for_query(hover_type)
            if type_sym then
                return type_sym
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
    local prefix = left:match("%.([%w_]*)$") or ""
    local receiver_end_col1 = #left - #tail - 1
    if receiver_end_col1 < 1 then
        receiver_end_col1 = #receiver
    end

    return {
        receiver = receiver,
        prefix = prefix,
        receiver_end_col1 = receiver_end_col1,
    }
end

local function prefix_member_candidates_for_type(type_name, prefix)
    type_name = sanitize_type_name(type_name)
    prefix = as_string(prefix) or ""
    if not type_name then
        return {}
    end

    local visited = {}
    local queue = { type_name }
    local out = {}
    local seen = {}

    while #queue > 0 do
        local current = table.remove(queue, 1)
        current = sanitize_type_name(current)
        if current and not visited[current] then
            visited[current] = true

            local type_tail = current:match("([%w_]+)$") or current
            local type_module = current:match("^(.*)%.([%w_]+)$")

            for _, sym in ipairs(state.symbols or {}) do
                local container = as_string(sym.container)
                local member_name = symbol_name(sym)
                if container == type_tail and member_name and member_name ~= "" then
                    local module_name = as_string(sym.module)
                    local module_match = (type_module == nil or type_module == "" or module_name == type_module)
                    local prefix_match = (prefix == "" or member_name:sub(1, #prefix) == prefix)
                    if module_match and prefix_match then
                        local sid = as_string(sym.id) or as_string(sym.fqname)
                        if sid and not seen[sid] then
                            seen[sid] = true
                            table.insert(out, sym)
                        end
                    end
                end
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

    return out
end

local function completion_item_kind_for_symbol(sym)
    local CompletionItemKind = vim.lsp.protocol.CompletionItemKind or {}
    local kind = normalize(as_string(sym and sym.kind) or "")
    if kind == "init" or kind == "constructor" then
        return CompletionItemKind.Constructor or 4
    end
    if kind == "func" or kind == "function" then
        return CompletionItemKind.Function or 3
    end
    if kind == "method" then
        return CompletionItemKind.Method or 2
    end
    if kind == "prop" or kind == "property" or kind == "field" then
        return CompletionItemKind.Field or 5
    end
    if kind == "let" or kind == "var" or kind == "const" then
        return CompletionItemKind.Variable or 6
    end
    if kind == "class" then
        return CompletionItemKind.Class or 7
    end
    if kind == "interface" then
        return CompletionItemKind.Interface or 8
    end
    if kind == "module" or kind == "package" then
        return CompletionItemKind.Module or 9
    end
    if kind == "struct" or kind == "type" then
        return CompletionItemKind.Struct or 22
    end
    if kind == "enum" then
        return CompletionItemKind.Enum or 13
    end
    if kind == "enum_member" then
        return CompletionItemKind.EnumMember or 20
    end
    return CompletionItemKind.Text or 1
end

function M.completion_items_for_current_context()
    load_index()

    local receiver_ctx = completion_receiver_context()
    if not receiver_ctx then
        return {}
    end

    local receiver = receiver_ctx.receiver
    local prefix = receiver_ctx.prefix or ""
    local receiver_type
    if looks_like_api_symbol(receiver) then
        receiver_type = receiver
    else
        receiver_type = infer_receiver_type_from_lsp(receiver, receiver_ctx.receiver_end_col1) or infer_local_variable_type(receiver)
    end
    if not receiver_type then
        return {}
    end

    local candidates = prefix_member_candidates_for_type(receiver_type, prefix)
    local items = {}
    local seen_labels = {}

    table.sort(candidates, function(a, b)
        local an = as_string(symbol_name(a)) or ""
        local bn = as_string(symbol_name(b)) or ""
        if an ~= bn then
            return an < bn
        end
        local af = as_string(a.fqname) or as_string(a.id) or ""
        local bf = as_string(b.fqname) or as_string(b.id) or ""
        return af < bf
    end)

    for _, sym in ipairs(candidates) do
        local label = as_string(symbol_name(sym))
        if label and label ~= "" and not seen_labels[label] then
            seen_labels[label] = true
            table.insert(items, {
                label = label,
                kind = completion_item_kind_for_symbol(sym),
                detail = as_string(sym.signature_short) or as_string(sym.signature) or as_string(sym.fqname),
                insertText = label,
                filterText = label,
                data = {
                    docs_index_id = sym.id,
                    docs_index_fqname = sym.fqname,
                },
            })
        end
    end

    return items
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

local function synthetic_hover_lines_for_symbol(sym)
    sym = as_table(sym)
    if not sym then
        return nil
    end

    local lines = {}
    if trim(sym.module) then
        table.insert(lines, "Package info: " .. sym.module)
    end

    local container = trim(as_string(sym.container))
    if container then
        local module_name = trim(as_string(sym.module))
        local container_sym = best_symbol_for_query((module_name and (module_name .. "." .. container)) or container)
        local container_kind = trim(container_sym and container_sym.kind) or "class"
        table.insert(lines, ("In %s %s"):format(container_kind, container))
    end

    local signature = trim(as_string(sym.signature_short)) or trim(as_string(sym.signature)) or trim(as_string(sym.qualified_title))
    if signature then
        table.insert(lines, signature)
    elseif trim(as_string(sym.display)) then
        table.insert(lines, as_string(sym.display))
    end

    return #lines > 0 and lines or nil
end

function M.synthetic_hover_cases(opts)
    load_index()
    opts = as_table(opts) or {}

    local limit = tonumber(opts.limit)
    local include_kinds = {}
    for _, kind in ipairs(as_list(opts.include_kinds)) do
        include_kinds[normalize(kind)] = true
    end

    if vim.tbl_isempty(include_kinds) then
        include_kinds = {
            class = true,
            struct = true,
            interface = true,
            enum = true,
            method = true,
            property = true,
            ["function"] = true,
            constructor = true,
            const = true,
            var = true,
        }
    end

    local cases = {}
    for _, sym in ipairs(state.symbols or {}) do
        local kind = normalize(sym.kind)
        if include_kinds[kind] then
            local lines = synthetic_hover_lines_for_symbol(sym)
            if lines then
                local module_name = trim(as_string(sym.module))
                local container = trim(as_string(sym.container))
                local display = as_string(sym.display) or as_string(sym.name)
                table.insert(cases, {
                    name = as_string(sym.fqname) or as_string(sym.id) or display or "?",
                    expected = as_string(sym.fqname) or as_string(sym.id),
                    kind = as_string(sym.kind),
                    lines = lines,
                    context = {
                        cursor_ident = display,
                        expr = container and display and (container .. "." .. display)
                            or (module_name and display and not container and kind ~= "class" and kind ~= "struct" and kind ~= "interface" and kind ~= "enum" and (module_name .. "." .. display))
                            or display,
                    },
                })
                if limit and #cases >= limit then
                    break
                end
            end
        end
    end

    return cases
end

function M.compare_hover_cases(cases, opts)
    load_index()
    opts = as_table(opts) or {}
    cases = as_list(cases)

    local results = {}
    local passed = 0

    for index, case in ipairs(cases) do
        case = as_table(case) or {}
        local expected = trim(case.expected)
        local lines = as_list(case.lines)
        local matched = M.find_symbol_for_hover_lines(lines, {
            context = as_table(case.context),
        })
        local actual = matched and (matched.fqname or matched.id) or nil
        local ok = expected ~= nil and actual == expected
        if ok then
            passed = passed + 1
        end

        table.insert(results, {
            index = index,
            name = trim(case.name) or expected or ("case-" .. index),
            expected = expected,
            actual = actual,
            ok = ok,
            kind = trim(case.kind),
            lines = lines,
            debug = M.debug_hover_symbol_context(lines, {
                context = as_table(case.context),
            }),
        })
    end

    local failures = {}
    for _, result in ipairs(results) do
        if not result.ok then
            table.insert(failures, result)
        end
    end

    if opts.failures_only then
        results = failures
    end

    return {
        total = #cases,
        passed = passed,
        failed = #cases - passed,
        failures = failures,
        results = results,
    }
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

local function cursor_in_call_like_position()
    local line = vim.api.nvim_get_current_line()
    local ctx = extract_symbol_context()
    local expr = as_table(ctx) and as_string(ctx.expr) or nil
    if not expr or expr == "" then
        return false
    end

    local parts = vim.split(expr, ".", { plain = true, trimempty = true })
    local ident = parts[#parts]
    local start_col = tonumber(ctx.start_col)

    if not ident or ident == "" or not start_col or start_col < 1 then
        return false
    end

    local idx = start_col + #ident
    while idx <= #line and line:sub(idx, idx):match("%s") do
        idx = idx + 1
    end

    local next_char = line:sub(idx, idx)
    return next_char == "(" or next_char == "<"
end

local function cursor_in_local_binding_position()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2] + 1
    local left = line:sub(1, col)

    return left:match("^%s*let%s+[%w_]*$")
        or left:match("^%s*var%s+[%w_]*$")
        or left:match("^%s*const%s+[%w_]*$")
        or left:match("^%s*for%s+[%w_]*$")
        or left:match("^%s*catch%s+[%w_]*$")
end

local function cursor_in_pattern_binding_position()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2] + 1
    local left = line:sub(1, col)

    return left:match("^%s*case.+%(%s*[%w_]*$") ~= nil
        or left:match("^%s*case.+,%s*[%w_]*$") ~= nil
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

    local function display_type_name_local(type_name)
        type_name = trim(as_string(type_name))
        if not type_name or type_name == "" then
            return nil
        end
        local nullable_prefix = type_name:match("^%?")
        type_name = type_name:gsub("[`%s]", "")
        type_name = type_name:gsub("[%?%!%[%]]+$", "")
        type_name = type_name:match("([%w_%.<>%[%],]+)$") or type_name
        if nullable_prefix and not type_name:match("^%?") then
            type_name = "?" .. type_name
        end
        return type_name ~= "" and type_name or nil
    end

    if rhs:match('^".*"$') then
        return "String"
    end
    if rhs:match("^'.*'$") then
        return "Rune"
    end
    if rhs == "true" or rhs == "false" then
        return "Bool"
    end
    if rhs:match("^%-?%d+$") then
        return "Int64"
    end
    if rhs:match("^%-?%d+%.%d+$") then
        return "Float64"
    end
    if rhs:find("+", 1, true) and not rhs:find("[%*/%%]", 1) then
        local only_string_parts = true
        for part in rhs:gmatch("[^+]+") do
            if not part:match('^".*"$') then
                only_string_parts = false
                break
            end
        end
        if only_string_parts then
            return "String"
        end
    end

    local function indexed_expr_return_type(expr)
        local receiver, bracket = expr:match("^([%w_%.]+)%[(.*)%]$")
        if not receiver or not bracket then
            return nil
        end

        local receiver_type = nil
        if looks_like_api_symbol(receiver) then
            receiver_type = display_type_name_local(receiver)
        elseif infer_local_variable_type then
            receiver_type = infer_local_variable_type(receiver)
        end
        local receiver_base = sanitize_type_name(receiver_type)
        append_debug_log(
            ("[infer_rhs_index] rhs=%s receiver=%s receiver_type=%s base=%s bracket=%s"):format(
                tostring(expr),
                tostring(receiver),
                tostring(receiver_type),
                tostring(receiver_base),
                tostring(bracket)
            )
        )
        if not receiver_base then
            return nil
        end

        local type_sym = best_symbol_for_query(receiver_base)
        local module_name = type_sym and as_string(type_sym.module) or receiver_base:match("^(.*)%.([%w_]+)$")
        local container_name = (type_sym and as_string(type_sym.display)) or receiver_base:match("([%w_]+)$") or receiver_base
        local arg_count = #(split_top_level_csv(bracket) or {})
        local wants_slice = bracket:find("..", 1, true) ~= nil
        append_debug_log(
            ("[infer_rhs_index] mode=%s arg_count=%s"):format(
                wants_slice and "slice" or "index",
                tostring(arg_count)
            )
        )
        local operator_return_type = nil

        for _, sym in ipairs(state.symbols or {}) do
            local kind = normalize(as_string(sym.kind) or "")
            local container = as_string(sym.container)
            local sym_module = as_string(sym.module)
            local signature = as_string(sym.signature) or as_string(sym.signature_short) or ""
            local callable = get_callable(sym)
            local return_type = as_string(callable.return_type) or as_string(sym.return_type)
            if kind == "operator"
                and container == container_name
                and signature:find("operator", 1, true)
                and signature:find("[]", 1, true)
                and (not module_name or module_name == "" or sym_module == module_name)
                and return_type
                and return_type ~= ""
                and sanitize_type_name(return_type) ~= "Unit"
            then
                local param_count = #(as_list(callable.params))
                local accepts_index = (not wants_slice) and arg_count <= 1 and param_count <= 1
                local accepts_slice = wants_slice
                    and (
                        signature:find("Range", 1, true)
                        or signature:find("..", 1, true)
                        or param_count > 1
                    )
                if accepts_index or accepts_slice then
                    operator_return_type = display_type_name_local(return_type)
                    append_debug_log(
                        ("[infer_rhs_index] operator_hit=%s signature=%s return_type=%s"):format(
                            tostring(sym.fqname or sym.id),
                            tostring(signature),
                            tostring(operator_return_type)
                        )
                    )
                    break
                end
            end
        end

        if operator_return_type then
            return operator_return_type
        end

        if receiver_base == "String" then
            if wants_slice then
                append_debug_log("[infer_rhs_index] string_slice_fallback=String")
                return "String"
            end
            local get_sym = find_member_on_type(receiver_base, "get")
            if get_sym then
                local callable = get_callable(get_sym)
                local return_type = as_string(callable.return_type) or as_string(get_sym.return_type)
                local display = display_type_name_local(return_type)
                append_debug_log(
                    ("[infer_rhs_index] string_get_fallback=%s return_type=%s"):format(
                        tostring(get_sym.fqname or get_sym.id),
                        tostring(display)
                    )
                )
                if display then
                    return display
                end
            end
        end

        append_debug_log("[infer_rhs_index] no_match")
        return nil
    end

    local indexed_type = indexed_expr_return_type(rhs)
    if indexed_type then
        return indexed_type
    end

    local direct_type = rhs:match("^([%w_%.]+)$")
    if direct_type and direct_type:match("^[A-Z]") then
        return sanitize_type_name(direct_type)
    end

    local callee = rhs:match("^([%w_%.]+)%b()$")
    if callee then
        if callee:match("^[A-Z]") then
            local init_sym = find_constructor_symbol(callee)
            if init_sym then
                return sanitize_type_name(callee)
            end
        end
        local receiver, member = callee:match("^(.-)%.([%w_]+)$")
        if receiver and member then
            local receiver_type = nil
            if looks_like_api_symbol(receiver) then
                receiver_type = sanitize_type_name(receiver)
            elseif infer_local_variable_type then
                receiver_type = infer_local_variable_type(receiver)
            end
            if receiver_type then
                local member_sym = find_member_on_type(receiver_type, member)
                if member_sym then
                    local callable = get_callable(member_sym)
                    local return_type = as_string(callable.return_type) or as_string(member_sym.return_type)
                    if return_type and return_type ~= "" then
                        return sanitize_type_name(return_type)
                    end
                end
            end
        end
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

local function display_type_name(type_name)
    type_name = trim(as_string(type_name))
    if not type_name or type_name == "" then
        return nil
    end
    local nullable_prefix = type_name:match("^%?")
    type_name = type_name:gsub("[`%s]", "")
    type_name = type_name:gsub("[%?%!%[%]]+$", "")
    type_name = type_name:match("([%w_%.<>%[%],]+)$") or type_name
    if nullable_prefix and not type_name:match("^%?") then
        type_name = "?" .. type_name
    end
    return type_name ~= "" and type_name or nil
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
    if type_name == "Invalid" then
        return nil
    end
    return type_name ~= "" and type_name or nil
end

extract_type_from_hover_lines = function(lines)
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

infer_receiver_type_from_lsp = function(receiver, receiver_end_col1)
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

local function parameter_type_from_signature_line(line, varname)
    line = as_string(line)
    varname = trim(varname)
    if not line or line == "" or not varname or varname == "" then
        return nil
    end

    local params_text = line:match("func%s+[%w_%.<>]+%s*%((.*)%)")
        or line:match("init%s*%((.*)%)")
    if not params_text then
        return nil
    end

    for _, part in ipairs(split_top_level_csv(params_text) or {}) do
        local piece = trim(part)
        if piece then
            local name, ptype = piece:match("^([%w_]+)!?%s*:%s*([%w_%.<>%[%]%?!]+)")
            if name == varname then
                append_debug_log(
                    ("[infer_local] var=%s param_hit=%s line=%s"):format(
                        tostring(varname),
                        tostring(ptype),
                        tostring(line)
                    )
                )
                return display_type_name(ptype)
            end
        end
    end
end

local function declared_type_from_line_raw(line, varname)
    line = as_string(line)
    varname = as_string(varname)
    if not line or not varname or varname == "" then
        return nil
    end

    local patterns = {
        "^%s*let%s+" .. vim.pesc(varname) .. "%s*:%s*([^=]+)",
        "^%s*var%s+" .. vim.pesc(varname) .. "%s*:%s*([^=]+)",
        "^%s*const%s+" .. vim.pesc(varname) .. "%s*:%s*([^=]+)",
    }
    for _, pattern in ipairs(patterns) do
        local declared = trim(line:match(pattern))
        if declared then
            return declared
        end
    end
end

local function option_inner_type(type_name)
    type_name = trim(as_string(type_name))
    if not type_name then
        return nil
    end

    local generic = trim(type_name:match("^[%w_%.]+%s*<(.+)>$"))
    if generic and (type_name:match("^Option%s*<") or type_name:match("^.*%.Option%s*<")) then
        return generic
    end
    if type_name:match("^%?") then
        return trim(type_name:sub(2))
    end
end

local function infer_pattern_binding_type(bufnr, line_nr, varname)
    varname = as_string(varname)
    if not varname or varname == "" then
        return nil
    end

    for lnum = line_nr, 1, -1 do
        local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
        local some_pat = "^%s*case%s+Some%s*%(%s*" .. vim.pesc(varname) .. "%s*%)"
        if line:match(some_pat) then
            local match_expr = nil
            for back = lnum - 1, 1, -1 do
                local prev = vim.api.nvim_buf_get_lines(bufnr, back - 1, back, false)[1] or ""
                match_expr = trim(prev:match("^%s*match%s*%((.+)%)%s*{?"))
                if match_expr then
                    break
                end
            end

            append_debug_log(
                ("[infer_pattern] var=%s line=%d match_expr=%s"):format(
                    tostring(varname),
                    lnum,
                    tostring(match_expr)
                )
            )

            if match_expr then
                local raw_scrutinee_type = nil
                if match_expr:match("^[%w_]+$") then
                    for back = lnum - 1, 1, -1 do
                        local prev = vim.api.nvim_buf_get_lines(bufnr, back - 1, back, false)[1] or ""
                        raw_scrutinee_type = declared_type_from_line_raw(prev, match_expr)
                        if raw_scrutinee_type then
                            break
                        end
                    end
                end

                local scrutinee_type = raw_scrutinee_type
                    or infer_local_variable_type(match_expr)
                    or infer_type_from_rhs(match_expr)
                local inner = option_inner_type(scrutinee_type)

                append_debug_log(
                    ("[infer_pattern] var=%s scrutinee_type=%s inner=%s"):format(
                        tostring(varname),
                        tostring(scrutinee_type),
                        tostring(inner)
                    )
                )

                if inner then
                    return display_type_name(inner)
                end
            end
        end
    end
end

local function infer_match_scrutinee_type(bufnr, line_nr)
    for back = line_nr - 1, 1, -1 do
        local prev = vim.api.nvim_buf_get_lines(bufnr, back - 1, back, false)[1] or ""
        local match_expr = trim(prev:match("^%s*match%s*%((.+)%)%s*{?"))
        if match_expr then
            local raw_scrutinee_type = nil
            if match_expr:match("^[%w_]+$") then
                for scan = back - 1, 1, -1 do
                    local decl = vim.api.nvim_buf_get_lines(bufnr, scan - 1, scan, false)[1] or ""
                    raw_scrutinee_type = declared_type_from_line_raw(decl, match_expr)
                    if raw_scrutinee_type then
                        break
                    end
                end
            end
            return match_expr, raw_scrutinee_type or infer_local_variable_type(match_expr) or infer_type_from_rhs(match_expr)
        end
    end
    return nil, nil
end

local function pattern_constructor_symbol_for_cursor()
    local ident = cursor_identifier() or vim.fn.expand("<cword>")
    if ident ~= "None" and ident ~= "Some" then
        return nil
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local line_nr = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(bufnr, line_nr - 1, line_nr, false)[1] or ""
    if not line:match("^%s*case%s+" .. vim.pesc(ident)) then
        return nil
    end

    local match_expr, scrutinee_type = infer_match_scrutinee_type(bufnr, line_nr)
    local base = scrutinee_type and sanitize_type_name(scrutinee_type) or nil
    append_debug_log(
        ("[pattern_ctor] ident=%s line=%d match_expr=%s scrutinee_type=%s base=%s"):format(
            tostring(ident),
            line_nr,
            tostring(match_expr),
            tostring(scrutinee_type),
            tostring(base)
        )
    )

    if base == "Option" then
        local sym = find_exact_symbol({ module = "std.core", member = "Option", kind = "enum" })
            or find_exact_symbol({ module = "std.core", member = "Option" })
            or exact_symbol_for_query("std.core.Option")
            or best_type_symbol_for_query("std.core.Option")
            or exact_symbol_for_query("Option")
            or best_type_symbol_for_query("Option")
        append_debug_log("[pattern_ctor] resolved=" .. tostring(sym and (sym.fqname or sym.id) or nil))
        return sym
    end
    return nil
end

local function source_symbol_for_cursor()
    load_index()
    local path = normalize_path(vim.api.nvim_buf_get_name(0))
    local ident = cursor_identifier() or vim.fn.expand("<cword>")
    if not path or not ident or ident == "" then
        return nil
    end

    local module_guess = nil
    local std_mod = path:match("/stdlib/libs/std/(.+)/[^/]+%.cj$")
    if std_mod then
        module_guess = "std." .. std_mod:gsub("/", ".")
    end
    if module_guess then
        local exact = find_exact_symbol({ module = module_guess, member = ident })
        append_debug_log("[source_cursor] ident=" .. tostring(ident) .. " module_guess=" .. tostring(module_guess) .. " exact=" .. tostring(exact and (exact.fqname or exact.id) or nil))
        if exact then
            return exact
        end
    end

    local symbols = state.by_source and state.by_source[path]
    if type(symbols) ~= "table" or #symbols == 0 then
        return nil
    end

    local line1 = vim.api.nvim_win_get_cursor(0)[1]
    local matches = {}
    for _, sym in ipairs(symbols) do
        local name = normalize(symbol_name(sym))
        if name == normalize(ident) then
            matches[#matches + 1] = sym
        end
    end

    if #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b)
        local sa = as_table(a.source) or {}
        local sb = as_table(b.source) or {}
        local la = math.abs((tonumber(sa.line) or 1) - line1)
        local lb = math.abs((tonumber(sb.line) or 1) - line1)
        if la ~= lb then
            return la < lb
        end
        return (as_string(a.fqname) or as_string(a.id) or "") < (as_string(b.fqname) or as_string(b.id) or "")
    end)

    local sym = matches[1]
    append_debug_log("[source_cursor] ident=" .. tostring(ident) .. " resolved=" .. tostring(sym and (sym.fqname or sym.id) or nil))
    return sym
end

infer_local_variable_type = function(varname)
    varname = as_string(varname)
    if not varname or varname == "" then
        return nil
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local current_line = vim.api.nvim_win_get_cursor(0)[1]

    for line_nr = current_line, 1, -1 do
        local line = vim.api.nvim_buf_get_lines(bufnr, line_nr - 1, line_nr, false)[1] or ""

        local declared_type = declared_type_from_line_raw(line, varname)
        if declared_type and declared_type ~= "" then
            append_debug_log(("[infer_local] var=%s line=%d declared=%s"):format(varname, line_nr, tostring(declared_type)))
            return display_type_name(declared_type)
        end

        local pattern_type = infer_pattern_binding_type(bufnr, line_nr, varname)
        if pattern_type then
            append_debug_log(("[infer_local] var=%s line=%d pattern=%s"):format(varname, line_nr, tostring(pattern_type)))
            return pattern_type
        end

        local param_type = parameter_type_from_signature_line(line, varname)
        if param_type then
            return param_type
        end

        local assign_patterns = {
            "^%s*let%s+" .. vim.pesc(varname) .. "%s*=%s*(.+)$",
            "^%s*var%s+" .. vim.pesc(varname) .. "%s*=%s*(.+)$",
            "^%s*const%s+" .. vim.pesc(varname) .. "%s*=%s*(.+)$",
        }
        for _, pattern in ipairs(assign_patterns) do
            local rhs = line:match(pattern)
            if rhs then
                local ctor_name = rhs:match("^%s*([A-Z][%w_%.]*)%s*%b()")
                append_debug_log(("[infer_local] var=%s line=%d rhs=%s ctor=%s"):format(varname, line_nr, tostring(rhs), tostring(ctor_name)))
                if ctor_name and find_constructor_symbol(ctor_name) then
                    append_debug_log(("[infer_local] var=%s line=%d ctor_hit=%s"):format(varname, line_nr, tostring(ctor_name)))
                    return sanitize_type_name(ctor_name)
                end
                local inferred = infer_type_from_rhs(rhs)
                if inferred then
                    append_debug_log(("[infer_local] var=%s line=%d inferred=%s"):format(varname, line_nr, tostring(inferred)))
                    return inferred
                end
            end
        end
    end

    append_debug_log(("[infer_local] var=%s no_match"):format(varname))
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
    local lsp_type = nil
    if looks_like_api_symbol(receiver) then
        receiver_type = receiver
    else
        local receiver_end_col1 = (ctx and ctx.start_col or 1) + #receiver - 1
        lsp_type = infer_receiver_type_from_lsp(receiver, receiver_end_col1)
        receiver_type = lsp_type
    end

    local local_type = nil
    if not receiver_type or receiver_type == "" then
        local_type = infer_local_variable_type(receiver)
        receiver_type = local_type
    end

    if not receiver_type or receiver_type == "" then
        append_debug_log(
            ("[receiver] expr=%s receiver=%s member=%s lsp_type=%s local_type=%s resolved=nil"):format(
                tostring(expr),
                tostring(receiver),
                tostring(member),
                tostring(lsp_type),
                tostring(local_type),
                tostring(nil)
            )
        )
        return nil
    end

    local resolved = find_member_on_type(receiver_type, member)
    append_debug_log(
        ("[receiver] expr=%s receiver=%s member=%s lsp_type=%s local_type=%s chosen_type=%s resolved=%s"):format(
            tostring(expr),
            tostring(receiver),
            tostring(member),
            tostring(lsp_type),
            tostring(local_type),
            tostring(receiver_type),
            tostring(resolved and (resolved.fqname or resolved.id) or nil)
        )
    )
    return resolved
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

    local pattern_ctor = pattern_constructor_symbol_for_cursor()
    if pattern_ctor then
        return pattern_ctor
    end

    local source_sym = source_symbol_for_cursor()
    if source_sym then
        return source_sym
    end

    local in_call_position = cursor_in_call_like_position()

    local candidates = extract_symbol_candidates()
    for index, candidate in ipairs(candidates) do
        if looks_like_api_symbol(candidate) or index > 1 then
            if in_call_position and candidate:match("^[A-Z]") then
                local init_sym = find_constructor_symbol(candidate)
                if init_sym then
                    return init_sym
                end
            end
            local sym = M.find_symbol(candidate)
            if sym then
                if in_call_position and is_type_kind(as_string(sym.kind)) then
                    local init_sym = find_constructor_symbol(candidate)
                    if init_sym then
                        return init_sym
                    end
                end
                return sym
            end
        end
    end

    local ident = cursor_identifier() or vim.fn.expand("<cword>")
    if cursor_in_local_binding_position() or cursor_in_pattern_binding_position() then
        local inferred_type = infer_local_variable_type(ident)
        if inferred_type then
            local inferred_base = sanitize_type_name(inferred_type)
            append_debug_log(("[cursor_local] ident=%s inferred=%s base=%s"):format(tostring(ident), tostring(inferred_type), tostring(inferred_base)))
            local inferred_sym = (inferred_base and (best_type_symbol_for_query(inferred_base) or best_symbol_for_query(inferred_base)))
                or best_type_symbol_for_query(inferred_type)
                or best_symbol_for_query(inferred_type)
            if inferred_sym then
                return inferred_sym
            end
        end
        return nil
    end

    if not looks_like_api_symbol(ident) then
        local inferred_type = infer_local_variable_type(ident)
        if inferred_type then
            local inferred_base = sanitize_type_name(inferred_type)
            append_debug_log(("[cursor_local] ident=%s inferred=%s base=%s"):format(tostring(ident), tostring(inferred_type), tostring(inferred_base)))
            local inferred_sym = (inferred_base and (best_type_symbol_for_query(inferred_base) or best_symbol_for_query(inferred_base)))
                or best_type_symbol_for_query(inferred_type)
                or best_symbol_for_query(inferred_type)
            if inferred_sym then
                return inferred_sym
            end
        end
        if in_call_position then
            return unique_symbol_for_query(ident)
        end
        return nil
    end

    if in_call_position and ident:match("^[A-Z]") then
        local init_sym = find_constructor_symbol(ident)
        if init_sym then
            return init_sym
        end
    end

    local sym = M.find_symbol(ident)
    if sym then
        if in_call_position and is_type_kind(as_string(sym.kind)) then
            local init_sym = find_constructor_symbol(ident)
            if init_sym then
                return init_sym
            end
        end
        return sym
    end

    return nil
end

function M.inferred_type_for_cursor()
    local ident = cursor_identifier() or vim.fn.expand("<cword>")
    if not ident or ident == "" then
        return nil
    end
    local inferred_type = infer_local_variable_type(ident)
    append_debug_log(("[cursor_type] ident=%s inferred=%s"):format(tostring(ident), tostring(inferred_type)))
    return inferred_type
end

function M.cursor_has_member_access()
    local ctx = extract_symbol_context()
    local expr = ctx and ctx.expr or nil
    return expr ~= nil and expr:find(".", 1, true) ~= nil
end

function M.cursor_in_local_like_position()
    return cursor_in_local_binding_position() or cursor_in_pattern_binding_position()
end

function M.should_try_lsp_hover()
    local candidates = extract_symbol_candidates()
    for _, candidate in ipairs(candidates) do
        if looks_like_api_symbol(candidate) then
            return true
        end
    end

    if M.cursor_in_local_like_position() then
        return false
    end

    local ident = cursor_identifier() or vim.fn.expand("<cword>")
    if looks_like_api_symbol(ident) then
        return true
    end
    return cursor_in_call_like_position() and unique_symbol_for_query(ident) ~= nil
end

local function format_symbol_item(sym)
    local display = as_string(sym.display) or as_string(sym.name) or as_string(sym.fqname) or as_string(sym.id) or "?"
    local signature = as_string(sym.signature_short) or as_string(sym.signature) or ""
    local summary = as_string(sym.summary_short_md) or as_string(sym.summary_md) or ""
    if #summary > 48 then
        summary = summary:sub(1, 45) .. "..."
    end
    local meta = table.concat(
        vim.tbl_filter(function(v)
            return v and v ~= ""
        end, {
            as_string(sym.kind),
            as_string(sym.module),
        }),
        " · "
    )

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
                local haystack = table
                    .concat(
                        vim.tbl_filter(function(v)
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
                        }),
                        "\n"
                    )
                    :lower()
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
    set_preview_state(bufnr, winid, nil)
end

function M.hover_markdown_for_symbol(sym)
    if not sym then
        return nil
    end
    append_debug_log(
        "[hover_doc] start fqname="
            .. tostring(sym.fqname or sym.id)
            .. " signature="
            .. tostring(sym.signature)
            .. " summary_short="
            .. tostring(sym.summary_short_md)
            .. " module="
            .. tostring(sym.module)
            .. " url="
            .. tostring(symbol_url(sym))
    )
    local lines = flatten_lines(build_hover_markdown(sym))
    if #lines > 0 then
        append_debug_log("[hover_doc] built lines=" .. tostring(#lines))
        return lines
    end

    local fallback = {}
    local title = trim(as_string(sym.signature))
        or trim(as_string(sym.signature_short))
        or trim(as_string(sym.qualified_title))
        or trim(as_string(sym.page_title))
        or trim(as_string(sym.display))
        or trim(as_string(sym.fqname))
        or trim(as_string(sym.id))
    local module_name = trim(as_string(sym.module))
    local summary = trim(as_string(sym.summary_short_md) or as_string(sym.summary_md))
    local url = symbol_url(sym)
    local doc_link = format_link("查看文档", url)

    if title then
        code_fence(fallback, title)
    end
    if summary then
        table.insert(fallback, summary)
        table.insert(fallback, "")
    end
    if module_name then
        table.insert(fallback, "`" .. module_name .. "`")
        table.insert(fallback, "")
    end
    if doc_link then
        table.insert(fallback, doc_link)
        table.insert(fallback, "")
    end

    append_debug_log("[hover_doc] hard_fallback title=" .. tostring(title) .. " lines=" .. tostring(#fallback))
    return fallback
end

function M.open_preview(lines, opts)
    lines = as_list(lines)
    opts = as_table(opts) or {}
    local action = as_table(opts.action)
    append_debug_log(("[preview] open lines=%d action=%s"):format(#lines, tostring(action and action.sym and (action.sym.fqname or action.sym.id) or nil)))
    local bufnr, winid = vim.lsp.util.open_floating_preview(lines, "markdown", {
        border = "rounded",
        max_width = 100,
        max_height = 30,
    })
    set_preview_state(bufnr, winid, action)
    if action and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.keymap.set("n", "<CR>", function()
            M.follow_preview_action()
        end, {
            buffer = bufnr,
            silent = true,
            nowait = true,
            desc = "Open Cangjie Docs Inner Type",
        })
    end
    return bufnr, winid
end

function M.follow_preview_action()
    local _, _, action = get_preview_state()
    action = as_table(action)
    if not action then
        return false
    end
    local sym = action.sym
    if sym then
        M.show_symbol(sym)
        return true
    end
    local lines = as_list(action.lines)
    if #lines > 0 then
        M.open_preview(lines, action.next and { action = action.next } or nil)
        return true
    end
    return false
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
        vim.fn.win_execute(win, string.format("call winrestview({'topline': %d, 'lnum': %d, 'col': 0})", new_topline, new_cursor))
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
    local parsed = extract_symbol_context()

    local data = as_table(item.data)
    local docs_index_id = trim(data and data.docs_index_id)
    local docs_index_fqname = trim(data and data.docs_index_fqname)
    local label = as_string(item.label) or as_string(item.insertText) or as_string(item.newText)
    local detail = as_string(item.detail)
    local kind = item.kind
    append_debug_log(
        ("[completion] label=%s detail=%s kind=%s docs_index_id=%s docs_index_fqname=%s expr=%s cursor_ident=%s"):format(
            tostring(label),
            tostring(detail),
            tostring(kind),
            tostring(docs_index_id),
            tostring(docs_index_fqname),
            tostring(parsed and parsed.expr or nil),
            tostring(parsed and parsed.cursor_ident or nil)
        )
    )
    if docs_index_id then
        local by_id = best_symbol_for_query(docs_index_id)
        append_debug_log("[completion] by_id=" .. tostring(by_id and (by_id.fqname or by_id.id) or nil))
        if by_id then
            return by_id
        end
    end
    if docs_index_fqname then
        local by_fqname = best_symbol_for_query(docs_index_fqname)
        append_debug_log("[completion] by_fqname=" .. tostring(by_fqname and (by_fqname.fqname or by_fqname.id) or nil))
        if by_fqname then
            return by_fqname
        end
    end

    if not label or label == "" then
        append_debug_log("[completion] no_label")
        return nil
    end

    label = label:match("^([%w_%.]+)") or label
    if label == "" then
        append_debug_log("[completion] normalized_label_empty")
        return nil
    end

    local receiver_ctx = completion_receiver_context()
    if receiver_ctx then
        local receiver = receiver_ctx.receiver
        local receiver_type
        if looks_like_api_symbol(receiver) then
            receiver_type = receiver
        else
            receiver_type = infer_receiver_type_from_lsp(receiver, receiver_ctx.receiver_end_col1) or infer_local_variable_type(receiver)
        end
        append_debug_log(("[completion] receiver=%s receiver_type=%s"):format(tostring(receiver), tostring(receiver_type)))
        if receiver_type then
            local exact_candidates = merge_symbol_lists(member_candidates_on_type_hierarchy(receiver_type, label), same_module_member_candidates(receiver_type, label))
            append_debug_log("[completion] exact_candidates=" .. tostring(#exact_candidates))
            for i, sym in ipairs(exact_candidates) do
                append_debug_log(
                    ("[completion] exact_candidate[%d]=%s | %s | %s"):format(
                        i,
                        tostring(sym and (sym.id or sym.fqname) or nil),
                        tostring(sym and sym.fqname or nil),
                        tostring(sym and (sym.signature_short or sym.signature or sym.qualified_title) or nil)
                    )
                )
            end
            local member_sym = choose_best_completion_overload(exact_candidates, item, parsed, receiver_type)
            append_debug_log(
                "[completion] exact_choice="
                    .. tostring(member_sym and (member_sym.id or member_sym.fqname) or nil)
                    .. " | "
                    .. tostring(member_sym and (member_sym.signature_short or member_sym.signature or member_sym.qualified_title) or nil)
            )
            if not member_sym then
                member_sym = find_member_on_type(receiver_type, label)
                append_debug_log("[completion] inherited_choice=" .. tostring(member_sym and (member_sym.fqname or member_sym.id) or nil))
            end
            if member_sym then
                return member_sym
            end
        end
    end

    local sym = best_symbol_for_query(label)
    append_debug_log("[completion] best_symbol=" .. tostring(sym and (sym.fqname or sym.id) or nil))
    if sym then
        return sym
    end

    if detail then
        local type_name = sanitize_type_name(detail)
        if type_name then
            local by_type = best_symbol_for_query(type_name)
            append_debug_log("[completion] by_type=" .. tostring(by_type and (by_type.fqname or by_type.id) or nil))
            return by_type
        end
    end

    append_debug_log("[completion] no_match")
    return nil
end

function M.documentation_for_completion_item(item, opts)
    local sym = M.find_symbol_for_completion_item(item)
    append_debug_log("[completion_doc] symbol=" .. tostring(sym and (sym.fqname or sym.id) or nil))
    if not sym then
        return nil, nil
    end
    return {
        kind = "markdown",
        value = table.concat(flatten_lines(build_completion_markdown(sym, opts)), "\n"),
    }, sym
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

function M.index_paths()
    return configured_index_paths()
end

function M.source_names()
    local names = {}
    for name, _ in pairs(configured_source_groups()) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

function M.current_source_name()
    return configured_source_name()
end

function M.index_source_url()
    return configured_source_url()
end

function M.index_source_urls()
    return configured_source_urls()
end

function M.set_source(name)
    name = trim(name)
    if not name then
        return false, "未提供 docs source 名称"
    end
    if not configured_source_groups()[name] then
        return false, "未知 docs source: " .. name
    end
    vim.g.cangjie_doc_source = name
    M.reload()
    return true, name
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
    local urls = ensure_string_list(opts.urls)
    local single_url = trim(opts.url)
    if #urls == 0 and single_url then
        urls = { single_url }
    end
    if #urls == 0 then
        urls = configured_source_urls()
    end
    if #urls == 0 then
        if callback then
            callback(false, "未配置 Cangjie docs URL，请设置 vim.g.cangjie_doc_index_url / vim.g.cangjie_doc_index_urls")
            return
        end
        return false, "未配置 Cangjie docs URL，请设置 vim.g.cangjie_doc_index_url / vim.g.cangjie_doc_index_urls"
    end

    local targets = resolve_sync_targets(urls, opts)
    if #targets == 0 then
        if callback then
            callback(false, "未配置 Cangjie docs 本地路径")
            return
        end
        return false, "未配置 Cangjie docs 本地路径"
    end
    if #targets ~= 1 and #targets ~= #urls then
        local err = ("docs 源数量(%d)和目标路径数量(%d)不匹配"):format(#urls, #targets)
        if callback then
            callback(false, err)
            return
        end
        return false, err
    end

    local function target_for(index)
        return normalize_path(targets[index] or targets[1])
    end

    local function sync_one(url, target)
        local target_dir = vim.fs.dirname(target)
        if target_dir and target_dir ~= "" then
            vim.fn.mkdir(target_dir, "p")
        end

        local tmp = target .. ".tmp"
        local cmd = { "curl", "-fsSL", url, "-o", tmp }
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
        return true, target
    end

    if callback then
        local written = {}

        local function finish(ok, result)
            vim.schedule(function()
                callback(ok, result)
            end)
        end

        local function sync_one_async(index)
            if index > #urls then
                vim.g.cangjie_doc_index = written[1]
                vim.g.cangjie_doc_indexes = written
                M.reload()
                finish(true, #written == 1 and written[1] or table.concat(written, ", "))
                return
            end

            local url = urls[index]
            local target = target_for(index)
            local target_dir = vim.fs.dirname(target)
            if target_dir and target_dir ~= "" then
                vim.fn.mkdir(target_dir, "p")
            end

            local tmp = target .. ".tmp"
            local cmd = { "curl", "-fsSL", url, "-o", tmp }
            vim.system(cmd, { text = true }, function(result)
                vim.schedule(function()
                    if result.code ~= 0 then
                        os.remove(tmp)
                        local err = trim(result.stderr) or trim(result.stdout) or ("curl failed: " .. tostring(result.code))
                        finish(false, err)
                        return
                    end

                    local text = read_file(tmp)
                    if not text then
                        os.remove(tmp)
                        finish(false, "下载完成但无法读取临时文件")
                        return
                    end

                    local ok, data = pcall(vim.json.decode, text)
                    if not ok or type(data) ~= "table" or type(data.symbols) ~= "table" then
                        os.remove(tmp)
                        finish(false, "下载的 docs-index.json 不是有效的 format=4 索引")
                        return
                    end

                    if not write_file(target, text) then
                        os.remove(tmp)
                        finish(false, "无法写入本地 docs-index 缓存: " .. target)
                        return
                    end

                    os.remove(tmp)
                    table.insert(written, target)
                    sync_one_async(index + 1)
                end)
            end)
        end

        sync_one_async(1)
        return
    end

    local written = {}
    for i, url in ipairs(urls) do
        local ok, result = sync_one(url, target_for(i))
        if not ok then
            return false, result
        end
        table.insert(written, result)
    end
    vim.g.cangjie_doc_index = written[1]
    vim.g.cangjie_doc_indexes = written
    M.reload()
    return true, #written == 1 and written[1] or table.concat(written, ", ")
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
