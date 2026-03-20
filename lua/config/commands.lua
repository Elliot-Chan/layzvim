local api = vim.api

api.nvim_create_user_command("FormatInfo", function()
    local ok, conform = pcall(require, "conform")
    if not ok then
        vim.notify("conform.nvim is not available", vim.log.levels.WARN)
        return
    end

    local filetype = vim.bo.filetype
    local formatters, lsp_fallback = conform.list_formatters_to_run(0)
    local parts = {}

    for _, formatter in ipairs(formatters) do
        local name = formatter.name or formatter.id or vim.inspect(formatter)
        local available = formatter.available
        if available == nil then
            table.insert(parts, name)
        else
            table.insert(parts, string.format("%s[%s]", name, available and "ready" or "missing"))
        end
    end

    if #parts == 0 then
        table.insert(parts, "none")
    end

    vim.notify(
        string.format("filetype=%s auto_format=%s lsp_fallback=%s formatters=%s", filetype, tostring(vim.g.auto_format ~= false), tostring(lsp_fallback), table.concat(parts, ", ")),
        vim.log.levels.INFO
    )
end, { desc = "Show formatter info for current buffer" })

api.nvim_create_user_command("LspInfoLite", function()
    local clients = vim.lsp.get_clients({ bufnr = 0 })
    local names = {}

    for _, client in ipairs(clients) do
        table.insert(names, client.name)
    end

    if #names == 0 then
        table.insert(names, "none")
    end

    vim.notify(
        string.format(
            "buf=%d filetype=%s diagnostics=%s clients=%s",
            vim.api.nvim_get_current_buf(),
            vim.bo.filetype,
            tostring(vim.diagnostic.is_enabled({ bufnr = 0 })),
            table.concat(names, ", ")
        ),
        vim.log.levels.INFO
    )
end, { desc = "Show lightweight LSP info" })

api.nvim_create_user_command("ToggleDiagnostics", function()
    local enabled = vim.diagnostic.is_enabled({ bufnr = 0 })
    vim.diagnostic.enable(not enabled, { bufnr = 0 })
    vim.notify("Diagnostics: " .. (enabled and "off" or "on"))
end, { desc = "Toggle diagnostics for current buffer" })

api.nvim_create_user_command("CangjieFormat", function()
    if vim.bo.filetype ~= "Cangjie" then
        vim.notify("Current buffer is not Cangjie", vim.log.levels.WARN)
        return
    end

    local ok, conform = pcall(require, "conform")
    if not ok then
        vim.notify("conform.nvim is not available", vim.log.levels.WARN)
        return
    end

    conform.format({ async = false, lsp_format = "fallback" })
end, { desc = "Format current Cangjie buffer" })

api.nvim_create_user_command("CangjieDocs", function()
    require("cangjie_docs_index").select_symbol()
end, { desc = "Search Cangjie docs index" })

api.nvim_create_user_command("CangjieDocsSync", function(opts)
    local docs = require("cangjie_docs_index")
    vim.notify("Cangjie docs sync started", vim.log.levels.INFO, { title = "Cangjie Docs" })
    docs.sync_index({
        url = opts.args ~= "" and opts.args or nil,
    }, function(ok, result)
        if ok then
            vim.notify("Synced Cangjie docs index: " .. result, vim.log.levels.INFO, { title = "Cangjie Docs" })
        else
            vim.notify("Cangjie docs sync failed: " .. result, vim.log.levels.ERROR, { title = "Cangjie Docs" })
        end
    end)
end, {
    desc = "Sync Cangjie docs index from remote URL into local cache",
    nargs = "?",
})

api.nvim_create_user_command("CangjieLspInfo", function()
    local clients = vim.lsp.get_clients({ bufnr = 0, name = "cangjie_lsp" })
    if #clients == 0 then
        vim.notify("Current buffer has no cangjie_lsp client", vim.log.levels.WARN, { title = "Cangjie" })
        return
    end

    local client = clients[1]
    local workspace = {}

    for _, folder in ipairs(client.workspace_folders or {}) do
        table.insert(workspace, folder.name or folder.uri or vim.inspect(folder))
    end

    if #workspace == 0 then
        workspace = { "none" }
    end

    vim.notify(
        table.concat({
            ("buf=%d"):format(vim.api.nvim_get_current_buf()),
            ("file=%s"):format(vim.api.nvim_buf_get_name(0)),
            ("filetype=%s"):format(vim.bo.filetype),
            ("root=%s"):format(client.config.root_dir or "nil"),
            ("workspace=%s"):format(table.concat(workspace, ", ")),
        }, "\n"),
        vim.log.levels.INFO,
        { title = "Cangjie LSP" }
    )
end, { desc = "Show current Cangjie LSP root/workspace info" })

api.nvim_create_user_command("CangjieDocsInfo", function()
    local docs = require("cangjie_docs_index")
    vim.notify(
        table.concat({
            ("index=%s"):format(docs.index_path()),
            ("source_url=%s"):format(docs.index_source_url() or "nil"),
            ("debug=%s"):format(docs.debug_enabled() and "on" or "off"),
        }, "\n"),
        vim.log.levels.INFO,
        { title = "Cangjie Docs" }
    )
end, { desc = "Show Cangjie docs index path/source info" })

api.nvim_create_user_command("CangjieDocsDebug", function(opts)
    local docs = require("cangjie_docs_index")
    local arg = (opts.args or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if arg == "" or arg == "toggle" then
        docs.set_debug(not docs.debug_enabled())
    elseif arg == "on" then
        docs.set_debug(true)
    elseif arg == "off" then
        docs.set_debug(false)
    else
        vim.notify("Usage: :CangjieDocsDebug [toggle|on|off]", vim.log.levels.WARN, { title = "Cangjie Docs" })
        return
    end

    vim.notify(("Cangjie docs debug: %s (%s)"):format(docs.debug_enabled() and "on" or "off", docs.debug_log_path()), vim.log.levels.INFO, { title = "Cangjie Docs" })
end, {
    desc = "Toggle Cangjie docs debug logging",
    nargs = "?",
    complete = function()
        return { "toggle", "on", "off" }
    end,
})

api.nvim_create_user_command("CangjieDocsDebugClear", function()
    local docs = require("cangjie_docs_index")
    docs.clear_debug_log()
    vim.notify("Cleared " .. docs.debug_log_path(), vim.log.levels.INFO, { title = "Cangjie Docs" })
end, { desc = "Clear Cangjie docs debug log" })

api.nvim_create_user_command("CangjieDocsDebugLog", function()
    local docs = require("cangjie_docs_index")
    local text = docs.read_debug_log()
    if text == "" then
        vim.notify("Cangjie docs debug log is empty", vim.log.levels.INFO, { title = "Cangjie Docs" })
        return
    end
    vim.notify(text, vim.log.levels.INFO, { title = "Cangjie Docs Log" })
end, { desc = "Show Cangjie docs debug log" })

api.nvim_create_user_command("CangjieDocsDebugInfo", function()
    local cfg = assert(dofile(vim.fn.stdpath("config") .. "/lsp/cangjie_lsp.lua"))
    cfg._codex_debug_snapshot()
end, { desc = "Show Cangjie docs debug snapshot" })

api.nvim_create_user_command("CangjieDocsCheck", function(opts)
    local docs = require("cangjie_docs_index")
    local limit = tonumber(opts.args)
    local report = docs.compare_hover_cases(
        docs.synthetic_hover_cases({
            limit = limit,
        }),
        {
            failures_only = true,
        }
    )

    local lines = {
        ("total=%d"):format(report.total),
        ("passed=%d"):format(report.passed),
        ("failed=%d"):format(report.failed),
    }

    for i, failure in ipairs(report.results or {}) do
        if i > 10 then
            table.insert(lines, ("... %d more failures"):format(#report.results - 10))
            break
        end
        table.insert(lines, "")
        table.insert(lines, ("[%d] %s"):format(i, failure.name or "?"))
        table.insert(lines, ("expected=%s"):format(failure.expected or "nil"))
        table.insert(lines, ("actual=%s"):format(failure.actual or "nil"))
        table.insert(
            lines,
            ("parsed=%s / %s / %s / %s"):format(
                failure.debug and failure.debug.module_name or "nil",
                failure.debug and failure.debug.container_name or "nil",
                failure.debug and failure.debug.member_name or "nil",
                failure.debug and failure.debug.member_kind or "nil"
            )
        )
    end

    vim.notify(table.concat(lines, "\n"), report.failed == 0 and vim.log.levels.INFO or vim.log.levels.WARN, {
        title = "Cangjie Docs Check",
    })
end, {
    desc = "Run synthetic hover/docs resolution checks",
    nargs = "?",
})
