-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
--
vim.opt.title = true
vim.opt.titlestring = "%F - nvim"
vim.g.autoformat = true

-- Cangjie defaults:
-- - Use local pseudo inlay hints by default because the Cangjie server's native inlay capability is unreliable.
-- - Keep pseudo type hints enabled, but default them to hover-first mode to avoid heavy local guessing.
-- - Keep pseudo parameter hints off by default because they are the noisiest and most cursor-sensitive.
-- - Hide hints in insert mode and debounce refreshes to reduce editing latency.
-- - Keep post-insert local refreshes enabled, but disable insert-mode dot completion and completion-doc augmentation by default.
vim.g.cangjie_inlay_hints = true
vim.g.cangjie_inlay_hints_hide_in_insert = true
vim.g.cangjie_native_inlay_hints = false
vim.g.cangjie_local_auto_features = true
vim.g.cangjie_format_scope = "changed"
vim.g.cangjie_completion_debug = false
vim.g.cangjie_completion_docs = false
vim.g.cangjie_manual_completion_docs = true
vim.g.cangjie_dot_completion = false
vim.g.cangjie_pseudo_inlay_hints = true
vim.g.cangjie_pseudo_inlay_hints_hide_in_insert = true
vim.g.cangjie_pseudo_inlay_hints_types = true
vim.g.cangjie_pseudo_inlay_hints_parameters = false
vim.g.cangjie_pseudo_inlay_hints_expression_parts = false
vim.g.cangjie_pseudo_inlay_hints_type_mode = "hover"
vim.g.cangjie_pseudo_inlay_hints_delay_ms = 150
vim.g.cangjie_pseudo_inlay_hints_cursor_delay_ms = 500
vim.g.cangjie_pseudo_inlay_hints_parameter_mode = "nested"
--vim.g.cangjie_doc_index = "/home/elliot/Code/docs/output/std_api_zh/docs-index.json"
vim.g.cangjie_doc_sources = {
    dev = {
        urls = {
            "https://955work.icu/dev/std/docs-index.json",
            "https://955work.icu/dev/stdx/docs-index.json",
        },
    },
    nightly = {
        urls = {
            "https://955work.icu/nightly/std/docs-index.json",
            "https://955work.icu/nightly/stdx/docs-index.json",
        },
    },
}
vim.g.cangjie_doc_source = "dev"

-- Shared Cangjie large-file / large-repo performance mode.
vim.g.cangjie_perf_mode = vim.g.cangjie_perf_mode or "auto"
vim.g.cangjie_perf_large_file_bytes = vim.g.cangjie_perf_large_file_bytes or (1024 * 1024)
vim.g.cangjie_perf_large_file_lines = vim.g.cangjie_perf_large_file_lines or 8000
vim.g.cangjie_perf_lsp_auto_start = vim.g.cangjie_perf_lsp_auto_start or false
vim.g.cangjie_perf_treesitter_auto_start = vim.g.cangjie_perf_treesitter_auto_start or false
vim.g.cangjie_lsp_debug = vim.g.cangjie_lsp_debug or false
vim.g.cangjie_lsp_source_roots = vim.g.cangjie_lsp_source_roots or {}
if vim.g.cangjie_lsp_warm_package_files == nil then
    vim.g.cangjie_lsp_warm_package_files = true
end
vim.g.cangjie_lsp_warm_package_max_files = vim.g.cangjie_lsp_warm_package_max_files or 80
vim.g.cangjie_lsp_warm_package_max_file_bytes = vim.g.cangjie_lsp_warm_package_max_file_bytes or (512 * 1024)
vim.g.cangjie_lsp_warm_package_delay_ms = vim.g.cangjie_lsp_warm_package_delay_ms or 300
vim.g.cangjie_lsp_warm_import_max_dirs = vim.g.cangjie_lsp_warm_import_max_dirs or 8
vim.g.cangjie_lsp_warm_import_max_files = vim.g.cangjie_lsp_warm_import_max_files or 40
vim.g.cangjie_lsp_warm_import_scan_lines = vim.g.cangjie_lsp_warm_import_scan_lines or 200
vim.g.cangjie_lsp_warm_batch_size = vim.g.cangjie_lsp_warm_batch_size or 5
vim.g.cangjie_lsp_warm_batch_delay_ms = vim.g.cangjie_lsp_warm_batch_delay_ms or 75
vim.g.cangjie_lsp_warm_on_demand = vim.g.cangjie_lsp_warm_on_demand ~= false
vim.g.cangjie_lsp_warm_progress = vim.g.cangjie_lsp_warm_progress ~= false
vim.g.cangjie_lsp_warm_progress_width = vim.g.cangjie_lsp_warm_progress_width or 20
vim.g.cangjie_lsp_warm_progress_style = vim.g.cangjie_lsp_warm_progress_style or "blocks"
vim.g.cangjie_lsp_warm_progress_backend = vim.g.cangjie_lsp_warm_progress_backend or "lsp"
vim.g.cangjie_lsp_warm_progress_min_interval_ms = vim.g.cangjie_lsp_warm_progress_min_interval_ms or 200
vim.g.cangjie_lsp_warm_diagnostics_settle_ms = vim.g.cangjie_lsp_warm_diagnostics_settle_ms or 1200
vim.g.cangjie_lsp_explorer_refresh = vim.g.cangjie_lsp_explorer_refresh ~= false
vim.g.cangjie_lsp_explorer_refresh_delay_ms = vim.g.cangjie_lsp_explorer_refresh_delay_ms or 450

_G.CangjiePerf = _G.CangjiePerf or {}

local cangjie_perf = _G.CangjiePerf

cangjie_perf.known_roots = cangjie_perf.known_roots or {
    cangjie_runtime = true,
    cangjie_stdx = true,
    cangjie_tools = true,
    cangjie_test = true,
    cangjie_test_framework = true,
    cangjie_sdk = true,
}

cangjie_perf.ignore = cangjie_perf.ignore or {
    "build",
    "build-*",
    "output",
    "outputs",
    "out",
    "target",
    ".git",
    ".cache",
    "generated",
    "third_party",
    "cangjie_sdk",
    "cangjie_sdk_*",
    "runtime/lib",
    "tools/bin",
}

local function cangjie_perf_start_dir(path)
    if type(path) ~= "string" or path == "" then
        return vim.fn.getcwd()
    end
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "directory" then
        return path
    end
    return vim.fs.dirname(path) or vim.fn.getcwd()
end

local function cangjie_perf_normalize(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function cangjie_perf_is_under(root, path)
    root = cangjie_perf_normalize(root)
    path = cangjie_perf_normalize(path)
    if not root or not path then
        return false
    end
    return path == root or vim.startswith(path, root .. "/")
end

local function cangjie_perf_read_cjpm_package(root)
    local path = root and vim.fs.joinpath(root, "cjpm.toml") or nil
    if not path or vim.fn.filereadable(path) ~= 1 then
        return nil
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or type(lines) ~= "table" then
        return nil
    end

    local in_package = false
    local package = {}
    for _, line in ipairs(lines) do
        local section = line:match("^%s*%[([^%]]+)%]")
        if section then
            in_package = section == "package"
        elseif in_package then
            local key, value = line:match("^%s*([%w%-]+)%s*=%s*\"([^\"]*)\"")
            if key and value then
                package[key] = value
            end
        end
    end
    return package
end

local function cangjie_perf_explicit_source_module(path)
    for _, entry in ipairs(vim.g.cangjie_lsp_source_roots or {}) do
        if type(entry) == "table" and type(entry.name) == "string" then
            local src_path = cangjie_perf_normalize(entry.src_path or entry.root)
            local root = cangjie_perf_normalize(entry.root or src_path)
            if src_path and (cangjie_perf_is_under(src_path, path) or cangjie_perf_is_under(root, path)) then
                return {
                    name = entry.name,
                    root = root or src_path,
                    src_path = src_path,
                    kind = entry.kind or entry.name,
                    explicit = true,
                }
            end
        end
    end
end

local function cangjie_perf_std_source_module(path)
    local dir = cangjie_perf_start_dir(path)
    while dir and dir ~= "" do
        local parent = vim.fs.dirname(dir)
        local grandparent = parent and vim.fs.dirname(parent) or nil
        if vim.fs.basename(dir) == "std" and parent and grandparent
            and vim.fs.basename(parent) == "libs"
            and vim.fs.basename(grandparent) == "stdlib"
        then
            return {
                name = "std",
                root = dir,
                src_path = dir,
                kind = "std",
            }
        end
        local next_dir = vim.fs.dirname(dir)
        if not next_dir or next_dir == dir then
            break
        end
        dir = next_dir
    end
end

local function cangjie_perf_stdx_source_module(path)
    local dir = cangjie_perf_start_dir(path)

    if vim.fn.filereadable(vim.fs.joinpath(dir, "cjpm.toml")) == 1 then
        local package = cangjie_perf_read_cjpm_package(dir)
        if package and package.name == "stdx" and package["src-dir"] then
            local src_path = cangjie_perf_normalize(vim.fs.joinpath(dir, package["src-dir"]))
            if src_path and vim.fn.isdirectory(src_path) == 1 then
                return {
                    name = "stdx",
                    root = dir,
                    src_path = src_path,
                    kind = "stdx",
                }
            end
        end
    end

    while dir and dir ~= "" do
        local parent = vim.fs.dirname(dir)
        if vim.fs.basename(dir) == "stdx" and parent and vim.fs.basename(parent) == "src" then
            local cjpm = vim.fs.find("cjpm.toml", { path = parent, upward = true })[1]
            if cjpm then
                local root = vim.fs.dirname(cjpm)
                local package = cangjie_perf_read_cjpm_package(root)
                local package_src = package and package["src-dir"] or nil
                local src_path = cangjie_perf_normalize(package_src and vim.fs.joinpath(root, package_src) or dir)
                if package and package.name == "stdx" and src_path == cangjie_perf_normalize(dir) then
                    return {
                        name = "stdx",
                        root = root,
                        src_path = src_path,
                        kind = "stdx",
                    }
                end
            end
            return {
                name = "stdx",
                root = dir,
                src_path = dir,
                kind = "stdx",
            }
        end
        local next_dir = vim.fs.dirname(dir)
        if not next_dir or next_dir == dir then
            break
        end
        dir = next_dir
    end
end

function cangjie_perf.source_module(path)
    local file = type(path) == "number" and vim.api.nvim_buf_get_name(path) or path
    return cangjie_perf_explicit_source_module(file)
        or cangjie_perf_std_source_module(file)
        or cangjie_perf_stdx_source_module(file)
end

function cangjie_perf.find_known_root(path)
    local dir = cangjie_perf_start_dir(path)
    while dir and dir ~= "" do
        if cangjie_perf.known_roots[vim.fs.basename(dir)] then
            return dir
        end
        local parent = vim.fs.dirname(dir)
        if not parent or parent == dir then
            break
        end
        dir = parent
    end
end

function cangjie_perf.root_dir(path)
    local file = type(path) == "number" and vim.api.nvim_buf_get_name(path) or path
    local dir = cangjie_perf_start_dir(file)
    local source_module = cangjie_perf.source_module(file)
    if source_module and source_module.root then
        return source_module.root
    end
    local cjpm = vim.fs.find("cjpm.toml", { path = dir, upward = true })[1]
    if cjpm then
        return vim.fs.dirname(cjpm)
    end
    local git = vim.fs.find(".git", { path = dir, upward = true })[1]
    if git then
        return vim.fs.dirname(git)
    end
    return cangjie_perf.find_known_root(dir) or dir or vim.fn.getcwd()
end

function cangjie_perf.detect(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local reasons = {}
    local file = vim.api.nvim_buf_get_name(bufnr)
    local root = cangjie_perf.root_dir(file ~= "" and file or bufnr)

    local stat = file ~= "" and vim.uv.fs_stat(file) or nil
    if stat and stat.size and stat.size >= vim.g.cangjie_perf_large_file_bytes then
        reasons[#reasons + 1] = ("file:%dB"):format(stat.size)
    end

    local ok_lines, line_count = pcall(vim.api.nvim_buf_line_count, bufnr)
    if ok_lines and line_count >= vim.g.cangjie_perf_large_file_lines then
        reasons[#reasons + 1] = ("lines:%d"):format(line_count)
    end

    if root and cangjie_perf.known_roots[vim.fs.basename(root)] then
        reasons[#reasons + 1] = "repo:" .. vim.fs.basename(root)
    end
    local source_module = cangjie_perf.source_module(file ~= "" and file or root)
    if source_module then
        reasons[#reasons + 1] = "source:" .. source_module.name
    end

    return {
        active = #reasons > 0,
        reasons = reasons,
        root = root,
        file = file,
        source_module = source_module,
    }
end

function cangjie_perf.refresh(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local mode = vim.g.cangjie_perf_mode or "auto"
    local detected = cangjie_perf.detect(bufnr)
    local active = mode == "on" or (mode == "auto" and detected.active)

    vim.b[bufnr].cangjie_perf_mode_active = active
    vim.b[bufnr].cangjie_perf_mode = mode
    vim.b[bufnr].cangjie_perf_reasons = detected.reasons
    vim.b[bufnr].cangjie_perf_root = detected.root
    vim.b[bufnr].cangjie_source_module_name = detected.source_module and detected.source_module.name or nil
    vim.b[bufnr].cangjie_source_module_root = detected.source_module and detected.source_module.root or nil
    vim.b[bufnr].cangjie_source_module_src_path = detected.source_module and detected.source_module.src_path or nil
    return active, detected
end

function cangjie_perf.enabled(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if vim.b[bufnr].cangjie_perf_mode_active == nil then
        return cangjie_perf.refresh(bufnr)
    end
    return vim.b[bufnr].cangjie_perf_mode_active == true
end

function cangjie_perf.status(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local active = cangjie_perf.refresh(bufnr)
    local reasons = vim.b[bufnr].cangjie_perf_reasons or {}
    return table.concat({
        ("mode=%s"):format(vim.g.cangjie_perf_mode or "auto"),
        ("active=%s"):format(active and "on" or "off"),
        ("root=%s"):format(vim.b[bufnr].cangjie_perf_root or "nil"),
        ("source=%s"):format(vim.b[bufnr].cangjie_source_module_name or "nil"),
        ("src_path=%s"):format(vim.b[bufnr].cangjie_source_module_src_path or "nil"),
        ("reasons=%s"):format(#reasons > 0 and table.concat(reasons, ",") or "none"),
    }, "\n")
end

function cangjie_perf.set_mode(mode)
    if mode == "toggle" then
        mode = cangjie_perf.enabled(0) and "off" or "on"
    end
    if mode ~= "auto" and mode ~= "on" and mode ~= "off" then
        vim.notify("Usage: :CangjiePerfMode [auto|on|off|toggle|status]", vim.log.levels.WARN, { title = "Cangjie Perf" })
        return
    end
    vim.g.cangjie_perf_mode = mode
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "Cangjie" then
            cangjie_perf.refresh(bufnr)
        end
    end
    vim.notify(cangjie_perf.status(0), vim.log.levels.INFO, { title = "Cangjie Perf" })
end

vim.api.nvim_create_user_command("CangjiePerfMode", function(opts)
    local action = opts.args ~= "" and opts.args or "status"
    if action == "status" then
        vim.notify(cangjie_perf.status(0), vim.log.levels.INFO, { title = "Cangjie Perf" })
        return
    end
    cangjie_perf.set_mode(action)
end, {
    desc = "Show or switch Cangjie large-file performance mode",
    force = true,
    nargs = "?",
    complete = function()
        return { "status", "auto", "on", "off", "toggle" }
    end,
})
