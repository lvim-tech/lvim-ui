-- lvim-ui.winband: a button BAND pinned to an edge of a REAL window.
--
-- The surface chassis owns the bands of ITS frames; this is the same visual bar — a `ui.bar` of
-- `ui.button` chips on an `LvimUiBarFill` row — for a window the chassis does NOT own: a genuine
-- editable buffer in a tiled window (lvim-db's / lvim-rest's query editor), or a window Neovim itself
-- opens and closes (the quickfix window, whose buffer must stay the real `buftype=quickfix` one).
--
-- `side` picks the edge, and the two are not symmetric in what they cost the host:
--   • "bottom" (default) rides the host's last TEXT row, so the host keeps `scrolloff >= 1` and the
--     cursor line can never sit under the bar;
--   • "top" rides the host's WINBAR row (`row = -1`) — chrome, not text, so it costs the host no line
--     at all: nothing scrolls under it and a real buffer keeps every one of its rows. The band claims
--     that row by setting the host's `winbar` to a blank, and restores it on close.
-- A 1-row float follows the host through resizes/layout shifts; clicks are hit-tested against the
-- rendered chips through the GLOBAL mouse layer.
--
-- KEYBOARD NAV (opt-in `opts.nav_through`): the bar is a real LAYER in the window column's vertical
-- chain, never a legend to jump over. `handle.enter` steps from the host INTO the bar (`opts.enter_key`
-- binds that key on the host buffer, which is what makes it beat a global window-navigation mapping);
-- inside, `<C-l>`/`<C-h>` move between chips, `<CR>` runs one, the key pointing back at the host steps
-- out, and the one pointing PAST the bar runs `opts.nav_through` — so the chain is host → band → the
-- window beyond, in both directions, matching the native-split footer's nav.
--
---@module "lvim-ui.winband"

local api = vim.api
local uibar = require("lvim-ui.bar")
local util = require("lvim-ui.util")
local cursor = require("lvim-utils.cursor")

local M = {}

--- Live bands, by the window they ride. Read by the window-navigation layer (`M.at`) so a move INTO a
--- window stops on its band first — a band has to be a layer from BOTH sides, or the same bar behaves
--- differently depending on which direction you approach it from.
---@type table<integer, { side: string, enter: fun(): boolean? }>
local live = {}

--- The band on `side` of `win`, as a callable that focuses it — or nil when there is none. `enter`
--- returns true only when it actually landed, so a caller can fall back to a plain window move.
---@param win integer?
---@param side string?  "top" | "bottom"
---@return fun(): boolean?|nil
function M.at(win, side)
    local rec = win and live[win]
    if not (rec and side and rec.side == side) then
        return nil
    end
    return rec.enter
end

local NS = api.nvim_create_namespace("lvim-ui-winband")

-- Below every surface frame (containers start at zindex ~50): a window footer belongs to the TILED
-- layer, so any modal/popup opened above the window must also cover its bar.
local ZINDEX = 40

-- The focused-footer buffer wears this filetype so `lvim-utils.cursor` hides the hardware cursor while
-- the bar is the current window (it is chrome, not text) — registered once as a panel_ft.
local WF_FT = "lvim-ui-winband"
local ft_registered = false
local function register_ft()
    if not ft_registered then
        ft_registered = true
        pcall(cursor.register, { panel_ft = { WF_FT } })
    end
end

---@class LvimUiWinBand
---@field set fun(items: table[], align?: "left"|"center"|"right")  replace the bar's items and repaint
---@field place fun()   re-pin the float to the host's current geometry (auto-run on resize/scroll)
---@field close fun()   tear the bar down (auto-run when the host window closes)
---@field enter fun(): boolean?  step from the host window INTO the bar (keyboard nav; no-op without
---                             nav_through). Returns true when the bar took focus — `footernav.mark` needs that.

--- Attach a band to `win`. Items are `ui.button` element specs (build them with `surface.button` for
--- the canonical chips); a spec's `run` fires on mouse click OR on `<CR>` when the bar is
--- keyboard-focused. Pass `nav_through` to enable keyboard nav — the action that continues PAST the
--- band (the host's own `wincmd j` / `wincmd k`) — and `enter_key` to have the band bind the step-in
--- key on the host buffer itself.
---@param win integer
---@param opts { items: table[], align?: "left"|"center"|"right", side?: "top"|"bottom", nav_through?: fun(), nav_down?: fun(), enter_key?: string, suffix?: fun(): string, on_close?: fun() }
---@return LvimUiWinBand? handle  nil when `win` is not a valid window
function M.attach(win, opts)
    if not (win and api.nvim_win_is_valid(win)) then
        return nil
    end
    local state = {
        win = win,
        buf = nil, ---@type integer?
        fwin = nil, ---@type integer?
        items = (opts and opts.items) or {},
        align = (opts and opts.align) or "center",
        rendered = nil, ---@type table[]?  the last band's per-item ranges (mouse hit-testing + keyboard sel)
        -- `nav_down` is the original (bottom-only) name for the same thing: the action that continues
        -- PAST the band. Both are accepted so a bottom-bar consumer reads naturally either way.
        nav_through = opts and (opts.nav_through or opts.nav_down), ---@type fun()?
        side = (opts and opts.side) or "bottom", ---@type string
        suffix = opts and opts.suffix, ---@type fun(): string|nil  right-aligned trailing text
        on_close = opts and opts.on_close, ---@type fun()|nil
        winbar = nil, ---@type string?  the host's own winbar, restored on close (top side only)
        focused = false, -- the bar currently holds keyboard focus
        sel = 1, -- the selected chip index (into `rendered`)
        aug = nil, ---@type integer?
        scrolloff = nil, ---@type integer?  the host's own scrolloff, when the bar had to raise it
        closed = false,
    }
    if state.nav_through then
        register_ft()
    end
    if state.side == "top" then
        -- Claim the winbar row: the band is painted over it, so the host must HAVE one.
        state.winbar = vim.wo[state.win].winbar
        pcall(function()
            vim.wo[state.win].winbar = " "
        end)
    end

    local function close()
        if state.closed then
            return
        end
        state.closed = true
        live[state.win] = nil
        if state.aug then
            pcall(api.nvim_del_augroup_by_id, state.aug)
            state.aug = nil
        end
        if state.fwin and api.nvim_win_is_valid(state.fwin) then
            pcall(api.nvim_win_close, state.fwin, true)
        end
        state.fwin = nil
        if state.buf and api.nvim_buf_is_valid(state.buf) then
            pcall(api.nvim_buf_delete, state.buf, { force = true })
        end
        state.buf = nil
        -- The host window can outlive the bar (a footer detaches while its editor stays open), so put
        -- its scroll margin back exactly as it was — including a -1, which restores the global fallback.
        if state.scrolloff ~= nil and api.nvim_win_is_valid(state.win) then
            pcall(function()
                vim.wo[state.win].scrolloff = state.scrolloff
            end)
            state.scrolloff = nil
        end
        -- Give a top band's host back exactly the winbar it had (a string of its own, or none).
        if state.winbar ~= nil and api.nvim_win_is_valid(state.win) then
            pcall(function()
                vim.wo[state.win].winbar = state.winbar
            end)
            state.winbar = nil
        end
        if state.enter_key and api.nvim_buf_is_valid(state.host_buf or -1) then
            pcall(vim.keymap.del, "n", state.enter_key, { buffer = state.host_buf })
        end
        if state.on_close then
            pcall(state.on_close)
        end
    end

    --- Pin (or re-pin) the float on the host's last TEXT row.
    local function place()
        if state.closed or not api.nvim_win_is_valid(state.win) then
            return
        end
        if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
            return
        end
        local wi = vim.fn.getwininfo(state.win)[1]
        if not wi then
            return
        end
        local fpos = {
            relative = "win",
            win = state.win,
            -- "top" rides the WINBAR row (-1): chrome, so it costs the host no text line. "bottom"
            -- rides the last text row, which is why that side (and only that side) raises `scrolloff`.
            row = state.side == "top" and -1 or math.max(0, wi.height - 1),
            col = 0,
            width = api.nvim_win_get_width(state.win),
            height = 1,
        }
        if state.fwin and api.nvim_win_is_valid(state.fwin) then
            pcall(api.nvim_win_set_config, state.fwin, fpos)
        else
            -- Focusable ONLY with keyboard nav enabled (else focus must never enter this chrome bar).
            fpos.focusable = state.nav_through ~= nil
            fpos.style = "minimal"
            fpos.zindex = ZINDEX
            fpos.noautocmd = true
            state.fwin = api.nvim_open_win(state.buf, false, fpos)
            -- No float tint: the fill extmark paints the band; the gaps must show the HOST's own bg.
            vim.wo[state.fwin].winhighlight = "Normal:Normal,NormalFloat:Normal"
            vim.wo[state.fwin].wrap = false
            vim.wo[state.fwin].cursorline = false
        end
    end

    -- ── keyboard navigation ──────────────────────────────────────────────────
    -- The runnable (non-separator) chip indices, in order.
    local function selectable()
        local out = {}
        for i, it in ipairs(state.rendered or {}) do
            if not it.sep and it.spec and it.spec.run then
                out[#out + 1] = i
            end
        end
        return out
    end
    local function place_cursor()
        local it = state.rendered and state.rendered[state.sel]
        if it and it.c0 and state.fwin and api.nvim_win_is_valid(state.fwin) then
            pcall(api.nvim_win_set_cursor, state.fwin, { 1, it.c0 })
        end
    end

    local render -- forward decl (the nav fns re-render; render binds the nav keys on first paint)

    --- Descend from the host window INTO the bar (select the first chip, highlight it, hide the cursor).
    local function enter()
        if not (state.nav_through and state.fwin and api.nvim_win_is_valid(state.fwin)) then
            return
        end
        local sel = selectable()
        if #sel == 0 then
            return
        end
        state.focused = true
        state.sel = sel[1]
        api.nvim_set_current_win(state.fwin)
        render()
        place_cursor()
        cursor.update() -- WF_FT is a panel_ft → the hardware cursor hides while the bar is current
        return true
    end
    --- Step back UP to the host editor window, dropping the chip highlight.
    local function leave()
        state.focused = false
        render()
        if api.nvim_win_is_valid(state.win) then
            api.nvim_set_current_win(state.win)
        end
        cursor.update()
    end
    --- Move the selection one runnable chip left/right (clamped — no wrap).
    local function move(dir)
        local sel = selectable()
        if #sel == 0 then
            return
        end
        local pos = 1
        for i, idx in ipairs(sel) do
            if idx == state.sel then
                pos = i
            end
        end
        state.sel = sel[math.min(#sel, math.max(1, pos + dir))]
        render()
        place_cursor()
    end
    --- Run a chip's action FROM THE HOST WINDOW. The band is a float, so while it holds focus the
    --- current window is the band itself — an action that reads the cursor (open the entry under it) or
    --- splits "this" window would act on the chrome instead of the panel. Focusing the host first makes a
    --- button do exactly what its key does in the list, which is the whole promise of showing the key on it.
    ---@param it table?  the chip
    ---@return nil
    local function run_chip(it)
        if not (it and it.spec and it.spec.run) then
            return
        end
        if api.nvim_win_is_valid(state.win) then
            api.nvim_set_current_win(state.win)
        end
        it.spec.run()
    end

    --- Run the selected chip's action (the exact handler a mouse click fires).
    local function activate()
        run_chip(state.rendered and state.rendered[state.sel])
    end
    --- Continue DOWN past the bar: leave the float for the host, then run the host's own down-nav
    --- (`wincmd j`) so the vertical chain is editor → footer → window below — the footer never skipped.
    local function continue_down()
        state.focused = false
        render()
        -- Remember this descent so a `<C-k>` back up returns to THIS bar (layer-by-layer, in this column).
        require("lvim-ui.footernav").mark(state.win, enter)
        if api.nvim_win_is_valid(state.win) then
            api.nvim_set_current_win(state.win) -- `wincmd j` from a float would not walk the tiled layout
        end
        pcall(state.nav_through)
        cursor.update()
    end

    --- Render the band into the float's buffer (line + fill + item spans), then re-pin.
    render = function()
        if state.closed or not api.nvim_win_is_valid(state.win) then
            return
        end
        if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
            state.buf = api.nvim_create_buf(false, true)
            vim.bo[state.buf].bufhidden = "wipe"
            -- Clicks through the GLOBAL mouse layer, hit-tested against the rendered chip ranges.
            require("lvim-utils.mouse").register_click(state.buf, function(_line, col0)
                if vim.o.mouse == "" then
                    return
                end
                for _, it in ipairs(state.rendered or {}) do
                    if it.c0 and col0 >= it.c0 and col0 < it.c1 and it.spec and it.spec.run then
                        run_chip(it)
                        return
                    end
                end
            end)
            -- Keyboard nav: the bar is a focusable layer. Register its cursor-hide ft + bind the in-bar keys.
            if state.nav_through then
                vim.bo[state.buf].filetype = WF_FT
                local function fmap(lhs, fn)
                    for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
                        vim.keymap.set("n", l, fn, { buffer = state.buf, nowait = true, silent = true })
                    end
                end
                -- Which chord leaves the band and which continues PAST it depends on the side: a
                -- bottom band sits below the host (so `<C-k>` goes back up to it), a top band above.
                local out_key = state.side == "top" and "<C-j>" or "<C-k>"
                local through_key = state.side == "top" and "<C-k>" or "<C-j>"
                fmap({ out_key, "<Esc>", "q" }, leave)
                fmap(through_key, continue_down)
                fmap({ "h", "<Left>", "<C-h>" }, function()
                    move(-1)
                end)
                fmap({ "l", "<Right>", "<C-l>" }, function()
                    move(1)
                end)
                fmap({ "<CR>", "<Space>" }, activate)
            end
        end
        local hov = state.focused and state.sel or nil
        local width = api.nvim_win_get_width(state.win)
        -- A right-aligned trailing note (an entry count), re-read on every paint so it tracks the content
        -- below rather than whatever it said when the band was attached.
        local suffix = state.suffix and state.suffix() or nil
        local band = uibar.render({
            items = state.items,
            width = (suffix and suffix ~= "") and math.max(1, width - util.dw(suffix) - 1) or width,
            align = state.align,
            hover = hov,
            sel = hov,
        })
        state.rendered = band.items
        local line = band.line
        if suffix and suffix ~= "" then
            line = line .. string.rep(" ", math.max(0, width - util.dw(line) - util.dw(suffix))) .. suffix
        end
        vim.bo[state.buf].modifiable = true
        api.nvim_buf_set_lines(state.buf, 0, -1, false, { line })
        vim.bo[state.buf].modifiable = false
        api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
        pcall(api.nvim_buf_set_extmark, state.buf, NS, 0, 0, {
            end_row = 1,
            hl_eol = true,
            hl_group = "LvimUiBarFill",
            priority = 90,
        })
        for _, s in ipairs(band.spans) do
            pcall(api.nvim_buf_set_extmark, state.buf, NS, 0, s[1], {
                end_col = s[2],
                hl_group = s[3],
                priority = 200,
            })
        end
        place()
    end

    -- The cursor line must never end up UNDER a BOTTOM bar: keep at least one bottom scroll margin. A top
    -- band rides the winbar row, outside the text area, so it needs none of this. Read the
    -- EFFECTIVE value first — a window-local `scrolloff` of -1 means "use the global one", so comparing
    -- the raw local value would treat a user's `set scrolloff=8` as 0 and then sever the global fallback
    -- by writing a literal 1. Only a genuinely too-small effective margin is raised, and the original is
    -- remembered so `close()` can put it back.
    if state.side ~= "top" then
        local effective = vim.wo[win].scrolloff
        if effective < 0 then
            effective = vim.o.scrolloff
        end
        if effective < 1 then
            state.scrolloff = vim.wo[win].scrolloff
            vim.wo[win].scrolloff = 1
        end
    end

    state.aug = api.nvim_create_augroup("LvimUiWinBand" .. win, { clear = true })
    -- Follow the host through anything that moves/resizes it.
    api.nvim_create_autocmd({ "WinResized", "WinScrolled" }, {
        group = state.aug,
        callback = function()
            local ev = vim.v.event or {}
            for _, w in ipairs(ev.windows or {}) do
                if w == state.win then
                    render()
                    return
                end
            end
        end,
    })
    api.nvim_create_autocmd("VimResized", {
        group = state.aug,
        callback = function()
            render()
        end,
    })
    api.nvim_create_autocmd("WinClosed", {
        group = state.aug,
        pattern = tostring(win),
        callback = close,
    })

    -- Bind the step-in key on the HOST buffer, when the consumer asked for one. Buffer-local is the
    -- point: a global window-navigation mapping (`<C-k>` = window up) would otherwise win, and the band
    -- would be reachable from everywhere except the panel it belongs to.
    state.host_buf = api.nvim_win_get_buf(win)
    if opts and opts.enter_key and opts.enter_key ~= "" then
        state.enter_key = opts.enter_key
        vim.keymap.set("n", state.enter_key, function()
            enter()
        end, { buffer = state.host_buf, nowait = true, silent = true })
    end
    -- Published for the window-navigation layer: a move INTO this window from the band's side lands here.
    if state.nav_through then
        live[win] = { side = state.side, enter = enter }
    end

    render()

    return {
        set = function(items, align)
            state.items = items or {}
            if align then
                state.align = align
            end
            render()
        end,
        place = place,
        close = close,
        enter = enter,
    }
end

return M
