-- lvim-ui.bridge: hand Neovim's own `vim.ui.*` entry points to this toolkit.
--
-- WHY A BRIDGE AND NOT A DEFAULT. `vim.ui.select` is a GLOBAL that any plugin may already own, so
-- taking it must be a decision the reader makes, never a side effect of loading a UI library. It is
-- therefore opt-in (`setup({ bridge = { ui_select = true } })`) and it remembers what it replaced.
--
-- WHAT IT GIVES. Every `vim.ui.select` in the editor — a plugin's picker, an LSP code-action list —
-- opens as the same centred, themed, cursor-managed popup as the rest of the set, instead of the
-- native list at the bottom of the screen.
--
-- `vim.ui.input` IS NOT HERE, DELIBERATELY. In this set the input surface is the message zone, and
-- lvim-hud owns it (`input = { enable = true }`) — a prompt belongs to the command line, a choice
-- belongs to a panel. Two bridges in two plugins, each where its surface lives.
--
---@module "lvim-ui.bridge"

local config = require("lvim-ui.config")

local M = {}

---@type function|nil  what `vim.ui.select` was before we took it, so `restore()` is honest
local previous_select = nil

--- A prompt as a TITLE: strip the newlines Neovim allows in it, and turn a trailing colon into the
--- spacing the title band expects ("Code action:" → " Code action ").
---@param prompt string|nil
---@param fallback string
---@return string
local function title_of(prompt, fallback)
    local t = (prompt and prompt:gsub("\n", "")) or fallback
    if t:sub(-1) == ":" then
        t = " " .. t:sub(1, -2) .. " "
    end
    return t
end

--- Take over `vim.ui.select`.
---
--- The popup opens AT THE CURSOR, because a `vim.ui.select` is always about the thing under it —
--- a code action for this line, a choice for this word — and a centred window would make the reader
--- look away from what they are choosing for.
---
--- CODE ACTIONS ARE THE ONE SPECIAL CASE: their labels are sentences of wildly different lengths, so
--- the list is opened through an auto-width instance instead of the shared fixed width, and each row
--- carries the action glyph. Recognised by the prompt, which is the only thing the API gives us.
---@return nil
function M.ui_select()
    local ui = require("lvim-ui")
    local auto = ui.new({ width = false })
    previous_select = previous_select or vim.ui.select

    ---@param items any[]
    ---@param opts table
    ---@param on_choice fun(item: any|nil, index: integer|nil)
    vim.ui.select = function(items, opts, on_choice)
        assert(type(on_choice) == "function", "vim.ui.select: missing on_choice function")
        opts = opts or {}
        local format_item = opts.format_item or tostring
        local is_code_action = opts.prompt ~= nil and opts.prompt:find("[Cc]ode [Aa]ction") ~= nil
        local presenter = is_code_action and auto or ui
        local icon = is_code_action and require("lvim-ui.rows").icons().action or nil

        local rows = {}
        for _, item in ipairs(items) do
            local label = format_item(item)
            rows[#rows + 1] = icon and { label = label, icon = icon } or label
        end

        presenter.select({
            title = title_of(opts.prompt, " Select "),
            items = rows,
            position = "cursor",
            max_width = vim.api.nvim_win_get_width(0) - 4,
            max_items = vim.api.nvim_win_get_height(0),
            callback = function(confirmed, index)
                if confirmed and index then
                    on_choice(items[index], index)
                else
                    on_choice(nil, nil)
                end
            end,
        })
    end
end

--- Give `vim.ui.select` back to whoever had it before this bridge took it.
---@return nil
function M.restore()
    if previous_select ~= nil then
        vim.ui.select = previous_select
        previous_select = nil
    end
end

--- Activate the bridges the config asks for. Called from `lvim-ui.setup()`.
---@return nil
function M.setup()
    if (config.bridge or {}).ui_select then
        M.ui_select()
    end
end

return M
