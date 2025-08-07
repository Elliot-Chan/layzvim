local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

return {
  "neovim/nvim-lspconfig",
  config = function()
    if not configs.cangjie_lsp then
      configs.cangjie_lsp = {
        default_config = {
          cmd = { "$CANGJIE_SDK_PATH/tools/bin/LSPServer" },
          root_dir = lspconfig.util.root_pattern(".git"),
          filetypes = { "Cangjie" },
          on_attach = function(client, bufnr)
            print("Cangjie LSP started")
          end,
          capabilities = vim.lsp.protocol.make_client_capabilities(),
        },
      }
    end
    lspconfig.cangjie_lsp.setup({})
  end,
}
