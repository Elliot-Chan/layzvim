return {
  "folke/noice.nvim",
  optional = true,
  opts = function(_, opts)
    opts = opts or {}
    opts.format = opts.format or {}
    opts.lsp = opts.lsp or {}
    opts.lsp.progress = opts.lsp.progress or {}

    local stage_hl = {
      prepare = "NoiceCangjieProgressPrepare",
      queue = "NoiceCangjieProgressQueue",
      index = "NoiceCangjieProgressIndex",
      settle = "NoiceCangjieProgressSettle",
      ready = "NoiceCangjieProgressReady",
    }

    local function setup_cangjie_progress_highlights()
      local links = {
        NoiceCangjieProgressPrepare = "DiagnosticInfo",
        NoiceCangjieProgressQueue = "DiagnosticInfo",
        NoiceCangjieProgressIndex = "DiagnosticWarn",
        NoiceCangjieProgressSettle = "DiagnosticHint",
        NoiceCangjieProgressReady = vim.fn.hlexists("DiagnosticOk") == 1 and "DiagnosticOk" or "DiagnosticHint",
      }

      for group, link in pairs(links) do
        vim.api.nvim_set_hl(0, group, { default = true, link = link })
      end
    end

    setup_cangjie_progress_highlights()
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("codex_cangjie_noice_progress", { clear = true }),
      callback = setup_cangjie_progress_highlights,
    })

    local ok, formatters = pcall(require, "noice.text.format.formatters")
    if ok then
      local noice_text = require("noice.text")

      local function cangjie_progress(input)
        local progress = input and input.opts and input.opts.progress
        if not progress or progress.title ~= "Cangjie source index" then
          return nil
        end
        return progress
      end

      formatters.cangjie_progress_stage = function(message, _, input)
        local progress = cangjie_progress(input)
        if not progress or not progress.stage then
          return
        end

        local label = progress.stage_label or progress.stage
        message:append((" %s "):format(label), stage_hl[progress.stage] or "NoiceFormatProgressDone")
      end

      formatters.cangjie_progress = function(message, format_opts, input)
        local progress = cangjie_progress(input)
        if not progress then
          return formatters.progress(message, format_opts, input)
        end

        local contents = require("noice.text.format").format(input, format_opts.contents, {
          debug = { enabled = false },
        })
        local value = progress.percentage
        if type(value) ~= "number" then
          message:append(contents)
          return
        end

        local width = math.max(format_opts.width or 20, contents:width() + 2)
        local done_length = math.floor(value / 100 * width + 0.5)
        local todo_length = width - done_length

        if format_opts.align == "left" then
          message:append(contents)
        end

        if width > contents:width() then
          message:append(string.rep(" ", width - contents:width()))
        end

        if format_opts.align ~= "left" then
          message:append(contents)
        end

        message:append(noice_text("", {
          hl_group = stage_hl[progress.stage] or format_opts.hl_group_done,
          hl_mode = "replace",
          relative = true,
          col = -width,
          length = done_length,
        }))
        message:append(noice_text("", {
          hl_group = format_opts.hl_group or "NoiceFormatProgressTodo",
          hl_mode = "replace",
          relative = true,
          col = -width + done_length,
          length = todo_length,
        }))
      end
    end

    opts.lsp.progress.format = {
      {
        "{cangjie_progress} ",
        key = "progress.percentage",
        contents = {
          { "{data.progress.message} " },
        },
        width = 20,
        align = "right",
        hl_group = "NoiceFormatProgressTodo",
        hl_group_done = "NoiceFormatProgressDone",
      },
      "({data.progress.percentage}%) ",
      { "{spinner} ", hl_group = "NoiceLspProgressSpinner" },
      { "{cangjie_progress_stage} " },
      { "{data.progress.title} ", hl_group = "NoiceLspProgressTitle" },
      { "{data.progress.client} ", hl_group = "NoiceLspProgressClient" },
    }
    opts.lsp.progress.format_done = {
      { "done ", hl_group = "NoiceCangjieProgressReady" },
      { "{cangjie_progress_stage} " },
      { "{data.progress.title} ", hl_group = "NoiceLspProgressTitle" },
      { "{data.progress.client} ", hl_group = "NoiceLspProgressClient" },
    }

    opts.lsp.signature = vim.tbl_deep_extend("force", opts.lsp.signature or {}, {
      enabled = false,
      auto_open = {
        enabled = false,
        trigger = false,
      },
    })
  end,
}
