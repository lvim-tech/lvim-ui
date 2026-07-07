-- lvim-ui: public API for the lvim-utils floating UI components — the thin presenter layer
-- that turns high-level opts (select/multiselect/input/confirm/tabs/info) into a configured surface +
-- form. It owns only the option-shaping and callback wiring; the actual window/frame lives in surface
-- and the typed-row logic in form.
--
-- Modes and their callback signatures:
--   select      → callback(confirmed: boolean, index: integer)
--   multiselect → callback(confirmed: boolean, selected: table<string, boolean>)
--   input       → callback(confirmed: boolean, value: string)
--   tabs        → callback(confirmed: boolean, result)
--                 result = { tab, index, item } for simple tabs
--                 result = table<name, value>   for typed-row tabs
--
-- Public API:
--   M.select(opts)        – pick one item from a list
--   M.multiselect(opts)   – pick multiple items
--   M.input(opts)         – free-text input field
--   M.confirm(opts)       – yes/no dialog → callback(yes: boolean)
--   M.tabs(opts)          – tabbed view with typed rows or simple item lists
--   M.info(content, opts) – read-only markdown/text info window
--   M.close_info(win)     – programmatically close an info window
---@module "lvim-ui"

local frame = require("lvim-ui.surface")
local form = require("lvim-ui.form")
local rows = require("lvim-ui.rows")
local util = require("lvim-ui.util")
local config = require("lvim-ui.config")
local merge = require("lvim-utils.utils").merge

local M = {}

--- Merge user options into the LIVE lvim-ui config in place (via lvim-utils.utils.merge), so every reader
--- `require("lvim-ui.config")` sees the effective values. Optional — the defaults work without calling it.
---@param opts? table  see lvim-ui.config for the full option set
function M.setup(opts)
    if opts then
        merge(config, opts)
    end
end

---@class UiOpts
---@field title? string|false        -- border-title (false hides it for M.info)
---@field items? any[]               -- select / multiselect items
---@field current_item? any          -- select: focus this item on open (e.g. the installed version)
---@field mark_current? boolean      -- select: default true → the focused current_item also gets a "  (current)" suffix; false = focus only (caller owns the marker)
---@field tabs? table[]              -- tabs: { { label, icon?, rows, menu?, hl?, actions? } , … } — or PROVIDER tabs (every tab carries `provider`; see M.tabs)
---@field menu? boolean              -- tabs: render the rows as a navigable MENU (action rows stay a selectable BODY list, not footer buttons); per-tab via `tab.menu`
---@field tab_bar? boolean           -- tabs: force the header tab bar ON (true — even with a single tab) or OFF (false); nil = auto (shown for >1 tab or when any tab-bar affordance exists)
---@field tab_bar_actions? table[]   -- tabs: trailing affordance buttons at the END of the tab bar (e.g. a `+` new-tab), each { name, icon?, key?, hl?, run(st) }
---@field callback? fun(...): any    -- result callback (signature varies per presenter)
---@field on_change? fun(row: table) -- tabs: fired on every typed-row edit
---@field subtitle? string|table|table[]  -- tabs / select: message line(s) under the title. A string, ONE line `{ text, type?, hl?, icon?, blank_below? }`, or a LIST of such lines. `type` ∈ "info"|"warn"|"error" (predefined fg colour); `hl` overrides; `icon` is fronted when given.
---@field default? any               -- input: initial value
---@field value? any                 -- input: alias for default
---@field prompt? string             -- input: prompt → title fallback
---@field width? number|table        -- FIXED width (number: fraction ≤1 or count). tabs ALSO accept a size SPEC — `{ auto = true, max = n }` (fit content, capped) or `{ fixed = n }` — to FORCE auto-fit at the call site over the shared fixed width
---@field height? number|table        -- FIXED height (number). tabs also accept a size SPEC (as `width`)
---@field max_width? number          -- auto-fit cap (fraction ≤1 or count)
---@field max_height? number         -- auto-fit cap (fraction ≤1 or count)
---@field position? string           -- "cursor" (anchor at the cursor) | "win" | "bottom" | "top" | nil (centred)
---@field layout? string             -- tabs: "float" (default centred) | "area" (cmdline/minibuffer dock) | "bottom"
---@field tab_selector? integer|string -- tabs: initial active tab — an index or a tab `name`
---@field initial_row? integer|string  -- tabs/form: focus this row on open — a row `name` or 1-based index (jump-to)
---@field title_count? fun(): integer|table  -- tabs: a live count for the chassis border counter — a total `number` or `{ current, total }` (placed per `counter`; default the bottom-right border-footer)
---@field title_line? string         -- title placement: "row" (a top content row, default) | "statusline" (publish to the chrome overlay) | "border" (opt-in native border-title)
---@field title_pos? string           -- title alignment: "left" (default) | "center" | "right"
---@field counter? string            -- tabs: "footer" (count in the bottom-right border, default) | "title" (count folded into the border-title)
---@field max_items? integer         -- select/multiselect: cap the VISIBLE list rows (a longer list scrolls past N); default config.max_items
---@field area_height? integer       -- tabs (docked): the docked content row budget (default AREA_CAP); scrolls past it
---@field slot? table                -- tabs: a per-open ANCHORED geometry override `{ height?, height_auto?, width?, width_auto?, backdrop? }` (a consumer's `config.force[layout]`) — WINS over the shared central geometry for THIS open; area/bottom ignore width/width_auto (always full-width)
---@field backdrop? table|false      -- tabs: backdrop veil override `{ enabled?, mode, dim, darken }` (or `false` to force OFF); falls back to `slot.backdrop`
---@field enter? boolean             -- false → open without focusing (cursor stays in the editor, e.g. hover)
---@field border? any                -- frame border override
---@field close_keys? string[]       -- keys that close the frame
---@field keymaps? table[]           -- extra frame-wide keymaps { { key, run } }
---@field highlights? table[]        -- info: extra content highlights
---@field on_open? fun(buf: integer, win: integer)  -- info: after open
---@field footer? boolean            -- info: false → no footer
---@field footer_fill? boolean       -- tabs: false → no tinted strip under the footer action bar (buttons float on the panel bg)
---@field footer_hints? boolean|table[] -- tabs: `true` → live key-hint LEGEND footer (panel keys • focused-row keys); a list `{ {key,label,run?,no_hotkey?} }` → footer hint BUTTONS (an item's own `run` wins, else `opts.keymaps[key].fn`; `no_hotkey` = label-only chip; a `type="separator"` item passes through as a divider)
---@field cursorline_hl? string      -- tabs: name a bg-only cursorline group so the hover changes only the bg (a row's own fg highlights survive)
---@field pad? integer               -- tabs/form: body row left padding
---@field on_item_change? fun(item: table) -- tabs item-list mode: live preview callback on focused item
---@field footer_items? table[]      -- info: extra footer action buttons { { key, name, run } } before `q close`
---@field hide_cursor? boolean       -- info: hide the hardware cursor (read-only viewer)
---@field wrap? boolean              -- info: enable line wrap in the window (default off)
---@field filetype? string           -- info: set the buffer filetype (e.g. "markdown" → treesitter colours)
---@field markview? boolean          -- info: render the content as markdown via markview.nvim

-- The canonical popup border — a FULL " " ring on all four sides (top for the native border-title / brand,
-- plus a " " gutter on the LEFT, RIGHT and BOTTOM) so the content breathes off every window edge. Titles
-- are always border-titles, blue-tinted — the diagnostics-panel approach. The ring lives in ONE place,
-- `config.border`; `lvim-ui.surface.FRAME_BORDER` is the marker bound to it (the chassis resolves
-- the marker to the LIVE config value at open time), and this re-exports that marker as `M.FRAME_BORDER` so
-- every consumer references the single config-driven source. (resolve_border fills the corners.)
local FRAME_BORDER = frame.FRAME_BORDER
M.FRAME_BORDER = FRAME_BORDER

-- The SECOND single-source ring — for the CONTENT data panels only (here: the M.tabs content block). It lives
-- in `config.content_border`; `lvim-ui.surface.CONTENT_BORDER` is the marker bound to it (the chassis
-- resolves it to the LIVE value at open time), re-exported as `M.CONTENT_BORDER`. The tab BAR / footer bands are
-- nav bars, not blocks, so they stay borderless — only the content block carries this ring.
local CONTENT_BORDER = frame.CONTENT_BORDER
M.CONTENT_BORDER = CONTENT_BORDER

--- The CENTRAL float geometry (`lvim-utils.config.dock.geometry.float`) — the single authority a modal's
--- content-fit cap (`max_width` / `max_height`) defaults to, so a select / input / tabs float fits its content
--- UP TO the shared float slot (0.9 × 0.7 by default) instead of a private constant.
---@return { width?: number, height?: number }
local function float_geo()
    local ok, uconf = pcall(require, "lvim-utils.config")
    return (ok and uconf and uconf.dock and uconf.dock.geometry and uconf.dock.geometry.float) or {}
end

-- (The old public `lvim-ui.M.size(layout)` façade is GONE — geometry is fully centralized. There is ONE
-- canonical path: `lvim-utils.config.dock.geometry` is the size authority; `lvim-utils.dock.slot(layout)`
-- resolves it to a rect (cells), and `lvim-ui.surface.size_spec(layout)` builds the fraction-based
-- `{ height, width }` axis shape the chassis needs. Consumers pass NO `size` and the surface derives it;
-- the modals here call `frame.size_spec` / `float_geo`.)

-- Docked (area / bottom) tabs cap their content to this many rows (it scrolls past the cap) when the consumer
-- gives no `area_height` — the cmdline zone grows `cmdheight`, so an unbounded accordion can't drive it (and a
-- float's `max_items` scroll cap is irrelevant to a dock). A compact minibuffer height, like the area finder.
local AREA_CAP = 16

--- The NATURAL row count for a scrollable list panel: the item count, capped at `max_items` (per-call
--- `opts.max_items`, else the shared `config.max_items`) so a longer list settles at N VISIBLE rows and
--- SCROLLS past them — the documented "maximum list rows shown before scrolling". Capping the panel's own
--- natural height (not the container) means the frame adds its chrome on top, so exactly N list rows show
--- (the picker does the same via its `max_rows`). `max_items` unset/≤0 ⇒ no cap (fit every item).
---@param n integer
---@param opts UiOpts
---@return integer
local function list_rows(n, opts)
    local cap = opts.max_items or config.max_items
    if cap and cap > 0 then
        return math.min(n, cap)
    end
    return n
end

--- Semantic subtitle `type` → its (fg-only) highlight group. A line may instead carry an explicit `hl`.
---@type table<string, string>
local SUBTITLE_TYPES = {
    info = "LvimUiSubtitleInfo", -- blue
    warn = "LvimUiSubtitleWarn", -- orange
    error = "LvimUiSubtitleError", -- red
}

--- Normalise `opts.subtitle` into header meta bars. Accepts a plain string, a single line table
--- `{ text, type?, hl?, icon?, blank_below? }`, or a LIST of such lines (a multi-line subtitle). Each line's
--- colour is its explicit `hl`, else its `type`'s predefined group, else the default `LvimUiSubtitle`; an
--- `icon` (optional, never implied by a type) is fronted; `blank_below` adds an empty row beneath the line.
---@param subtitle string|table|nil
---@return table[]
local function subtitle_bars(subtitle)
    if not subtitle then
        return {}
    end
    ---@type table
    local list
    if type(subtitle) ~= "table" or subtitle.text then
        list = { subtitle } -- a single line (string or `{ text = … }`) → a one-element list
    else
        list = subtitle -- already a LIST of line specs
    end
    local out = {}
    for _, ln in ipairs(list) do
        if type(ln) == "string" then
            out[#out + 1] = { text = ln, hl = "LvimUiSubtitle" }
        else
            local hl = ln.hl or (ln.type and SUBTITLE_TYPES[ln.type]) or "LvimUiSubtitle"
            out[#out + 1] = { text = (ln.icon and (ln.icon .. "  ") or "") .. (ln.text or ""), hl = hl }
            if ln.blank_below then
                out[#out + 1] = { text = "" } -- one empty meta band = a blank row under this line
            end
        end
    end
    return out
end

--- Pick one item from a list — a 1-panel `frame` (the list) + a confirm/cancel footer. `<C-j>`
--- descends into the footer (which scrolls to follow the selection on a narrow popup); the list shows
--- its selection via cursorline. callback(confirmed, index, item).
---@param opts UiOpts
function M.select(opts)
    opts = opts or {}
    local items = opts.items or {}
    -- Focus ONE item on open (e.g. the installed version). `current_item` is an item reference/value; nil =
    -- nothing focused (unchanged behaviour). By default the focused row also gets a "  (current)" suffix; set
    -- `mark_current = false` to only FOCUS it (for callers that build their own marker into the label).
    local current_idx = nil
    if opts.current_item ~= nil then
        for i, it in ipairs(items) do
            if it == opts.current_item then
                current_idx = i
                break
            end
        end
    end
    local mark_current = opts.mark_current ~= false
    local CURRENT_SUFFIX = "  (current)"
    ---@type fun(...): any
    local cb = opts.callback or function() end
    if #items == 0 then
        vim.schedule(function()
            cb(false)
        end)
        return
    end
    local confirmed = false
    local pan

    local function index()
        if pan and pan.win and vim.api.nvim_win_is_valid(pan.win) then
            return vim.api.nvim_win_get_cursor(pan.win)[1]
        end
        return 1
    end
    --- Confirm the focused item and close. `st` is the frame state (carries `close`).
    ---@param st table
    local function pick(st)
        confirmed = true
        local i = index()
        st.close()
        vim.schedule(function()
            cb(true, i)
        end)
    end

    local provider = {
        hide_cursor = true,
        cursorline = true,
        size = function()
            local w = util.dw(opts.title or "Select") + 4
            for i, it in ipairs(items) do
                local icon = rows.item_icon(it)
                local suffix = (mark_current and i == current_idx) and CURRENT_SUFFIX or ""
                w = math.max(w, util.dw((icon and icon .. " " or "") .. rows.item_label(it) .. suffix) + 4)
            end
            return w, list_rows(#items, opts)
        end,
        render = function(width)
            local lines, hls = {}, {}
            for i, it in ipairs(items) do
                local icon = rows.item_icon(it)
                local base = (icon and (icon .. " ") or "") .. rows.item_label(it)
                local suffix = (mark_current and i == current_idx) and CURRENT_SUFFIX or ""
                lines[i] = util.lpad(base .. suffix, width, 2)
                if icon then
                    hls[#hls + 1] = { i - 1, 2, 2 + #icon, "LvimUiItemIconInactive" }
                end
                if suffix ~= "" then
                    -- +2 for lpad's lead; #base is byte length (matches the icon offsets). Clamp the span to the
                    -- ACTUAL rendered line so a clipped row (lpad truncated it) never points the extmark past its
                    -- end (the window is sized to fit the suffix, so this only bites a forced-narrow width).
                    local scol = math.min(2 + #base, #lines[i])
                    hls[#hls + 1] = { i - 1, scol, math.min(scol + #suffix, #lines[i]), "Comment" }
                end
            end
            return lines, hls
        end,
        keys = function(map, p, st)
            pan = p
            -- Land the cursor on the current item (the installed version) when there is one.
            if current_idx and p.win and vim.api.nvim_win_is_valid(p.win) then
                pcall(vim.api.nvim_win_set_cursor, p.win, { current_idx, 0 })
            end
            map({ "<CR>", "<Space>" }, function()
                pick(st)
            end)
        end,
    }

    return frame.open({
        mode = "float",
        position = opts.position or config.position, -- nil/"editor" = centred; "cursor" anchors at the cursor
        border = FRAME_BORDER,
        title = opts.title or "Select", -- a plain string → a single blue-tinted border-title text box
        title_pos = opts.title_pos or "center", -- the select title is CENTRED (matches the hover); override per-call
        panel_border = "none",
        size = {
            -- a given `width` is FIXED (e.g. a 0.9-wide prompt); else auto-fit to the items, capped at max_width
            width = type(opts.width) == "number" and { fixed = opts.width }
                or { auto = true, max = opts.max_width or float_geo().width or 0.9 },
            height = { auto = true, max = opts.max_height or float_geo().height or 0.7 },
        },
        -- An optional `subtitle` (description / warning line) under the title — the SAME meta-band model as
        -- M.tabs, so a select can carry a one-liner like "Deletes it from disk." above its list.
        header = (function()
            local bars = subtitle_bars(opts.subtitle)
            return #bars > 0 and { bars = bars } or nil
        end)(),
        -- The list IS the data-content panel → the single-source content ring (CONTENT_BORDER →
        -- config.content_border, resolved live). The footer button bar is a nav bar, not a block, so it
        -- stays borderless (panel_border "none" only governs any block that doesn't set its own border).
        content = { blocks = { { id = "list", provider = provider, border = CONTENT_BORDER } } },
        footer = {
            bars = {
                {
                    align = "center", -- centred hint bar, matching the hover's action footer
                    items = {
                        { key = "<CR>", name = "select", run = pick }, -- naming consistent with the other footers
                        {
                            key = "<Esc>",
                            name = "close",
                            run = function(st)
                                st.close()
                            end,
                        },
                    },
                },
            },
        },
        on_close = function()
            if not confirmed then
                vim.schedule(function()
                    cb(false)
                end)
            end
        end,
    })
end

--- Pick multiple items — a 1-panel `frame` of checkbox rows + a toggle/confirm/cancel footer.
--- `<Space>` toggles the focused row, `<CR>` confirms. callback(confirmed, selected) where `selected`
--- maps each chosen item to true.
---@param opts UiOpts
function M.multiselect(opts)
    opts = opts or {}
    local items = opts.items or {}
    ---@type fun(...): any
    local cb = opts.callback or function() end
    if #items == 0 then
        vim.schedule(function()
            cb(false)
        end)
        return
    end
    local confirmed = false
    local selected = {}
    local pan
    local ico = util.cfg().icons or {}

    local function index()
        if pan and pan.win and vim.api.nvim_win_is_valid(pan.win) then
            return vim.api.nvim_win_get_cursor(pan.win)[1]
        end
        return 1
    end
    local function toggle_current()
        local it = items[index()]
        if it ~= nil then
            selected[it] = (not selected[it]) or nil
        end
        if pan and pan.refresh then
            pan.refresh()
        end
    end
    --- @param st table
    local function confirm(st)
        confirmed = true
        st.close()
        vim.schedule(function()
            cb(true, selected)
        end)
    end

    local provider = {
        hide_cursor = true,
        cursorline = true,
        size = function()
            local w = util.dw(opts.title or "Select") + 6
            for _, it in ipairs(items) do
                local icon = rows.item_icon(it)
                w = math.max(w, util.dw((icon and icon .. " " or "") .. rows.item_label(it)) + 6)
            end
            return w, list_rows(#items, opts)
        end,
        render = function(width)
            local lines, hls = {}, {}
            for i, it in ipairs(items) do
                local check = selected[it] and (ico.multi_selected or "") or (ico.multi_empty or "")
                local icon = rows.item_icon(it)
                lines[i] = util.lpad(check .. " " .. (icon and (icon .. " ") or "") .. rows.item_label(it), width, 2)
                hls[#hls + 1] =
                    { i - 1, 2, 2 + #check, selected[it] and "LvimUiCheckboxSelected" or "LvimUiCheckboxEmpty" }
                if icon then
                    local off = 2 + #check + 1
                    hls[#hls + 1] = { i - 1, off, off + #icon, "LvimUiItemIconInactive" }
                end
            end
            return lines, hls
        end,
        keys = function(map, p, st)
            pan = p
            map({ "<Space>" }, toggle_current)
            map({ "<CR>" }, function()
                confirm(st)
            end)
        end,
    }

    frame.open({
        mode = "float",
        border = FRAME_BORDER,
        title = opts.title or "Select",
        panel_border = "none",
        size = { width = { auto = true, max = 0.6 }, height = { auto = true, max = 0.6 } },
        -- The checkbox list IS the data-content panel → the single-source content ring; the toggle/confirm/
        -- cancel footer is a nav bar (borderless).
        content = { blocks = { { id = "list", provider = provider, border = CONTENT_BORDER } } },
        footer = {
            bars = {
                {
                    items = {
                        {
                            key = "<Space>",
                            name = "toggle",
                            run = function()
                                toggle_current()
                            end,
                        },
                        { key = "<CR>", name = "confirm", run = confirm },
                        {
                            key = "<Esc>",
                            name = "cancel",
                            run = function(st)
                                st.close()
                            end,
                        },
                    },
                },
            },
        },
        on_close = function()
            if not confirmed then
                vim.schedule(function()
                    cb(false)
                end)
            end
        end,
    })
end

--- Free-text input — a 1-panel `frame` whose single editable line IS the field; `<CR>` confirms,
--- `<Esc>` cancels. callback(confirmed, value).
---@param opts UiOpts
function M.input(opts)
    opts = opts or {}
    ---@type fun(...): any
    local cb = opts.callback or function() end
    local default = tostring(opts.default or opts.value or "")
    local confirmed = false
    local buf

    --- @param st table
    local function confirm(st)
        confirmed = true
        local val = ""
        if buf and vim.api.nvim_buf_is_valid(buf) then
            val = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
        end
        st.close()
        vim.schedule(function()
            cb(true, val)
        end)
    end

    local provider = {
        editable = true,
        size = function()
            return math.max(util.dw(default) + 4, util.dw(opts.title or opts.prompt or "Input") + 4, 30), 1
        end,
        render = function()
            return { default }, {}
        end,
        keys = function(map, p, st)
            buf = p.buf
            vim.keymap.set("i", "<CR>", function()
                vim.cmd("stopinsert")
                confirm(st)
            end, { buffer = p.buf, nowait = true })
            vim.keymap.set("i", "<Esc>", function()
                vim.cmd("stopinsert")
                st.close()
            end, { buffer = p.buf, nowait = true })
            map("<CR>", function()
                confirm(st)
            end)
        end,
    }

    frame.open({
        mode = "float",
        border = FRAME_BORDER,
        title = opts.title or opts.prompt or "Input",
        -- The single editable line IS an INPUT / entry band, NOT a data-content panel — so it stays BORDERLESS
        -- (panel_border "none"), per the content-vs-nav rule. Only DATA panels carry the content ring.
        panel_border = "none",
        size = { width = { auto = true, max = opts.width or 0.6 }, height = { auto = true } },
        content = { blocks = { { id = "input", provider = provider } } },
        footer = {
            bars = {
                {
                    items = {
                        { key = "<CR>", name = "confirm", run = confirm },
                        {
                            key = "<Esc>",
                            name = "cancel",
                            run = function(st)
                                st.close()
                            end,
                        },
                    },
                },
            },
        },
        on_close = function()
            if not confirmed then
                vim.schedule(function()
                    cb(false)
                end)
            end
        end,
    })
end

--- Yes/no confirmation dialog (a two-item select). The default choice is listed first so
--- it is focused on open; cancelling (<Esc>) resolves to `false`.
---@param opts { prompt?: string, title?: string, yes?: string, no?: string, default_no?: boolean, callback: fun(yes: boolean) }
function M.confirm(opts)
    opts = opts or {}
    local yes_label, no_label = opts.yes or "Yes", opts.no or "No"
    local items = opts.default_no and { no_label, yes_label } or { yes_label, no_label }
    ---@type fun(...): any
    local cb = opts.callback or function() end
    M.select({
        title = opts.title or opts.prompt or " Confirm",
        items = items,
        callback = function(confirmed, index)
            cb(confirmed == true and items[index] == yes_label)
        end,
    })
end

--- Tabbed / form view on a `frame`: the center is a `form` provider of the active tab's typed rows;
--- the tab's ACTION rows become the navigable FOOTER (so `<C-j>` reaches them, scrolling on a narrow
--- popup); a tab bar in the header (when more than one tab) switches the row set live with `h`/`l`.
--- callback(confirmed, result) where result = table<name, value>; `on_change(row)` on every edit.
--- NOTE: a per-tab DIFFERENT footer is a follow-up — the footer is built from the first tab's actions.
---@param opts UiOpts
function M.tabs(opts)
    opts = opts or {}
    -- Share ROWS-based tabs by REFERENCE so a consumer that mutates `tab.rows` LIVE (the installer's refresh:
    -- rebuild `state.tabs[i].rows`, then `handle.recalc()`; and the row spinners, which mutate a row in place)
    -- is seen by split()/recalc() — they read `tabset[ti].rows`. Only ITEMS-based tabs are DEEP-COPIED: their
    -- one-shot items→rows conversion writes `t.menu`/`t.rows` back, which on a REUSED spec (a theme picker
    -- reopened) would leave a stale "(current)" — the per-open copy keeps that conversion isolated. (A blanket
    -- deepcopy of ALL tabs silently broke the live-mutation contract: the handle rendered its own copy and
    -- never saw a consumer's row updates → install/update/delete "did nothing" and the spinner never animated.)
    local tabset = {}
    for i, t in ipairs(opts.tabs or {}) do
        tabset[i] = (t.items and not t.rows) and vim.deepcopy(t) or t
    end
    if #tabset == 0 then
        return
    end
    ---@type fun(...): any
    local cb = opts.callback or function() end
    local active = 1
    local done = false

    -- PROVIDER-tab mode: a tab carrying `provider` supplies its content as a raw surface CONTENT PROVIDER —
    -- an `update` provider that OWNS the shared panel window (it may swap an EXTERNAL buffer in via
    -- nvim_win_set_buf: the lsp-outline / peek-preview pattern) — instead of typed rows. There is ONE content
    -- block, so the whole tabset must be provider tabs (rows/items tabs cannot mix in). Switching tabs
    -- relayouts the chassis, which re-fires the ACTIVE tab's `update` — that is the buffer swap. The
    -- provider's `keys` hook fires ONCE at open, for the tab active then (the shared pan/st recorder — the
    -- outline pattern); a tab's own keymaps belong buffer-local on the buffer its `update` swaps in.
    local provider_mode = tabset[1].provider ~= nil

    -- Back-compat item-list PICKER mode: a tab with `.items` (each item = label/icon + a payload) is a simple
    -- selectable list, NOT typed rows. Convert each to a navigable MENU row carrying the item, so
    -- `on_item_change(item)` fires on cursor move (live preview), <CR> returns `{ tab, index, item }`, and
    -- `current_item` (an item REFERENCE) focuses its row + gets a ➤ marker on open.
    local item_focus -- the row `name` to focus on open (the current item)
    --- Convert one items-tab into menu rows in place (also reused by the handle's `set_tabs`).
    ---@param ti integer  the tab's index (row-name namespace)
    ---@param t table     the tab spec (mutated: `menu` + `rows`)
    local function items_to_rows(ti, t)
        t.menu = true
        local rs = {}
        for j, it in ipairs(t.items) do
            local rname = ("__item_%d_%d"):format(ti, j)
            local is_current = opts.current_item ~= nil and it == opts.current_item
            if is_current then
                item_focus = rname
            end
            rs[j] = {
                type = "action",
                flat = true,
                tight = true, -- a compact list: no 2-space lead (the body lpad gives a single space)
                icon = it.icon or "",
                name = rname,
                -- the CURRENT item is marked with a "(current)" suffix on its label
                label = (it.label or "") .. (is_current and "  (current)" or ""),
                _item = it,
                run = function(_, close)
                    if close then
                        close(true, { tab = t, index = j, item = it })
                    end
                end,
            }
        end
        t.rows = rs
    end
    for ti, t in ipairs(tabset) do
        if t.items and not t.rows and not t.provider then
            items_to_rows(ti, t)
        end
    end

    -- Layout: "float" (default centred modal) | "area" (the Emacs-minibuffer cmdline zone, like the area
    -- finder + the fzf pickers) | "bottom" (a bottom dock). Docked layouts publish their title to the
    -- statusline overlay, render the bars centered, and (area) host themselves in the msgarea zone.
    local layout = opts.layout or "float"
    local area = layout == "area"
    local bottom = layout == "bottom"
    local docked = area or bottom
    -- The window the panel opened from — docked layouts return to it on an escape-up.
    local opener = vim.api.nvim_get_current_win()
    -- Initial active tab: a `tab_selector` index (number) or a tab `name` (string).
    if type(opts.tab_selector) == "number" then
        active = math.max(1, math.min(opts.tab_selector --[[@as integer]], #tabset))
    elseif type(opts.tab_selector) == "string" then
        for i, t in ipairs(tabset) do
            if t.name == opts.tab_selector then
                active = i
                break
            end
        end
    end

    -- Split a tab's rows into content (form center) and action rows (footer buttons). An `action` row that
    -- owns `children` is an expandable accordion SECTION, not a leaf button — it stays in the content body
    -- (its caret + label render in place and its children flatten under it). Only childless action rows are
    -- footer buttons.
    -- MENU mode (`opts.menu` or per-tab `tab.menu`): a tab is a navigable MENU, not a form — its childless
    -- action rows STAY IN THE BODY as a selectable list (the form provider runs `row.run` on <CR>/<Space>),
    -- instead of collapsing into footer buttons. (A long list — e.g. every saved quickfix — needs a scrollable
    -- body, not N keyed footer chips.)
    local menu = opts.menu == true
    local function split(ti)
        local content, actions, bars = {}, {}, {}
        local tab_menu = menu or (tabset[ti] and tabset[ti].menu == true)
        for _, r in ipairs((tabset[ti] or {}).rows or {}) do
            if r.type == "bar" then
                -- A TOP-LEVEL toolbar bar becomes its own header-band SECTOR (reached with C-j/C-k), like the
                -- picker's filter bar. (Nested bar rows — e.g. a per-item action bar — stay in the content.)
                bars[#bars + 1] = r
            elseif r.type == "action" and not r.children and not tab_menu then
                actions[#actions + 1] = r
            else
                content[#content + 1] = r
            end
        end
        -- Drop trailing/leading BLANK spacer rows from the body: they separated the fields from the action rows
        -- (now in the FOOTER) and the toolbar bars (now in the HEADER), so otherwise they dangle (a stray ──────
        -- at the top/bottom). A LABELED spacer is a section HEADER (e.g. "Frontend" atop the Projects menu), not
        -- a stray divider — it must survive even as the first/last row.
        local function is_blank_spacer(r)
            return r
                and (r.type == "spacer" or r.type == "spacer_line")
                and not (type(r.label) == "string" and vim.trim(r.label) ~= "")
        end
        while #content > 0 and is_blank_spacer(content[#content]) do
            content[#content] = nil
        end
        while #content > 0 and is_blank_spacer(content[1]) do
            table.remove(content, 1)
        end
        return content, actions, bars
    end
    -- Typed-row values from every tab, keyed by name (the callback result).
    local function collect()
        local res = {}
        for _, tab in ipairs(tabset) do
            for _, r in ipairs(tab.rows or {}) do
                if r.name and r.type ~= "action" and r.type ~= "spacer" and r.type ~= "spacer_line" then
                    res[r.name] = r.value
                end
            end
        end
        return res
    end

    local st -- forward decl: the frame state (assigned by frame.open below); reached by the footer's deferred callbacks
    local update_footer -- forward decl: rebuild the live key-hint footer (assigned once footer_hints_spec exists)
    local actions1 = {} -- the initially-active tab's footer action rows (rows mode only)
    local form_p -- the typed-row form provider (nil in provider-tab mode)
    local content_p -- the ONE content-block provider the frame hosts (the form, or the provider-tab delegate)
    if provider_mode then
        -- The DELEGATE content provider: one panel window shared by every tab, each call forwarded to the
        -- ACTIVE tab's provider — so `set_active_tab`'s relayout re-fires `update` on the newly-active tab
        -- (the buffer swap) with zero window churn. `hide_cursor` only when EVERY tab hides it (an interactive
        -- tab — e.g. a terminal — needs the real cursor, so one such tab keeps it for the shared panel);
        -- `filetype` from the initially-active tab (the shared scratch buffer is stamped once).
        local function active_provider()
            local t = tabset[active]
            return t and t.provider or nil
        end
        local all_hide = true
        for _, t in ipairs(tabset) do
            if not (t.provider and t.provider.hide_cursor) then
                all_hide = false
                break
            end
        end
        content_p = {
            hide_cursor = all_hide,
            filetype = tabset[active].provider.filetype,
            --- Content-size hint — the active tab's, used only when an axis resolves to AUTO sizing.
            ---@return integer width, integer height
            size = function()
                local pr = active_provider()
                if pr and pr.size then
                    return pr.size()
                end
                return 40, 10
            end,
            --- Realise the ACTIVE tab's content in the (re)laid-out shared panel window.
            ---@param pan table
            ---@param L table?
            update = function(pan, L)
                local pr = active_provider()
                if pr and pr.update then
                    pr.update(pan, L)
                end
            end,
            --- Fired once at open (chassis key wiring) — forwarded to the tab active THEN (see above).
            ---@param map fun(lhs: string|string[], fn: fun())
            ---@param pan table
            ---@param st2 table
            keys = function(map, pan, st2)
                local pr = active_provider()
                if pr and pr.keys then
                    pr.keys(map, pan, st2)
                end
            end,
            --- Frame teardown — every tab's provider gets its `on_close` (each owns per-tab state).
            ---@param pan table
            on_close = function(pan)
                for _, t in ipairs(tabset) do
                    if t.provider and t.provider.on_close then
                        pcall(t.provider.on_close, pan)
                    end
                end
            end,
        }
    else
        local content1
        content1, actions1 = split(active)
        form_p = form.new({
            rows = content1,
            -- Focus a specific row on open (jump-to): a row `name` or index in the initially-active tab.
            initial_row = opts.initial_row,
            on_change = opts.on_change,
            cursorline_hl = opts.cursorline_hl,
            pad = opts.pad, -- body content lpad (default 2); a compact picker can drop it (e.g. 0)
            -- a footer key-hint legend tracks the focused row: re-notify on cursor move (legend only, not the
            -- static button-list form of `footer_hints`)
            on_cursor = opts.footer_hints == true and function()
                if update_footer then
                    update_footer()
                end
            end or nil,
            -- Item-list picker live preview: fire the consumer's `on_item_change` with the focused item on EVERY
            -- cursor move (raw, no dedup — the variant rows are all `action`, so a sig-deduped hook would miss them).
            on_move = opts.on_item_change and function(r)
                if r and r._item then
                    opts.on_item_change(r._item)
                end
            end or nil,
            on_action_close = function(confirmed, result)
                if confirmed ~= nil then
                    done = true
                    cb(confirmed == true, result or collect())
                end
            end,
        })
        content_p = form_p
    end

    local function action_specs(actions)
        local specs = {}
        for _, a in ipairs(actions) do
            specs[#specs + 1] = {
                key = a.key or (a.label or "?"):sub(1, 1):lower(),
                name = a.label or a.name or "",
                run = function(st)
                    if a.run then
                        a.run(a.value, function(confirmed, r)
                            st.close()
                            if confirmed ~= nil then
                                done = true
                                cb(confirmed == true, r or collect())
                            end
                        end)
                    else
                        st.close()
                    end
                end,
            }
        end
        return specs
    end

    -- `footer_hints` as a LIST `{ {key, label, run?, no_hotkey?}, … }` renders FOOTER BUTTONS (the installer
    -- prompt's All/Selected/Cancel, diagnostics next/prev, the terminal's nav chips). An item's own `run(st)`
    -- wins; else it wires to the matching `opts.keymaps[key].fn`; else it closes. `no_hotkey` makes it a
    -- label-only chip (a multi-char key LABEL — "A-l", "q/Esc" — must never become a real mapping: it would
    -- turn its first char into a mapping prefix → a timeoutlen stall); a `type = "separator"` item passes
    -- through as a divider. Distinct from `footer_hints = true`, the live key-hint legend. Pressing the key
    -- (when real) OR clicking the button fires it.
    local function footer_hint_specs(hints)
        local specs = {}
        for _, h in ipairs(hints) do
            if h.type then
                specs[#specs + 1] = h -- a separator (or any full bar-element spec) passes through unchanged
            else
                local key = h.key
                specs[#specs + 1] = {
                    key = key,
                    name = h.label or h.name or "",
                    no_hotkey = h.no_hotkey,
                    run = function(st2)
                        if h.run then
                            h.run(st2)
                            return
                        end
                        local km = opts.keymaps and opts.keymaps[key]
                        if km and km.fn then
                            km.fn(function(confirmed, r)
                                st2.close()
                                if confirmed ~= nil then
                                    done = true
                                    cb(confirmed == true, r or collect())
                                end
                            end)
                        else
                            st2.close()
                        end
                    end,
                }
            end
        end
        return specs
    end

    -- A live key-hint LEGEND footer (opt-in `footer_hints`): a ui.bar of PANEL keys (constant) • the focused
    -- row's keys (dynamic, from the form's `hints()`). Clickable: q closes; a row hint cycles / activates the
    -- focused row. The h/l Tabs and j/k Move chips are an informational legend (the real keys live in the body).
    local function footer_hints_spec()
        -- `no_hotkey` on every chip: this is a LEGEND — the keys it shows (h/l, j/k, q, ↵/→ …) are already
        -- mapped by the body/frame. Registering the multi-char LABELS ("j/k") as keymaps would make "j" a
        -- mapping prefix → a `timeoutlen` stall on every "j". They stay mouse-clickable via `run`.
        local items = {
            { key = "h/l", name = "Tabs", run = function() end, no_hotkey = true },
            { key = "j/k", name = "Move", run = function() end, no_hotkey = true },
            {
                key = "q",
                name = "Close",
                no_hotkey = true,
                run = function(st)
                    st.close()
                end,
            },
        }
        local hints = (form_p and form_p.hints) and form_p.hints() or {}
        -- The ● divider + chevrons only appear when there ARE focused-row keys to the right; on a row with no
        -- keys of its own (e.g. a display-only detail field) the divider would dangle, so drop it.
        if #hints > 0 then
            items[#items + 1] =
                { type = "separator", text = "●", style = { padding = { 1, 1 }, hl = "LvimUiFooterSep" } }
        end
        for _, h in ipairs(hints) do
            items[#items + 1] = {
                key = h.key,
                name = h.label,
                no_hotkey = true,
                run = function(st2)
                    if h.act == "next" then
                        form_p.cycle(1)
                    elseif h.act == "prev" then
                        form_p.cycle(-1)
                    elseif form_p.act then
                        form_p.act(st2)
                    end
                end,
            }
        end
        return {
            bars = {
                {
                    items = items,
                    align = "center",
                    -- the overflow chevrons borrow the separator's accent (same box as the ● divider), using the
                    -- SHARED glyphs (config.chevrons) in that colour.
                    chevrons = frame.chevrons("LvimUiFooterSep"),
                },
            },
        }
    end
    update_footer = function()
        if opts.footer_hints == true and st and st.set_footer then
            st.set_footer(footer_hints_spec())
        end
    end

    -- Header bars: an optional subtitle text bar + a tab bar (live switch), then the ACTIVE tab's toolbar
    -- bars — each `type="bar"` row becomes its OWN header-band SECTOR (reached with C-j/C-k, like the
    -- picker's filter bar). The TITLE is the frame's border-title, not a header bar.
    local static_bars = {} -- the per-surface prefix (subtitle bars); the tab bar + per-TAB bars are appended live
    local set_active_tab -- forward decl: switch to a tab; shared by the tab bar, the body l/h keymaps + the handle
    for _, b in ipairs(subtitle_bars(opts.subtitle)) do
        static_bars[#static_bars + 1] = b
    end

    --- Map one tab-bar AFFORDANCE record — a per-tab companion (`tab.actions`, e.g. a kill ×) or a bar
    --- trailer (`opts.tab_bar_actions`, e.g. a + new-tab) — through the shared button mapper, `plain` kind
    --- (a bare glyph; the record's `hl` box override carries its own accent).
    ---@param a { name?: string, icon?: string, key?: string, hl?: table, run?: fun(st: table) }
    ---@return table  a ui.button spec
    local function affordance_button(a)
        return frame.button({
            name = a.name,
            icon = a.icon,
            key = a.key,
            style = "plain",
            hl = a.hl,
            run = a.run,
            no_hotkey = a.no_hotkey,
        }, "plain")
    end

    --- Whether the header shows a tab bar RIGHT NOW: the explicit `opts.tab_bar` wins; else auto — more
    --- than one tab, or ANY tab-bar affordance (a per-tab `actions` / trailing `tab_bar_actions` bar is
    --- functional chrome even for a single tab). Re-evaluated per header rebuild, so a tabset grown past
    --- one tab via `set_tabs` gains its bar live.
    ---@return boolean
    local function want_tab_bar()
        if opts.tab_bar ~= nil then
            return opts.tab_bar == true
        end
        if #tabset > 1 then
            return true
        end
        if type(opts.tab_bar_actions) == "table" and #opts.tab_bar_actions > 0 then
            return true
        end
        for _, t in ipairs(tabset) do
            if t.actions and #t.actions > 0 then
                return true
            end
        end
        return false
    end

    -- The PERSISTENT tab-bar band (identity kept across rebuilds so `_sel`/`_off` scroll state survives a
    -- header re-derive). `_follow` + `_sel` keep the ACTIVE tab scrolled into view on an overflowing bar,
    -- even when the bar isn't the focused sector (tabs are usually switched with h/l from the body).
    -- Overflow chevrons: the ui.bar DEFAULT chevron glyph is empty (a consumer supplies it), so an
    -- overflowing tab bar needs its own — the SHARED glyphs (config.chevrons) in the tab accent.
    local tab_bar = {
        align = "center",
        _follow = true,
        chevrons = frame.chevrons("LvimUiTabChevron"),
    }

    --- (Re)build the tab bar's element list from the LIVE tabset: a `tab`-kind button per tab (icon +
    --- label, the shared styling path; a per-tab `hl` box override rides on it — e.g. a "dead" accent) —
    --- the tab index in `_meta` drives the switch — each followed by its affordance buttons
    --- (`tab.actions`), then the bar trailers (`opts.tab_bar_actions`). Rebuilt on every tab switch /
    --- `set_tabs`, anchoring `_sel` on the active tab's button.
    local function refresh_tab_bar()
        local items, sel = {}, nil
        for i, t in ipairs(tabset) do
            items[#items + 1] = frame.button({
                name = t.label or ("Tab " .. i),
                icon = t.icon,
                style = "tab",
                hl = t.hl,
                active = (i == active),
                meta = { tab = i },
            }, "tab")
            if i == active then
                sel = #items
            end
            for _, a in ipairs(t.actions or {}) do
                items[#items + 1] = affordance_button(a)
            end
        end
        for _, a in ipairs(opts.tab_bar_actions or {}) do
            items[#items + 1] = affordance_button(a)
        end
        tab_bar.items = items
        tab_bar._sel = sel or 1
    end
    refresh_tab_bar()
    -- A "live" bar: moving the bar's selection onto a TAB button switches to it immediately (an affordance
    -- button under the selection is a no-op here — it fires via <CR>/its `run`).
    tab_bar.on_change = function(spec, st2)
        if spec and spec._meta and spec._meta.tab then
            set_active_tab(st2, spec._meta.tab)
        end
    end

    -- The full header spec for the CURRENT active tab: the static prefix + the tab bar (when shown) + the
    -- active tab's bar rows as bands. Re-evaluated on every tab switch / content rebuild via `st.set_header`.
    local function header_spec()
        local hb = {}
        for _, b in ipairs(static_bars) do
            hb[#hb + 1] = b
        end
        if want_tab_bar() then
            hb[#hb + 1] = tab_bar
            hb[#hb + 1] = { text = "" } -- 1 blank "air" row between the tab bar and the toolbars/content
        end
        local _, _, tbars = split(active)
        for _, br in ipairs(tbars) do
            hb[#hb + 1] = { items = br.items, align = br.align or "center" }
        end
        return { bars = hb }
    end

    --- Switch to tab `i` (clamped): re-anchor the bar, swap the content — rows mode re-reads the new tab's
    --- rows into the form; provider mode lets the header relayout re-fire the delegate's `update`, which
    --- realises the NEW active tab's content in the shared panel (the buffer swap) — and re-fit.
    ---@param st2 table    the frame state
    ---@param i integer?   the target tab index (non-numbers are ignored — e.g. an affordance button's nil meta)
    set_active_tab = function(st2, i)
        if type(i) ~= "number" or #tabset == 0 then
            return
        end
        i = math.max(1, math.min(i, #tabset))
        if i == active then
            return
        end
        active = i
        refresh_tab_bar()
        if form_p then
            form_p.set_rows((split(active)))
        end
        -- Rebuild the header with the NEW tab's bar state (+ re-fit). set_header relayouts, which also
        -- re-renders the content block (the provider-mode buffer swap).
        if st2.set_header then
            st2.set_header(header_spec())
        elseif st2.relayout then
            st2.relayout()
        end
        if st2.set_counter then
            st2.set_counter(opts.title_count) -- refresh the border counter for the new tab
        end
    end

    -- (HOSTED area) An `area` panel homes itself in the msgarea zone via the surface engine's auto-host
    -- provider (position="cmdline" + no explicit host): the zone reserves our rows above the messages and the
    -- surface follows the rect. The engine also wires the descend (`on_escape_below`) + release — ui never
    -- references msgarea. `area` alone drives the zindex hint below; the surface bumps it to 210 when hosted.
    st = frame.open({
        mode = "float",
        -- Docked: "area" sits IN the cmdline region (grows cmdheight, chrome above), "bottom" floats over the
        -- bottom rows; `host` re-homes an area panel INSIDE the msgarea zone (above the messages). Float = nil.
        position = area and "cmdline" or (bottom and "bottom") or nil,
        zindex = (area and 200) or nil, -- the surface bumps a hosted area dock to 210 in its auto-host block
        header_air = docked and false or nil,
        -- The canonical full " " ring on EVERY mode; the chassis owns the title placement: a native centered
        -- border-title in the top border by default, or (area + `title_line="statusline"`) the chrome overlay.
        -- The count (`opts.title_count`) rides the border per `counter` (default the bottom-right border-footer).
        border = opts.border or FRAME_BORDER,
        -- Backdrop veil override: an explicit `opts.backdrop`, else the anchored `slot.backdrop` (so a
        -- consumer's `config.force[layout].backdrop` forces the veil for this open). nil = the central default.
        backdrop = opts.backdrop or (opts.slot and opts.slot.backdrop) or nil,
        title = opts.title,
        title_line = opts.title_line,
        title_pos = opts.title_pos, -- "left" (default) | "center" | "right" — title alignment
        counter = opts.counter,
        count = opts.title_count,
        close_keys = opts.close_keys or config.close_keys,
        keymaps = opts.keymaps,
        panel_border = "none",
        -- Docked: <C-k> off the top sector returns to the opener window; <C-j> off the bottom descends into
        -- the messages composed below (hosted area only).
        on_escape_above = docked and function()
            if opener and vim.api.nvim_win_is_valid(opener) then
                vim.api.nvim_set_current_win(opener)
            end
        end or nil,
        -- on_escape_below (descend into the messages) is wired by the surface auto-host provider for a hosted
        -- area dock — ui no longer references msgarea.
        -- Size DEFAULTS from the CENTRAL geometry authority `lvim-utils.config.dock.geometry` (via
        -- `frame.size_spec(layout)`), so a change in control-center's Utils tab resizes every ui.tabs consumer.
        -- An explicit per-call `opts.width` / `opts.height` / `opts.area_height` still overrides. Docked: the
        -- area height also passes through the msgarea reserve cap; the tabs scroll past it.
        size = (function()
            local shared = frame.size_spec(docked and (area and "area" or "bottom") or "float")
            -- `opts.slot` is an optional per-open ANCHORED geometry override (a consumer's `config.force[layout]`):
            -- `height`/`width` ≤ 1 = a screen fraction, > 1 = an absolute count; `*_auto` picks content-fit-up-to-max
            -- over fixed. It WINS over the shared central geometry for THIS open only. area/bottom are ALWAYS
            -- full-width, so `width`/`width_auto` are ignored there — matching `dock.slot`.
            local slot = opts.slot
            local function slot_axis(val, auto)
                if val == nil then
                    return nil
                end
                return (auto == true) and { auto = true, max = val } or { fixed = val }
            end
            if docked then
                return {
                    height = (slot and slot_axis(slot.height, slot.height_auto))
                        or shared.height
                        or { auto = true, max = opts.area_height or AREA_CAP },
                }
            end
            return {
                -- A caller may FORCE the axis at the call site by passing a size SPEC table — `{ auto = true,
                -- max = 0.9 }` to override the shared FIXED width and auto-fit content (e.g. the install / quit
                -- prompts), or `{ fixed = n }`. A plain NUMBER is shorthand for `{ fixed = n }`. `type == number`
                -- (not truthy) also means a stray non-number (an old `"auto"` string) is ignored — it would become
                -- `{ fixed = "auto" }` and crash `axis_size` — and auto-fits instead. Then the `slot` anchored
                -- override, else the SHARED size, then a final auto cap.
                width = (type(opts.width) == "table" and opts.width)
                    or (type(opts.width) == "number" and { fixed = opts.width })
                    or (slot and slot_axis(slot.width, slot.width_auto))
                    or shared.width
                    or { auto = true, max = float_geo().width or 0.7 },
                height = (type(opts.height) == "table" and opts.height)
                    or (type(opts.height) == "number" and { fixed = opts.height })
                    or (slot and slot_axis(slot.height, slot.height_auto))
                    or shared.height
                    or { auto = true, max = float_geo().height or 0.9 },
            }
        end)(),
        header = (function()
            local hs = header_spec()
            return (#hs.bars > 0) and hs or nil
        end)(),
        -- The tab CONTENT panel carries the single-source content ring (CONTENT_BORDER → config.content_border,
        -- resolved live). The tab BAR + footer hint bands are nav bars, not blocks, so they stay borderless.
        -- ONE block either way: the typed-row form, or (provider mode) the per-tab provider delegate.
        content = {
            blocks = { { id = provider_mode and "content" or "form", provider = content_p, border = CONTENT_BORDER } },
        },
        footer = (opts.footer_hints == true and footer_hints_spec())
            or (
                type(opts.footer_hints) == "table"
                and {
                    bars = {
                        {
                            items = footer_hint_specs(opts.footer_hints),
                            align = "center",
                            fill = opts.footer_fill ~= false,
                            -- overflow chevrons in the footer accent (same box as the ● divider), shared glyphs
                            chevrons = frame.chevrons("LvimUiFooterSep"),
                        },
                    },
                }
            )
            or (
                (#actions1 > 0)
                    and {
                        bars = {
                            { items = action_specs(actions1), align = "center", fill = opts.footer_fill ~= false },
                        },
                    }
                or nil
            ),
        on_close = function()
            if docked then
                -- Clear the statusline title overlay if the chrome module is present. Loaded lazily + guarded
                -- so ui does not hard-depend on chrome (post-split: chrome → lvim-hud; ui works without it).
                pcall(function()
                    require("lvim-hud.overlay").clear()
                end)
            end
            -- (HOSTED area) the reserved zone rows are released by the surface engine (its `state._host_release`,
            -- set by the auto-host provider) — ui no longer releases them itself.
            if not done then
                vim.schedule(function()
                    cb(false)
                end)
            end
        end,
    })

    -- After-open hook: hand the content buffer/window to the consumer (e.g. the installer's per-row action
    -- keymaps r/u/d/b). The content panel is the first frame panel.
    if opts.on_open then
        local p = st and st.panels and st.panels[1]
        if p then
            opts.on_open(p.buf, p.win)
        end
    end

    -- Item-list picker: focus the CURRENT item's row on open (after the form's own initial-cursor schedule), so
    -- the cursor starts on the active theme instead of the first row (which would live-preview the wrong one).
    if item_focus then
        vim.schedule(function()
            pcall(form_p.focus_name, item_focus)
        end)
    end

    -- `l` / `h` switch tabs from the content body too (multi-tab) — not only while the tab bar is focused,
    -- matching the project panel. (Plain h/l are free on the body; the form owns j/k/<CR>.)
    if set_active_tab then
        local body_buf = st and st.panels and st.panels[1] and st.panels[1].buf
        if body_buf and vim.api.nvim_buf_is_valid(body_buf) then
            -- On a toolbar `bar` row, h/l move the focused button; otherwise they switch tabs.
            vim.keymap.set("n", "l", function()
                if not form_p.bar_nav(1) then
                    set_active_tab(st, active + 1)
                end
            end, { buffer = body_buf, nowait = true, silent = true })
            vim.keymap.set("n", "h", function()
                if not form_p.bar_nav(-1) then
                    set_active_tab(st, active - 1)
                end
            end, { buffer = body_buf, nowait = true, silent = true })
        end
    end

    -- The interactive handle the consumer drives (validity, repaint, re-fit, cursor query / move). The frame
    -- redesign dropped this rich API; restored here as a thin layer over the frame state + the form provider.
    local function panel_win()
        return st and st.panels and st.panels[1] and st.panels[1].win
    end
    return {
        --- Whether the content panel window is still open.
        ---@return boolean
        valid = function()
            local w = panel_win()
            return w ~= nil and vim.api.nvim_win_is_valid(w)
        end,
        --- Close the panel programmatically (full frame teardown — fires the close `callback`),
        --- as if the user pressed the close key. Lets a host tear the panel down on its own events.
        ---@return nil
        close = function()
            if st and st.close then
                st.close()
            end
        end,
        --- Re-paint the active tab's rows in place (after the consumer mutated row values).
        render = function()
            form_p.rerender()
        end,
        --- Re-read the active tab's (mutated) row set + rebuild its toolbar header bands, and re-fit — for a
        --- content/filter rebuild (e.g. the installer applying a filter). set_header relayouts.
        recalc = function()
            form_p.set_rows((split(active)))
            if st and st.set_header then
                st.set_header(header_spec())
            elseif st and st.relayout then
                st.relayout()
            end
            if st and st.set_counter then
                st.set_counter(opts.title_count) -- refresh the border counter for the rebuilt content
            end
        end,
        --- The `name` of the row under the cursor.
        ---@return string?
        cursor_name = function()
            return form_p.cursor_name()
        end,
        --- The 1-based window line of the cursor.
        ---@return integer
        cursor_index = function()
            return form_p.cursor_index()
        end,
        --- Move the cursor to the first row whose `name` matches (expanding its ancestors).
        ---@param name string
        ---@return boolean
        focus = function(name)
            return form_p.focus_name(name)
        end,
        --- Move the cursor to (a clamped) window line `i`.
        ---@param i integer
        ---@return boolean
        focus_index = function(i)
            return form_p.focus_index(i)
        end,
    }
end

--- Read-only info viewer — a 1-panel `frame` that scrolls the content, with a `q close` footer.
--- Returns the panel buffer + window (close via M.close_info or the frame's own keys).
--- NOTE: markview / syntax rendering is not yet ported (plain lines + optional `opts.highlights`).
---@param content string|string[]
---@param opts?   table
---@return integer|nil buf, integer|nil win
function M.info(content, opts)
    opts = opts or {}
    local lines = type(content) == "string" and vim.split(content, "\n")
        or (type(content) == "table" and vim.list_extend({}, content) or {})
    local buf_ref, win_ref
    local provider = {
        -- A read-only viewer may hide the hardware cursor (delegated to lvim-utils.cursor via FRAME_FT);
        -- the active line still reads via cursorline. Off by default (e.g. hover keeps the cursor).
        hide_cursor = opts.hide_cursor == true,
        size = function()
            local w = 1
            for _, l in ipairs(lines) do
                w = math.max(w, util.dw(l))
            end
            return w + 4, math.max(1, #lines)
        end,
        render = function()
            -- Accept BOTH the positional `{ row, c0, c1, hl[, prio] }` and the named
            -- `{ line, col_start, col_end, group }` highlight shapes (the LSP info builder uses the
            -- latter); a `-1` end_col means "to the end of the line".
            local hls = {}
            for _, h in ipairs(opts.highlights or {}) do
                local row = h.line ~= nil and h.line or h[1]
                local c0 = h.col_start ~= nil and h.col_start or h[2]
                local c1 = h.col_end ~= nil and h.col_end or h[3]
                if c1 == -1 then
                    c1 = #(lines[(row or 0) + 1] or "")
                end
                hls[#hls + 1] = { row, c0, c1, h.group or h[4], h[5] }
            end
            return lines, hls
        end,
        keys = function(_, p)
            buf_ref, win_ref = p.buf, p.win
            -- Line wrap is window-local — off by default (a viewer); a consumer may enable it (e.g. hover).
            if p.win and vim.api.nvim_win_is_valid(p.win) then
                vim.wo[p.win].wrap = opts.wrap == true
            end
            if opts.markview then
                -- Optional, explicit opt-in: render the WHOLE content buffer with markview.nvim (the frame
                -- keeps header/footer in separate buffers, so there is no row offset). Its decorations add
                -- virtual lines, so the rendered content can be taller than the raw line count.
                local pr_ok, mv_parser = pcall(require, "markview.parser")
                local rn_ok, mv_renderer = pcall(require, "markview.renderer")
                if pr_ok and rn_ok then
                    vim.bo[p.buf].filetype = "markdown"
                    local ac_ok, mv_actions = pcall(require, "markview.actions")
                    if ac_ok then
                        pcall(mv_actions.clear, p.buf)
                    end
                    local ok2, content = pcall(mv_parser.parse, p.buf, 0, -1, true)
                    if ok2 and content then
                        pcall(mv_renderer.render, p.buf, content)
                    end
                end
            elseif opts.filetype then
                -- Colour via the treesitter highlighter DIRECTLY — NEVER `:set filetype`. Setting the
                -- filetype would fire markview's auto-attach (it gates on `filetype`), which boxes code
                -- blocks with virtual lines + cursor-aware conceal. treesitter gives the same colours
                -- (headers, emphasis, fenced-code injections) with none of that. `conceallevel = 2` lets the
                -- markdown query hide the ``` fence delimiters (whole lines, via `conceal_lines`) and inline
                -- backticks; `concealcursor` keeps them hidden STABLY — never revealed on the cursor line.
                pcall(vim.treesitter.start, p.buf, opts.filetype)
                if p.win and vim.api.nvim_win_is_valid(p.win) then
                    vim.wo[p.win].conceallevel = 2
                    vim.wo[p.win].concealcursor = "nvic"
                end
            end
            if opts.on_open then
                opts.on_open(p.buf, p.win)
            end
        end,
    }
    -- Footer: the consumer's extra action buttons (`opts.footer_items` — e.g. fold all / unfold all),
    -- then the standard `q close`. Each is a footer action shorthand `{ key, name, run }`.
    local footer_items = {}
    for _, it in ipairs(opts.footer_items or {}) do
        footer_items[#footer_items + 1] = it
    end
    footer_items[#footer_items + 1] = {
        key = "q",
        name = "close",
        run = function(st)
            st.close()
        end,
    }
    frame.open({
        mode = "float",
        enter = opts.enter, -- false → open WITHOUT focusing (cursor stays in the editor, e.g. hover)
        position = opts.position, -- nil = centred; "cursor" anchors at the cursor (e.g. hover), "win", …
        border = opts.border or FRAME_BORDER,
        title = opts.title ~= false and (opts.title or "Info") or nil, -- border-title, blue-tinted
        title_pos = opts.title_pos, -- "left" (default) | "center" | "right" — title alignment
        close_keys = opts.close_keys or config.close_keys,
        keymaps = opts.keymaps,
        panel_border = "none",
        -- A given `width` / `height` is FIXED (a clean rectangle — e.g. the LSP info viewer, whose folded
        -- height the consumer computes); else auto-fit to content, capped by `max_width` / `max_height`
        -- (fraction ≤ 1 or absolute count; default 0.7 / 0.85). A cursor-anchored hover passes a tight cap.
        size = {
            width = type(opts.width) == "number" and { fixed = opts.width }
                or { auto = true, max = opts.max_width or 0.7 },
            height = type(opts.height) == "number" and { fixed = opts.height }
                or { auto = true, max = opts.max_height or 0.85 },
        },
        -- The info viewer IS the data-content panel → the single-source content ring (CONTENT_BORDER →
        -- config.content_border, resolved live). The `q close` footer is a nav bar, so it stays borderless.
        content = { blocks = { { id = "info", provider = provider, border = CONTENT_BORDER } } },
        footer = opts.footer == false and nil or { bars = { { items = footer_items } } },
    })
    return buf_ref, win_ref
end

--- Programmatically close an info window.
---@param win integer
function M.close_info(win)
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
end

--- Create an independent UI instance with its own config overrides.
--- Useful when multiple plugins share lvim-utils but need different colours/icons.
---
---@param instance_cfg? table  Any subset of the per-open opts + a `highlights` table:
---   highlights = { LvimUiTitle = { fg = "#..." }, ... }  -- per-instance hl overrides (named groups)
---   border/title_pos/position/close_keys/filetype/markview/footer_hints/layout/…  -- per-open DEFAULTS
--- The `highlights` are registered once here; everything ELSE is merged UNDER each presenter's per-call opts
--- (the caller's opts win) so the instance's frames carry its overrides instead of the raw module defaults.
--- NOTE: SIZE is NOT taken from here — it comes from the CENTRAL `lvim-utils.config.dock.geometry` (via the
--- surface's `size_spec` / `dock.slot`); pass an explicit per-call `width`/`height` on the opts to deviate.
---@return { select: fun(opts: table), multiselect: fun(opts: table),
---          input: fun(opts: table), confirm: fun(opts: table), tabs: fun(opts: table),
---          info: fun(content: any, opts: table): integer, integer }
function M.new(instance_cfg)
    instance_cfg = instance_cfg or {}
    -- Per-instance highlight overrides apply immediately — lvim-utils highlights are named groups.
    if type(instance_cfg.highlights) == "table" then
        pcall(function()
            require("lvim-utils.highlight").register(instance_cfg.highlights, true)
        end)
    end
    -- The rest becomes per-open DEFAULTS merged under each opts (opts wins, via tbl_deep_extend "keep").
    local defaults = {}
    for k, v in pairs(instance_cfg) do
        if k ~= "highlights" then
            defaults[k] = v
        end
    end
    --- Wrap a presenter so the instance defaults fill in any opts the caller left unset.
    ---@param fn fun(opts: table): any
    ---@return fun(opts?: table): any
    local function bind(fn)
        return function(opts)
            return fn(vim.tbl_deep_extend("keep", opts or {}, defaults))
        end
    end
    return {
        select = bind(M.select),
        multiselect = bind(M.multiselect),
        input = bind(M.input),
        confirm = bind(M.confirm),
        tabs = bind(M.tabs),
        info = function(content, opts)
            return M.info(content, vim.tbl_deep_extend("keep", opts or {}, defaults))
        end,
    }
end

return M
