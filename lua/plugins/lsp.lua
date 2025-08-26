local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

return {
  "neovim/nvim-lspconfig",
  config = function()
    if not configs.cangjie_lsp then
      configs.cangjie_lsp = {
        default_config = {
          cmd = { "true" }, -- 占位，真正的 cmd 在 ftplugin 里设置
          filetypes = { "Cangjie" },
          on_attach = function(client, bufnr)
            vim.notify("Cangjie LSP 已启动 (client id: " .. client.id .. ")", vim.log.levels.INFO)
          end,
          root_dir = function(fname)
            return lspconfig.util.root_pattern(".git")(fname)
              or lspconfig.util.root_pattern("CMakeLists.txt", "Makefile")(fname)
              or vim.fn.getcwd()
          end,
        },
      }
    end
  end,
}
