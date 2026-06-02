-- ~/.config/nvim/lsp/cangjie.lua
local util = require("lspconfig.util")

local sdk = vim.env.CANGJIE_SDK_PATH or os.getenv("CANGJIE_SDK_PATH") or ""
local server = (sdk ~= "" and vim.fs.joinpath(sdk, "tools", "bin", "LSPServer")) or "LSPServer"
local restart_state = {
    pending = false,
    attempts = {},
}
local restart_delay_ms = 1200
local restart_burst_window_ms = 60000
local restart_burst_limit = 5

local function cangjie_perf()
    return rawget(_G, "CangjiePerf")
end

local function cangjie_perf_enabled(bufnr)
    local perf = cangjie_perf()
    return perf and perf.enabled and perf.enabled(bufnr) or false
end

local function make_cmd()
    local cmd = { server, "--test" }
    if vim.g.cangjie_lsp_debug == true then
        vim.list_extend(cmd, { "--enable-log=true", "--log-path=/tmp/" })
    else
        vim.list_extend(cmd, { "--enable-log=false" })
    end
    return cmd
end

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
    [466] = true,
    [751] = true,
    [753] = true,
    [781] = true,
}

local function get_docs_index()
    local path = vim.fn.stdpath("config") .. "/lua/cangjie_docs_index.lua"
    local stat = (vim.uv or vim.loop).fs_stat(path)
    local mtime = stat and stat.mtime and ("%s.%s"):format(tostring(stat.mtime.sec), tostring(stat.mtime.nsec or 0)) or nil
    local loaded = package.loaded.cangjie_docs_index
    if loaded and loaded._source_mtime == mtime then
        return loaded
    end

    package.loaded.cangjie_docs_index = nil
    local docs = require("cangjie_docs_index")
    docs._source_mtime = mtime
    return docs
end

local function trim_text(value)
    if type(value) ~= "string" then
        return nil
    end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or nil
end

local function trim_empty_lines(lines)
    lines = type(lines) == "table" and lines or {}
    if vim.lsp.util.trim_empty_lines then
        return vim.lsp.util.trim_empty_lines(lines)
    end

    local first = 1
    local last = #lines
    while first <= last and trim_text(lines[first]) == nil do
        first = first + 1
    end
    while last >= first and trim_text(lines[last]) == nil do
        last = last - 1
    end

    local out = {}
    for i = first, last do
        out[#out + 1] = lines[i]
    end
    return out
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
    if vim.g.cangjie_completion_debug ~= true then
        return
    end
    local ok, fd = pcall(io.open, "/tmp/cangjie_completion.log", "a")
    if not ok or not fd then
        return
    end
    fd:write(os.date("%H:%M:%S "), message, "\n")
    fd:close()
end

local function prune_restart_attempts(now)
    local kept = {}
    for _, ts in ipairs(restart_state.attempts) do
        if now - ts <= restart_burst_window_ms then
            kept[#kept + 1] = ts
        end
    end
    restart_state.attempts = kept
end

local function has_live_cangjie_buffers()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "Cangjie" and vim.api.nvim_buf_get_name(bufnr) ~= "" then
            return true
        end
    end
    return false
end

local function schedule_cangjie_lsp_restart(reason)
    if restart_state.pending then
        return
    end

    local now = vim.uv.now()
    prune_restart_attempts(now)
    if #restart_state.attempts >= restart_burst_limit then
        vim.notify("Cangjie LSP exited too frequently; auto restart paused. Check /tmp LSP logs before restarting manually.", vim.log.levels.ERROR, { title = "Cangjie LSP" })
        return
    end

    restart_state.pending = true
    restart_state.attempts[#restart_state.attempts + 1] = now

    vim.defer_fn(function()
        restart_state.pending = false
        if not vim.lsp.is_enabled("cangjie_lsp") then
            return
        end
        if not has_live_cangjie_buffers() then
            return
        end
        vim.lsp.enable("cangjie_lsp")
        vim.notify("Cangjie LSP restarted" .. (reason and (": " .. reason) or ""), vim.log.levels.WARN, { title = "Cangjie LSP" })
    end, restart_delay_ms)
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

local function cangjie_prefer_native_inlay_hints()
    return vim.g.cangjie_native_inlay_hints == true
end

local function cangjie_local_auto_features_enabled()
    return vim.g.cangjie_local_auto_features ~= false
end

local function cangjie_completion_docs_enabled()
    return vim.g.cangjie_completion_docs == true
end

local function cangjie_manual_completion_docs_enabled()
    return vim.g.cangjie_manual_completion_docs ~= false
end

local function cangjie_dot_completion_enabled()
    return vim.g.cangjie_dot_completion == true
end

local function any_cangjie_client_supports_inlay(bufnr)
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = "cangjie_lsp" })) do
        if client_supports_inlay_hints(client, bufnr) then
            return true
        end
    end
    return false
end

local function use_native_cangjie_inlay(bufnr)
    return cangjie_prefer_native_inlay_hints() and any_cangjie_client_supports_inlay(bufnr)
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
    pseudo_inlay_hints().setup(bufnr)

    if use_native_cangjie_inlay(bufnr) then
        ensure_cangjie_inlay_autocmds(bufnr)
        if cangjie_inlay_enabled() and not vim.api.nvim_get_mode().mode:match("^i") then
            set_cangjie_inlay_hints(bufnr, true)
        end
        return
    end

    if cangjie_inlay_enabled() and not vim.api.nvim_get_mode().mode:match("^i") then
        pseudo_inlay_hints().render(bufnr, { force = true })
    end
end

local function ensure_cangjie_document_highlight_autocmds(client, bufnr)
    if cangjie_perf_enabled(bufnr) and vim.g.cangjie_perf_document_highlight ~= true then
        vim.b[bufnr].cangjie_document_highlight_skipped = true
        return
    end
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
    local perf = cangjie_perf()
    if perf and perf.root_dir then
        return perf.root_dir(fname ~= "" and fname or bufnr)
    end

    local project_root = util.root_pattern("cjpm.toml")(fname)
    if project_root then
        return project_root
    end

    local dir = vim.fs.dirname(fname)
    if dir then
        local git_root = util.find_git_ancestor(fname)
        if git_root then
            return git_root
        end
        if vim.fs.basename(fname) == "main.cj" then
            return dir
        end
    end

    return dir or vim.fn.getcwd()
end

local function source_module_for_path(path)
    local perf = cangjie_perf()
    if perf and perf.source_module then
        return perf.source_module(path)
    end
end

local function source_module_init_options(source_module)
    if not (source_module and source_module.name and source_module.root and source_module.src_path) then
        return nil
    end

    local root_uri = vim.uri_from_fname(source_module.root)
    return {
        multiModuleOption = {
            [root_uri] = {
                name = source_module.name,
                src_path = source_module.src_path,
                requires = {},
            },
        },
    }
end

local package_cj_files
local current_cangjie_client
local schedule_explorer_refresh

local function warm_stats(client)
    if not (client and client.config) then
        return nil
    end
    client.config._cangjie_warm_stats = client.config._cangjie_warm_stats
        or {
            warmed_files = 0,
            skipped_large_files = 0,
            skipped_read_files = 0,
            queued_files = 0,
            packages = {},
            last_elapsed_ms = 0,
            last_reason = "none",
            explorer_refreshes = 0,
            explorer_last_reason = "none",
            suppressed_warm_diagnostics = 0,
            progress_done = 0,
            progress_total = 0,
            progress_percent = 0,
            diagnostic_display_refreshes = 0,
            diagnostic_display_buffers = 0,
            diagnostic_cursor_events = 0,
            diagnostic_refresh_last_reason = "none",
        }
    return client.config._cangjie_warm_stats
end

local function warm_progress_state(client)
    if not (client and client.config) then
        return nil
    end
    client.config._cangjie_warm_progress = client.config._cangjie_warm_progress
        or {
            id = ("cangjie-warm-%s"):format(tostring(client.id or "client")),
            token = ("cangjie-warm-%s"):format(tostring(client.id or "client")),
            active = false,
            done = 0,
            total = 0,
            last_update_ms = 0,
            last_percent = -1,
            settle_generation = 0,
        }
    return client.config._cangjie_warm_progress
end

local function now_ms()
    return math.floor((vim.uv or vim.loop).hrtime() / 1000000)
end

local function warm_progress_bar(done, total)
    local width = vim.g.cangjie_lsp_warm_progress_width or 20
    total = math.max(total or 0, 1)
    local percent = math.min(100, math.floor((done or 0) * 100 / total))
    local filled = math.floor(width * percent / 100)
    if vim.g.cangjie_lsp_warm_progress_style == "ascii" then
        return ("[%s%s]"):format(string.rep("#", filled), string.rep(".", width - filled)), percent
    end

    return ("%s%s"):format(string.rep("█", filled), string.rep("░", width - filled)), percent
end

local function warm_progress_label(reason)
    local labels = {
        ["starting"] = "Preparing source index",
        ["warming"] = "Indexing source files",
        ["settling diagnostics"] = "Settling diagnostics",
        ["done"] = "Source index ready",
        ["current-package"] = "Queueing current package",
        ["direct-import"] = "Queueing imports",
        ["on-demand"] = "Queueing symbol package",
    }
    return labels[reason or ""] or reason or "Working"
end

local function warm_progress_stage(reason)
    local stages = {
        ["starting"] = "prepare",
        ["current-package"] = "queue",
        ["direct-import"] = "queue",
        ["on-demand"] = "queue",
        ["queued"] = "queue",
        ["warming"] = "index",
        ["settling diagnostics"] = "settle",
        ["done"] = "ready",
    }
    return stages[reason or ""] or "index"
end

local function warm_progress_stage_label(stage)
    local labels = {
        prepare = "prepare",
        queue = "queue",
        index = "index",
        settle = "settle",
        ready = "ready",
    }
    return labels[stage or ""] or stage or "index"
end

local function emit_lsp_warm_progress(client, reason, percent)
    if not (client and client.id) then
        return false
    end
    local progress = warm_progress_state(client)
    if not progress then
        return false
    end

    local kind
    if reason == "done" then
        kind = "end"
    elseif progress.lsp_started then
        kind = "report"
    else
        kind = "begin"
        progress.lsp_started = true
    end

    local message = ("%d/%d files"):format(progress.done or 0, progress.total or 0)
    local stage = warm_progress_stage(reason)

    local ok = pcall(vim.api.nvim_exec_autocmds, "LspProgress", {
        pattern = kind,
        modeline = false,
        data = {
            client_id = client.id,
            params = {
                token = progress.token,
                value = {
                    kind = kind,
                    title = "Cangjie source index",
                    message = message,
                    percentage = percent,
                    detail = warm_progress_label(reason),
                    stage = stage,
                    stage_label = warm_progress_stage_label(stage),
                },
            },
        },
    })

    if reason == "done" then
        progress.lsp_started = false
    end
    return ok
end

local function update_warm_progress_stats(client, progress)
    local stats = warm_stats(client)
    if not stats or not progress then
        return
    end
    stats.progress_done = progress.done or 0
    stats.progress_total = progress.total or 0
    stats.progress_percent = progress.total and progress.total > 0 and math.floor((progress.done or 0) * 100 / progress.total) or 0
end

local function notify_warm_progress(client, reason, force)
    if vim.g.cangjie_lsp_warm_progress == false then
        return
    end
    local progress = warm_progress_state(client)
    if not progress or not progress.active or (progress.total or 0) == 0 then
        return
    end

    local percent = math.min(100, math.floor((progress.done or 0) * 100 / math.max(progress.total or 0, 1)))
    local now = now_ms()
    local min_interval = vim.g.cangjie_lsp_warm_progress_min_interval_ms or 200
    if not force and percent == progress.last_percent and now - (progress.last_update_ms or 0) < min_interval then
        return
    end
    if not force and now - (progress.last_update_ms or 0) < min_interval and percent < 100 then
        return
    end

    progress.last_update_ms = now
    progress.last_percent = percent
    if vim.g.cangjie_lsp_warm_progress_backend ~= "notify" and emit_lsp_warm_progress(client, reason, percent) then
        return
    end

    local bar, display_percent = warm_progress_bar(progress.done, progress.total)
    local label = warm_progress_label(reason)
    local message = ("%s\n%s  %3d%%  %d/%d files"):format(label, bar, display_percent, progress.done or 0, progress.total or 0)

    local ok, notify_id = pcall(vim.notify, message, vim.log.levels.INFO, {
        title = "Cangjie LSP",
        id = progress.id,
        replace = progress.notify_id or progress.id,
        timeout = percent >= 100 and reason == "done" and 1800 or false,
    })
    if ok and notify_id then
        progress.notify_id = notify_id
    end
end

local function reset_warm_progress(client)
    local progress = warm_progress_state(client)
    if not progress then
        return
    end
    progress.active = false
    progress.last_percent = -1
end

local diagnostic_display_refresh_generation = 0

local function refresh_cangjie_diagnostic_display(reason)
    local touched = {}
    local buffer_count = 0
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
        if name:match("%.cj$") and vim.api.nvim_buf_is_loaded(bufnr) then
            pcall(vim.diagnostic.show, nil, bufnr)
            touched[bufnr] = true
            buffer_count = buffer_count + 1
        end
    end
    local cursor_events = 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) or nil
        if bufnr and touched[bufnr] then
            pcall(vim.api.nvim_exec_autocmds, "CursorMoved", {
                buffer = bufnr,
                modeline = false,
            })
            cursor_events = cursor_events + 1
            if vim.fn.mode():find("^i") then
                pcall(vim.api.nvim_exec_autocmds, "CursorMovedI", {
                    buffer = bufnr,
                    modeline = false,
                })
                cursor_events = cursor_events + 1
            end
        end
    end
    local stats = current_cangjie_client and warm_stats(current_cangjie_client()) or nil
    if stats then
        stats.diagnostic_display_refreshes = (stats.diagnostic_display_refreshes or 0) + 1
        stats.diagnostic_display_buffers = buffer_count
        stats.diagnostic_cursor_events = cursor_events
        stats.diagnostic_refresh_last_reason = reason or "unknown"
    end
    if vim.api.nvim__redraw then
        pcall(vim.api.nvim__redraw, { flush = true, valid = false })
    end
    pcall(vim.cmd, "redraw!")
end

local function schedule_cangjie_diagnostic_display_refresh(reason)
    diagnostic_display_refresh_generation = diagnostic_display_refresh_generation + 1
    local generation = diagnostic_display_refresh_generation
    vim.defer_fn(function()
        if generation ~= diagnostic_display_refresh_generation then
            return
        end
        refresh_cangjie_diagnostic_display(reason)
    end, vim.g.cangjie_lsp_diagnostic_redraw_delay_ms or 80)
end

local function schedule_warm_progress_done(client, reason)
    local progress = warm_progress_state(client)
    if not progress or not progress.active then
        return
    end
    progress.done = progress.total
    progress.settle_generation = (progress.settle_generation or 0) + 1
    local generation = progress.settle_generation
    update_warm_progress_stats(client, progress)
    notify_warm_progress(client, reason or "settling diagnostics", true)

    vim.defer_fn(function()
        local current = warm_progress_state(client)
        if not current or not current.active or current.settle_generation ~= generation then
            return
        end
        current.done = current.total
        update_warm_progress_stats(client, current)
        notify_warm_progress(client, "done", true)
        reset_warm_progress(client)
        schedule_cangjie_diagnostic_display_refresh("warm-complete")
        schedule_explorer_refresh("warm-complete")
    end, vim.g.cangjie_lsp_warm_diagnostics_settle_ms or 1200)
end

local function warm_package_key(source_module, dir)
    if not (source_module and source_module.name and dir) then
        return nil
    end
    return source_module.name .. ":" .. vim.fs.normalize(dir)
end

local explorer_refresh_generation = 0
local explorer_diagnostic_autocmd_ready = false

local function snacks_picker_module()
    local snacks = rawget(_G, "Snacks")
    if not (snacks and snacks.picker and snacks.picker.get) then
        local ok_snacks, loaded = pcall(require, "snacks")
        snacks = ok_snacks and loaded or nil
    end
    if snacks and snacks.picker and snacks.picker.get then
        return snacks.picker
    end
    local ok_picker, picker = pcall(require, "snacks.picker")
    if ok_picker and picker and picker.get then
        return picker
    end
end

local function refresh_open_snacks_explorers(reason, notify)
    local picker_mod = snacks_picker_module()
    local report = {
        reason = reason or "unknown",
        pickers = 0,
        refreshed = 0,
        diagnostics_updates = 0,
    }
    if not picker_mod then
        report.error = "snacks.picker unavailable"
        if notify then
            vim.notify(vim.inspect(report), vim.log.levels.WARN, { title = "Cangjie Explorer Refresh" })
        end
        return report
    end
    local ok_diag, diagnostics = pcall(require, "snacks.explorer.diagnostics")
    local ok_actions, explorer_actions = pcall(require, "snacks.explorer.actions")
    local pickers = picker_mod.get({ source = "explorer", tab = false }) or {}
    report.pickers = #pickers

    local function force_picker_redraw(picker)
        if not picker or picker.closed then
            return
        end
        if picker.list then
            if picker.list.unpause then
                pcall(picker.list.unpause, picker.list)
            end
            if picker.list.update then
                pcall(picker.list.update, picker.list, { force = true })
            end
            if picker.list.win and picker.list.win.redraw then
                pcall(picker.list.win.redraw, picker.list.win)
            end
        end
        if picker.input and picker.input.update then
            pcall(picker.input.update, picker.input)
        end
    end

    for _, picker in ipairs(pickers) do
        if picker and not picker.closed then
            local picker_info = {
                cwd = picker.cwd and picker:cwd() or nil,
                diagnostics = picker.opts and picker.opts.diagnostics,
                diagnostics_open = picker.opts and picker.opts.diagnostics_open,
                list_items = picker.list and picker.list.items and #picker.list.items or 0,
                finder_items = picker.finder and picker.finder.items and #picker.finder.items or 0,
                cwd_diagnostics = 0,
                tree_severity = nil,
            }
            if picker_info.cwd then
                for _, diag in ipairs(vim.diagnostic.get()) do
                    local path = diag.bufnr and vim.api.nvim_buf_is_valid(diag.bufnr) and vim.api.nvim_buf_get_name(diag.bufnr) or nil
                    if path and path ~= "" then
                        path = vim.fs.normalize(path)
                        local cwd = vim.fs.normalize(picker_info.cwd)
                        if path == cwd or vim.startswith(path, cwd .. "/") then
                            picker_info.cwd_diagnostics = picker_info.cwd_diagnostics + 1
                        end
                    end
                end
            end
            if ok_diag and diagnostics and diagnostics.update and picker.cwd then
                local ok_update = pcall(diagnostics.update, picker:cwd())
                if ok_update then
                    report.diagnostics_updates = report.diagnostics_updates + 1
                end
            end
            local ok_tree, tree = pcall(require, "snacks.explorer.tree")
            if ok_tree and tree and tree.find and picker_info.cwd then
                local ok_node, node = pcall(tree.find, tree, picker_info.cwd)
                picker_info.tree_severity = ok_node and node and node.severity or nil
            end
            if picker.list and picker.list.set_target then
                pcall(picker.list.set_target, picker.list)
            end
            if ok_actions and explorer_actions and explorer_actions.update then
                local ok_update = pcall(explorer_actions.update, picker, { refresh = true })
                if not ok_update then
                    force_picker_redraw(picker)
                end
                vim.defer_fn(function()
                    force_picker_redraw(picker)
                end, 80)
            elseif picker.find then
                local ok_find = pcall(picker.find, picker, {
                    refresh = true,
                    on_done = function()
                        force_picker_redraw(picker)
                    end,
                })
                if not ok_find then
                    force_picker_redraw(picker)
                end
            elseif picker.refresh then
                pcall(picker.refresh, picker)
                force_picker_redraw(picker)
            else
                force_picker_redraw(picker)
            end
            report[#report + 1] = picker_info
            report.refreshed = report.refreshed + 1
        end
    end

    local client = current_cangjie_client and current_cangjie_client() or nil
    local stats = warm_stats(client)
    if stats then
        stats.explorer_seen = report.pickers
        stats.explorer_diag_updates = report.diagnostics_updates
    end
    if stats and report.refreshed > 0 then
        stats.explorer_refreshes = (stats.explorer_refreshes or 0) + report.refreshed
        stats.explorer_last_reason = reason or "unknown"
    end
    if notify then
        local ok_file, fd = pcall(io.open, "/tmp/cangjie_explorer_refresh.log", "w")
        if ok_file and fd then
            fd:write(vim.inspect(report))
            fd:write("\n")
            fd:close()
        end
        vim.notify(vim.inspect(report), vim.log.levels.INFO, { title = "Cangjie Explorer Refresh" })
    end
    return report
end

schedule_explorer_refresh = function(reason)
    if vim.g.cangjie_lsp_explorer_refresh == false then
        return
    end
    explorer_refresh_generation = explorer_refresh_generation + 1
    local generation = explorer_refresh_generation
    vim.defer_fn(function()
        if generation ~= explorer_refresh_generation then
            return
        end
        refresh_open_snacks_explorers(reason)
    end, vim.g.cangjie_lsp_explorer_refresh_delay_ms or 450)
end

local function schedule_explorer_refresh_for_uri(uri, reason)
    if type(uri) ~= "string" or uri == "" then
        return
    end
    local ok, path = pcall(vim.uri_to_fname, uri)
    if ok and type(path) == "string" and path:match("%.cj$") then
        schedule_explorer_refresh(reason)
    end
end

local function existing_bufnr_for_path(path)
    local normalized = path and vim.fs.normalize(path) or nil
    if not normalized then
        return nil
    end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name ~= "" and vim.fs.normalize(name) == normalized then
            return bufnr
        end
    end
end

local function user_loaded_buffer_for_path(path)
    local bufnr = existing_bufnr_for_path(path)
    return bufnr and vim.api.nvim_buf_is_loaded(bufnr) or false
end

local function should_suppress_warm_diagnostics(client, uri)
    if not (client and client.config and client.config._cangjie_warmed_package_files and uri) then
        return false
    end
    local ok, path = pcall(vim.uri_to_fname, uri)
    if not ok or type(path) ~= "string" then
        return false
    end
    local normalized = vim.fs.normalize(path)
    return client.config._cangjie_warmed_package_files[normalized] == true and not user_loaded_buffer_for_path(normalized)
end

local function clear_existing_diagnostics_for_uri(uri)
    local ok, path = pcall(vim.uri_to_fname, uri)
    if not ok or type(path) ~= "string" then
        return
    end
    local bufnr = existing_bufnr_for_path(path)
    if bufnr then
        vim.diagnostic.reset(nil, bufnr)
    end
end

local function ensure_explorer_diagnostic_refresh_autocmd()
    if explorer_diagnostic_autocmd_ready then
        return
    end
    explorer_diagnostic_autocmd_ready = true
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
        group = vim.api.nvim_create_augroup("codex_cangjie_explorer_refresh", { clear = true }),
        callback = function(ev)
            local name = ev and ev.buf and vim.api.nvim_buf_is_valid(ev.buf) and vim.api.nvim_buf_get_name(ev.buf) or ""
            if name:match("%.cj$") then
                schedule_cangjie_diagnostic_display_refresh("diagnostic-changed")
                schedule_explorer_refresh("diagnostics-autocmd")
            end
        end,
        desc = "Debounced Snacks explorer refresh for Cangjie diagnostics",
    })
end

package_cj_files = function(dir, current, limit)
    local files = vim.fs.find(function(name, path)
        if current and name == vim.fs.basename(current) then
            return false
        end
        return name:match("%.cj$") and path == dir
    end, {
        path = dir,
        type = "file",
        limit = limit,
    })
    table.sort(files)
    return files
end

local function trim_import_package(import_name)
    import_name = trim_text(import_name)
    if not import_name then
        return nil
    end
    import_name = import_name:gsub("%.+$", "")
    return import_name ~= "" and import_name or nil
end

local function imported_package_names(lines)
    local packages = {}
    local seen = {}
    for _, line in ipairs(lines or {}) do
        line = line:gsub("//.*$", "")
        local package = line:match("^%s*import%s+([%w_%.]+)")
        if not package then
            package = line:match("^%s*from%s+([%w_%.]+)%s+import%s+")
        end
        package = trim_import_package(package)
        if package and not seen[package] then
            seen[package] = true
            packages[#packages + 1] = package
        end
    end
    return packages
end

local function import_scan_lines(bufnr)
    local max_lines = vim.g.cangjie_lsp_warm_import_scan_lines or 200
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, math.min(line_count, max_lines), false)
end

local function resolve_source_package_dir(source_module, package_name)
    if not (source_module and source_module.name and source_module.src_path and package_name) then
        return nil
    end
    if package_name ~= source_module.name and not vim.startswith(package_name, source_module.name .. ".") then
        return nil
    end

    local rest = package_name:sub(#source_module.name + 2)
    local parts = {}
    for part in rest:gmatch("[^.]+") do
        parts[#parts + 1] = part
    end

    while true do
        local dir = source_module.src_path
        for _, part in ipairs(parts) do
            dir = vim.fs.joinpath(dir, part)
        end
        if vim.fn.isdirectory(dir) == 1 then
            return vim.fs.normalize(dir)
        end
        if #parts == 0 then
            return nil
        end
        table.remove(parts)
    end
end

local function current_import_package_dirs(bufnr, source_module)
    local lines = import_scan_lines(bufnr)
    local dirs = {}
    local seen = {}
    for _, package_name in ipairs(imported_package_names(lines)) do
        local dir = resolve_source_package_dir(source_module, package_name)
        if dir and not seen[dir] then
            seen[dir] = true
            dirs[#dirs + 1] = dir
        end
    end
    table.sort(dirs)
    return dirs
end

local function source_package_dir_from_symbol(source_module, symbol)
    local name = symbol and (symbol.fqname or symbol.id or symbol.name) or nil
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return resolve_source_package_dir(source_module, name)
end

local function warm_package_file(client, path)
    client.config._cangjie_warmed_package_files = client.config._cangjie_warmed_package_files or {}
    local normalized = vim.fs.normalize(path)
    if client.config._cangjie_warmed_package_files[normalized] then
        return false, "duplicate"
    end

    local max_bytes = vim.g.cangjie_lsp_warm_package_max_file_bytes or (512 * 1024)
    local stat = (vim.uv or vim.loop).fs_stat(normalized)
    if not stat or stat.type ~= "file" or stat.size > max_bytes then
        local stats = warm_stats(client)
        if stats and stat and stat.type == "file" and stat.size > max_bytes then
            stats.skipped_large_files = (stats.skipped_large_files or 0) + 1
        end
        return false, "skipped"
    end

    local ok, lines = pcall(vim.fn.readfile, normalized)
    if not ok or type(lines) ~= "table" then
        local stats = warm_stats(client)
        if stats then
            stats.skipped_read_files = (stats.skipped_read_files or 0) + 1
        end
        return false, "read_error"
    end

    client.config._cangjie_warmed_package_files[normalized] = true
    client.notify("textDocument/didOpen", {
        textDocument = {
            uri = vim.uri_from_fname(normalized),
            languageId = "Cangjie",
            version = 0,
            text = table.concat(lines, "\n"),
        },
    })
    local stats = warm_stats(client)
    if stats then
        stats.warmed_files = (stats.warmed_files or 0) + 1
    end
    return true, "warmed"
end

local function queue_warm_files(client, bufnr, package_dir, files, reason)
    if not (client and client.config and files and #files > 0) then
        return 0
    end

    client.config._cangjie_warm_queue = client.config._cangjie_warm_queue or {}
    client.config._cangjie_queued_warm_files = client.config._cangjie_queued_warm_files or {}
    client.config._cangjie_warmed_package_dirs = client.config._cangjie_warmed_package_dirs or {}

    local source_module = client.config._cangjie_source_module
    local package_key = warm_package_key(source_module, package_dir)
    if package_key and client.config._cangjie_warmed_package_dirs[package_key] then
        return 0
    end
    if package_key then
        client.config._cangjie_warmed_package_dirs[package_key] = true
    end

    local queued = 0
    for _, path in ipairs(files) do
        local normalized = vim.fs.normalize(path)
        if not client.config._cangjie_warmed_package_files or not client.config._cangjie_warmed_package_files[normalized] then
            if not client.config._cangjie_queued_warm_files[normalized] then
                client.config._cangjie_queued_warm_files[normalized] = true
                table.insert(client.config._cangjie_warm_queue, {
                    path = normalized,
                    bufnr = bufnr,
                    package_key = package_key,
                    reason = reason or "warm",
                })
                queued = queued + 1
            end
        end
    end

    local stats = warm_stats(client)
    if stats then
        stats.queued_files = #client.config._cangjie_warm_queue
        stats.last_reason = reason or stats.last_reason
        if package_key then
            stats.packages[package_key] = stats.packages[package_key]
                or {
                    dir = package_dir,
                    queued = 0,
                    warmed = 0,
                    reason = reason or "warm",
                }
            stats.packages[package_key].queued = stats.packages[package_key].queued + queued
        end
    end
    local progress = warm_progress_state(client)
    if progress and progress.active and queued > 0 then
        progress.total = (progress.done or 0) + #client.config._cangjie_warm_queue
        update_warm_progress_stats(client, progress)
        notify_warm_progress(client, reason or "queued", true)
    end
    return queued
end

local function run_warm_queue(client)
    if not (client and client.config and client.notify) then
        return
    end
    if client.config._cangjie_warm_queue_running then
        return
    end

    client.config._cangjie_warm_queue_running = true
    local progress = warm_progress_state(client)
    if progress then
        progress.active = true
        progress.done = 0
        progress.total = #(client.config._cangjie_warm_queue or {})
        progress.last_update_ms = 0
        progress.last_percent = -1
        update_warm_progress_stats(client, progress)
        notify_warm_progress(client, "starting", true)
    end
    local uv = vim.uv or vim.loop
    local function step()
        if not (client and client.config and client.notify) then
            return
        end

        local queue = client.config._cangjie_warm_queue or {}
        local stats = warm_stats(client)
        if #queue == 0 then
            client.config._cangjie_warm_queue_running = false
            if stats then
                stats.queued_files = 0
            end
            schedule_warm_progress_done(client, "settling diagnostics")
            return
        end

        local started = uv.hrtime()
        local batch_size = vim.g.cangjie_lsp_warm_batch_size or 5
        local processed = 0
        while processed < batch_size and #queue > 0 do
            local item = table.remove(queue, 1)
            if item and item.path then
                client.config._cangjie_queued_warm_files[item.path] = nil
                local warmed = warm_package_file(client, item.path)
                if warmed and item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) then
                    vim.b[item.bufnr].cangjie_lsp_warmed_package_files = (vim.b[item.bufnr].cangjie_lsp_warmed_package_files or 0) + 1
                end
                if warmed and stats and item.package_key and stats.packages[item.package_key] then
                    stats.packages[item.package_key].warmed = stats.packages[item.package_key].warmed + 1
                end
                local item_progress = warm_progress_state(client)
                if item_progress and item_progress.active then
                    item_progress.done = math.min((item_progress.done or 0) + 1, item_progress.total or 0)
                end
            end
            processed = processed + 1
        end

        if stats then
            stats.queued_files = #queue
            stats.last_elapsed_ms = math.floor((uv.hrtime() - started) / 1000000)
        end
        local batch_progress = warm_progress_state(client)
        if batch_progress and batch_progress.active then
            batch_progress.total = math.max(batch_progress.total or 0, (batch_progress.done or 0) + #queue)
            update_warm_progress_stats(client, batch_progress)
            notify_warm_progress(client, "warming", false)
        end
        vim.defer_fn(step, vim.g.cangjie_lsp_warm_batch_delay_ms or 75)
    end

    vim.schedule(step)
end

local function enqueue_package_dir_warm(client, bufnr, dir, current, limit, reason)
    if not dir then
        return 0
    end
    local files = package_cj_files(dir, current, limit)
    local queued = queue_warm_files(client, bufnr, dir, files, reason)
    if queued > 0 then
        run_warm_queue(client)
    end
    return queued
end

local function warm_current_package_sources(client, bufnr)
    if vim.g.cangjie_lsp_warm_package_files == false then
        return
    end
    if not (client and client.notify and client.config and client.config._cangjie_source_module) then
        return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local current = vim.api.nvim_buf_get_name(bufnr)
    local current_dir = current ~= "" and vim.fs.dirname(current) or nil
    local queued = 0
    queued = queued + enqueue_package_dir_warm(client, bufnr, current_dir, current, vim.g.cangjie_lsp_warm_package_max_files or 80, "current-package")

    local max_import_dirs = vim.g.cangjie_lsp_warm_import_max_dirs or 8
    local import_dir_count = 0
    for _, dir in ipairs(current_import_package_dirs(bufnr, client.config._cangjie_source_module)) do
        if dir ~= current_dir then
            import_dir_count = import_dir_count + 1
            if import_dir_count > max_import_dirs then
                break
            end
            queued = queued + enqueue_package_dir_warm(client, bufnr, dir, nil, vim.g.cangjie_lsp_warm_import_max_files or 40, "direct-import")
        end
    end
    vim.b[bufnr].cangjie_lsp_warm_queued_files = queued
end

local function warm_symbol_package_on_demand(symbol, reason)
    if vim.g.cangjie_lsp_warm_on_demand == false then
        return
    end
    local client = current_cangjie_client()
    local bufnr = vim.api.nvim_get_current_buf()
    if not (client and client.config and client.config._cangjie_source_module) then
        return
    end
    local dir = source_package_dir_from_symbol(client.config._cangjie_source_module, symbol)
    if not dir then
        return
    end
    enqueue_package_dir_warm(client, bufnr, dir, nil, vim.g.cangjie_lsp_warm_import_max_files or 40, reason or "on-demand")
end

local function warm_cursor_symbol_package_on_demand(reason)
    if vim.g.cangjie_lsp_warm_on_demand == false then
        return
    end
    local docs = get_docs_index()
    if not (docs.current_cursor_context and docs.find_symbol_for_hover_lines) then
        return
    end
    local context = docs.current_cursor_context()
    local symbol = docs.find_symbol_for_hover_lines({}, { context = context })
    if symbol then
        warm_symbol_package_on_demand(symbol, reason)
    end
end

local function configure_source_module_init(init_params, config)
    local root = config and config.root_dir or nil
    local source_module = source_module_for_path(root)
    if not source_module then
        local root_uri = init_params and init_params.rootUri or nil
        if root_uri then
            source_module = source_module_for_path(vim.uri_to_fname(root_uri))
        end
    end
    if not source_module then
        return
    end

    local init_options = vim.tbl_deep_extend("force", init_params.initializationOptions or {}, source_module_init_options(source_module) or {})
    init_params.initializationOptions = init_options
    if config then
        config._cangjie_source_module = source_module
        config._cangjie_init_options = init_options
    end
end

local function hover_markdown_lines(result)
    if not result or not result.contents then
        return {}
    end
    local ok, lines = pcall(vim.lsp.util.convert_input_to_markdown_lines, result.contents)
    if not ok or type(lines) ~= "table" then
        return {}
    end
    lines = trim_empty_lines(lines)
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
    warm_cursor_symbol_package_on_demand(method .. "-empty")
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
    append_debug_log(("[source_doc] declaration_check raw=%s stripped=%s matched=%s"):format(tostring(line), tostring(declaration), tostring(matched ~= nil)))
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
    append_debug_log(("[source_doc] render signature=%s lines=%d params=%d throws=%d"):format(tostring(signature), #out, param_count, throws_count))
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
        append_debug_log(("[source_doc] skip_non_declaration path=%s line=%d signature=%s"):format(tostring(path), (line0 or 0) + 1, tostring(signature)))
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
        append_debug_log(("[source_doc] empty path=%s line=%d signature=%s"):format(tostring(path), (line0 or 0) + 1, tostring(signature)))
        return nil
    end
    append_debug_log(("[source_doc] extracted path=%s line=%d signature=%s raw_lines=%d"):format(tostring(path), (line0 or 0) + 1, tostring(signature), #docs))
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
    warm_cursor_symbol_package_on_demand(method .. "-empty-source-doc")
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

current_cangjie_client = function()
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
    local source_module = client.config and (client.config._cangjie_source_module or source_module_for_path(client.config.root_dir)) or nil
    if source_module then
        local stats = client.config and client.config._cangjie_warm_stats or {}
        lines[#lines + 1] = ("module=%s"):format(source_module.name or "nil")
        lines[#lines + 1] = ("root=%s"):format(source_module.root or "nil")
        lines[#lines + 1] = ("src_path=%s"):format(source_module.src_path or "nil")
        lines[#lines + 1] = ("multiModuleOption=%s"):format(
            client.config and client.config._cangjie_init_options and client.config._cangjie_init_options.multiModuleOption and "yes" or "unknown"
        )
        lines[#lines + 1] = ("warm_package_files=%s"):format(tostring(vim.b.cangjie_lsp_warmed_package_files or 0))
        lines[#lines + 1] = ("warm_queued_files=%s"):format(tostring(stats.queued_files or vim.b.cangjie_lsp_warm_queued_files or 0))
        lines[#lines + 1] = ("warm_total_files=%s"):format(tostring(stats.warmed_files or 0))
        lines[#lines + 1] = ("warm_skipped_large=%s"):format(tostring(stats.skipped_large_files or 0))
        lines[#lines + 1] = ("warm_last_batch_ms=%s"):format(tostring(stats.last_elapsed_ms or 0))
        lines[#lines + 1] = ("warm_last_reason=%s"):format(tostring(stats.last_reason or "none"))
        lines[#lines + 1] = ("warm_progress=%s/%s %s%%"):format(tostring(stats.progress_done or 0), tostring(stats.progress_total or 0), tostring(stats.progress_percent or 0))
        lines[#lines + 1] = ("suppressed_warm_diagnostics=%s"):format(tostring(stats.suppressed_warm_diagnostics or 0))
        lines[#lines + 1] = ("diagnostic_display_refreshes=%s"):format(tostring(stats.diagnostic_display_refreshes or 0))
        lines[#lines + 1] = ("diagnostic_display_buffers=%s"):format(tostring(stats.diagnostic_display_buffers or 0))
        lines[#lines + 1] = ("diagnostic_cursor_events=%s"):format(tostring(stats.diagnostic_cursor_events or 0))
        lines[#lines + 1] = ("diagnostic_refresh_last_reason=%s"):format(tostring(stats.diagnostic_refresh_last_reason or "none"))
        lines[#lines + 1] = ("explorer_seen=%s"):format(tostring(stats.explorer_seen or 0))
        lines[#lines + 1] = ("explorer_diag_updates=%s"):format(tostring(stats.explorer_diag_updates or 0))
        lines[#lines + 1] = ("explorer_refreshes=%s"):format(tostring(stats.explorer_refreshes or 0))
        lines[#lines + 1] = ("explorer_last_reason=%s"):format(tostring(stats.explorer_last_reason or "none"))
        lines[#lines + 1] = ""
    elseif client.config and client.config.root_dir then
        lines[#lines + 1] = ("root=%s"):format(client.config.root_dir)
        lines[#lines + 1] = ""
    end
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

    local function symbol_from_context(reason)
        local hover_sym = docs.find_symbol_for_hover_lines and docs.find_symbol_for_hover_lines({}, { context = context }) or nil
        append_debug_log("[hover] " .. reason .. "_fallback_symbol=" .. tostring(hover_sym and (hover_sym.fqname or hover_sym.id) or nil))
        if hover_sym then
            warm_symbol_package_on_demand(hover_sym, "hover-" .. reason)
            return hover_sym, nil
        end
        return nil, nil
    end

    local params = make_position_params()
    local results = vim.lsp.buf_request_sync(0, "textDocument/hover", params, 500)
    if not results then
        append_debug_log("[hover] results=nil")
        return symbol_from_context("nil")
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
    return symbol_from_context("empty")
end

local function cursor_in_call_site()
    local line = vim.api.nvim_get_current_line()
    local col1 = (vim.api.nvim_win_get_cursor(0)[2] or 0) + 1
    local left = line:sub(1, col1)
    local ident = left:match("([%w_]+)%s*$")
    if not ident or ident == "" then
        return false
    end

    local start_col = col1 - #ident + 1
    local idx = start_col + #ident
    while idx <= #line and line:sub(idx, idx):match("%s") do
        idx = idx + 1
    end

    local next_char = line:sub(idx, idx)
    if next_char == "<" then
        local depth = 0
        for i = idx, #line do
            local ch = line:sub(i, i)
            if ch == "<" then
                depth = depth + 1
            elseif ch == ">" then
                depth = depth - 1
                if depth == 0 then
                    idx = i + 1
                    while idx <= #line and line:sub(idx, idx):match("%s") do
                        idx = idx + 1
                    end
                    next_char = line:sub(idx, idx)
                    break
                end
            end
        end
    end

    return next_char == "("
end

local function hover_local_declared_type(lines)
    local ident = trim_text(vim.fn.expand("<cword>"))
    if not ident then
        return nil, nil
    end

    local escaped_ident = vim.pesc(ident)
    for _, raw in ipairs(lines or {}) do
        local line = trim_text(raw)
        if line then
            for _, keyword in ipairs({ "let", "var", "const" }) do
                local type_name = trim_text(line:match("^" .. keyword .. "%s+" .. escaped_ident .. "%s*:%s*(.+)$"))
                if type_name then
                    return line, type_name
                end
            end
        end
    end
end

local function single_generic_inner_type(type_name)
    type_name = trim_text(type_name)
    if not type_name then
        return nil
    end

    local start_col = type_name:find("<", 1, true)
    if not start_col or type_name:sub(-1) ~= ">" then
        return nil
    end

    local body = trim_text(type_name:sub(start_col + 1, -2))
    if not body then
        return nil
    end

    local depth = 0
    for i = 1, #body do
        local ch = body:sub(i, i)
        if ch == "<" then
            depth = depth + 1
        elseif ch == ">" then
            depth = depth - 1
        elseif ch == "," and depth == 0 then
            return nil
        end
    end
    return body
end

local function find_type_symbol(docs, type_name)
    if not (docs and docs.find_symbol) then
        return nil
    end

    type_name = trim_text(type_name)
    local base = sanitize_lookup_type_name(type_name)
    if type_name then
        local sym = docs.find_symbol(type_name)
        if sym then
            return sym
        end
    end
    if base and base ~= type_name then
        return docs.find_symbol(base)
    end
end

local function show_local_hover_type_docs(docs, hover_sym, hover_lines)
    if not (docs and hover_sym and hover_lines and #hover_lines > 0) then
        return false
    end

    local declaration, type_name = hover_local_declared_type(hover_lines)
    if not declaration or not type_name then
        return false
    end

    local render_lines = docs.hover_markdown_for_symbol and docs.hover_markdown_for_symbol(hover_sym) or nil
    if not (render_lines and #render_lines > 0) then
        return false
    end

    local inner_type = single_generic_inner_type(type_name)
    local inner_sym = find_type_symbol(docs, inner_type)
    local lines = {
        "```cangjie",
        declaration,
        "```",
        "",
    }
    if inner_type then
        lines[#lines + 1] = ("元素类型：`%s`"):format(inner_type)
        if inner_sym then
            lines[#lines + 1] = "按 `<CR>` 打开元素类型文档。"
        end
        lines[#lines + 1] = ""
    end

    for _, line in ipairs(render_lines) do
        lines[#lines + 1] = line
    end

    append_debug_log(
        "[K] local_hover_type_docs type="
            .. tostring(type_name)
            .. " symbol="
            .. tostring(hover_sym and (hover_sym.fqname or hover_sym.id) or nil)
            .. " inner="
            .. tostring(inner_sym and (inner_sym.fqname or inner_sym.id) or inner_type)
    )
    if docs.open_preview then
        docs.open_preview(lines, inner_sym and { action = { sym = inner_sym } } or nil)
    else
        vim.lsp.util.open_floating_preview(lines, "markdown", {
            border = "rounded",
            max_width = 100,
            max_height = 30,
        })
    end
    return true
end

local function hover_or_local_docs()
    local docs = get_docs_index()
    append_debug_log("[K] start")
    if docs.preview_visible and docs.preview_visible() then
        append_debug_log("[K] close_preview")
        if docs.close_preview then
            docs.close_preview()
        end
        return
    end
    local local_sym = docs_from_lsp_locations("textDocument/declaration") or docs_from_lsp_locations("textDocument/definition")
    append_debug_log("[K] lsp_locations=" .. tostring(local_sym and (local_sym.fqname or local_sym.id) or nil))
    if local_sym then
        docs.show_symbol(local_sym)
        return
    end

    local hover_sym, hover_lines = docs_from_current_hover()
    append_debug_log("[K] hover_early=" .. tostring(hover_sym and (hover_sym.fqname or hover_sym.id) or nil))
    append_debug_log("[K] cursor_in_call_site=" .. tostring(cursor_in_call_site()))
    local prefer_hover_lines = hover_lines
        and #hover_lines > 0
        and ((docs.cursor_has_member_access and docs.cursor_has_member_access()) or cursor_in_call_site() or docs.should_try_lsp_hover())
    append_debug_log("[K] prefer_hover_lines=" .. tostring(prefer_hover_lines))
    if prefer_hover_lines then
        if hover_sym then
            append_debug_log("[K] prefer_hover_docs=" .. tostring(hover_sym and (hover_sym.fqname or hover_sym.id) or nil))
            if show_local_hover_type_docs(docs, hover_sym, hover_lines) then
                return
            end
            docs.show_symbol(hover_sym)
            return
        end
        vim.lsp.util.open_floating_preview(hover_lines, "markdown", {
            border = "rounded",
            max_width = 100,
            max_height = 30,
        })
        return
    end
    if hover_sym then
        if show_local_hover_type_docs(docs, hover_sym, hover_lines) then
            return
        end
        docs.show_symbol(hover_sym)
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

    local source_lines = source_doc_lines_from_locations("textDocument/declaration") or source_doc_lines_from_locations("textDocument/definition") or source_doc_lines_for_cursor()
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
    local using_native = use_native_cangjie_inlay(bufnr)
    local pseudo_status = pseudo_inlay_hints().status(bufnr)
    local enabled = using_native and ih and ih.is_enabled and ih.is_enabled({ bufnr = bufnr }) or pseudo_status.enabled
    return {
        supported = supported,
        using_native = using_native,
        enabled = enabled,
        hide_in_insert = cangjie_inlay_hide_in_insert(),
        local_auto_features = cangjie_local_auto_features_enabled(),
    }
end

local function manage_cangjie_inlay_hints(action)
    local bufnr = vim.api.nvim_get_current_buf()
    local status = cangjie_inlay_hints_status(bufnr)
    if not status.using_native then
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
                ("using_native=%s"):format(tostring(status.using_native)),
                ("enabled=%s"):format(tostring(status.enabled)),
                ("hide_in_insert=%s"):format(tostring(status.hide_in_insert)),
                ("local_auto_features=%s"):format(tostring(status.local_auto_features)),
            }, "\n"),
            vim.log.levels.INFO,
            { title = "Cangjie Inlay Hints" }
        )
    end
end

local function manage_cangjie_completion_docs(action)
    action = trim_text(action) or "toggle"

    if action == "toggle" then
        vim.g.cangjie_manual_completion_docs = not cangjie_manual_completion_docs_enabled()
    elseif action == "on" then
        vim.g.cangjie_manual_completion_docs = true
    elseif action == "off" then
        vim.g.cangjie_manual_completion_docs = false
    elseif action == "status" then
        -- handled below
    else
        vim.notify("Usage: CangjieCompletionDocs [toggle|on|off|status]", vim.log.levels.WARN, { title = "Cangjie" })
        return
    end

    vim.b.cangjie_completion_docs_manual = false

    vim.notify(
        table.concat({
            ("manual_docs=%s"):format(tostring(cangjie_manual_completion_docs_enabled())),
            ("auto_docs=%s"):format(tostring(cangjie_completion_docs_enabled())),
        }, action == "status" and "\n" or ""),
        vim.log.levels.INFO,
        { title = "Cangjie Completion Docs" }
    )
end

local function show_completion_or_notify()
    append_completion_log(("[manual] ft=%s line=%s"):format(tostring(vim.bo.filetype), tostring(vim.api.nvim_get_current_line())))
    local blink = get_blink()
    if blink and blink.show then
        vim.b.cangjie_completion_docs_manual = cangjie_manual_completion_docs_enabled()
        append_completion_log("[manual] blink.show")
        blink.show({
            providers = (cangjie_completion_docs_enabled() or cangjie_manual_completion_docs_enabled()) and { "lsp", "cangjie_docs", "buffer", "path" }
                or { "lsp", "buffer", "path" },
        })
        return
    end
    append_completion_log("[manual] blink_unavailable")
    vim.notify("blink.cmp 不可用，无法触发补全", vim.log.levels.WARN, { title = "Cangjie" })
end

local function trigger_completion_after_dot()
    if not cangjie_local_auto_features_enabled() or not cangjie_dot_completion_enabled() then
        append_completion_log("[dot] skipped auto_features_or_dot_completion=off")
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
            blink.show({ providers = cangjie_completion_docs_enabled() and { "lsp", "cangjie_docs", "buffer", "path" } or { "lsp", "buffer", "path" } })
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

    if not vim.fn.maparg("K", "n", false, true).buffer then
        map("n", "K", live("_codex_hover_or_local_docs"), "Cangjie Docs")
    end
    map("n", "gK", live("_codex_signature_help_or_notify"), "Cangjie Signature Help")
    map("n", "gr", live("_codex_references"), "Cangjie References")
    map("n", "<localleader>jr", live("_codex_rename"), "Cangjie Rename")
    map("n", "<localleader>jR", live("_codex_references"), "Cangjie References")
    map("n", "<localleader>ju", live("_codex_incoming_calls"), "Cangjie Incoming Calls")
    map("n", "<localleader>jU", live("_codex_outgoing_calls"), "Cangjie Outgoing Calls")
    map("n", "<localleader>jt", live("_codex_supertypes"), "Cangjie Supertypes")
    map("n", "<localleader>jT", live("_codex_subtypes"), "Cangjie Subtypes")
    map("n", "gD", function()
        notify_unsupported_lsp_feature("Declaration")
    end, "Declaration Unsupported")
    map("n", "gi", function()
        notify_unsupported_lsp_feature("Implementation")
    end, "Implementation Unsupported")
    map("n", "gy", function()
        notify_unsupported_lsp_feature("Type Definition")
    end, "Type Definition Unsupported")
    map("n", "<localleader>jo", live("_codex_open_docs_in_browser"), "Open Cangjie docs in browser")
    map("n", "<localleader>jq", live("_codex_document_symbols"), "Cangjie Document Symbols")
    map("n", "<localleader>jQ", live("_codex_workspace_symbols"), "Cangjie Workspace Symbols")
    map("n", "<localleader>jk", live("_codex_run_codelens"), "Run Cangjie CodeLens (Optional)")
    map("n", "<localleader>jK", live("_codex_refresh_codelens"), "Refresh Cangjie CodeLens (Optional)")
    map({ "i", "n" }, "<C-x><C-o>", live("_codex_show_completion_or_notify"), "Trigger Cangjie Completion")
    if cangjie_dot_completion_enabled() then
        map("i", ".", function()
            live("_codex_trigger_completion_after_dot")()
            return "."
        end, "Insert . and trigger completion", { expr = true })
    end
end

return {
    cmd = make_cmd(),
    filetypes = { "Cangjie" },
    root_dir = function(bufnr, on_dir)
        on_dir(resolve_root_dir(bufnr))
    end,
    capabilities = capabilities,
    before_init = configure_source_module_init,

    handlers = {
        ["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
            local client = ctx and ctx.client_id and vim.lsp.get_client_by_id(ctx.client_id) or nil
            if result and result.uri and should_suppress_warm_diagnostics(client, result.uri) then
                local stats = warm_stats(client)
                if stats then
                    stats.suppressed_warm_diagnostics = (stats.suppressed_warm_diagnostics or 0) + #(result.diagnostics or {})
                end
                clear_existing_diagnostics_for_uri(result.uri)
                schedule_cangjie_diagnostic_display_refresh("warm-diagnostics-suppressed")
                schedule_warm_progress_done(client, "settling diagnostics")
                schedule_explorer_refresh_for_uri(result.uri, "warm-diagnostics-suppressed")
                return
            end

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

            local ret = vim.lsp.diagnostic.on_publish_diagnostics(err, result, ctx, config)
            if result and result.uri then
                schedule_cangjie_diagnostic_display_refresh("diagnostics-publish")
                schedule_explorer_refresh_for_uri(result.uri, "diagnostics-publish")
            end
            return ret
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
            ensure_explorer_diagnostic_refresh_autocmd()
            setup_cangjie_inlay_hints(client, bufnr)
            vim.defer_fn(function()
                warm_current_package_sources(client, bufnr)
            end, vim.g.cangjie_lsp_warm_package_delay_ms or 300)
        end)
        vim.notify("Cangjie LSP start success", vim.log.levels.INFO)
    end,
    on_exit = function(code, signal, client_id)
        local client = vim.lsp.get_client_by_id(client_id)
        local reason = ("code=%s signal=%s"):format(tostring(code), tostring(signal))
        if client and client._cangjie_intentional_stop then
            return
        end
        vim.schedule(function()
            schedule_cangjie_lsp_restart(reason)
        end)
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
    _codex_manage_completion_docs = manage_cangjie_completion_docs,
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
    _codex_refresh_explorer = function(notify)
        refresh_open_snacks_explorers("manual", notify)
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
