local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

return {
  "neovim/nvim-lspconfig",
  config = function()
    local sdk_path = os.getenv("CANGJIE_SDK_PATH")
    if not sdk_path then
      vim.notify("CANGJIE_SDK_PATH 未设置，请先设置环境变量", vim.log.levels.ERROR)
      return
    end

    local capabilities = vim.lsp.protocol.make_client_capabilities()

    -- 注册自定义 LSP
    if not configs.cangjie_lsp then
      configs.cangjie_lsp = {
        default_config = {
          cmd = { sdk_path .. "/tools/bin/LSPServer", "--test" },
          -- 自动检测根目录，兼容 Git / 非 Git 项目
          root_dir = function(fname)
            return lspconfig.util.root_pattern(".git")(fname)
                or lspconfig.util.root_pattern("CMakeLists.txt", "Makefile")(fname)
                or vim.fn.getcwd()
          end,
          filetypes = { "Cangjie" },
          on_attach = function(client, bufnr)
            vim.notify("Cangjie LSP 已启动 (client id: " .. client.id .. ")", vim.log.levels.INFO)
          end,
          capabilities = vim.lsp.protocol.make_client_capabilities(),
        },
      }
    end

    -- 设置 LSP
    lspconfig.cangjie_lsp.setup({})

    -- 自动在打开 cangjie 文件时触发 LSP
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "Cangjie",
      callback = function()
        -- 确保 LSP 已经 setup
        local clients = vim.lsp.get_active_clients()
        if #clients == 0 then
          vim.notify("尝试启动 Cangjie LSP...", vim.log.levels.INFO)
        end
      end,
    })
  end,
}
