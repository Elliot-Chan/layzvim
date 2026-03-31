return {
  "folke/noice.nvim",
  optional = true,
  opts = function(_, opts)
    opts = opts or {}
    opts.lsp = opts.lsp or {}
    opts.lsp.signature = vim.tbl_deep_extend("force", opts.lsp.signature or {}, {
      enabled = false,
      auto_open = {
        enabled = false,
        trigger = false,
      },
    })
  end,
}
