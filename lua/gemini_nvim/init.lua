local M = {}

M.config = {
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
    local content = table.concat(lines, '\n')
    if #content == 0 then
        return nil 
    end

    if #content > M.config.max_input_length then
        vim.notify(
            string.format("Warning: Text too long (%d chars). Truncating to %d characters.", #content, M.config.max_input_length),
            vim.log.levels.WARN
        )
        content = string.sub(content, 1, M.config.max_input_length)
    end
    return content
end

-- Function to construct the Gemini API request payload
local function construct_payload(text_to_improve, prompt_instruction)
    return {
        contents = {
            {
                parts = {
                    { text = prompt_instruction .. "\n\n" .. text_to_improve }
                }
            }
        }
    }
end

-- Main function to call Gemini API
local function call_gemini_api()
    local api_key = get_api_key()
    if not api_key then return end

    local original_content = get_buffer_content()
    if not original_content or #original_content == 0 then
        vim.notify("Current buffer is empty or contains no text. Nothing to improve.", vim.log.levels.INFO)
        return
    end

    vim.notify("Sending text to Gemini API... Please wait.", vim.log.levels.INFO)

    local prompt_instruction = M.config.default_prompt
    -- Check for a buffer-local variable for custom prompt
    if vim.b.gemini_prompt then
        prompt_instruction = vim.b.gemini_prompt
    end

    local payload = construct_payload(original_content, prompt_instruction)
    local json_payload = vim.fn.json_encode(payload)

    local cmd = {
        "curl",
        "-s", -- Silent mode, don't show progress
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "--data-binary", "@-", -- Tell curl to read the body from stdin
        M.config.api_url .. "?key=" .. api_key
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
                local error_msg = "Gemini API call failed with exit code " .. exit_code .. ".\n"
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

            -- Open new tab and write the result
            vim.cmd('tabnew')
            vim.api.nvim_buf_set_option(0, 'bufhidden', 'wipe') -- Allow closing without save prompt
            vim.api.nvim_buf_set_option(0, 'buftype', 'nofile') -- Don't associate with a file
            vim.api.nvim_buf_set_option(0, 'swapfile', false)
            vim.api.nvim_buf_set_option(0, 'modifiable', true) -- Make sure it's modifiable for writing
            vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(improved_text, '\n'))
            vim.api.nvim_buf_set_option(0, 'modifiable', false) -- Make it read-only
            vim.api.nvim_buf_set_option(0, 'readonly', true)
            vim.api.nvim_buf_set_option(0, 'filetype', 'markdown') -- Suggest a filetype for highlighting

            vim.notify("Text improved and opened in a new tab!", vim.log.levels.INFO)
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

-- Expose configuration function
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

-- Define Neovim Commands and Keymaps
function M.init()
    -- User Command: :GeminiImprove
    vim.api.nvim_create_user_command('GeminiImprove', function()
        call_gemini_api()
    end, {
        desc = "Improve current buffer text using Google Gemini API"
    })

    -- User Command: :GeminiSetPrompt
    vim.api.nvim_create_user_command('GeminiSetPrompt', function(args)
        local new_prompt = table.concat(args.fargs, ' ')
        if new_prompt ~= '' then
            M.config.default_prompt = new_prompt
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
            vim.notify("Current buffer-local Gemini prompt:\n" .. current_prompt, vim.log.levels.INFO)
        else
            current_prompt = M.config.default_prompt
            vim.notify("Current default Gemini prompt:\n" .. current_prompt, vim.log.levels.INFO)
        end
    end, {
        desc = "Display the current Gemini prompt (buffer-local or default)"
    })

    -- Keymap: <leader>gip (Gemini Improve)
    vim.keymap.set('n', '<leader>i', ':GeminiImprove<CR>', {
        noremap = true,
        silent = true,
        desc = "Improve text with Gemini"
    })
end

-- Initialize the plugin on load
M.init()

return M
