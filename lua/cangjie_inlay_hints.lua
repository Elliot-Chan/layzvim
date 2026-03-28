local M = {}

local ns_types = vim.api.nvim_create_namespace("cangjie_pseudo_inlay_hints_types")
local ns_params = vim.api.nvim_create_namespace("cangjie_pseudo_inlay_hints_params")
local state = {
    timers = {},
    render_keys = {},
    param_keys = {},
    hover_type_cache = {},
}
local choose_best_call_symbol
local infer_expression_type
local resolve_expression_symbol
local call_expressions
local hover_start_for_callee
local hover_type_for_expression
local parse_call_expression

local function trim(s)
    if type(s) ~= "string" then
        return nil
    end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end

local function docs_index()
    return assert(dofile(vim.fn.stdpath("config") .. "/lua/cangjie_docs_index.lua"))
end

local function enabled()
    return vim.g.cangjie_pseudo_inlay_hints ~= false
end

local function hide_in_insert()
    return vim.g.cangjie_pseudo_inlay_hints_hide_in_insert ~= false
end

local function type_hints_enabled()
    return vim.g.cangjie_pseudo_inlay_hints_types ~= false
end

local function parameter_hints_enabled()
    return vim.g.cangjie_pseudo_inlay_hints_parameters ~= false
end

local function local_auto_features_enabled()
    return vim.g.cangjie_local_auto_features ~= false
end

local function hint_hl()
    return vim.g.cangjie_pseudo_inlay_hints_hl or "LspInlayHint"
end

local function update_delay_ms()
    local delay = tonumber(vim.g.cangjie_pseudo_inlay_hints_delay_ms)
    if delay and delay >= 0 then
        return delay
    end
    return 150
end

local function cursor_delay_ms()
    local delay = tonumber(vim.g.cangjie_pseudo_inlay_hints_cursor_delay_ms)
    if delay and delay >= 0 then
        return delay
    end
    return 350
end

local function parameter_hint_mode()
    local mode = trim(vim.g.cangjie_pseudo_inlay_hints_parameter_mode)
    if mode == "active" or mode == "nested" then
        return mode
    end
    return "nested"
end

local function type_hint_mode()
    local mode = trim(vim.g.cangjie_pseudo_inlay_hints_type_mode)
    if mode == "all" or mode == "hover" then
        return mode
    end
    return "hover"
end

local function is_ident_char(ch)
    return ch and ch ~= "" and ch:match("[%w_]")
end

local function render_range(bufnr)
    local wins = vim.fn.win_findbuf(bufnr)
    local winid = nil
    local current = vim.api.nvim_get_current_win()

    for _, candidate in ipairs(wins) do
        if candidate == current then
            winid = candidate
            break
        end
    end
    if not winid then
        winid = wins[1]
    end
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        return 0, line_count
    end

    local top = vim.fn.line("w0", winid)
    local bottom = vim.fn.line("w$", winid)
    top = math.max((tonumber(top) or 1) - 3, 1)
    bottom = math.min((tonumber(bottom) or 1) + 3, vim.api.nvim_buf_line_count(bufnr))
    return top - 1, bottom
end

local function preferred_win_for_buf(bufnr)
    local wins = vim.fn.win_findbuf(bufnr)
    local current = vim.api.nvim_get_current_win()
    for _, winid in ipairs(wins) do
        if winid == current then
            return winid
        end
    end
    return wins[1]
end

local function sanitize_type_name(type_name)
    type_name = trim(type_name)
    if not type_name then
        return nil
    end
    type_name = type_name:gsub("[`%s]", "")
    type_name = type_name:gsub("<.*>$", "")
    type_name = type_name:gsub("[%?%!%[%]]+$", "")
    type_name = type_name:match("([%w_%.]+)$") or type_name
    return type_name ~= "" and type_name or nil
end

local function callable_return_type(sym)
    if type(sym) ~= "table" then
        return nil
    end

    local direct = sanitize_type_name(sym.return_type)
    if direct then
        return direct
    end

    local callable = type(sym.callable) == "table" and sym.callable or nil
    local from_callable = sanitize_type_name(callable and callable.return_type or nil)
    if from_callable then
        return from_callable
    end

    local signature = trim(sym.signature_short) or trim(sym.signature)
    if signature then
        local by_arrow = sanitize_type_name(signature:match("%)%s*:%s*([%w_%.<>%[%]%?!]+)"))
        if by_arrow then
            return by_arrow
        end
    end
end

local function symbol_value_type(sym)
    if type(sym) ~= "table" then
        return nil
    end

    local value_info = type(sym.value_info) == "table" and sym.value_info or nil
    local value_type = sanitize_type_name(value_info and value_info.value_type or nil)
    if value_type then
        return value_type
    end

    local member_name = trim(sym.name)
    local kind_name = trim(sym.kind)
    local container_type = sanitize_type_name(sym.container)
        or sanitize_type_name(sym.container_name)
        or sanitize_type_name(type(sym.owner) == "table" and sym.owner.name or nil)
    if container_type and (member_name == "init" or kind_name == "init" or tostring(sym.fqname or sym.id or ""):match("%.init$")) then
        return container_type
    end

    local fqname = sanitize_type_name(tostring(sym.fqname or sym.id or ""):gsub("%.init$", ""))
    if fqname and (member_name == "init" or kind_name == "init" or tostring(sym.fqname or sym.id or ""):match("%.init$")) then
        return fqname
    end

    return callable_return_type(sym)
end

local function literal_rhs_type(rhs)
    if rhs:match('^".*"$') then
        return "String"
    end
    if rhs:match("^'.*'$") then
        return "Rune"
    end
    if rhs == "true" or rhs == "false" then
        return "Bool"
    end
    if rhs:match("^%-?%d+[lL]$") or rhs:match("^%-?%d+$") then
        return "Int64"
    end
    if rhs:match("^%-?%d+%.%d+$") then
        return "Float64"
    end
end

local function constructor_call_type(rhs)
    local call = parse_call_expression(rhs)
    if not call then
        return nil, nil
    end
    local ctor_type = sanitize_type_name(call.callee)
    if ctor_type and call.callee:match("^[A-Z]") then
        return ctor_type, call
    end
    return nil, call
end

local function infer_type_from_rhs(rhs, bufnr, line_nr, line_text)
    rhs = trim(rhs)
    if not rhs then
        return nil
    end

    local literal_type = literal_rhs_type(rhs)
    if literal_type then
        return literal_type
    end

    local direct_type = sanitize_type_name(rhs:match("^([A-Z][%w_%.<>%[%]%?!]*)$"))
    if direct_type then
        return direct_type
    end

    if bufnr ~= nil and line_nr ~= nil then
        local hover_type = hover_type_for_expression(bufnr, line_nr, rhs, line_text)
        if hover_type then
            return hover_type
        end
    end

    local ctor_type, call = constructor_call_type(rhs)
    if ctor_type then
        return ctor_type
    end

    if type_hint_mode() == "hover" then
        return nil
    end

    if bufnr ~= nil and line_nr ~= nil and infer_expression_type then
        local inferred_expr_type = infer_expression_type(bufnr, line_nr, rhs, {})
        if inferred_expr_type then
            return inferred_expr_type
        end
    elseif bufnr == nil or line_nr == nil then
        return nil
    end

    local callee = trim(rhs:match("^([%w_%.<>]+)%s*%b()"))
    if not callee then
        return nil
    end

    local docs = docs_index()
    local sym = docs.find_symbol(callee) or docs.find_symbol(sanitize_type_name(callee) or callee)
    return callable_return_type(sym)
end

local function local_binding_info(line)
    local patterns = {
        "^%s*let%s+([%w_]+)%s*:%s*([%w_%.<>%[%]%?!]+)%s*=%s*(.+)$",
        "^%s*var%s+([%w_]+)%s*:%s*([%w_%.<>%[%]%?!]+)%s*=%s*(.+)$",
        "^%s*const%s+([%w_]+)%s*:%s*([%w_%.<>%[%]%?!]+)%s*=%s*(.+)$",
        "^%s*let%s+([%w_]+)%s*=%s*(.+)$",
        "^%s*var%s+([%w_]+)%s*=%s*(.+)$",
        "^%s*const%s+([%w_]+)%s*=%s*(.+)$",
    }

    for _, pattern in ipairs(patterns) do
        local name, a, b = line:match(pattern)
        if name then
            local _, name_end = line:find(name, 1, true)
            if b then
                return {
                    name = name,
                    name_end_col0 = name_end,
                    declared_type = sanitize_type_name(a),
                    rhs = trim(b),
                }
            end
            return {
                name = name,
                name_end_col0 = name_end,
                declared_type = nil,
                rhs = trim(a),
            }
        end
    end
end

local function infer_local_variable_type(bufnr, line_nr, varname)
    varname = trim(varname)
    if not varname then
        return nil
    end

    for lnum = line_nr, 0, -1 do
        local line = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""
        local typed_patterns = {
            "^%s*let%s+" .. vim.pesc(varname) .. "%s*:%s*([%w_%.<>%[%]%?!]+)",
            "^%s*var%s+" .. vim.pesc(varname) .. "%s*:%s*([%w_%.<>%[%]%?!]+)",
            "^%s*const%s+" .. vim.pesc(varname) .. "%s*:%s*([%w_%.<>%[%]%?!]+)",
        }
        for _, pattern in ipairs(typed_patterns) do
            local declared = sanitize_type_name(line:match(pattern))
            if declared then
                return declared
            end
        end

        local assign_patterns = {
            "^%s*let%s+" .. vim.pesc(varname) .. "%s*=%s*(.+)$",
            "^%s*var%s+" .. vim.pesc(varname) .. "%s*=%s*(.+)$",
            "^%s*const%s+" .. vim.pesc(varname) .. "%s*=%s*(.+)$",
        }
        for _, pattern in ipairs(assign_patterns) do
            local rhs = trim(line:match(pattern))
            local inferred = rhs and infer_type_from_rhs(rhs, bufnr, lnum, line) or nil
            if inferred then
                return inferred
            end
        end
    end
end

local function split_args(text)
    local args = {}
    local start_idx = 1
    local depth_paren, depth_brack, depth_brace, depth_angle = 0, 0, 0, 0
    local quote = nil
    local escaped = false

    local function push_arg(stop_idx)
        local raw = text:sub(start_idx, stop_idx)
        if raw ~= "" then
            table.insert(args, {
                text = raw,
                start_col = start_idx,
                end_col = stop_idx,
            })
        end
    end

    for i = 1, #text do
        local ch = text:sub(i, i)
        if quote then
            if escaped then
                escaped = false
            elseif ch == "\\" then
                escaped = true
            elseif ch == quote then
                quote = nil
            end
        else
            if ch == '"' or ch == "'" then
                quote = ch
            elseif ch == "(" then
                depth_paren = depth_paren + 1
            elseif ch == ")" then
                depth_paren = math.max(depth_paren - 1, 0)
            elseif ch == "[" then
                depth_brack = depth_brack + 1
            elseif ch == "]" then
                depth_brack = math.max(depth_brack - 1, 0)
            elseif ch == "{" then
                depth_brace = depth_brace + 1
            elseif ch == "}" then
                depth_brace = math.max(depth_brace - 1, 0)
            elseif ch == "<" then
                depth_angle = depth_angle + 1
            elseif ch == ">" then
                depth_angle = math.max(depth_angle - 1, 0)
            elseif ch == "," and depth_paren == 0 and depth_brack == 0 and depth_brace == 0 and depth_angle == 0 then
                push_arg(i - 1)
                start_idx = i + 1
            end
        end
    end

    push_arg(#text)
    return args
end

local function positional_args_count(args)
    local count = 0
    for _, arg in ipairs(args or {}) do
        local arg_text = trim(arg.text)
        if arg_text and arg_text ~= "" and not arg_text:match("^[%w_]+%s*:") then
            count = count + 1
        end
    end
    return count
end

parse_call_expression = function(expr)
    expr = trim(expr)
    if not expr then
        return nil
    end

    local callee = trim(expr:match("^([%w_%.<>]+)%s*%("))
    if not callee then
        return nil
    end

    local args_text = expr:match("^[%w_%.<>]+%s*%((.*)%)$") or ""
    local args = split_args(args_text)
    return {
        callee = callee,
        args_text = args_text,
        args = args,
        positional_count = positional_args_count(args),
    }
end

local function find_matching_paren(line, open_idx)
    local depth = 0
    local quote = nil
    local escaped = false

    for i = open_idx, #line do
        local ch = line:sub(i, i)
        if quote then
            if escaped then
                escaped = false
            elseif ch == "\\" then
                escaped = true
            elseif ch == quote then
                quote = nil
            end
        else
            if ch == '"' or ch == "'" then
                quote = ch
            elseif ch == "(" then
                depth = depth + 1
            elseif ch == ")" then
                depth = depth - 1
                if depth == 0 then
                    return i
                end
            end
        end
    end
end

local function hover_lines_at(bufnr, line_nr, col0)
    local params = {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
        position = { line = line_nr, character = col0 },
    }
    local results = vim.lsp.buf_request_sync(bufnr, "textDocument/hover", params, 300)
    if not results then
        return {}
    end

    for _, res in pairs(results) do
        local result = res and res.result or nil
        if result and result.contents then
            local ok, lines = pcall(vim.lsp.util.convert_input_to_markdown_lines, result.contents)
            if ok and type(lines) == "table" then
                return vim.lsp.util.trim_empty_lines(lines)
            end
        end
    end
end

hover_type_for_expression = function(bufnr, line_nr, expr, line_text)
    expr = trim(expr)
    line_text = type(line_text) == "string" and line_text or ""
    if not expr or expr == "" or line_text == "" then
        return nil
    end

    local expr_start = line_text:find(expr, 1, true)
    if not expr_start then
        return nil
    end

    local hover_col0 = expr_start - 1
    local call = parse_call_expression(expr)
    if call then
        hover_col0 = hover_start_for_callee(call.callee, expr_start) - 1
    else
        local last_dot = expr:match("^.*()%.")
        if last_dot then
            hover_col0 = expr_start + last_dot - 1
        end
    end

    state.hover_type_cache[bufnr] = state.hover_type_cache[bufnr] or {}
    local line_cache = state.hover_type_cache[bufnr][line_nr]
    if line_cache and line_cache.line_text ~= line_text then
        state.hover_type_cache[bufnr][line_nr] = nil
        line_cache = nil
    end
    if not line_cache then
        line_cache = { line_text = line_text, values = {} }
        state.hover_type_cache[bufnr][line_nr] = line_cache
    end
    if line_cache.values[expr] ~= nil then
        return line_cache.values[expr] ~= false and line_cache.values[expr] or nil
    end

    local lines = hover_lines_at(bufnr, line_nr, hover_col0)
    local hover_container = nil
    for _, line in ipairs(lines) do
        local container = sanitize_type_name(line:match("^//%s+In%s+class%s+([%w_%.]+)"))
            or sanitize_type_name(line:match("^//%s+In%s+struct%s+([%w_%.]+)"))
            or sanitize_type_name(line:match("^//%s+In%s+interface%s+([%w_%.]+)"))
            or sanitize_type_name(line:match("^//%s+In%s+enum%s+([%w_%.]+)"))
        if container then
            hover_container = container
        end

        local return_type = sanitize_type_name(line:match("%)%s*:%s*([%w_%.<>%[%]%?!]+)"))
        if return_type then
            line_cache.values[expr] = return_type
            return return_type
        end

        if hover_container and line:match("^.-%f[%w_](init)%f[^%w_]") then
            line_cache.values[expr] = hover_container
            return hover_container
        end

        local kind1, kind2 = line:match("^.-%f[%w_](let|var|const|prop)%f[^%w_]%s+[%w_]+%s*:%s*([%w_%.<>%[%]%?!]+)")
        local value_type = sanitize_type_name(kind2)
        if kind1 and value_type then
            line_cache.values[expr] = value_type
            return value_type
        end

        local type_kind, type_name = line:match("^.-%f[%w_](class|struct|interface|enum)%f[^%w_]%s+([%w_%.]+)")
        if type_kind and type_name then
            local sanitized = sanitize_type_name(type_name)
            line_cache.values[expr] = sanitized or false
            return sanitized
        end
    end

    if call then
        local ctor_type = sanitize_type_name(call.callee)
        if ctor_type and call.callee:match("^[A-Z]") and #lines > 0 then
            line_cache.values[expr] = ctor_type
            return ctor_type
        end
    end

    line_cache.values[expr] = false
    return nil
end

local function split_top_level_csv(text)
    local out = {}
    local start_idx = 1
    local depth_paren, depth_brack, depth_brace, depth_angle = 0, 0, 0, 0
    for i = 1, #text do
        local ch = text:sub(i, i)
        if ch == "(" then
            depth_paren = depth_paren + 1
        elseif ch == ")" then
            depth_paren = math.max(depth_paren - 1, 0)
        elseif ch == "[" then
            depth_brack = depth_brack + 1
        elseif ch == "]" then
            depth_brack = math.max(depth_brack - 1, 0)
        elseif ch == "{" then
            depth_brace = depth_brace + 1
        elseif ch == "}" then
            depth_brace = math.max(depth_brace - 1, 0)
        elseif ch == "<" then
            depth_angle = depth_angle + 1
        elseif ch == ">" then
            depth_angle = math.max(depth_angle - 1, 0)
        elseif ch == "," and depth_paren == 0 and depth_brack == 0 and depth_brace == 0 and depth_angle == 0 then
            table.insert(out, text:sub(start_idx, i - 1))
            start_idx = i + 1
        end
    end
    table.insert(out, text:sub(start_idx))
    return out
end

local function parameter_labels_from_hover(bufnr, line_nr, callee_start_col0)
    local lines = hover_lines_at(bufnr, line_nr, callee_start_col0)
    for _, line in ipairs(lines) do
        local params_text = line:match("func%s+[%w_%.<>]+%s*%((.*)%)")
        if params_text ~= nil then
            local labels = {}
            for _, part in ipairs(split_top_level_csv(params_text)) do
                local label = trim(part:match("^%s*([%w_]+)%s*:"))
                if label then
                    table.insert(labels, label)
                end
            end
            return labels
        end
    end
    return {}
end

hover_start_for_callee = function(callee, callee_start)
    local hover_start = callee_start
    local last_dot = callee and callee:match("^.*()%.") or nil
    if last_dot then
        hover_start = callee_start + last_dot
    end
    return hover_start
end

local function active_call_at_cursor(calls, cursor_col1)
    if not cursor_col1 then
        return nil
    end

    local chosen = nil
    for _, call in ipairs(calls or {}) do
        local start_col1 = call.callee_start or call.open_idx or 1
        local end_col1 = call.close_idx or 0
        if cursor_col1 >= start_col1 and cursor_col1 <= end_col1 then
            if not chosen or ((start_col1 or 0) > ((chosen.callee_start or chosen.open_idx or 0))) then
                chosen = call
            end
        end
    end
    return chosen
end

local function nested_calls_for_cursor(calls, cursor_col1)
    local direct = active_call_at_cursor(calls, cursor_col1)
    if not direct then
        return {}
    end

    local root = direct
    for _, call in ipairs(calls or {}) do
        local start_col1 = call.callee_start or call.open_idx or 1
        local end_col1 = call.close_idx or 0
        local root_start = root.callee_start or root.open_idx or 1
        local root_end = root.close_idx or 0
        if (call ~= root)
            and cursor_col1 >= start_col1
            and cursor_col1 <= end_col1
            and start_col1 <= root_start
            and end_col1 >= root_end then
            root = call
        end
    end

    local out = {}
    local seen = {}
    local root_start = root.callee_start or root.open_idx or 1
    local root_end = root.close_idx or 0
    for _, call in ipairs(calls or {}) do
        local start_col1 = call.callee_start or call.open_idx or 1
        local end_col1 = call.close_idx or 0
        local key = tostring(call.callee_start or call.open_idx or 0) .. ":" .. tostring(call.close_idx or 0)
        if start_col1 >= root_start and end_col1 <= root_end and not seen[key] then
            seen[key] = true
            table.insert(out, call)
        end
    end

    table.sort(out, function(a, b)
        local astart = a.callee_start or a.open_idx or 0
        local bstart = b.callee_start or b.open_idx or 0
        if astart ~= bstart then
            return astart < bstart
        end
        return (a.close_idx or 0) > (b.close_idx or 0)
    end)
    return out
end

local function parameter_calls_for_cursor(line, cursor_col1)
    local calls = call_expressions(line)
    if parameter_hint_mode() == "nested" then
        return nested_calls_for_cursor(calls, cursor_col1)
    end
    local active_call = active_call_at_cursor(calls, cursor_col1)
    return active_call and { active_call } or {}
end

local function render_key_for_view(bufnr, cursor_line, cursor_col1, start_line, end_line)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
    local parts = {
        tostring(start_line),
        tostring(end_line),
        tostring(cursor_line),
    }

    for idx, line in ipairs(lines) do
        local line_nr = start_line + idx - 1
        local item = table.concat({
            tostring(line_nr),
            line,
        }, "|")
        local info = local_binding_info(line)
        if type_hints_enabled() and info and not info.declared_type and info.rhs then
            item = item .. "|type"
        end
        if line_nr == cursor_line then
            local active_calls = parameter_hints_enabled() and parameter_calls_for_cursor(line, cursor_col1) or {}
            local keys = {}
            for _, call in ipairs(active_calls) do
                keys[#keys + 1] = table.concat({
                    tostring(call.callee or ""),
                    tostring(call.callee_start or ""),
                    tostring(call.open_idx or ""),
                    tostring(call.close_idx or ""),
                }, "@")
            end
            item = item .. "|calls=" .. table.concat(keys, ",")
        end
        parts[#parts + 1] = item
    end

    return table.concat(parts, "#")
end

call_expressions = function(line)
    local calls = {}
    local i = 1
    while i <= #line do
        if line:sub(i, i) == "(" then
            local j = i - 1
            while j >= 1 and line:sub(j, j):match("%s") do
                j = j - 1
            end
            local callee_end = j
            while j >= 1 and (is_ident_char(line:sub(j, j)) or line:sub(j, j) == "." or line:sub(j, j) == "<" or line:sub(j, j) == ">") do
                j = j - 1
            end
            local callee = trim(line:sub(j + 1, callee_end))
            if callee and callee ~= "" then
                local close_idx = find_matching_paren(line, i)
                if close_idx and close_idx > i then
                    table.insert(calls, {
                        callee = callee,
                        callee_start = j + 1,
                        hover_start = hover_start_for_callee(callee, j + 1),
                        open_idx = i,
                        close_idx = close_idx,
                        args_text = line:sub(i + 1, close_idx - 1),
                    })
                end
            end
        end
        i = i + 1
    end
    return calls
end

local function parameter_labels_for_symbol(sym)
    local docs = docs_index()
    local sig = docs.signature_help_for_symbol and docs.signature_help_for_symbol(sym) or nil
    local signature = sig and sig.signatures and sig.signatures[1] or nil
    if not signature or type(signature.parameters) ~= "table" then
        return {}
    end

    local labels = {}
    for _, param in ipairs(signature.parameters) do
        local label = trim(type(param) == "table" and param.label or nil)
        if label and label ~= "" then
            label = label:match("^([%w_]+)") or label
            table.insert(labels, label)
        end
    end
    return labels
end

local function is_type_symbol(sym)
    local kind = trim(type(sym) == "table" and sym.kind or nil)
    if not kind then
        return false
    end
    kind = kind:lower()
    return kind == "class" or kind == "struct" or kind == "interface" or kind == "enum"
end

local function split_type_tail(type_name)
    type_name = sanitize_type_name(type_name)
    if not type_name then
        return nil
    end
    return type_name:match("([%w_]+)$") or type_name
end

local function infer_expression_type(bufnr, line_nr, expr, cache)
    expr = trim(expr)
    if not expr then
        return nil
    end

    cache = cache or {}
    if cache[expr] ~= nil then
        return cache[expr] ~= false and cache[expr] or nil
    end

    local direct_type = sanitize_type_name(expr:match("^([A-Z][%w_%.<>%[%]%?!]*)$"))
    if direct_type then
        cache[expr] = direct_type
        return direct_type
    end

    local sym = nil
    if expr:find("%(", 1, true) then
        local call = parse_call_expression(expr)
        if call then
            sym = choose_best_call_symbol(bufnr, line_nr, call.callee, call.positional_count, call.args, cache)
            if not sym then
                sym = resolve_expression_symbol(bufnr, line_nr, call.callee, call.positional_count, call.args, cache)
            end
        end
    else
        sym = resolve_expression_symbol(bufnr, line_nr, expr, nil, nil, cache)
    end

    local value_type = symbol_value_type(sym)
    cache[expr] = value_type or false
    return value_type
end

local function score_call_candidate(sym, arg_types, arg_count)
    local callable = type(sym) == "table" and type(sym.callable) == "table" and sym.callable or nil
    local params = callable and type(callable.params) == "table" and callable.params or {}
    local score = 0

    if arg_count ~= nil then
        if #params == arg_count then
            score = score + 100
        else
            score = score - math.abs(#params - arg_count) * 10
        end
    end

    local positional_index = 1
    for _, arg_type in ipairs(arg_types or {}) do
        if arg_type ~= false then
            local param = params[positional_index]
            local param_type = sanitize_type_name(type(param) == "table" and param.type or nil)
            if param_type and arg_type then
                if param_type == arg_type then
                    score = score + 40
                elseif split_type_tail(param_type) == split_type_tail(arg_type) then
                    score = score + 20
                end
            end
            positional_index = positional_index + 1
        end
    end

    return score
end

local function infer_argument_type(bufnr, line_nr, arg_text, cache)
    arg_text = trim(arg_text)
    if not arg_text then
        return nil
    end

    if arg_text:find("%(", 1, true) then
        local inner_call = parse_call_expression(arg_text)
        if inner_call then
            local inner_sym = choose_best_call_symbol(bufnr, line_nr, inner_call.callee, inner_call.positional_count, inner_call.args, cache)
            if not inner_sym then
                inner_sym = resolve_expression_symbol(bufnr, line_nr, inner_call.callee, inner_call.positional_count, inner_call.args, cache)
            end
            local inner_type = symbol_value_type(inner_sym)
            if inner_type then
                return inner_type
            end
        end
    end

    return infer_expression_type(bufnr, line_nr, arg_text, cache)
end

choose_best_call_symbol = function(bufnr, line_nr, expr, arg_count, args, cache)
    local docs = docs_index()
    local base_expr = sanitize_type_name(expr) or expr
    local type_sym = docs.find_symbol(expr) or docs.find_symbol(base_expr)
    if type_sym and is_type_symbol(type_sym) then
        local init_sym = docs.find_symbol(base_expr .. ".init")
        if init_sym then
            return init_sym
        end
    end
    local candidates = docs.find_symbols and (docs.find_symbols(expr) or {}) or {}
    if #candidates == 0 and docs.find_symbols then
        candidates = docs.find_symbols(base_expr) or {}
    end
    if #candidates == 0 then
        local fallback = docs.find_symbol_for_call and (docs.find_symbol_for_call(expr, arg_count) or docs.find_symbol_for_call(base_expr, arg_count))
            or docs.find_symbol(expr)
            or docs.find_symbol(base_expr)
        return fallback
    end

    cache = cache or {}
    local arg_types = {}
    local positional_index = 1
    for _, arg in ipairs(args or {}) do
        local arg_text = trim(arg.text)
        if arg_text and arg_text ~= "" and not arg_text:match("^[%w_]+%s*:") then
            arg_types[positional_index] = infer_argument_type(bufnr, line_nr, arg_text, cache) or false
            positional_index = positional_index + 1
        end
    end

    table.sort(candidates, function(a, b)
        local sa = score_call_candidate(a, arg_types, arg_count)
        local sb = score_call_candidate(b, arg_types, arg_count)
        if sa ~= sb then
            return sa > sb
        end
        return tostring(a.fqname or a.id or "") < tostring(b.fqname or b.id or "")
    end)

    return candidates[1]
end

resolve_expression_symbol = function(bufnr, line_nr, expr, arg_count, args, cache)
    expr = trim(expr)
    if not expr then
        return nil
    end

    local docs = docs_index()
    local direct = choose_best_call_symbol(bufnr, line_nr, expr, arg_count, args, cache)
    if direct then
        return direct
    end

    local parts = vim.split(expr, ".", { plain = true, trimempty = true })
    if #parts < 2 then
        return nil
    end

    local current_type = nil
    local first = parts[1]
    local first_sym = docs.find_symbol(first)
    if first_sym and (first:match("^[A-Z]") or first:find(".", 1, true)) then
        current_type = sanitize_type_name(first_sym.fqname or first_sym.id or first)
    else
        current_type = infer_local_variable_type(bufnr, line_nr, first)
    end

    if not current_type then
        return nil
    end

    local resolved = nil
    for i = 2, #parts do
        local member = parts[i]
        if i == #parts then
            resolved = choose_best_call_symbol(bufnr, line_nr, current_type .. "." .. member, arg_count, args, cache)
        end
        if not resolved then
            resolved = (docs.resolve_member_on_type and docs.resolve_member_on_type(current_type, member)) or docs.find_symbol(current_type .. "." .. member)
        end
        if not resolved then
            return nil
        end

        if i < #parts then
            current_type = symbol_value_type(resolved)
            if not current_type then
                return nil
            end
        end
    end

    return resolved
end

local function add_type_hint(bufnr, line_nr, col0, type_name)
    vim.api.nvim_buf_set_extmark(bufnr, ns_types, line_nr, col0, {
        virt_text = { { " : " .. type_name, hint_hl() } },
        virt_text_pos = "inline",
        priority = 80,
    })
end

local function add_arg_hint(bufnr, line_nr, col0, label)
    vim.api.nvim_buf_set_extmark(bufnr, ns_params, line_nr, col0, {
        virt_text = { { label .. ": ", hint_hl() } },
        virt_text_pos = "inline",
        priority = 90,
    })
end

local function render_line(bufnr, line_nr, line, opts)
    opts = opts or {}
    local info = local_binding_info(line)
    if opts.type_hints ~= false and type_hints_enabled() and info and not info.declared_type and info.rhs then
        local inferred = infer_type_from_rhs(info.rhs, bufnr, line_nr, line)
        if inferred and info.name_end_col0 then
            add_type_hint(bufnr, line_nr, info.name_end_col0, inferred)
        end
    end

    if not parameter_hints_enabled() or opts.parameter_hints == false then
        return
    end

    local active_calls = parameter_calls_for_cursor(line, opts.cursor_col1)

    if #active_calls == 0 then
        return
    end

    for _, call in ipairs(active_calls) do
        local args = split_args(call.args_text)
        local positional_count = positional_args_count(args)

        local labels = parameter_labels_from_hover(bufnr, line_nr, (call.hover_start or call.callee_start or 1) - 1)
        if #labels == 0 then
            local sym = resolve_expression_symbol(bufnr, line_nr, call.callee, positional_count, args)
            if sym then
                labels = parameter_labels_for_symbol(sym)
            end
        end

        if #labels > 0 then
            local positional_index = 1
            for _, arg in ipairs(args) do
                local arg_text = trim(arg.text)
                if arg_text and arg_text ~= "" and not arg_text:match("^[%w_]+%s*:") then
                    local label = labels[positional_index]
                    if label then
                        local leading = #arg.text:match("^%s*")
                        local col0 = call.open_idx + arg.start_col + leading - 1
                        add_arg_hint(bufnr, line_nr, col0, label)
                    end
                    positional_index = positional_index + 1
                end
            end
        end
    end
end

local function clear_type_marks(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns_types, 0, -1)
    end
end

local function clear_param_marks(bufnr, start_line, end_line)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns_params, start_line or 0, end_line or -1)
    end
end

function M.clear(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    clear_type_marks(bufnr)
    clear_param_marks(bufnr)
    state.render_keys[bufnr] = nil
    state.param_keys[bufnr] = nil
    state.hover_type_cache[bufnr] = nil
end

function M.render(bufnr, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    if vim.bo[bufnr].filetype ~= "Cangjie" or not enabled() then
        return false
    end

    if hide_in_insert() and vim.api.nvim_get_mode().mode:match("^i") then
        return false
    end

    local winid = preferred_win_for_buf(bufnr)
    local cursor = winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_cursor(winid) or vim.api.nvim_win_get_cursor(0)
    local cursor_line = (cursor[1] or 1) - 1
    local cursor_col1 = (cursor[2] or 0) + 1
    local start_line, end_line = render_range(bufnr)

    local current_line = vim.api.nvim_buf_get_lines(bufnr, cursor_line, cursor_line + 1, false)[1] or ""
    local current_param_calls = parameter_hints_enabled() and parameter_calls_for_cursor(current_line, cursor_col1) or {}
    local param_key_parts = { tostring(cursor_line), tostring(cursor_col1) }
    for _, call in ipairs(current_param_calls) do
        param_key_parts[#param_key_parts + 1] = table.concat({
            tostring(call.callee or ""),
            tostring(call.callee_start or ""),
            tostring(call.open_idx or ""),
            tostring(call.close_idx or ""),
        }, "@")
    end
    local param_key = table.concat(param_key_parts, "#")

    if opts.force then
        state.render_keys[bufnr] = nil
        state.param_keys[bufnr] = nil
        state.hover_type_cache[bufnr] = nil
    end

    if opts.cursor_only then
        if state.param_keys[bufnr] == param_key then
            vim.b[bufnr].cangjie_pseudo_inlay_hints_enabled = true
            return true
        end
        clear_param_marks(bufnr, cursor_line, cursor_line + 1)
        render_line(bufnr, cursor_line, current_line, {
            parameter_hints = true,
            cursor_col1 = cursor_col1,
            type_hints = false,
        })
        state.param_keys[bufnr] = param_key
        vim.b[bufnr].cangjie_pseudo_inlay_hints_enabled = true
        return true
    end

    local render_key = render_key_for_view(bufnr, cursor_line, cursor_col1, start_line, end_line)
    if state.render_keys[bufnr] == render_key then
        vim.b[bufnr].cangjie_pseudo_inlay_hints_enabled = true
        return true
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
    clear_type_marks(bufnr)
    clear_param_marks(bufnr)
    for idx, line in ipairs(lines) do
        local line_nr = start_line + idx - 1
        render_line(bufnr, line_nr, line, {
            parameter_hints = line_nr == cursor_line,
            cursor_col1 = line_nr == cursor_line and cursor_col1 or nil,
            type_hints = true,
        })
    end
    state.render_keys[bufnr] = render_key
    state.param_keys[bufnr] = param_key
    vim.b[bufnr].cangjie_pseudo_inlay_hints_enabled = true
    return true
end

function M.status(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    return {
        enabled = enabled(),
        active = vim.b[bufnr].cangjie_pseudo_inlay_hints_enabled == true,
        hide_in_insert = hide_in_insert(),
        type_hints = type_hints_enabled(),
        parameter_hints = parameter_hints_enabled(),
        type_mode = type_hint_mode(),
    }
end

function M.manage(action)
    local bufnr = vim.api.nvim_get_current_buf()
    action = trim(action) or "toggle"

    if action == "toggle" then
        vim.g.cangjie_pseudo_inlay_hints = not enabled()
        if enabled() then
            M.render(bufnr)
        else
            M.clear(bufnr)
            vim.b[bufnr].cangjie_pseudo_inlay_hints_enabled = false
        end
    elseif action == "on" then
        vim.g.cangjie_pseudo_inlay_hints = true
        M.render(bufnr)
    elseif action == "off" then
        vim.g.cangjie_pseudo_inlay_hints = false
        M.clear(bufnr)
        vim.b[bufnr].cangjie_pseudo_inlay_hints_enabled = false
    elseif action == "refresh" then
        M.clear(bufnr)
        M.render(bufnr, { force = true })
    elseif action == "toggle-types" then
        vim.g.cangjie_pseudo_inlay_hints_types = not type_hints_enabled()
        M.render(bufnr)
    elseif action == "toggle-params" then
        vim.g.cangjie_pseudo_inlay_hints_parameters = not parameter_hints_enabled()
        M.render(bufnr)
    elseif action == "types-on" then
        vim.g.cangjie_pseudo_inlay_hints_types = true
        M.render(bufnr)
    elseif action == "types-off" then
        vim.g.cangjie_pseudo_inlay_hints_types = false
        M.render(bufnr)
    elseif action == "params-on" then
        vim.g.cangjie_pseudo_inlay_hints_parameters = true
        M.render(bufnr)
    elseif action == "params-off" then
        vim.g.cangjie_pseudo_inlay_hints_parameters = false
        M.render(bufnr)
    elseif action == "status" then
        local status = M.status(bufnr)
        vim.notify(
            table.concat({
                ("enabled=%s"):format(tostring(status.enabled)),
                ("active=%s"):format(tostring(status.active)),
                ("hide_in_insert=%s"):format(tostring(status.hide_in_insert)),
                ("type_hints=%s"):format(tostring(status.type_hints)),
                ("parameter_hints=%s"):format(tostring(status.parameter_hints)),
                ("type_mode=%s"):format(tostring(status.type_mode)),
            }, "\n"),
            vim.log.levels.INFO,
            { title = "Cangjie Pseudo Inlay Hints" }
        )
        return
    else
        vim.notify("Usage: CangjieInlayHints [toggle|on|off|refresh|status|toggle-types|toggle-params|types-on|types-off|params-on|params-off]", vim.log.levels.WARN, { title = "Cangjie" })
        return
    end

    local status = M.status(bufnr)
    vim.notify("Cangjie pseudo inlay hints: " .. (status.enabled and "on" or "off"), vim.log.levels.INFO, { title = "Cangjie" })
end

function M.setup(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "Cangjie" then
        return
    end
    if vim.b[bufnr].cangjie_pseudo_inlay_hints_ready then
        return
    end

    local function schedule_render(delay_ms, opts)
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end
        if not local_auto_features_enabled() then
            return
        end

        if hide_in_insert() and vim.api.nvim_get_mode().mode:match("^i") then
            return
        end

        local timer = state.timers[bufnr]
        if timer then
            timer:stop()
            timer:close()
        end

        timer = vim.uv.new_timer()
        state.timers[bufnr] = timer
        timer:start(delay_ms or update_delay_ms(), 0, function()
            vim.schedule(function()
                if timer == state.timers[bufnr] then
                    state.timers[bufnr] = nil
                end
                if timer and not timer:is_closing() then
                    timer:stop()
                    timer:close()
                end
                M.render(bufnr, opts)
            end)
        end)
    end

    local group = vim.api.nvim_create_augroup("cangjie_pseudo_inlay_hints_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "InsertLeave", "WinScrolled" }, {
        group = group,
        buffer = bufnr,
        callback = function()
            if not local_auto_features_enabled() then
                return
            end
            schedule_render(update_delay_ms(), { cursor_only = false })
        end,
    })
    vim.api.nvim_create_autocmd("CursorMoved", {
        group = group,
        buffer = bufnr,
        callback = function()
            if not local_auto_features_enabled() then
                return
            end
            schedule_render(cursor_delay_ms(), { cursor_only = true })
        end,
    })
    vim.api.nvim_create_autocmd("TextChangedI", {
        group = group,
        buffer = bufnr,
        callback = function()
            if not local_auto_features_enabled() then
                return
            end
            if hide_in_insert() then
                return
            end
            schedule_render(update_delay_ms(), { cursor_only = false })
        end,
    })
    vim.api.nvim_create_autocmd("InsertEnter", {
        group = group,
        buffer = bufnr,
        callback = function()
            if hide_in_insert() then
                M.clear(bufnr)
            end
        end,
    })
    vim.api.nvim_create_autocmd("LspDetach", {
        group = group,
        buffer = bufnr,
        callback = function()
            local timer = state.timers[bufnr]
            if timer then
                timer:stop()
                timer:close()
                state.timers[bufnr] = nil
            end
            M.clear(bufnr)
            pcall(vim.api.nvim_del_augroup_by_id, group)
        end,
    })

    vim.b[bufnr].cangjie_pseudo_inlay_hints_ready = true
    if local_auto_features_enabled() then
        schedule_render(update_delay_ms(), { cursor_only = false })
    end
end

function M._debug_resolve_call(bufnr, line_nr, expr, args_text)
    local args = split_args(args_text or "")
    local positional_count = 0
    local arg_types = {}
    for _, arg in ipairs(args) do
        local arg_text = trim(arg.text)
        if arg_text and arg_text ~= "" and not arg_text:match("^[%w_]+%s*:") then
            positional_count = positional_count + 1
            arg_types[#arg_types + 1] = infer_argument_type(bufnr or 0, line_nr or 0, arg_text, {})
        end
    end
    local sym = resolve_expression_symbol(bufnr or 0, line_nr or 0, expr, positional_count, args, {})
    local candidates = {}
    local docs = docs_index()
    for _, candidate in ipairs(docs.find_symbols and docs.find_symbols(expr) or {}) do
        candidates[#candidates + 1] = {
            symbol = candidate.signature_short or candidate.fqname or candidate.id,
            score = score_call_candidate(candidate, arg_types, positional_count),
        }
    end
    table.sort(candidates, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return tostring(a.symbol) < tostring(b.symbol)
    end)
    return {
        symbol = sym and (sym.signature_short or sym.fqname or sym.id) or nil,
        labels = sym and parameter_labels_for_symbol(sym) or {},
        arg_types = arg_types,
        candidates = candidates,
    }
end

function M._debug_infer_expr_type(bufnr, line_nr, expr)
    return infer_expression_type(bufnr or 0, line_nr or 0, expr, {})
end

function M._debug_infer_expr_type_details(bufnr, line_nr, expr)
    expr = trim(expr)
    local cache = {}
    local callee = expr and trim(expr:match("^([%w_%.]+)%s*%(")) or nil
    local args_text = expr and expr:match("^[%w_%.]+%s*%((.*)%)$") or nil
    local args = split_args(args_text or "")
    local positional_count = 0
    for _, arg in ipairs(args) do
        local arg_text = trim(arg.text)
        if arg_text and arg_text ~= "" and not arg_text:match("^[%w_]+%s*:") then
            positional_count = positional_count + 1
        end
    end
    local sym = callee and choose_best_call_symbol(bufnr or 0, line_nr or 0, callee, positional_count, args, cache) or nil
    return {
        callee = callee,
        args_text = args_text,
        positional_count = positional_count,
        symbol = sym and (sym.signature_short or sym.fqname or sym.id) or nil,
        value_type = symbol_value_type(sym),
        final = infer_expression_type(bufnr or 0, line_nr or 0, expr, {}),
    }
end

function M._debug_parameter_calls(line, cursor_col1)
    local out = {}
    for _, call in ipairs(parameter_calls_for_cursor(line or "", cursor_col1)) do
        out[#out + 1] = {
            callee = call.callee,
            callee_start = call.callee_start,
            hover_start = call.hover_start,
            open_idx = call.open_idx,
            close_idx = call.close_idx,
        }
    end
    return out
end

return M
