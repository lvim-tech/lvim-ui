-- lvim-ui.menu: the cursor-anchored, NON-FOCUSABLE completion-menu primitive — a passive
-- projection redrawn per keystroke while focus STAYS in the editing buffer (insert mode).
-- Every other lvim-ui shape (select/tabs/surface) is a FOCUSED modal: sectors, C-j/C-k,
-- close keys and cursor hiding all presuppose focus, and tearing a surface down/up per
-- keystroke is the wrong weight. This preset is the sanctioned home for that different
-- interaction model — consumers (lvim-cmp) NEVER open their own float.
--
-- Mechanics (the per-keystroke fast path):
--   • ONE long-lived scratch buffer + window (`focusable = false`, `noautocmd = true`),
--     REPOSITIONED via nvim_win_set_config — never recreated per keystroke.
--   • Keyword-anchored geometry: the window is glued to a (lnum, col) anchor — the start
--     of the matched keyword — so it does NOT shift while the user types; direction flips
--     (below/above) via `direction_priority` when the screen edge is near.
--   • Rows are BOX lists (the ui.button box model reused as data): lead kind box + label
--     + right-aligned detail. The buffer holds PLAIN text; ALL colour is applied by a
--     `nvim_set_decoration_provider` as EPHEMERAL extmarks on the VISIBLE lines only —
--     match positions are computed lazily per visible row (persistent extmarks per
--     keystroke are the slow path this design exists to avoid).
--   • Selection = cursorline canon: nvim_win_set_cursor in the non-focused window (which
--     also scrolls the view) + a bg-only CursorLine group, so row colours survive.
--   • A sibling DOCS slot: a second non-focusable window glued beside the menu, kept
--     aligned through every reposition.
-- Theming: the standard pipeline — a highlight.bind factory over the live palette; no
-- cursor hiding needed (focus never enters the menu).
--
---@module "lvim-ui.menu"

local util = require("lvim-ui.util")
local hl = require("lvim-utils.highlight")

local api = vim.api

local M = {}

-- ─── theming (the standard build()-factory pipeline) ─────────────────────────

hl.bind(function(c)
    c = c or require("lvim-utils.colors")
    ---@param color string
    ---@param t number
    ---@return string
    local function mtint(color, t)
        return hl.blend(color, c.bg, t)
    end
    -- Same panel-bg rule as the shared chrome (config/highlight.lua): follow the theme's
    -- float shade when synced, else the transparent-or-bg_dark fallback.
    local panel_bg = c.bg_float or (c.transparent and c.none or c.bg_dark)
    return {
        LvimUiMenuNormal = { bg = panel_bg, fg = c.fg },
        -- Selection is BG-ONLY so each row's own fg colours (kind boxes, match chars) survive it.
        LvimUiMenuSel = { bg = mtint(c.blue, 0.15) },
        LvimUiMenuMatch = { fg = c.red, bold = true },
        LvimUiMenuDetail = { fg = c.comment },
        LvimUiMenuThumb = { bg = mtint(c.blue, 0.5) },
        LvimUiMenuTrack = { bg = mtint(c.blue, 0.08) },
    }
end)

-- ─── types ────────────────────────────────────────────────────────────────────

---@class LvimUiMenuBox                     one cell of a menu row (the ui.button box model as data)
---@field text string                       the box text (already padded by the consumer if it wants a fixed column)
---@field hl? string                        highlight group for the whole box
---@field right? boolean                    right-align this box (detail column); the gap is space-filled
---@field positions? fun(): integer[]?      LAZY matched-char byte columns (1-based, within `text`) — called
---                                         only when the row is VISIBLE, once per render generation
---@field match_hl? string                  group for the matched chars (default the menu's `match` group)

---@class LvimUiMenuRow
---@field boxes LvimUiMenuBox[]

---@class LvimUiMenuAnchor                  where the menu is glued: the matched keyword's START
---@field lnum integer                      1-based buffer line in the anchor window
---@field col integer                       0-based byte column of the keyword start
---@field win? integer                      the anchor window (default: current)

---@class LvimUiMenuOpts
---@field max_height? integer               visible rows cap (default 12; longer lists scroll)
---@field max_width? integer                content width cap in cells (default 60)
---@field min_width? integer                content width floor (default 0)
---@field col_offset? integer               shift the window left/right of the anchor col (e.g. minus the
---                                         lead kind-box width, so the LABEL column sits on the keyword)
---@field direction_priority? string[]      "s" (below) / "n" (above), tried in order (default { "s", "n" })
---@field scrollbar? boolean                paint a right-edge thumb when the list overflows (default true)
---@field zindex? integer                   window stack position (default 65 — above floats, below msgarea)
---@field docs? { max_width?: integer, max_height?: integer }  the sibling docs slot's caps (80 × 20)
---@field hl? { normal?: string, selection?: string, match?: string, thumb?: string, track?: string }

---@class LvimUiMenuShowOpts
---@field items LvimUiMenuRow[]
---@field anchor LvimUiMenuAnchor
---@field selected? integer                 initial selection (nil = none)

-- Handle instance counter — each handle owns a private namespace for its decoration provider.
---@type integer
local seq = 0

-- ─── the handle ───────────────────────────────────────────────────────────────

--- Create a menu handle. The handle owns one long-lived buffer (+ its decoration provider)
--- and shows/hides/repositions one window — create it ONCE per consumer, drive it per keystroke.
---@param opts? LvimUiMenuOpts
---@return table handle  see the `handle` table below for the full method set
function M.new(opts)
    opts = opts or {}
    seq = seq + 1
    local ns = api.nvim_create_namespace("lvim_ui_menu_" .. seq)

    local max_height = opts.max_height or 12
    local max_width = opts.max_width or 60
    local min_width = opts.min_width or 0
    local col_offset = opts.col_offset or 0
    local dirs = opts.direction_priority or { "s", "n" }
    local scrollbar = opts.scrollbar ~= false
    local zindex = opts.zindex or 65
    local docs_caps = opts.docs or {}
    local groups = {
        normal = (opts.hl and opts.hl.normal) or "LvimUiMenuNormal",
        selection = (opts.hl and opts.hl.selection) or "LvimUiMenuSel",
        match = (opts.hl and opts.hl.match) or "LvimUiMenuMatch",
        thumb = (opts.hl and opts.hl.thumb) or "LvimUiMenuThumb",
        track = (opts.hl and opts.hl.track) or "LvimUiMenuTrack",
    }

    ---@class LvimUiMenuState
    local state = {
        buf = nil, ---@type integer?      the long-lived scratch buffer
        win = nil, ---@type integer?      the menu window (nil while hidden)
        docs_buf = nil, ---@type integer?
        docs_win = nil, ---@type integer?
        items = {}, ---@type LvimUiMenuRow[]
        anchor = nil, ---@type LvimUiMenuAnchor?
        selected = nil, ---@type integer?
        width = 0, ---@type integer       current content width (cells)
        height = 0, ---@type integer      current window height (rows)
        row = 0, ---@type integer         current editor-relative window row
        col = 0, ---@type integer         current editor-relative window col
        -- per-render metadata the decoration provider reads: rows_meta[i] = { spans, pos }
        rows_meta = {}, ---@type table[]
        pos_cache = {}, ---@type table<integer, integer[]|false>  lazy positions per row (false = none)
        thumb_from = 0, ---@type integer  scrollbar thumb range (1-based rows; 0 = no bar)
        thumb_to = 0, ---@type integer
    }

    --- The long-lived scratch buffer (created on first use).
    ---@return integer
    local function ensure_buf()
        if state.buf and api.nvim_buf_is_valid(state.buf) then
            return state.buf
        end
        local buf = api.nvim_create_buf(false, true)
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "hide"
        vim.bo[buf].swapfile = false
        vim.bo[buf].undolevels = -1
        vim.bo[buf].filetype = "lvim-ui-menu"
        state.buf = buf
        return buf
    end

    -- ─── decoration provider: EPHEMERAL highlights on VISIBLE rows only ──────
    -- The buffer holds plain text; every span (box colours, match chars, scrollbar) is
    -- an ephemeral extmark applied per redraw, only for the lines the window shows.
    api.nvim_set_decoration_provider(ns, {
        on_win = function(_, winid, bufnr, topline, botline)
            if winid ~= state.win or bufnr ~= state.buf then
                return false
            end
            -- Scrollbar thumb range for THIS view (topline/botline are 0-based).
            state.thumb_from, state.thumb_to = 0, 0
            local total = #state.items
            if scrollbar and total > state.height and state.height > 0 then
                local span = math.max(1, math.floor(state.height * state.height / total + 0.5))
                local from = math.floor(topline * (state.height - span) / math.max(1, total - state.height) + 0.5)
                state.thumb_from = topline + from + 1
                state.thumb_to = state.thumb_from + span - 1
            end
            local _ = botline
            return true
        end,
        on_line = function(_, winid, bufnr, row)
            if winid ~= state.win or bufnr ~= state.buf then
                return
            end
            local meta = state.rows_meta[row + 1]
            if not meta then
                return
            end
            for _, s in ipairs(meta.spans) do
                api.nvim_buf_set_extmark(bufnr, ns, row, s[1], {
                    end_col = s[2],
                    hl_group = s[3],
                    ephemeral = true,
                    strict = false,
                })
            end
            -- Matched-char columns: computed LAZILY, only for rows that actually reach the
            -- screen, once per render generation (pos_cache is cleared on every update).
            if meta.pos then
                local cached = state.pos_cache[row + 1]
                if cached == nil then
                    cached = meta.pos.fn() or false
                    state.pos_cache[row + 1] = cached
                end
                if cached then
                    for _, p in ipairs(cached) do
                        local c0 = meta.pos.off + p - 1
                        api.nvim_buf_set_extmark(bufnr, ns, row, c0, {
                            end_col = c0 + 1,
                            hl_group = meta.pos.hl,
                            ephemeral = true,
                            strict = false,
                        })
                    end
                end
            end
            -- Scrollbar: a 1-cell overlay glued to the window's right edge (virt_text, so it
            -- lands on the last CELL regardless of the line's byte layout).
            if state.thumb_from > 0 then
                local r1 = row + 1
                local g = (r1 >= state.thumb_from and r1 <= state.thumb_to) and groups.thumb or groups.track
                api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
                    virt_text = { { " ", g } },
                    virt_text_pos = "right_align",
                    ephemeral = true,
                })
            end
        end,
    })

    -- ─── render: rows → plain lines + span metadata ───────────────────────────

    --- Rebuild the buffer lines and the decoration metadata from `state.items`, and compute
    --- the content width. Called on every show/update — the hot path, so it only writes
    --- plain text (colours are ephemeral, see above).
    local function render()
        local buf = ensure_buf()
        local items = state.items
        -- content width: widest row, clamped to [min_width, max_width]; +1 cell for the scrollbar
        local w = min_width
        local widths = {} ---@type integer[][]  per row: each box's display width
        for i, row in ipairs(items) do
            local bw, total = {}, 0
            for bi, box in ipairs(row.boxes) do
                bw[bi] = util.dw(box.text)
                total = total + bw[bi]
            end
            widths[i] = bw
            w = math.max(w, total + 1) -- +1: minimum gap before a right box / trailing air
        end
        w = math.min(w, max_width)
        local sb = (scrollbar and #items > math.min(#items, max_height) and 1 or 0)
        -- the window is w + sb wide; text stays w wide so the bar never covers content
        state.width = w + sb

        local lines = {}
        state.rows_meta = {}
        state.pos_cache = {}
        for i, row in ipairs(items) do
            local left, right = {}, {}
            local left_w, right_w = 0, 0
            local spans = {}
            local pos_meta = nil
            -- byte offset accumulates as boxes are concatenated; right boxes are appended
            -- after the space fill, so their offsets are resolved afterwards
            for bi, box in ipairs(row.boxes) do
                if box.right then
                    right[#right + 1] = { box = box, w = widths[i][bi] }
                    right_w = right_w + widths[i][bi]
                else
                    left[#left + 1] = { box = box, w = widths[i][bi] }
                    left_w = left_w + widths[i][bi]
                end
            end
            -- clip: drop the right column entirely when it does not fit beside the left one
            if right_w > 0 and left_w + right_w + 1 > w then
                right, right_w = {}, 0
            end
            local parts, off = {}, 0
            for _, e in ipairs(left) do
                local text = e.box.text
                if off == 0 and e.w > w then
                    text = util.truncate(text, w) -- a single over-wide box is clipped, not overflowed
                end
                parts[#parts + 1] = text
                local b = #text
                if e.box.hl then
                    spans[#spans + 1] = { off, off + b, e.box.hl }
                end
                if e.box.positions then
                    pos_meta = { off = off, fn = e.box.positions, hl = e.box.match_hl or groups.match }
                end
                off = off + b
            end
            local fill = w - left_w - right_w
            if fill > 0 then
                parts[#parts + 1] = string.rep(" ", fill)
                off = off + fill
            end
            for _, e in ipairs(right) do
                parts[#parts + 1] = e.box.text
                local b = #e.box.text
                if e.box.hl then
                    spans[#spans + 1] = { off, off + b, e.box.hl }
                end
                off = off + b
            end
            local line = table.concat(parts)
            if util.dw(line) > w then
                line = util.truncate(line, w)
            end
            lines[i] = line .. (sb == 1 and " " or "") -- reserve the scrollbar cell
            state.rows_meta[i] = { spans = spans, pos = pos_meta }
        end
        vim.bo[buf].modifiable = true
        api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
    end

    -- ─── geometry: keyword-anchored, no-shift, edge-flip ──────────────────────

    --- Resolve the window geometry against the CURRENT screen. Returns nil when the anchor
    --- is off-screen (the menu should hide rather than float detached).
    ---@return { row: integer, col: integer, height: integer }?
    local function geometry()
        local a = state.anchor
        if not a then
            return nil
        end
        local awin = (a.win and api.nvim_win_is_valid(a.win)) and a.win or api.nvim_get_current_win()
        -- screenpos: 1-based screen cell of the anchor (keyword start) — col+1 → byte → virtcol
        local sp = vim.fn.screenpos(awin, a.lnum, a.col + 1)
        if sp.row == 0 then
            return nil
        end
        -- usable rows end above the cmdline AND the statusline (laststatus 2/3 always;
        -- laststatus 1 only when a second non-floating window shows it)
        local status_rows = 0
        if vim.o.laststatus >= 2 then
            status_rows = 1
        elseif vim.o.laststatus == 1 then
            for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
                if w ~= awin and api.nvim_win_get_config(w).relative == "" then
                    status_rows = 1
                    break
                end
            end
        end
        local editor_h = vim.o.lines - vim.o.cmdheight - status_rows
        local want = math.min(#state.items, max_height)
        if want == 0 then
            return nil
        end
        -- direction: first priority entry with FULL room, else the roomier side (shrunk to fit)
        local below_avail = editor_h - sp.row
        local above_avail = sp.row - 1
        local dir, avail
        for _, d in ipairs(dirs) do
            local av = (d == "s") and below_avail or above_avail
            if av >= want then
                dir, avail = d, av
                break
            end
        end
        if not dir then
            if below_avail >= above_avail then
                dir, avail = "s", below_avail
            else
                dir, avail = "n", above_avail
            end
        end
        local height = math.max(1, math.min(want, avail))
        local row = (dir == "s") and sp.row or (sp.row - 1 - height)
        -- col: glued to the keyword start (+ the consumer's offset), clamped to the right edge
        local col = math.max(0, math.min(sp.col - 1 + col_offset, vim.o.columns - state.width))
        return { row = row, col = col, height = height }
    end

    --- Apply selection state to the window (cursorline + cursor row → auto-scroll).
    local function apply_selection()
        local win = state.win
        if not (win and api.nvim_win_is_valid(win)) then
            return
        end
        if state.selected and state.items[state.selected] then
            vim.wo[win].cursorline = true
            pcall(api.nvim_win_set_cursor, win, { state.selected, 0 })
        else
            vim.wo[win].cursorline = false
            pcall(api.nvim_win_set_cursor, win, { 1, 0 })
        end
    end

    local reposition_docs -- forward decl (docs glue runs on every menu reposition)

    --- Open or reposition the window for the current items/anchor. Hides when the anchor
    --- left the screen or there is nothing to show.
    ---@param handle table
    local function place(handle)
        local geo = geometry()
        if not geo then
            handle.hide()
            return
        end
        state.height = geo.height
        state.row, state.col = geo.row, geo.col
        local cfg = {
            relative = "editor",
            row = geo.row,
            col = geo.col,
            width = math.max(1, state.width),
            height = geo.height,
        }
        if state.win and api.nvim_win_is_valid(state.win) then
            api.nvim_win_set_config(state.win, cfg) -- REPOSITIONED, never recreated
        else
            cfg.style = "minimal"
            cfg.focusable = false
            cfg.noautocmd = true
            cfg.zindex = zindex
            state.win = api.nvim_open_win(ensure_buf(), false, cfg)
            local win = state.win
            vim.wo[win].winhighlight = ("Normal:%s,NormalFloat:%s,CursorLine:%s,Search:None"):format(
                groups.normal,
                groups.normal,
                groups.selection
            )
            vim.wo[win].wrap = false
            vim.wo[win].scrolloff = 0
            vim.wo[win].sidescrolloff = 0
            vim.wo[win].cursorlineopt = "line"
            vim.wo[win].winfixbuf = true
        end
        apply_selection()
        if reposition_docs then
            reposition_docs()
        end
    end

    -- ─── the sibling DOCS slot ────────────────────────────────────────────────

    ---@type { width: integer, height: integer }?  the docs content size (while shown)
    local docs_size = nil

    --- Re-glue the docs window beside the menu (east, flipping west near the edge),
    --- top-aligned with the menu row. Runs on every menu reposition.
    reposition_docs = function()
        local dwin = state.docs_win
        if not (dwin and api.nvim_win_is_valid(dwin)) or not docs_size then
            return
        end
        if not (state.win and api.nvim_win_is_valid(state.win)) then
            return
        end
        local east_col = state.col + state.width + 1
        local east_room = vim.o.columns - east_col
        local col
        if east_room >= docs_size.width then
            col = east_col
        else
            col = math.max(0, state.col - 1 - docs_size.width)
        end
        api.nvim_win_set_config(dwin, {
            relative = "editor",
            row = state.row,
            col = col,
            width = docs_size.width,
            height = math.min(docs_size.height, math.max(1, vim.o.lines - vim.o.cmdheight - state.row)),
        })
    end

    -- ─── the public handle ────────────────────────────────────────────────────

    local handle = {}

    --- Whether the menu window is currently on screen.
    ---@return boolean
    function handle.visible()
        return state.win ~= nil and api.nvim_win_is_valid(state.win)
    end

    --- Show the menu (or re-show it) with a fresh item set at an anchor.
    ---@param show LvimUiMenuShowOpts
    function handle.show(show)
        state.items = show.items or {}
        state.anchor = show.anchor or state.anchor
        state.selected = show.selected
        if #state.items == 0 or not state.anchor then
            handle.hide()
            return
        end
        render()
        place(handle)
    end

    --- Replace the items (per-keystroke re-rank) keeping the current anchor. The selection
    --- resets (pass `selected` to preserve/preselect).
    ---@param items LvimUiMenuRow[]
    ---@param selected? integer
    function handle.update(items, selected)
        handle.show({ items = items, anchor = state.anchor, selected = selected })
    end

    --- Re-anchor the menu (a NEW keyword/context) without changing the items.
    ---@param anchor LvimUiMenuAnchor
    function handle.move(anchor)
        state.anchor = anchor
        if handle.visible() then
            place(handle)
        end
    end

    --- Select row `i` (clamped; nil clears the selection). The view scrolls to keep it visible.
    ---@param i integer?
    function handle.select(i)
        if i ~= nil then
            if #state.items == 0 then
                return
            end
            i = math.max(1, math.min(i, #state.items))
        end
        state.selected = i
        apply_selection()
    end

    --- Move the selection by `delta`, wrapping; from "nothing selected" it enters at the
    --- first (delta > 0) or last (delta < 0) row.
    ---@param delta integer
    function handle.select_move(delta)
        local n = #state.items
        if n == 0 then
            return
        end
        local cur = state.selected
        local nxt
        if not cur then
            nxt = delta > 0 and 1 or n
        else
            nxt = ((cur - 1 + delta) % n) + 1
        end
        handle.select(nxt)
    end

    --- The selected row index (nil when nothing is selected).
    ---@return integer?
    function handle.selected()
        return state.selected
    end

    --- The current item count.
    ---@return integer
    function handle.count()
        return #state.items
    end

    --- Hide the menu (and its docs sibling), keeping the long-lived buffer for the next show.
    function handle.hide()
        handle.docs_hide()
        if state.win and api.nvim_win_is_valid(state.win) then
            api.nvim_win_close(state.win, true)
        end
        state.win = nil
        state.selected = nil
    end

    --- Show documentation LINES in the sibling slot beside the menu. No-op while the menu
    --- itself is hidden (the slot has nothing to glue to).
    ---@param lines string[]
    ---@param o? { filetype?: string, max_width?: integer, max_height?: integer }
    function handle.docs_show(lines, o)
        if not handle.visible() or #lines == 0 then
            return
        end
        o = o or {}
        if not (state.docs_buf and api.nvim_buf_is_valid(state.docs_buf)) then
            local b = api.nvim_create_buf(false, true)
            vim.bo[b].buftype = "nofile"
            vim.bo[b].bufhidden = "hide"
            vim.bo[b].swapfile = false
            state.docs_buf = b
        end
        local buf = state.docs_buf
        vim.bo[buf].modifiable = true
        api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        local mw = o.max_width or docs_caps.max_width or 80
        local mh = o.max_height or docs_caps.max_height or 20
        local w = 1
        for _, l in ipairs(lines) do
            w = math.max(w, util.dw(l))
        end
        docs_size = { width = math.min(w + 2, mw), height = math.min(#lines, mh) }
        if not (state.docs_win and api.nvim_win_is_valid(state.docs_win)) then
            state.docs_win = api.nvim_open_win(buf, false, {
                relative = "editor",
                row = state.row,
                col = state.col + state.width + 1,
                width = docs_size.width,
                height = docs_size.height,
                style = "minimal",
                focusable = false,
                noautocmd = true,
                zindex = zindex - 1,
            })
            vim.wo[state.docs_win].winhighlight = ("Normal:%s,NormalFloat:%s"):format(groups.normal, groups.normal)
            vim.wo[state.docs_win].wrap = true
        end
        if o.filetype then
            pcall(vim.treesitter.start, buf, o.filetype)
            vim.wo[state.docs_win].conceallevel = 2
            vim.wo[state.docs_win].concealcursor = "nvic"
        end
        reposition_docs()
    end

    --- Hide the docs sibling (the menu stays).
    function handle.docs_hide()
        if state.docs_win and api.nvim_win_is_valid(state.docs_win) then
            api.nvim_win_close(state.docs_win, true)
        end
        state.docs_win = nil
        docs_size = nil
    end

    --- Destroy the handle: windows, buffers and the decoration provider. The handle must
    --- not be used afterwards (create a new one).
    function handle.close()
        handle.hide()
        api.nvim_set_decoration_provider(ns, {})
        for _, b in ipairs({ state.buf, state.docs_buf }) do
            if b and api.nvim_buf_is_valid(b) then
                api.nvim_buf_delete(b, { force = true })
            end
        end
        state.buf, state.docs_buf = nil, nil
    end

    --- The menu window (nil while hidden) — read-only, for consumers that need geometry.
    ---@return integer?
    function handle.win()
        return state.win
    end

    return handle
end

return M
