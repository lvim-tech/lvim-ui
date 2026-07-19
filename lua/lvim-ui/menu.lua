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
--   • Selection = a full-row EPHEMERAL `hl_eol` highlight painted by the decoration provider
--     (on_line), the SAME path as the box spans — so it is as reliable as the chip, which never
--     flickers (a PERSISTENT line-highlight mark, by contrast, repainted on this never-current
--     window only intermittently). `end_col` = the row's byte length (from rows_meta) so the
--     bar covers the whole line regardless of glyph display width; box fg-spans compose over it;
--     `cursorline` is unusable here (a current-window feature). The cursor is moved only to
--     auto-scroll; a pure selection change (no re-rank) forces one targeted redraw.
--   • A sibling DOCS slot: a second non-focusable window docked FLUSH beside the menu
--     (east, flipping/shrinking west near the edge) behind the canonical inter-panel
--     divider (`config.separator`), kept aligned through every reposition.
--   • Panel background via `winhighlight`, like every other lvim-ui window. (It used to be pinned
--     to a private hl namespace to survive the colorscheme's dim namespace, whose EMPTY group defs
--     blocked the fall-back to the global groups and made the selection bar / kind chips vanish.
--     That is fixed at the source now — `lvim-utils.dim` writes no blank defs — so the workaround
--     is gone, and with it its cost: nvim BYPASSES `winhighlight` under a window-local namespace.)
-- Theming: the standard pipeline — a highlight.bind factory over the live palette; no
-- cursor hiding needed (focus never enters the menu).
--
---@module "lvim-ui.menu"

local util = require("lvim-ui.util")
local config = require("lvim-ui.config")
local hl = require("lvim-utils.highlight")

local api = vim.api

local M = {}

--- Render revision of the loaded module — bumped when the render/selection mechanism changes.
--- Read at runtime (`require("lvim-ui.menu").RENDER_REV`) to tell whether a live session has
--- picked up the latest code (require caches the module, so this reflects the IN-MEMORY version,
--- not the file on disk). If it does not match the current source, the session is stale — restart.
M.RENDER_REV = "2026-07-12.ephemeral-sel-in-on_line"

-- ─── theming (the standard build()-factory pipeline) ─────────────────────────

hl.bind(function(c)
    c = c or require("lvim-utils.colors")
    -- Same panel-bg rule as the shared chrome (config/highlight.lua): follow the theme's
    -- float shade when synced, else the transparent-or-bg_dark fallback.
    local panel_bg = c.bg_float or (c.transparent and c.none or c.bg_dark)
    -- Concrete panel shade every ON-PANEL cell blends against (panel_bg may be "NONE" under
    -- a transparent theme, which cannot be blended). The tint canon: a coloured cell is its
    -- own accent tinted toward the surface it SITS ON — for the selection bar and the
    -- scrollbar that surface is the menu PANEL, never the editor bg (which may be lighter
    -- or darker than the panel and makes the cells read as foreign patches).
    local sel_base = c.bg_float or c.bg_dark
    -- Accent + strength per role, from `config.menu.colors` — nothing here is decided in code.
    local roles = (config.menu or {}).colors or {}
    ---@param role string
    ---@param fb string
    ---@return string
    local function mc(role, fb)
        local v = (roles[role] or {}).accent or fb
        if type(v) == "string" and v:sub(1, 1) == "#" then
            return v
        end
        return c[v] or c[fb] or c.blue
    end
    ---@param role string
    ---@param fb number
    ---@return number
    local function mt(role, fb)
        return (roles[role] or {}).tint or fb
    end
    return {
        LvimUiMenuNormal = { bg = panel_bg, fg = c.fg },
        -- Selection is BG-ONLY so each row's own fg colours (kind boxes, match chars) survive
        -- it. Blended over the PANEL shade at a STRONG tint — the tint canon's active level —
        -- so the selected row is unmistakable on the float, including on matched rows where
        -- the bold match fg would otherwise pull the eye off a faint bg.
        LvimUiMenuSel = { bg = hl.blend(mc("selection", "blue"), sel_base, mt("selection", 0.4)) },
        LvimUiMenuMatch = { fg = mc("match", "red"), bold = true },
        LvimUiMenuDetail = { fg = mc("detail", "comment") },
        LvimUiMenuThumb = { bg = hl.blend(mc("thumb", "blue"), sel_base, mt("thumb", 0.5)) },
        LvimUiMenuTrack = { bg = hl.blend(mc("track", "blue"), sel_base, mt("track", 0.1)) },
    }
end)

-- ─── types ────────────────────────────────────────────────────────────────────

---@class LvimUiMenuBox                     one cell of a menu row (the ui.button box model as data)
---@field text string                       the box text (already padded by the consumer if it wants a fixed column)
---@field hl? string                        highlight group for the whole box
---@field sel_hl? string                    group for the box while its row is SELECTED (default `hl`). A box
---                                         with its OWN bg needs this to re-tint against the selection bar —
---                                         its normal bg would punch a hole in the bar (bg-less boxes just
---                                         let the bar show through and need nothing)
---@field right? boolean                    right-align this box (detail column); the gap is space-filled
---@field positions? fun(): integer[]?      LAZY matched-char byte columns (1-based, within `text`) — called
---                                         only when the row is VISIBLE, once per render generation
---@field match_hl? string                  group for the matched chars (default the menu's `match` group)

---@class LvimUiMenuRow
---@field boxes LvimUiMenuBox[]
---@field hl? string                       full-row background group (painted under the box spans and the
---                                         selection bar) — lets a consumer tint each row by category
---@field sel_hl? string                   full-row background for THIS row while it is SELECTED, used
---                                         INSTEAD of the shared selection group — lets the selection be
---                                         per-row (e.g. a stronger tint of the row's own category colour)

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
    -- The selection bar is an EPHEMERAL extmark emitted from the decoration provider's `on_line` (see below),
    -- the SAME mechanism as the box spans — NOT a persistent `line_hl_group` mark. A persistent mark depended on
    -- nvim repainting the line highlight on this non-current float, which it did only intermittently ("the tint
    -- sometimes shows, sometimes not"); re-emitting it per redraw in on_line is what made it reliable. Do NOT
    -- revert this to a persistent mark — that is the flicker bug the recorder was needed to kill.
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
        docs_ft = nil, ---@type string?     the filetype the docs buffer's treesitter parser was started for
        docs_win = nil, ---@type integer?
        items = {}, ---@type LvimUiMenuRow[]
        anchor = nil, ---@type LvimUiMenuAnchor?
        selected = nil, ---@type integer?
        width = 0, ---@type integer       current content width (cells)
        height = 0, ---@type integer      current window height (rows)
        row = 0, ---@type integer         current editor-relative window row
        col = 0, ---@type integer         current editor-relative window col
        -- per-render metadata the decoration provider reads: rows_meta[i] = { spans, pos, len }
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
            local selected = state.selected ~= nil and row + 1 == state.selected
            -- Optional per-row BACKGROUND (the consumer's `row.hl`) — a full-row hl_eol at the
            -- LOWEST priority, so the selection bar (100) and every box span compose on top. Lets
            -- a consumer tint each row by category (e.g. lvim-cmp's per-kind accent rows).
            if meta.row_hl then
                api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
                    end_col = meta.len,
                    hl_group = meta.row_hl,
                    hl_eol = true,
                    ephemeral = true,
                    strict = false,
                    priority = 50,
                })
            end
            -- The full-row selection BAR is painted HERE, in the decoration provider, as an
            -- EPHEMERAL extmark over the whole line (`end_col` = the line's byte length + hl_eol
            -- to reach the window edge past the text). This is the SAME mechanism as the box
            -- spans below (chip, match, scrollbar) — which never flicker — so the bar is as
            -- reliable as they are. A PERSISTENT mark instead depended on nvim repainting the
            -- line highlight on a non-current window, which it did only intermittently ("the
            -- selected row's tint sometimes shows, sometimes not"). Low priority (100) so the
            -- box spans (110) and match chars (120) compose on top: a fg-only box keeps the
            -- bar's bg, a box with its OWN bg (the sel_hl chip) overrides just its cells.
            if selected then
                api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
                    end_col = meta.len,
                    -- a per-row `sel_hl` overrides the shared selection group (lets the selection
                    -- be a stronger tint of the row's own category colour, not one global bar)
                    hl_group = meta.row_sel_hl or groups.selection,
                    hl_eol = true,
                    ephemeral = true,
                    strict = false,
                    priority = 100,
                })
            end
            -- on the SELECTED row a box's `sel_hl` (span slot 4) replaces its normal group,
            -- so boxes with their own bg compose with the selection bar instead of cutting it
            for _, s in ipairs(meta.spans) do
                api.nvim_buf_set_extmark(bufnr, ns, row, s[1], {
                    end_col = s[2],
                    hl_group = (selected and s[4]) or s[3],
                    ephemeral = true,
                    strict = false,
                    priority = 110,
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
                            priority = 120,
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
                    spans[#spans + 1] = { off, off + b, e.box.hl, e.box.sel_hl }
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
                    spans[#spans + 1] = { off, off + b, e.box.hl, e.box.sel_hl }
                end
                off = off + b
            end
            local line = table.concat(parts)
            if util.dw(line) > w then
                line = util.truncate(line, w)
            end
            lines[i] = line .. (sb == 1 and " " or "") -- reserve the scrollbar cell
            -- `len` = the row's byte length; the decoration provider uses it as the selection
            -- bar's end_col (full-line highlight independent of glyph display width).
            state.rows_meta[i] =
                { spans = spans, pos = pos_meta, len = #lines[i], row_hl = row.hl, row_sel_hl = row.sel_hl }
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
        -- usable rows end above the cmdline AND the statusline (the single shared util.status_rows authority)
        local editor_h = vim.o.lines - vim.o.cmdheight - util.status_rows(awin)
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

    --- Apply the selection: (re)place the persistent bar on the selected row and move the cursor
    --- so the view scrolls to keep it visible.
    --- `force_redraw` — only for a PURE selection change (C-n/C-p, no re-rank): the window is not
    --- reconfigured, and moving this never-current window's cursor does not by itself trigger a
    --- redraw, so we ask for a targeted one. On the SHOW/UPDATE path it is FALSE: place()'s
    --- nvim_win_set_config (or the fresh window) already schedules a redraw, and nvim COALESCES
    --- those per input — forcing an extra flushed redraw there instead makes intermediate frames
    --- visible (a selection-bar flicker during fast typing).
    ---@param force_redraw boolean
    local function apply_selection(force_redraw)
        local win = state.win
        if not (win and api.nvim_win_is_valid(win)) then
            return
        end
        local target = (state.selected and state.items[state.selected]) and state.selected or 1
        pcall(api.nvim_win_set_cursor, win, { target, 0 })
        if force_redraw then
            -- pure selection change: no re-rank redrew the window, and the decoration provider
            -- only repaints (the bar included) on a redraw — so trigger one for this window.
            pcall(api.nvim__redraw, { win = win, valid = false, flush = true })
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
            -- The panel background, through the ORDINARY mechanism (`winhighlight`). This used to be pinned to a
            -- private highlight namespace instead, because the colorscheme's dim namespace wrote EMPTY group
            -- defs (`nvim_set_hl(ns, name, {})`) which BLOCK the fall-back to the global groups — the menu's own
            -- groups (selection bar, kind chips) then resolved to nothing and vanished. That was a workaround for
            -- a bug now fixed at its source: `lvim-utils.dim` no longer writes blank defs, so an undefined group
            -- in a namespace falls back to its live global definition, exactly as it should. And a window-local
            -- namespace has a real cost — nvim BYPASSES `winhighlight` under one — so it is gone.
            vim.wo[win].winhighlight = ("Normal:%s,NormalFloat:%s,Search:%s"):format(
                groups.normal,
                groups.normal,
                groups.normal
            )
            vim.wo[win].wrap = false
            vim.wo[win].scrolloff = 0
            vim.wo[win].sidescrolloff = 0
            vim.wo[win].cursorline = false
            vim.wo[win].winfixbuf = true
        end
        apply_selection(false) -- win_set_config / the fresh window already schedules the redraw
        if reposition_docs then
            reposition_docs()
        end
    end

    -- ─── the sibling DOCS slot ────────────────────────────────────────────────

    ---@type { width: integer, height: integer }?  the docs content size (while shown)
    local docs_size = nil

    --- The inter-panel divider for the docs sibling — the SAME `config.separator` rule the
    --- surface chassis draws between side-by-side panels ("│", peek-border tint), resolved
    --- live so a global separator restyle re-divides the docs slot too. nil = disabled
    --- (`separator = false`; the docs then docks flush with no rule).
    ---@return string? glyph, string hl_group
    local function docs_divider()
        local sep = config.separator
        if sep == false or sep == "" then
            return nil, ""
        end
        local glyph = (config.menu or {}).separator or "│"
        if type(sep) == "string" then
            glyph = sep
        elseif type(sep) == "table" then
            glyph = sep.h or sep.horizontal or glyph
        end
        return glyph, (type(sep) == "table" and sep.hl) or config.separator_hl or "LvimUiPeekBorder"
    end

    --- Re-glue the docs window beside the menu (east, flipping west near the edge),
    --- top-aligned with the menu row. Runs on every menu reposition. The docs dock FLUSH
    --- against the menu, carrying the canonical inter-panel divider ("│") on the window's
    --- MENU-facing border side — an open gutter would show a 1-cell sliver of the buffer
    --- between the two panels, which reads as the popups colliding with the text.
    reposition_docs = function()
        local dwin = state.docs_win
        if not (dwin and api.nvim_win_is_valid(dwin)) or not docs_size then
            return
        end
        if not (state.win and api.nvim_win_is_valid(state.win)) then
            return
        end
        local glyph, sep_hl = docs_divider()
        local edge = glyph and 1 or 0 -- the divider is a border column: it widens the frame by 1
        local east_col = state.col + state.width -- window frame (divider first) flush at the menu edge
        local east_room = vim.o.columns - east_col - edge
        local west_room = state.col - edge
        local col, width, east
        if east_room >= docs_size.width then
            col, width, east = east_col, docs_size.width, true -- fits fully east
        elseif west_room >= docs_size.width then
            col, width, east = state.col - edge - docs_size.width, docs_size.width, false -- fits fully west
        elseif east_room >= west_room then
            -- neither side fits the full width → take the roomier side and SHRINK the docs to
            -- it, never straddling the menu (the old code clamped west to col 0 and overlapped)
            col, width, east = east_col, math.max(1, east_room), true
        else
            width = math.max(1, west_room)
            col, east = math.max(0, state.col - edge - width), false
        end
        local cfg = {
            relative = "editor",
            row = state.row,
            col = col,
            width = width,
            -- Clamp the docs height to the rows between its anchor and the bottom, MINUS the statusline (the
            -- same authority geometry() uses) — else a tall docs panel beside a low menu overlaps the statusline.
            height = math.min(
                docs_size.height,
                math.max(
                    1,
                    vim.o.lines - vim.o.cmdheight - util.status_rows(state.anchor and state.anchor.win) - state.row
                )
            ),
        }
        if glyph then
            -- border order { tl, t, tr, r, br, b, bl, l }: the rule sits on the side FACING
            -- the menu — left when the docs are east of it, right when they flipped west
            local rule = { glyph, sep_hl }
            cfg.border = east and { "", "", "", "", "", "", "", rule } or { "", "", "", rule, "", "", "", "" }
        end
        api.nvim_win_set_config(dwin, cfg)
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
        apply_selection(true) -- pure selection change: force the repaint
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
        local function fresh_docs_buf()
            local b = api.nvim_create_buf(false, true)
            vim.bo[b].buftype = "nofile"
            vim.bo[b].bufhidden = "hide"
            vim.bo[b].swapfile = false
            return b
        end
        -- Treesitter caches ONE parser per buffer (the FIRST language started on it), so the REUSED docs buffer
        -- cannot switch languages between candidates — `start()` for a new language silently fails on a buffer
        -- already parsing another and the highlight degrades to none. Mirror preview.render_file: on a filetype
        -- change, stop treesitter and swap a FRESH scratch buffer into the (already-open) docs window so the new
        -- language starts clean. The window-local options (winhighlight / wrap / conceal) persist across the swap.
        if state.docs_buf and api.nvim_buf_is_valid(state.docs_buf) and state.docs_ft ~= o.filetype then
            pcall(vim.treesitter.stop, state.docs_buf)
            local old = state.docs_buf
            state.docs_buf = fresh_docs_buf()
            if state.docs_win and api.nvim_win_is_valid(state.docs_win) then
                pcall(api.nvim_win_set_buf, state.docs_win, state.docs_buf)
            end
            pcall(api.nvim_buf_delete, old, { force = true })
        end
        if not (state.docs_buf and api.nvim_buf_is_valid(state.docs_buf)) then
            state.docs_buf = fresh_docs_buf()
        end
        state.docs_ft = o.filetype
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
                col = state.col + state.width, -- provisional: reposition_docs() below sets the real dock + divider
                width = docs_size.width,
                height = docs_size.height,
                style = "minimal",
                focusable = false,
                noautocmd = true,
                zindex = zindex - 1,
            })
            -- Same panel background as the menu window, via `winhighlight` (see there).
            vim.wo[state.docs_win].winhighlight = ("Normal:%s,NormalFloat:%s,Search:%s"):format(
                groups.normal,
                groups.normal,
                groups.normal
            )
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

    --- Whether the docs sibling is currently on screen.
    ---@return boolean
    function handle.docs_visible()
        return state.docs_win ~= nil and api.nvim_win_is_valid(state.docs_win)
    end

    --- Scroll the (non-focusable) docs sibling by `delta` SCREEN lines: > 0 down, < 0 up.
    --- Uses <C-e>/<C-y> inside the window (via nvim_win_call) so wrapped lines scroll
    --- correctly and the view clamps at the buffer ends. Returns false when no docs
    --- window is open (nothing to scroll).
    ---@param delta integer
    ---@return boolean
    function handle.docs_scroll(delta)
        if not handle.docs_visible() or delta == 0 then
            return false
        end
        local n = math.abs(delta)
        local key = delta > 0 and "\5" or "\25" -- <C-e> scroll down / <C-y> scroll up
        api.nvim_win_call(state.docs_win, function()
            vim.cmd("normal! " .. n .. key)
        end)
        return true
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
