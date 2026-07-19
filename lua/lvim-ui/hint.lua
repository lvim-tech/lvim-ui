-- lvim-ui.hint: the NON-FOCUSABLE key-hint BAR — one full-width row pinned above the statusline that
-- announces what the keys do while a modal SUB-MODE owns the keyboard (an interactive resize / move mode,
-- a getcharstr loop). It is the sanctioned surface for "show the live keys", replacing every `echo`.
--
-- Why it is not the surface chassis: a sub-mode NEVER takes focus — the keys act on the user's REAL window
-- (they resize / move it) while it is still current, and the loop repaints under an explicit `redraw` inside
-- a blocking `getcharstr`. The chassis presupposes focus (sectors, close keys, cursor hiding, autocmd-driven
-- relayout), so it is the wrong interaction model here — exactly like `lvim-ui.menu` (the other passive,
-- non-focusable projection). The hint shares the chassis' BOX MODEL though: its items are ordinary bar
-- records rendered by `ui.surface.button` + `ui.bar`, so a hint key badge is byte-identical to a footer one
-- and the overflow chevrons come for free.
--
--   local h = require("lvim-ui").hint()
--   h:show({ { key = "h", name = "left" }, { type = "separator", text = "➤" }, { name = "80x24" } })
--   h:update(items)  -- same window, re-rendered (call after every state change)
--   h:close()
--
---@module "lvim-ui.hint"

local uibar = require("lvim-ui.bar")
local surface = require("lvim-ui.surface")
local config = require("lvim-ui.config")
local util = require("lvim-ui.util")

local api = vim.api

local M = {}

local NS = api.nvim_create_namespace("lvim_ui_hint")

---@class LvimUiHintOpts
---@field align?         "left"|"center"|"right"  Item alignment in the row (default: config.hint.align)
---@field default_style? string                   The ui.surface STYLE kind a record with no `style` uses
---@field zindex?        integer                  Window stack position (default: config.hint.zindex)
---@field fill_hl?       string                   The continuous full-width strip under the items
---@field filetype?      string                   Filetype of the hint buffer (cursor module / autocmd matching)

---@class LvimUiHintHandle
---@field show    fun(self: LvimUiHintHandle, items: table[]): nil
---@field update  fun(self: LvimUiHintHandle, items: table[]): nil
---@field hide    fun(self: LvimUiHintHandle): nil
---@field close   fun(self: LvimUiHintHandle): nil
---@field visible fun(self: LvimUiHintHandle): boolean

--- The row the bar sits on: the last editor row that is not the command line and not the statusline, so the
--- hint replaces nothing — it floats over the top line of the editor's bottom chrome-free area.
---@return integer row, integer width
local function geometry()
    -- The single shared authority (also used by the menu): `laststatus == 1` with only ONE window shows NO
    -- statusline, so reserving a row there would float the hint one row above the bottom.
    local status = util.status_rows()
    local row = math.max(0, vim.o.lines - vim.o.cmdheight - status - 1)
    return row, math.max(1, vim.o.columns)
end

--- Turn ONE hint record into a `ui.button` spec. A `separator` record passes through as a static box (the
--- canonical `➤` divider between the key group and a status cell); everything else goes through the shared
--- `ui.surface.button` so the box model / padding / 4 states are identical to every other bar in the set.
---@param rec table
---@param default_style string?
---@return table
local function spec_of(rec, default_style)
    if rec.type == "separator" then
        return { type = "separator", text = rec.text, style = rec.style or { padding = { 1, 1 }, hl = rec.hl } }
    end
    return surface.button(rec, default_style)
end

--- Create a hint-bar handle. The window/buffer are created on the first `show` and REUSED (repositioned +
--- re-rendered) afterwards, so an update inside a keystroke loop never flickers.
---@param opts? LvimUiHintOpts
---@return LvimUiHintHandle
function M.new(opts)
    opts = opts or {}
    local cfg = config.hint or {}
    local state = { buf = nil, win = nil }

    local handle = {}

    --- The scratch buffer the row is written into (created once).
    ---@return integer
    local function ensure_buf()
        if state.buf and api.nvim_buf_is_valid(state.buf) then
            return state.buf
        end
        state.buf = api.nvim_create_buf(false, true)
        vim.bo[state.buf].bufhidden = "wipe"
        vim.bo[state.buf].filetype = opts.filetype or cfg.filetype
        return state.buf
    end

    --- Render `items` into the (re)positioned window.
    ---@param items table[]
    ---@return nil
    local function render(items)
        local row, width = geometry()
        local buf = ensure_buf()

        local specs = {}
        for i, rec in ipairs(items or {}) do
            specs[i] = spec_of(rec, opts.default_style or cfg.default_style)
        end
        local res = uibar.render({ items = specs, width = width, align = opts.align or cfg.align })

        vim.bo[buf].modifiable = true
        api.nvim_buf_set_lines(buf, 0, -1, false, { res.line })
        vim.bo[buf].modifiable = false

        local wcfg = {
            relative = "editor",
            row = row,
            col = 0,
            width = width,
            height = 1,
            zindex = opts.zindex or cfg.zindex,
        }
        if state.win and api.nvim_win_is_valid(state.win) then
            api.nvim_win_set_config(state.win, wcfg) -- repositioned, never recreated
        else
            wcfg.style = "minimal"
            wcfg.focusable = false
            wcfg.noautocmd = true
            state.win = api.nvim_open_win(buf, false, wcfg)
            vim.wo[state.win].wrap = false
            vim.wo[state.win].winfixbuf = true
        end

        api.nvim_buf_clear_namespace(buf, NS, 0, -1)
        -- The continuous strip first (low priority) — the item boxes paint over it, exactly as a surface band.
        local fill = opts.fill_hl or cfg.fill_hl
        if fill then
            api.nvim_buf_set_extmark(buf, NS, 0, 0, { end_col = #res.line, hl_group = fill, priority = 150 })
        end
        for _, sp in ipairs(res.spans) do
            api.nvim_buf_set_extmark(buf, NS, 0, sp[1], { end_col = sp[2], hl_group = sp[3], priority = 200 })
        end
    end

    --- Show the bar with `items` (creating the window on first call).
    ---@param items table[]
    ---@return nil
    function handle:show(items)
        render(items)
    end

    --- Re-render the bar with `items` (same window — no flicker); a no-op when it is not shown.
    ---@param items table[]
    ---@return nil
    function handle:update(items)
        if state.win and api.nvim_win_is_valid(state.win) then
            render(items)
        end
    end

    --- Hide the window, keeping the handle (a later `show` re-opens it).
    ---@return nil
    function handle:hide()
        if state.win and api.nvim_win_is_valid(state.win) then
            api.nvim_win_close(state.win, true)
        end
        state.win = nil
    end

    --- Tear the handle down: close the window and wipe the buffer.
    ---@return nil
    function handle:close()
        self:hide()
        if state.buf and api.nvim_buf_is_valid(state.buf) then
            api.nvim_buf_delete(state.buf, { force = true })
        end
        state.buf = nil
    end

    --- Is the bar on screen?
    ---@return boolean
    function handle:visible()
        return state.win ~= nil and api.nvim_win_is_valid(state.win)
    end

    return handle
end

return M
