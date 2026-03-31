-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
--
vim.opt.title = true
vim.opt.titlestring = "%F - nvim"
vim.g.autoformat = true

-- Cangjie defaults:
-- - Prefer native LSP inlay hints when available; otherwise fall back to local pseudo hints.
-- - Keep pseudo type hints enabled, but default them to hover-first mode to avoid heavy local guessing.
-- - Keep pseudo parameter hints off by default because they are the noisiest and most cursor-sensitive.
-- - Hide hints in insert mode and debounce refreshes to reduce editing latency.
-- - Keep local auto features enabled, but allow one-shot shutdown via :CangjieLocalAuto.
vim.g.cangjie_inlay_hints = true
vim.g.cangjie_inlay_hints_hide_in_insert = true
vim.g.cangjie_local_auto_features = true
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
