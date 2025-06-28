---@diagnostic disable: undefined-global

local plugin = {}

plugin.config = {
    api_url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",

    -- Default prompt for improving text
    default_prompt = "Improve the following text for clarity, grammar, and style, while maintaining its original meaning and tone. Return only the improved text, without any conversational filler:",

    -- Maximum number of characters to send (Gemini has context limits)
    max_input_length = 30000,
}

-- Function to get the Gemini API key from environment variable
local function get_api_key()
    local api_key = vim.env.GEMINI_API_KEY
    if not api_key then
        vim.notify("Error: GEMINI_API_KEY environment variable not set. Please set it before using the plugin.",
                   vim.log.levels.ERROR)
        return nil
    end
    return api_key
end

-- Function to get the current buffer content
local function get_buffer_content()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local content = table.concat(lines, ' ')
    if #content == 0 then
        return nil
    end

    if #content > plugin.config.max_input_length then
        vim.notify(
            string.format("Warning: Text too long (%d chars). Truncating to %d characters.", #content, plugin.config.max_input_length),
            vim.log.levels.WARN
        )
        content = string.sub(content, 1, plugin.config.max_input_length)
    end
    return content
end

-- Function to get the visually selected text and its range
local function get_visual_selection()
    local start_mark = vim.api.nvim_buf_get_mark(0, "'<'")
    local end_mark = vim.api.nvim_buf_get_mark(0, "'>'")

    -- If mark is not set, line is 0
    if start_mark[1] == 0 then
        return nil
    end

    local start_line = start_mark[1]
    local end_line = end_mark[1]
    local start_col = start_mark[2]
    local end_col = end_mark[2]

    -- nvim_buf_get_text is 0-indexed for lines and columns.
    -- get_mark returns 1-based line and 0-based col.
    -- The end column for get_text is exclusive, but the mark is inclusive.
    local text_lines = vim.api.nvim_buf_get_text(0, start_line - 1, start_col, end_line - 1, end_col + 1, {})
    local selection = table.concat(text_lines, " ")

    if #selection == 0 then
        return nil
    end

    return {
        text = selection,
        start_line = start_line - 1,
        start_col = start_col,
        end_line = end_line - 1,
        end_col = end_col + 1
    }
end

-- Function to construct the Gemini API request payload
local function construct_payload(text_to_improve, prompt_instruction)
    return {
        contents = {
            {
                parts = {
                    { text = prompt_instruction .. " " .. text_to_improve }
                }
            }
        }
    }
end

-- Generic function to call Gemini API
local function call_gemini(text_to_improve, on_success_callback)
    local api_key = get_api_key()
    if not api_key then return end

    if not text_to_improve or #text_to_improve == 0 then
        vim.notify("No text to improve.", vim.log.levels.INFO)
        return
    end

    if #text_to_improve > plugin.config.max_input_length then
        vim.notify(
            string.format("Warning: Text too long (%d chars). Truncating to %d characters.", #text_to_improve, plugin.config.max_input_length),
            vim.log.levels.WARN
        )
        text_to_improve = string.sub(text_to_improve, 1, plugin.config.max_input_length)
    end

    vim.notify("Sending text to Gemini API... Please wait.", vim.log.levels.INFO)

    local prompt_instruction = plugin.config.default_prompt
    -- Check for a buffer-local variable for custom prompt
    if vim.b.gemini_prompt then
        prompt_instruction = vim.b.gemini_prompt
    end

    local payload = construct_payload(text_to_improve, prompt_instruction)
    local json_payload = vim.fn.json_encode(payload)

    local cmd = {
        "curl",
        "-s", -- Silent mode, don't show progress
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "--data-binary", "@-", -- Tell curl to read the body from stdin
        plugin.config.api_url .. "?key=" .. api_key
    }

    local stdout_data = {}
    local stderr_data = {}

    local stdin_pipe = vim.loop.new_pipe(false)
    local stdout_pipe = vim.loop.new_pipe(false)
    local stderr_pipe = vim.loop.new_pipe(false)

    local handle = vim.loop.spawn(cmd[1], {
        args = vim.list_slice(cmd, 2),
        stdio = {
            stdin_pipe,
            stdout_pipe,
            stderr_pipe
        }
    }, function(exit_code)

        local stdout_str = table.concat(stdout_data)
        local stderr_str = table.concat(stderr_data)

        if stdin_pipe then stdin_pipe:close() end
        if stdout_pipe then stdout_pipe:close() end
        if stderr_pipe then stderr_pipe:close() end

        vim.schedule(function()
            if exit_code ~= 0 then
                local error_msg = "Gemini API call failed with exit code " .. exit_code .. ". "
                if stderr_str ~= "" then
                    error_msg = error_msg .. "Stderr: " .. stderr_str
                end
                vim.notify(error_msg, vim.log.levels.ERROR)
                return
            end

            if stdout_str == "" then
                vim.notify("Gemini API returned an empty response.", vim.log.levels.WARN)
                return
            end

            local response_data
            local success, decoded_response = pcall(vim.fn.json_decode, stdout_str)
            if not success then
                vim.notify("Failed to decode JSON response from Gemini API: " .. decoded_response, vim.log.levels.ERROR)
                vim.notify("Raw response: " .. stdout_str, vim.log.levels.ERROR) -- Show raw response for debugging
                return
            end
            response_data = decoded_response

            local improved_text = ""
            if response_data and response_data.candidates and response_data.candidates[1]
               and response_data.candidates[1].content and response_data.candidates[1].content.parts
               and response_data.candidates[1].content.parts[1] and response_data.candidates[1].content.parts[1].text then
                improved_text = response_data.candidates[1].content.parts[1].text
            elseif response_data and response_data.error then
                vim.notify("Gemini API Error: " .. response_data.error.message, vim.log.levels.ERROR)
                return
            else
                vim.notify("Could not extract improved text from Gemini response. Unexpected format.", vim.log.levels.ERROR)
                vim.notify("Raw response: " .. stdout_str, vim.log.levels.ERROR)
                return
            end

            on_success_callback(improved_text)
        end) -- End of vim.schedule function
    end) -- End of vim.loop.spawn callback

    stdin_pipe:write(json_payload, function(err)
        if err then
            vim.notify("Error writing JSON payload to curl stdin: " .. err, vim.log.levels.ERROR)
        end
        -- Shut down the stdin pipe after writing to signal EOF to curl
        stdin_pipe:shutdown(function(shutdown_err)
            if shutdown_err then
                vim.notify("Error shutting down stdin pipe: " .. shutdown_err, vim.log.levels.WARN)
            end
        end)
    end)

    -- Start reading from the stdout pipe
    vim.loop.read_start(stdout_pipe, function(err, chunk)
        if err then
            vim.notify("Error reading stdout pipe: " .. err, vim.log.levels.ERROR)
            return
        end
        if chunk then
            table.insert(stdout_data, chunk)
        end
    end)

    -- Start reading from the stderr pipe
    vim.loop.read_start(stderr_pipe, function(err, chunk)
        if err then
            vim.notify("Error reading stderr pipe: " .. err, vim.log.levels.ERROR)
            return
        end
        if chunk then
            table.insert(stderr_data, chunk)
        end
    end)
end

-- Function to improve the whole buffer
local function improve_buffer()
    local original_content = get_buffer_content()
    if not original_content then
        vim.notify("Current buffer is empty or contains no text. Nothing to improve.", vim.log.levels.INFO)
        return
    end

    call_gemini(original_content, function(improved_text)
        -- Open new tab and write the result
        vim.cmd('tabnew')
        vim.api.nvim_buf_set_option(0, 'bufhidden', 'wipe') -- Allow closing without save prompt
        vim.api.nvim_buf_set_option(0, 'buftype', 'nofile') -- Don't associate with a file
        vim.api.nvim_buf_set_option(0, 'swapfile', false)
        vim.api.nvim_buf_set_option(0, 'modifiable', true) -- Make sure it's modifiable for writing
        vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(improved_text, ' '))
        vim.api.nvim_buf_set_option(0, 'modifiable', false) -- Make it read-only
        vim.api.nvim_buf_set_option(0, 'readonly', true)
        vim.api.nvim_buf_set_option(0, 'filetype', 'markdown') -- Suggest a filetype for highlighting

        vim.notify("Text improved and opened in a new tab!", vim.log.levels.INFO)
    end)
end

-- Function to improve the current selection
local function improve_selection()
    local selection_info = get_visual_selection()
    if not selection_info or #selection_info.text == 0 then
        vim.notify("No text selected or selection is empty.", vim.log.levels.INFO)
        return
    end

    call_gemini(selection_info.text, function(improved_text)
        local new_text_lines = vim.split(improved_text, ' ')
        vim.api.nvim_buf_set_text(0,
            selection_info.start_line,
            selection_info.start_col,
            selection_info.end_line,
            selection_info.end_col,
            new_text_lines)
        vim.notify("Selected text improved!", vim.log.levels.INFO)
    end)
end


-- Expose configuration function
function plugin.setup(opts)
    plugin.config = vim.tbl_deep_extend("force", plugin.config, opts or {})
end

-- Define Neovim Commands and Keymaps
function plugin.init()
    -- User Command: :GeminiImprove
    vim.api.nvim_create_user_command('GeminiImprove', function()
        improve_buffer()
    end, {
        desc = "Improve current buffer text using Google Gemini API"
    })

    -- User Command: :GeminiImproveSelection
    vim.api.nvim_create_user_command('GeminiImproveSelection', function()
        improve_selection()
    end, {
        range = '',
        desc = "Improve selected text using Google Gemini API"
    })

    -- User Command: :GeminiSetPrompt
    vim.api.nvim_create_user_command('GeminiSetPrompt', function(args)
        local new_prompt = table.concat(args.fargs, ' ')
        if new_prompt ~= '' then
            plugin.config.default_prompt = new_prompt
            vim.notify("Default Gemini prompt set to: " .. new_prompt, vim.log.levels.INFO)
        else
            vim.notify("Usage: :GeminiSetPrompt <your new prompt>", vim.log.levels.WARN)
        end
    end, {
        nargs = "+",
        desc = "Set the default prompt for Gemini API text improvement"
    })

    -- User Command: :GeminiSetBufferPrompt
    vim.api.nvim_create_user_command('GeminiSetBufferPrompt', function(args)
        local new_prompt = table.concat(args.fargs, ' ')
        if new_prompt ~= '' then
            vim.b.gemini_prompt = new_prompt
            vim.notify("Buffer-local Gemini prompt set to: " .. new_prompt, vim.log.levels.INFO)
        else
            vim.notify("Usage: :GeminiSetBufferPrompt <your new prompt>", vim.log.levels.WARN)
        end
    end, {
        nargs = "+",
        desc = "Set a buffer-local prompt for Gemini API text improvement"
    })

    -- User Command: :GeminiDisplayPrompt
    vim.api.nvim_create_user_command('GeminiDisplayPrompt', function()
        local current_prompt
        if vim.b.gemini_prompt then
            current_prompt = vim.b.gemini_prompt
            vim.notify("Current buffer-local Gemini prompt: " .. current_prompt, vim.log.levels.INFO)
        else
            current_prompt = plugin.config.default_prompt
            vim.notify("Current default Gemini prompt: " .. current_prompt, vim.log.levels.INFO)
        end
    end, {
        desc = "Display the current Gemini prompt (buffer-local or default)"
    })

    -- Keymap: <leader>gi (Gemini Improve)
    vim.keymap.set('n', '<leader>gi', ':GeminiImprove<CR>', {
        noremap = true,
        silent = true,
        desc = "Improve text with Gemini"
    })

    -- Keymap: <leader>gi (Gemini Improve Selection)
    vim.keymap.set('v', '<leader>gs', ':GeminiImproveSelection', {
        noremap = true,
        silent = true,
        desc = "Improve selected text with Gemini"
    })

    -- Keymap: <leader>gd (Gemini Display Prompt)
    vim.keymap.set('n', '<leader>gd', ':GeminiDisplayPrompt', {
        noremap = true,
        silent = true,
        desc = "Show current prompt"
    })
end

-- Initialize the plugin on load
plugin.init()

return plugin
