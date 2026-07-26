-- lvim-ui.winfooter: a button FOOTER BAR pinned to the bottom row of a REAL window.
--
-- The surface chassis owns footers for ITS frames; this is the same visual band — a `ui.bar` of
-- `ui.button` chips on an `LvimUiBarFill` row — for a window the chassis does NOT own: a genuine
-- editable buffer in a tiled window (lvim-db's / lvim-rest's query editor). A 1-row float rides
-- `relative = "win"` on the host's last text row and follows it through resizes/layout shifts; clicks
-- are hit-tested against the rendered chips through the GLOBAL mouse layer.
--
-- KEYBOARD NAV (opt-in `opts.nav_down`): the bar is a real LAYER in the window column's vertical chain.
-- The host binds `<C-j>` → `handle.enter` (descend from the editor INTO the bar); inside the bar
-- `<C-l>`/`<C-h>` move between chips, `<CR>` runs one, `<C-k>`/`<Esc>`/`q` step back UP to the editor,
-- and `<C-j>` runs `opts.nav_down` (the editor's own `wincmd j`) to descend onto the window BELOW — so
-- the footer is never skipped (panel → footer → window below), matching the native-split footer's nav.
--
---@module "lvim-ui.winfooter"

local api = vim.api
local uibar = require("lvim-ui.bar")
local cursor = require("lvim-utils.cursor")

local M = {}

local NS = api.nvim_create_namespace("lvim-ui-winfooter")

-- Below every surface frame (containers start at zindex ~50): a window footer belongs to the TILED
-- layer, so any modal/popup opened above the window must also cover its bar.
local ZINDEX = 40

-- The focused-footer buffer wears this filetype so `lvim-utils.cursor` hides the hardware cursor while
-- the bar is the current window (it is chrome, not text) — registered once as a panel_ft.
local WF_FT = "lvim-ui-winfooter"
local ft_registered = false
local function register_ft()
    if not ft_registered then
        ft_registered = true
        pcall(cursor.register, { panel_ft = { WF_FT } })
    end
end

---@class LvimUiWinFooter
---@field set fun(items: table[], align?: "left"|"center"|"right")  replace the bar's items and repaint
---@field place fun()   re-pin the float to the host's current geometry (auto-run on resize/scroll)
---@field close fun()   tear the bar down (auto-run when the host window closes)
---@field enter fun(): boolean?  descend from the host window INTO the bar (keyboard nav; no-op without
---                             nav_down). Returns true when the bar took focus — `footernav.mark` needs that.

--- Attach a footer bar to `win`. Items are `ui.button` element specs (build them with
--- `surface.button` for the canonical chips); a spec's `run` fires on mouse click OR on `<CR>` when the
--- bar is keyboard-focused. Pass `nav_down` to enable keyboard nav: the host binds `<C-j>` → `enter`.
---@param win integer
---@param opts { items: table[], align?: "left"|"center"|"right", nav_down?: fun() }
---@return LvimUiWinFooter? handle  nil when `win` is not a valid window
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
        nav_down = opts and opts.nav_down, ---@type fun()?  descend past the bar (the host's own `wincmd j`)
        focused = false, -- the bar currently holds keyboard focus
        sel = 1, -- the selected chip index (into `rendered`)
        aug = nil, ---@type integer?
        scrolloff = nil, ---@type integer?  the host's own scrolloff, when the bar had to raise it
        closed = false,
    }
    if state.nav_down then
        register_ft()
    end

    local function close()
        if state.closed then
            return
        end
        state.closed = true
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
            row = math.max(0, wi.height - 1),
            col = 0,
            width = api.nvim_win_get_width(state.win),
            height = 1,
        }
        if state.fwin and api.nvim_win_is_valid(state.fwin) then
            pcall(api.nvim_win_set_config, state.fwin, fpos)
        else
            -- Focusable ONLY with keyboard nav enabled (else focus must never enter this chrome bar).
            fpos.focusable = state.nav_down ~= nil
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
        if not (state.nav_down and state.fwin and api.nvim_win_is_valid(state.fwin)) then
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
    --- Run the selected chip's action (the exact handler a mouse click fires).
    local function activate()
        local it = state.rendered and state.rendered[state.sel]
        if it and it.spec and it.spec.run then
            it.spec.run()
        end
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
        pcall(state.nav_down)
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
                        it.spec.run()
                        return
                    end
                end
            end)
            -- Keyboard nav: the bar is a focusable layer. Register its cursor-hide ft + bind the in-bar keys.
            if state.nav_down then
                vim.bo[state.buf].filetype = WF_FT
                local function fmap(lhs, fn)
                    for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
                        vim.keymap.set("n", l, fn, { buffer = state.buf, nowait = true, silent = true })
                    end
                end
                fmap({ "<C-k>", "<Esc>", "q" }, leave)
                fmap("<C-j>", continue_down)
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
        local band = uibar.render({
            items = state.items,
            width = api.nvim_win_get_width(state.win),
            align = state.align,
            hover = hov,
            sel = hov,
        })
        state.rendered = band.items
        vim.bo[state.buf].modifiable = true
        api.nvim_buf_set_lines(state.buf, 0, -1, false, { band.line })
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

    -- The cursor line must never end up UNDER the bar: keep at least one bottom scroll margin. Read the
    -- EFFECTIVE value first — a window-local `scrolloff` of -1 means "use the global one", so comparing
    -- the raw local value would treat a user's `set scrolloff=8` as 0 and then sever the global fallback
    -- by writing a literal 1. Only a genuinely too-small effective margin is raised, and the original is
    -- remembered so `close()` can put it back.
    local effective = vim.wo[win].scrolloff
    if effective < 0 then
        effective = vim.o.scrolloff
    end
    if effective < 1 then
        state.scrolloff = vim.wo[win].scrolloff
        vim.wo[win].scrolloff = 1
    end

    state.aug = api.nvim_create_augroup("LvimUiWinFooter" .. win, { clear = true })
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
