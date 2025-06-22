# gemini_nvim

A Neovim plugin for interacting with the Google Gemini API to improve text directly within your editor.

## Features

-   **Improve Text**: Send the current buffer's content to the Gemini API for improvements in clarity, grammar, and style.
-   **Custom Prompts**: Set a default global prompt or a buffer-local prompt to guide Gemini's text improvement.
-   **Display Prompt**: Easily view the currently active prompt (buffer-local or default).
-   **New Tab Output**: Improved text is displayed in a new, read-only Neovim tab.

## Installation

Install `gemini_nvim` using [lazy.nvim](https://github.com/folke/lazy.nvim):

```
  {
    "fossmo/gemini_nvim",
    name   = "gemini_nvim",
    config = function()  
        require("gemini_nvim").setup({
            default_prompt = "Improve the following text for clarity, grammar, and style, while maintaining its original meaning and tone. Return only the improved text, without any conversational filler:",
        })
    end,
    cmd = {"GeminiImprove", "GeminiSetPrompt", "GeminiSetBufferPrompt"},
    keys = {{"<leader>gi", desc = "Improve text with Gemini"}},
  },
```

Remember to restart your shell or source the configuration file after setting the variable.

## Usage

### Commands

-   `:GeminiImprove`
    Sends the content of the current buffer to the Gemini API for improvement. The result will open in a new read-only tab.

-   `:GeminiSetPrompt <your new prompt>`
    Sets a new default prompt that will be used for all subsequent `:GeminiImprove` calls, unless overridden by a buffer-local prompt.

    Example: `:GeminiSetPrompt Summarize the following text in 100 words:`

-   `:GeminiSetBufferPrompt <your new prompt>`
    Sets a prompt specifically for the current buffer. This prompt will take precedence over the default prompt for this buffer.

    Example: `:GeminiSetBufferPrompt Translate this to French:`

-   `:GeminiDisplayPrompt`
    Displays the currently active prompt. It will show the buffer-local prompt if set, otherwise it will show the default global prompt.

### Keymaps

The plugin sets the following default keymaps (if you use the `keys` table in your Lazy.nvim config as shown above):

-   `<leader>gi`: Calls `:GeminiImprove` to improve the current buffer's text.
-   `<leader>gd`: Calls `:GeminiDisplayPrompt` to show the current prompt.

