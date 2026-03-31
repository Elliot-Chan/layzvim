require("config.lazy")
require("config.commands")
vim.g.ai_cmp = false

_G.test_lsp_method = function(method)
    local bufnr = vim.api.nvim_get_current_buf()
    local clients = vim.lsp.get_clients({ bufnr = bufnr })

    if vim.tbl_isempty(clients) then
        print("No LSP client attached")
        return
    end

    for _, client in ipairs(clients) do
        local supports = client:supports_method(method)
        print(("client=%s id=%d method=%s supports=%s"):format(client.name, client.id, method, tostring(supports)))
    end

    local params
    if method:match("^textDocument/") then
        params = vim.lsp.util.make_position_params(0, "utf-16")
    elseif method == "workspace/symbol" then
        params = { query = vim.fn.expand("<cword>") }
    else
        print("No default params for method: " .. method)
        return
    end

    vim.lsp.buf_request(bufnr, method, params, function(err, result, ctx, _)
        print("---- response ----")
        print("client_id = " .. vim.inspect(ctx and ctx.client_id or nil))
        print("error     = " .. vim.inspect(err))
        print("result    = " .. vim.inspect(result))
    end)
end
