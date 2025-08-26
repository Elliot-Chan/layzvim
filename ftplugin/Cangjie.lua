local lspconfig = require("lspconfig")

local sdk_path = os.getenv("CANGJIE_SDK_PATH")
if not sdk_path then
  vim.notify("CANGJIE_SDK_PATH 未设置，请先设置环境变量", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_autocmd({ "VimEnter", "BufWinEnter" }, {
  callback = function(args)
    if vim.bo[args.buf].filetype == "Cangjie" then
      -- 强制重新设置文件类型来触发 LSP
      vim.bo[args.buf].filetype = "Cangjie"
    end
  end,
})
lspconfig.cangjie_lsp.setup({
  cmd = { sdk_path .. "/tools/bin/LSPServer", "--test" },
  on_attach = function(client, bufnr)
    vim.notify("Cangjie LSP 已启动 (client id: " .. client.id .. ")", vim.log.levels.INFO)
  end,
})
