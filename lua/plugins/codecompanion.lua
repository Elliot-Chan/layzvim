return {
    {
        "olimorris/codecompanion.nvim",
        dependencies = {
            "nvim-lua/plenary.nvim",
            "nvim-treesitter/nvim-treesitter",
        },
        keys = {
            { "<leader>aa", "<cmd>CodeCompanionChat Toggle<cr>", desc = "Toggle AI Chat" },
            { "<leader>aA", "<cmd>CodeCompanionChat Add<cr>", desc = "Add Selection to AI Chat", mode = { "v" } },
            { "<leader>as", "<cmd>CodeCompanionActions<cr>", desc = "AI Actions", mode = { "n", "v" } },
            { "<leader>ai", "<cmd>CodeCompanion<cr>", desc = "AI Inline", mode = { "n", "v" } },
        },
        opts = {
            adapters = {
                http = {
                    opts = {
                        show_presets = false,
                    },
                    glm5 = function()
                        return require("codecompanion.adapters").extend("openai_compatible", {
                            name = "glm5",
                            formatted_name = "GLM-5",
                            env = {
                                api_key = "ZAI_API_KEY",
                                url = function()
                                    return os.getenv("ZAI_BASE_URL") or "https://api.z.ai/api/coding/paas/v4"
                                end,
                                chat_url = "/chat/completions",
                                models_endpoint = "/models",
                            },
                            schema = {
                                model = {
                                    default = "GLM-5",
                                    choices = {
                                        "GLM-5",
                                        "GLM-5.1",
                                    },
                                },
                            },
                        })
                    end,
                },
            },
            interactions = {
                background = {
                    adapter = {
                        name = "glm5",
                        model = "GLM-5",
                    },
                },
                chat = {
                    adapter = {
                        name = "glm5",
                        model = "GLM-5",
                    },
                },
                inline = {
                    adapter = {
                        name = "glm5",
                        model = "GLM-5",
                    },
                },
                cmd = {
                    adapter = {
                        name = "glm5",
                        model = "GLM-5",
                    },
                },
            },
            opts = {
                language = "Chinese",
            },
        },
    },
}
