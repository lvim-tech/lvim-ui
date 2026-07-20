-- lvim-ui.winfooter: a button FOOTER BAR pinned to the bottom row of a REAL window.
--
-- The surface chassis owns footers for ITS frames; this is the same visual band — a `ui.bar` of
-- `ui.button` chips on an `LvimUiBarFill` row — for a window the chassis does NOT own: a genuine
-- editable buffer in a tiled window (lvim-db's query editor is the first consumer). A 1-row,
-- non-focusable float rides `relative = "win"` on the host's last text row and follows it through
-- resizes/layout shifts; clicks are hit-tested against the rendered chips through the GLOBAL mouse
-- layer (the float is never focused, so a buffer-local map could not fire — the same reasoning as
-- the chassis' native-split footer). The bar DISPLAYS keys and runs actions on click — it never
-- binds a key itself: the host buffer owns its own keymaps.
--
-- The host window keeps `scrolloff >= 1` so the CURSOR line can never sit under the bar (the
-- reserve philosophy of the native-split footer, minus the buffer-side row reserve — an EDITABLE
-- buffer's lines belong to the user, so the bar only guarantees the cursor stays clear).
--
---@module "lvim-ui.winfooter"

local api = vim.api
local uibar = require("lvim-ui.bar")

local M = {}

local NS = api.nvim_create_namespace("lvim-ui-winfooter")

-- Below every surface frame (containers start at zindex ~50): a window footer belongs to the TILED
-- layer, so any modal/popup opened above the window must also cover its bar.
local ZINDEX = 40

---@class LvimUiWinFooter
---@field set fun(items: table[], align?: "left"|"center"|"right")  replace the bar's items and repaint
---@field place fun()   re-pin the float to the host's current geometry (auto-run on resize/scroll)
---@field close fun()   tear the bar down (auto-run when the host window closes)

--- Attach a footer bar to `win`. Items are `ui.button` element specs (build them with
--- `surface.button` for the canonical chips); a spec's `run` fires on mouse click.
---@param win integer
---@param opts { items: table[], align?: "left"|"center"|"right" }
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
        rendered = nil, ---@type table[]?  the last band's per-item ranges (mouse hit-testing)
        aug = nil, ---@type integer?
        closed = false,
    }

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
    end

    --- Pin (or re-pin) the float on the host's last TEXT row. `getwininfo().height` is
    --- winbar-exclusive and a `relative = "win"` float's row 0 is the first text row below the
    --- winbar, so `text_h - 1` is exactly the bottom row whatever chrome the host carries.
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
            fpos.focusable = false
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

    --- Render the band into the float's buffer (line + fill + item spans), then re-pin.
    local function render()
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
        end
        local band = uibar.render({
            items = state.items,
            width = api.nvim_win_get_width(state.win),
            align = state.align,
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

    -- The cursor line must never end up UNDER the bar: keep at least one bottom scroll margin.
    if vim.wo[win].scrolloff < 1 then
        vim.wo[win].scrolloff = 1
    end

    state.aug = api.nvim_create_augroup("LvimUiWinFooter" .. win, { clear = true })
    -- Follow the host through anything that moves/resizes it. WinResized/WinScrolled report the
    -- affected windows in v.event; re-pin whenever ours is among them (or on a global resize).
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
    }
end

return M
