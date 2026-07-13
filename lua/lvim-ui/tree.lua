-- lvim-ui.tree: the generic node-provider TREE — the shared content layer every lvim-tech tree panel
-- (the lvim-files file tree, the lvim-lsp outline, the lvim-db drawer, lvim-dap-view scopes/stack)
-- renders through, instead of each hand-rolling the same fold-state + guides + marker + icon/label +
-- extmark pipeline on `lvim-ui.surface`.
--
-- The tree is ONLY the content: the handle exposes a surface CONTENT PROVIDER (`t.provider`) the
-- consumer plugs into its own `surface.open` (a persistent native split, a modal float, a tabs
-- provider-tab — the chassis owns the window/dock/cursor-hide/footer/teardown, exactly as before).
-- The consumer supplies NODES (`{ id, label, icon?, …, children = nodes|fun(node) }`, lazy or eager);
-- the tree owns: expand/collapse state (keyed by the stable node `id`), indent guides + branch
-- connectors, the 2-column fold-marker cell, icon + label + dim detail (eol virtual text) + right
-- badges (right_align virtual text), the marked "follow" row, a right-edge scrollbar thumb when the
-- content overflows (the menu's ephemeral decoration-provider canon), the canonical keymaps
-- (`l`/`<CR>` expand-or-activate, `h` collapse-or-parent, per-node `actions`) and the canonical mouse
-- (a click on a row selects + activates it; on a fold chevron / a double-click it toggles the fold).
--
-- Why children may be a FUNCTION re-run per render: a lazy consumer (a file tree) materializes only
-- expanded directories and re-decorates live (git badges), so the tree never caches what the provider
-- can answer; an eager consumer (an LSP symbol tree) just passes the tables.
--
---@module "lvim-ui.tree"

local config = require("lvim-ui.config")
local util = require("lvim-ui.util")
local hl = require("lvim-utils.highlight")
local mouse = require("lvim-utils.mouse")

local api = vim.api

local M = {}

-- ─── theming (the standard build()-factory pipeline) ─────────────────────────

hl.bind(function(c)
    c = c or require("lvim-utils.colors")
    -- The scrollbar sits ON the panel — blend against the panel shade, never the editor bg
    -- (the menu's rule: a transparent theme's "NONE" bg cannot be blended).
    local panel_base = c.bg_float or c.bg_dark
    return {
        LvimUiTreeGuide = { fg = hl.blend(c.fg_dark, c.bg, 0.6) }, -- the │ indent guides + ├/└ connectors
        LvimUiTreeFold = { fg = c.blue }, -- the open/closed fold chevron
        LvimUiTreeDetail = { fg = c.comment }, -- the dim eol detail text
        LvimUiTreeMark = { bg = hl.blend(c.blue, c.bg, 0.16), bold = true }, -- the marked (follow) row
        LvimUiTreeEmpty = { fg = c.comment, italic = true }, -- the placeholder when there are no nodes
        LvimUiTreeThumb = { bg = hl.blend(c.blue, panel_base, 0.5) }, -- scrollbar thumb
        LvimUiTreeTrack = { bg = hl.blend(c.blue, panel_base, 0.1) }, -- scrollbar track
    }
end)

-- ─── types ────────────────────────────────────────────────────────────────────

---@class LvimUiTreeNode
---@field id string                     STABLE identity — fold state, focus and the mark are keyed by it
---@field label string                  the node text
---@field icon? string                  lead kind icon (a Nerd Font glyph)
---@field icon_hl? string               highlight group for the icon
---@field label_hl? string              highlight group for the label
---@field hl? string                    ONE group for icon AND label together (source-colour mode); wins
---                                     over `icon_hl`/`label_hl` so the two never diverge
---@field kind? string                  free-form consumer tag (carried, never interpreted)
---@field expandable? boolean           show a fold chevron even before children are known (a lazy dir)
---@field children? LvimUiTreeNode[]|fun(node: LvimUiTreeNode): LvimUiTreeNode[]  eager list, or a LAZY
---                                     function called only while the node is EXPANDED (per render — the
---                                     consumer may re-decorate live and kick off async loads there)
---@field detail? string                dim eol virtual text (e.g. a symbol signature)
---@field badges? { [1]: string, [2]: string }[]  right-aligned virt-text cells `{ text, hl }` (git/diag)
---@field actions? table<string, fun(node: LvimUiTreeNode, t: table)>  per-node extra keys → handlers
---@field data? any                     consumer payload (returned untouched on `selected()`/callbacks)

---@class LvimUiTreeIcons
---@field fold_open? string             expanded-node chevron
---@field fold_closed? string           collapsed-node chevron
---@field guide? string                 ancestor guide column (│)
---@field branch? string                leaf connector with siblings below (├) — `connectors` only
---@field branch_last? string           last-leaf connector (└) — `connectors` only

---@class LvimUiTreeKeys
---@field activate? string|string[]     expand a collapsed node / activate (default { "l", "<CR>" })
---@field collapse? string|string[]     collapse an expanded node / jump to the parent row (default "h")

---@class LvimUiTreePadding
---@field left? integer   blank columns before every CONTENT row (default 1)
---@field right? integer  blank columns kept free on the RIGHT (default 1). The scrollbar thumb is painted on the
---                       LAST window column, so ONE MORE column is reserved on top of this whenever the bar is
---                       actually shown — i.e. the bar never eats into this padding, and the reserve disappears
---                       when the content fits (no bar). Everything that would otherwise run into it is
---                       constrained: the row text is clipped, the `detail` virtual text is clipped to the space
---                       actually left, and right-aligned badges are pushed in.
---                       The header (a title band) is NOT padded — it spans the full width.

---@class LvimUiTreeOpts
---@field root? LvimUiTreeNode|LvimUiTreeNode[]|fun(): LvimUiTreeNode[]  initial top level (see `set_root`)
---@field default_expanded? boolean     nodes start EXPANDED (an outline) or COLLAPSED (a file tree); default false
---@field connectors? boolean           ├/└ connectors on leaf rows that have a parent (default false)
---@field elide_guides? boolean         drop the ancestor guide column below a LAST child (default true);
---                                     false keeps a solid │ for every level (the file-tree style)
---@field margin? integer               DEPRECATED alias for `padding.left` (kept for existing consumers)
---@field padding? LvimUiTreePadding    breathing room around the CONTENT rows (not the header) — default { left = 1, right = 2 }
---@field icons? LvimUiTreeIcons        chrome glyph overrides
---@field hl? { guide?: string, fold?: string, detail?: string, mark?: string, empty?: string, thumb?: string, track?: string }
---@field empty? string                 placeholder row when there are no nodes (default " No entries")
---@field header? fun(width: integer): string[], table[]  static rows ABOVE the tree (e.g. a root band);
---                                     returns lines + hl spans `{ row0, c0, c1, group }` (row0 relative
---                                     to the header; `c1 = -1` = full row, bg to the window edge). The
---                                     cursor is kept off these rows.
---@field filetype? string              stamped on the panel buffer (drives the user's cursor `panel_ft`)
---@field cursorline? boolean           selection bar via cursorline (default true)
---@field hide_cursor? boolean          modal usage: hide the hardware cursor (chassis list-move + click seam)
---@field scrollbar? boolean            right-edge thumb when the tree overflows the window (default FALSE — opt in
---                                     with `true`). When on, ONE extra right column is reserved for it on top of
---                                     `padding.right`, so the bar never sits on the content.
---@field size? fun(): integer, integer natural content size override (a docked panel passes its width)
---@field keys? LvimUiTreeKeys|false    canonical keymap overrides; `false` binds none (consumer owns all)
---@field on_activate? fun(node: LvimUiTreeNode, t: table)  `l`/`<CR>`/click on a leaf or an expanded node
---@field on_expand? fun(node: LvimUiTreeNode, t: table)    after a node expands (lazy loads/watches go here)
---@field on_collapse? fun(node: LvimUiTreeNode, t: table)  after a node collapses
---@field on_move? fun(node: LvimUiTreeNode|nil, t: table)  cursor moved to a row (nil on a header row)
---@field on_keys? fun(map: fun(lhs: string|string[], fn: fun()), pan: table, st: table, t: table)  the
---                                     consumer's own buffer keymaps (bound AFTER the canonical ones, so
---                                     a consumer's config key overrides a default on the same lhs)
---@field on_render? fun(t: table)      after every repaint (live footers/counters)
---@field on_close? fun(pan: table)     surface teardown passthrough

-- Handle instance counter — each handle owns private namespaces (content marks / the mark row / the
-- scrollbar decoration provider).
---@type integer
local seq = 0

--- Default chrome glyphs (Nerd Font carets — built from codepoints so they survive tooling).
---@return LvimUiTreeIcons
local function default_icons()
    return {
        fold_open = "", -- nf-fa-caret_down
        fold_closed = "", -- nf-fa-caret_right
        guide = "│",
        branch = "├",
        branch_last = "└",
    }
end

--- Pad a 1-glyph marker to exactly two DISPLAY columns (glyphs are multibyte and may render 1 or 2
--- cells wide) so a child's icon always sits in the same column regardless of the glyph.
---@param glyph string
---@return string
local function cell(glyph)
    return glyph .. string.rep(" ", math.max(0, 2 - vim.fn.strdisplaywidth(glyph)))
end

--- Create a tree handle. See the module header for the model and `LvimUiTreeOpts` for every option.
---@param opts? LvimUiTreeOpts
---@return table t  the handle (`t.provider` + the API methods below)
function M.new(opts)
    opts = opts or {}
    seq = seq + 1
    local ns = api.nvim_create_namespace("lvim_ui_tree_" .. seq) -- content spans + virt text
    local ns_mark = api.nvim_create_namespace("lvim_ui_tree_mark_" .. seq) -- the follow-mark row
    local ns_bar = api.nvim_create_namespace("lvim_ui_tree_bar_" .. seq) -- scrollbar decoration provider
    local ns_width = api.nvim_create_namespace("lvim_ui_tree_width_" .. seq) -- width-change watcher (see below)

    local icons = vim.tbl_extend("force", default_icons(), opts.icons or {})
    local groups = vim.tbl_extend("force", {
        guide = "LvimUiTreeGuide",
        fold = "LvimUiTreeFold",
        detail = "LvimUiTreeDetail",
        mark = "LvimUiTreeMark",
        empty = "LvimUiTreeEmpty",
        thumb = "LvimUiTreeThumb",
        track = "LvimUiTreeTrack",
    }, opts.hl or {})
    local default_expanded = opts.default_expanded == true
    local connectors = opts.connectors == true
    local elide_guides = opts.elide_guides ~= false
    -- Resolution order for every tree default: the CONSUMER's own opts win; otherwise the shared `config.tree`
    -- settings apply (so a user can retune every tree panel from one place); a literal is only the last resort.
    local tcfg = config.tree or {}
    local tpad = tcfg.padding or {}
    local scrollbar = opts.scrollbar
    if scrollbar == nil then
        scrollbar = tcfg.scrollbar
    end
    scrollbar = scrollbar == true
    -- Content padding — breathing room around the tree ROWS only; the HEADER (a title band) is never padded and
    -- keeps the full width. `margin` is the old left-only option, kept as an alias.
    ---@type integer
    local pad_left = (opts.padding and opts.padding.left) or opts.margin or tpad.left or 1
    ---@type integer
    local pad_right = (opts.padding and opts.padding.right) or tpad.right or 1
    local margin = pad_left

    ---@class LvimUiTreeState
    local state = {
        roots = nil, ---@type LvimUiTreeNode[]|fun(): LvimUiTreeNode[]|nil  the top level (list or factory)
        override = {}, ---@type table<string, boolean>  per-id fold override (absent = `default_expanded`)
        rows = {}, ---@type table<integer, table>  buffer line → row entry { node, parent, c0, c1 }
        order = {}, ---@type table[]               row entries in display order (visible walk order)
        header_rows = 0, ---@type integer          lines the `header` rows take at the top
        last_width = 0, ---@type integer           width the last render CLIPPED against (a resize re-renders)
        marked = nil, ---@type string|nil          the marked (follow) node id
        pan = nil, ---@type table|nil              the surface panel (buf/win/refresh)
        st = nil, ---@type table|nil               the surface state
        map = nil, ---@type fun(lhs: string|string[], fn: fun())|nil  the chassis buffer-map fn
        bound = {}, ---@type table<string, boolean>  per-node action keys already dispatched-bound
        queued = false, ---@type boolean           a coalesced refresh is scheduled
        dirty = false, ---@type boolean            content changed since the last render (the queue's gate)
        destroyed = false, ---@type boolean
    }

    local t = {} -- the public handle (forward-declared so callbacks can close over it)

    -- ─── model helpers ─────────────────────────────────────────────────────────

    --- Whether a node can fold: an explicit `expandable`, a non-empty eager list, or a lazy function.
    ---@param n LvimUiTreeNode
    ---@return boolean
    local function expandable(n)
        if n.expandable ~= nil then
            return n.expandable == true
        end
        local ch = n.children
        return type(ch) == "function" or (type(ch) == "table" and #ch > 0)
    end

    --- The node's CURRENT fold state (override, else the instance default).
    ---@param id string
    ---@return boolean
    local function is_expanded(id)
        local o = state.override[id]
        if o ~= nil then
            return o
        end
        return default_expanded
    end

    --- Materialize a node's children (a lazy function is called only here — i.e. only while expanded).
    ---@param n LvimUiTreeNode
    ---@return LvimUiTreeNode[]
    local function kids(n)
        local ch = n.children
        if type(ch) == "function" then
            return ch(n) or {}
        end
        return ch or {}
    end

    --- The current top-level node list (a factory root is re-run — live re-decoration).
    ---@return LvimUiTreeNode[]
    local function top()
        local r = state.roots
        if type(r) == "function" then
            return r() or {}
        end
        return r or {}
    end

    --- Visit every KNOWN node: eager children always, lazy children only while expanded (so a walk
    --- never triggers a load). Used by the bulk fold operations.
    ---@param nodes LvimUiTreeNode[]
    ---@param fn fun(node: LvimUiTreeNode)
    local function walk_known(nodes, fn)
        for _, n in ipairs(nodes) do
            fn(n)
            if type(n.children) == "table" then
                walk_known(n.children --[[@as LvimUiTreeNode[] ]], fn)
            elseif type(n.children) == "function" and expandable(n) and is_expanded(n.id) then
                walk_known(kids(n), fn)
            end
        end
    end

    -- ─── rendering ─────────────────────────────────────────────────────────────

    --- Clip `s` to at most `w` DISPLAY columns (never mid-codepoint). Used so a long row cannot run under the
    --- scrollbar / into the right padding. Returns `s` untouched when it already fits.
    ---@param s string
    ---@param w integer
    ---@return string
    local function clip(s, w)
        if w <= 0 or util.dw(s) <= w then
            return s
        end
        local n = vim.fn.strchars(s)
        while n > 0 do
            local cut = vim.fn.strcharpart(s, 0, n)
            if util.dw(cut) <= w then
                return cut
            end
            n = n - 1
        end
        return ""
    end

    --- Build the visible rows: lines, hl spans, virt texts and the row registry. Each line is
    --- `<padding><guides><marker><icon> <label>`, CLIPPED to the content width (panel minus the right padding +
    --- scrollbar column); the marker is a fixed 2-display-column cell (a fold chevron, a ├/└ connector, or
    --- blanks), so children align under their parents. Pure — the caller commits the returned registries (a
    --- `size` measurement pass must not clobber the live ones).
    ---@param width integer  the panel width (passed to `header` and available to consumers via it)
    ---@param bar_reserve integer  extra right columns kept free for the scrollbar thumb — 1 only when the bar is
    ---       ACTUALLY shown (the content overflows), 0 otherwise. Reserving it whenever the OPTION is on would
    ---       waste a column on every panel that happens to fit.
    ---@return string[] lines, table[] hls, table[] virts, table<integer, table> rows, table[] order, integer header_rows
    local function build(width, bar_reserve)
        local pad_right_eff = pad_right + (bar_reserve or 0)
        local lines, hls, virts = {}, {}, {}
        local rows, order = {}, {}

        if opts.header then
            local hlines, hspans = opts.header(width)
            for _, l in ipairs(hlines or {}) do
                lines[#lines + 1] = l
            end
            for _, s in ipairs(hspans or {}) do
                hls[#hls + 1] = s
            end
        end
        local header_rows = #lines

        local lead = string.rep(" ", margin)

        ---@param nodes LvimUiTreeNode[]
        ---@param guide string             accumulated ancestor guide columns ("│ " / "  " per level)
        ---@param parent LvimUiTreeNode|nil
        local function walk(nodes, guide, parent)
            local count = #nodes
            for i, n in ipairs(nodes) do
                local is_last = i == count
                local can_fold = expandable(n)
                local open = can_fold and is_expanded(n.id)

                -- Marker: a fold chevron for a foldable node; a ├/└ connector for a leaf that has a
                -- parent (connectors mode); two blanks otherwise.
                local arrow = can_fold and (open and icons.fold_open or icons.fold_closed) or nil
                local connector = (not arrow and connectors and parent ~= nil)
                        and (is_last and icons.branch_last or icons.branch)
                    or nil
                local marker = arrow or connector
                local fold_cell = marker and cell(marker) or "  "

                local prefix = lead .. guide
                local icon = n.icon or ""
                local gap = icon ~= "" and " " or ""
                -- Cut the row to the CONTENT width (the panel minus the right padding + scrollbar column).
                -- Without this a long label runs under the bar — the bar is painted ON the last column, so it
                -- would sit on top of the text instead of beside it.
                lines[#lines + 1] = clip(prefix .. fold_cell .. icon .. gap .. (n.label or ""), width - pad_right_eff)
                local row = #lines

                if #prefix > 0 then
                    hls[#hls + 1] = { row - 1, 0, #prefix, groups.guide }
                end
                if marker then
                    hls[#hls + 1] = { row - 1, #prefix, #prefix + #marker, arrow and groups.fold or groups.guide }
                end
                -- `hl` paints icon AND label with ONE colour (source-colour mode: the two never
                -- diverge); else each takes its own group.
                local ioff = #prefix + #fold_cell
                if icon ~= "" then
                    local g = n.hl or n.icon_hl
                    if g then
                        hls[#hls + 1] = { row - 1, ioff, ioff + #icon, g }
                    end
                end
                local noff = ioff + #icon + #gap
                local lg = n.hl or n.label_hl
                if lg then
                    hls[#hls + 1] = { row - 1, noff, noff + #(n.label or ""), lg }
                end

                if n.detail and n.detail ~= "" then
                    -- `detail` is VIRTUAL text (`eol`), not part of the line — so clipping the line does NOT
                    -- constrain it: it keeps flowing right, straight under the scrollbar. Clip it to the space
                    -- that is actually left on the row (content width minus what the row already uses).
                    local avail = (width - pad_right_eff) - util.dw(lines[row])
                    if avail > 1 then
                        local d = clip(" " .. n.detail, avail)
                        if d ~= "" then
                            virts[#virts + 1] = { row - 1, { { d, groups.detail } }, "eol" }
                        end
                    end
                end
                if n.badges and #n.badges > 0 then
                    -- `right_align` pins the badges to the LAST window column — exactly where the scrollbar
                    -- thumb is painted. Push them left by the effective right padding so the two never overlap.
                    local badges = n.badges
                    if pad_right_eff > 0 then
                        badges = vim.list_extend({}, n.badges)
                        badges[#badges + 1] = { string.rep(" ", pad_right_eff), groups.detail }
                    end
                    virts[#virts + 1] = { row - 1, badges, "right_align" }
                end

                -- The row registry: the node, its parent (for `h` → parent) and the marker's byte
                -- range (the mouse chevron hit-test).
                local entry = {
                    node = n,
                    parent = parent,
                    c0 = arrow and #prefix or nil,
                    c1 = arrow and (#prefix + #fold_cell) or nil,
                }
                rows[row] = entry
                order[#order + 1] = entry

                if can_fold and open then
                    walk(kids(n), guide .. (elide_guides and is_last and "  " or icons.guide .. " "), n)
                end
            end
        end

        walk(top(), "", nil)

        if #order == 0 then
            lines[#lines + 1] = opts.empty or " No entries"
            hls[#hls + 1] = { #lines - 1, 0, -1, groups.empty }
        end
        return lines, hls, virts, rows, order, header_rows
    end

    --- Re-apply the marked (follow) row after a repaint. `move` also parks the panel cursor on the
    --- row — only when the panel is NOT the current window, so it never fights the user inside it.
    ---@param move? boolean
    local function apply_mark(move)
        local pan = state.pan
        if not (pan and pan.buf and api.nvim_buf_is_valid(pan.buf)) then
            return
        end
        api.nvim_buf_clear_namespace(pan.buf, ns_mark, 0, -1)
        if not state.marked then
            return
        end
        local row = t.row_of(state.marked)
        if not row then
            return
        end
        pcall(api.nvim_buf_set_extmark, pan.buf, ns_mark, row - 1, 0, {
            line_hl_group = groups.mark,
            priority = 200,
        })
        if move and pan.win and api.nvim_win_is_valid(pan.win) and api.nvim_get_current_win() ~= pan.win then
            pcall(api.nvim_win_set_cursor, pan.win, { row, 0 })
        end
    end

    --- Bind any NEW per-node action keys seen in this render — one dispatcher per key, resolving
    --- against the SELECTED node's `actions` at press time. A lhs the buffer already maps (a
    --- consumer's own key) is left alone.
    local function bind_actions()
        if not (state.map and state.pan and state.pan.buf and api.nvim_buf_is_valid(state.pan.buf)) then
            return
        end
        local existing = nil -- lazily built set of buffer-local mappings
        for _, e in ipairs(state.order) do
            for key in pairs(e.node.actions or {}) do
                if not state.bound[key] then
                    if existing == nil then
                        existing = {}
                        for _, m in ipairs(api.nvim_buf_get_keymap(state.pan.buf, "n")) do
                            existing[m.lhs] = true
                        end
                    end
                    state.bound[key] = true
                    if not existing[key] then
                        state.map(key, function()
                            local n = t.selected()
                            local a = n and n.actions and n.actions[key]
                            if n and a then
                                a(n, t)
                            end
                        end)
                    end
                end
            end
        end
    end

    --- Repaint the panel buffer from the current roots + fold state (synchronous).
    local function render()
        local pan = state.pan
        if state.destroyed or not (pan and pan.buf and api.nvim_buf_is_valid(pan.buf)) then
            return
        end
        state.dirty = false -- this render satisfies any queued refresh (its callback checks the flag)
        local width = (pan.win and api.nvim_win_is_valid(pan.win)) and api.nvim_win_get_width(pan.win) or 80
        state.last_width = width -- the width this render's clipping was derived from (see the resize autocmd)
        -- The scrollbar only appears when the content OVERFLOWS, and only then does it need a column reserved.
        -- Whether it overflows depends on the row count, which is what `build` produces — so build once assuming
        -- the bar (the common case for a panel worth scrolling), and rebuild without the reserve only if it
        -- turns out everything fits. Otherwise a panel that fits would waste a column on a bar it never shows.
        local info = (pan.win and api.nvim_win_is_valid(pan.win)) and vim.fn.getwininfo(pan.win)[1] or nil
        local height = (info and info.height) or (pan.win and api.nvim_win_get_height(pan.win)) or 0
        local reserve = scrollbar and 1 or 0
        local lines, hls, virts, rows, order, header_rows = build(width, reserve)
        if reserve == 1 and height > 0 and #lines <= height then
            lines, hls, virts, rows, order, header_rows = build(width, 0) -- fits: no bar, no reserved column
        end
        state.rows, state.order, state.header_rows = rows, order, header_rows
        vim.bo[pan.buf].modifiable = true
        api.nvim_buf_set_lines(pan.buf, 0, -1, false, lines)
        vim.bo[pan.buf].modifiable = false
        api.nvim_buf_clear_namespace(pan.buf, ns, 0, -1)
        for _, h in ipairs(hls) do
            -- Clamp to the row's real length: `build` CLIPS long rows to the content width (so they cannot run
            -- under the scrollbar), which can leave a span pointing past the end — an out-of-range `end_col`
            -- throws and kills the whole render.
            local len = #(lines[h[1] + 1] or "")
            local c0 = math.min(h[2], len)
            local c1 = h[3] >= 0 and math.min(h[3], len) or nil
            if not (c1 and c1 <= c0) then
                pcall(api.nvim_buf_set_extmark, pan.buf, ns, h[1], c0, {
                    end_col = c1,
                    end_row = h[3] < 0 and h[1] + 1 or nil,
                    hl_eol = h[3] < 0 or nil,
                    hl_group = h[4],
                    priority = 200,
                })
            end
        end
        for _, v in ipairs(virts) do
            pcall(api.nvim_buf_set_extmark, pan.buf, ns, v[1], 0, {
                virt_text = v[2],
                virt_text_pos = v[3],
                hl_mode = "combine",
            })
        end
        apply_mark(false)
        bind_actions()
        if opts.on_render then
            opts.on_render(t)
        end
    end

    -- ─── re-render when the WIDTH changes ──────────────────────────────────────
    -- Every width-dependent decision is baked into the buffer at `build` time: rows are CLIPPED to the content
    -- width, and `detail` (eol virtual text) is clipped to the space actually left on its row. So a panel whose
    -- width changes AFTER its render keeps content sized for the OLD width — and a docked panel is laid out and
    -- THEN adjusted, so the very first render is routinely one column off. Its detail then runs to the very edge,
    -- eating the right padding entirely.
    --
    -- This is checked from a decoration provider, NOT from `WinResized`: that autocmd simply does not fire for
    -- the panel here (verified — `build` was never re-entered), whereas `on_win` runs on every single redraw of
    -- the window, which is exactly when a stale width would become visible. The re-render is SCHEDULED: `on_win`
    -- runs inside the redraw and must not mutate the buffer.
    api.nvim_set_decoration_provider(ns_width, {
        on_win = function(_, winid, bufnr, _, _)
            local pan = state.pan
            if state.destroyed or not (pan and winid == pan.win and bufnr == pan.buf) then
                return false
            end
            local w = api.nvim_win_get_width(winid)
            if w ~= state.last_width and w > 0 then
                state.last_width = w
                vim.schedule(function()
                    if not state.destroyed then
                        render()
                    end
                end)
            end
            return false
        end,
    })

    -- ─── scrollbar (the menu's ephemeral decoration-provider canon) ────────────
    -- The buffer text is untouched: a thumb/track cell is painted on the LAST window column of the
    -- VISIBLE rows only, per redraw, and only while the content overflows the window.
    if scrollbar then
        local bar = { from = 0, to = 0, col = 0 } -- thumb range (1-based rows) + window column, per on_win

        -- The thumb is drawn ON BUFFER ROWS, but it belongs to the SCREEN. On a j/k scroll nvim optimises the
        -- repaint: it SHIFTS the already-drawn rows up/down and only redraws the ones that newly came into view.
        -- The painted thumb therefore travels with the text, while the fresh rows get it at the correct place —
        -- so it appears at wrong Y positions, and can even show as TWO pieces far apart. Forcing a full (invalid)
        -- repaint of the panel on every scroll makes every visible row go through `on_line` again, so the thumb
        -- is always re-derived from the CURRENT topline.
        api.nvim_create_autocmd("WinScrolled", {
            group = api.nvim_create_augroup("LvimUiTreeBar" .. seq, { clear = true }),
            callback = function()
                local pan = state.pan
                if state.destroyed or not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
                    return
                end
                -- only when THIS panel scrolled (`v:event` is keyed by window id)
                local ev = vim.v.event or {}
                if ev[tostring(pan.win)] == nil then
                    return
                end
                pcall(api.nvim__redraw, { win = pan.win, valid = false })
            end,
        })

        api.nvim_set_decoration_provider(ns_bar, {
            on_win = function(_, winid, bufnr, topline, _)
                local pan = state.pan
                if state.destroyed or not (pan and winid == pan.win and bufnr == pan.buf) then
                    return false
                end
                local total = api.nvim_buf_line_count(bufnr)
                local info = vim.fn.getwininfo(winid)[1]
                local height = (info and info.height) or api.nvim_win_get_height(winid)
                if total <= height or height <= 0 then
                    return false
                end
                local span = math.max(1, math.floor(height * height / total + 0.5))
                local from = math.floor(topline * (height - span) / math.max(1, total - height) + 0.5)
                bar.from = topline + from + 1
                bar.to = bar.from + span - 1
                bar.col = math.max(0, api.nvim_win_get_width(winid) - 1)
                return true
            end,
            on_line = function(_, winid, bufnr, row)
                local pan = state.pan
                if state.destroyed or not (pan and winid == pan.win and bufnr == pan.buf) then
                    return
                end
                local group = (row + 1 >= bar.from and row + 1 <= bar.to) and groups.thumb or groups.track
                api.nvim_buf_set_extmark(bufnr, ns_bar, row, 0, {
                    virt_text = { { " ", group } },
                    virt_text_win_col = bar.col,
                    hl_mode = "combine",
                    ephemeral = true,
                    priority = 300,
                })
            end,
        })
    end

    -- ─── selection / activation ────────────────────────────────────────────────

    --- The row entry under the panel cursor (nil on a header/empty row or without a window).
    ---@return table|nil
    local function cur_entry()
        local pan = state.pan
        if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
            return nil
        end
        return state.rows[api.nvim_win_get_cursor(pan.win)[1]]
    end

    --- `l`/`<CR>`/click: expand a collapsed foldable node, else hand the node to the consumer.
    local function expand_or_activate()
        local e = cur_entry()
        if not e then
            return
        end
        if expandable(e.node) and not is_expanded(e.node.id) then
            t.expand(e.node.id)
        elseif opts.on_activate then
            opts.on_activate(e.node, t)
        end
    end

    --- `h`: collapse an expanded foldable node, else jump to its parent's row.
    local function collapse_or_parent()
        local e = cur_entry()
        if not e then
            return
        end
        if expandable(e.node) and is_expanded(e.node.id) then
            t.collapse(e.node.id)
            return
        end
        if e.parent then
            t.focus(e.parent.id)
        end
    end

    --- The shared click handler (the chassis `on_click` seam AND the panel's own `<LeftMouse>`):
    --- a click on a fold chevron toggles it; anywhere else on the row selects + activates.
    ---
    --- The ACTIVATION is deferred to the mouse RELEASE (`lvim-utils.mouse`). A consumer's activate may leave the
    --- panel — the LSP outline jumps to the symbol (`nvim_set_current_win`), and even its `peek`/`follow` runs
    --- `zz` in the source via `nvim_win_call`, which switches the current window transiently. Doing that while
    --- the button is STILL DOWN points CURRENT at the (unlocked) source buffer, so the pending drag/release miss
    --- this panel's Nops, fall through to nvim's native mouse handler, and start a Visual selection over the row
    --- label under the pointer. Folding stays immediate (it never leaves the panel), and the row selection has
    --- already been moved by the caller — so the click still feels instant.
    ---@param line integer  1-based clicked buffer row
    ---@param col0 integer  0-based byte column
    local function click(line, col0)
        local e = state.rows[line]
        if not e then
            return
        end
        if e.c0 and col0 >= e.c0 and col0 < e.c1 then
            t.toggle(e.node.id) -- a fold toggle never leaves the panel — safe to run now
            return
        end
        mouse.defer_activation(expand_or_activate)
    end

    -- ─── the surface content provider ──────────────────────────────────────────

    ---@type table  the surface CONTENT PROVIDER — plug into `surface.open{ content.blocks }` / a tabs provider tab
    t.provider = {
        cursorline = opts.cursorline ~= false,
        hide_cursor = opts.hide_cursor == true,
        filetype = opts.filetype,
        --- Natural content size: the consumer's override, else measured from the current rows.
        ---@return integer width, integer height
        size = function()
            if opts.size then
                return opts.size()
            end
            -- Measure with the bar reserved: the natural width must leave room for it, since a panel sized to
            -- its content is exactly the one that may then overflow vertically and grow a scrollbar.
            local reserve = scrollbar and 1 or 0
            local lines = build(80, reserve)
            local w = 20
            for _, l in ipairs(lines) do
                -- the rows already carry `pad_left`; reserve the right side (padding + the scrollbar column)
                w = math.max(w, util.dw(l) + pad_right + reserve)
            end
            return w, math.max(1, #lines)
        end,
        --- Realise the tree in the (re)laid-out panel window — the provider OWNS the buffer.
        ---@param pan table
        update = function(pan)
            if state.pan == nil or state.pan.buf ~= pan.buf then
                state.pan = pan
                vim.bo[pan.buf].buftype = "nofile"
            else
                state.pan = pan
            end
            render()
        end,
        --- Chassis click seam (hide-cursor modal panels): the selection was already moved to `line`.
        ---@param _ table
        ---@param _st table
        ---@param line integer
        ---@param col0 integer
        on_click = function(_, _st, line, col0)
            click(line, col0)
        end,
        --- Key wiring at open: the canonical tree keys + mouse, then the consumer's own (`on_keys`).
        ---@param map fun(lhs: string|string[], fn: fun())
        ---@param pan table
        ---@param st table
        keys = function(map, pan, st)
            state.pan, state.st, state.map = pan, st, map
            local keys = opts.keys
            if keys ~= false then
                keys = keys or {}
                map(keys.activate or { "l", "<CR>" }, expand_or_activate)
                map(keys.collapse or "h", collapse_or_parent)
            end
            -- Mouse: the row-click is registered with the GLOBAL mouse layer (`lvim-utils.mouse`), NOT bound as a
            -- buffer-local `<LeftMouse>`. A buffer-local map only fires when the panel is ALREADY current — but
            -- the everyday case is clicking INTO the panel from the editor, where nvim runs its native click
            -- instead (moving focus AND parking the cursor on the clicked column, which is what let
            -- word-highlighters paint the row's label). The global layer decides by the window under the pointer,
            -- focuses the panel, parks the cursor at column 0, and calls this handler with the clicked (line,
            -- col0) — so chevron hit-testing still works. Registered for EVERY tree panel (modal or not).
            require("lvim-utils.mouse").register_click(pan.buf, function(line, col0)
                if vim.o.mouse == "" then
                    return
                end
                click(line, col0)
            end)
            if not t.provider.hide_cursor then
                map("<2-LeftMouse>", function()
                    local m = vim.fn.getmousepos()
                    if m.winid ~= pan.win then
                        return
                    end
                    local e = state.rows[m.line]
                    if e then
                        t.toggle(e.node.id)
                    end
                end)
            end
            -- Keep the cursor off the header rows (the tree starts below them) + notify row moves.
            api.nvim_create_autocmd("CursorMoved", {
                buffer = pan.buf,
                callback = function()
                    if state.destroyed or not (pan.win and api.nvim_win_is_valid(pan.win)) then
                        return
                    end
                    local line = api.nvim_win_get_cursor(pan.win)[1]
                    if
                        state.header_rows > 0
                        and line <= state.header_rows
                        and api.nvim_buf_line_count(pan.buf) > state.header_rows
                    then
                        api.nvim_win_set_cursor(pan.win, { state.header_rows + 1, 0 })
                        return -- the clamp re-fires CursorMoved; notify from that pass
                    end
                    if opts.on_move then
                        local e = state.rows[line]
                        opts.on_move(e and e.node or nil, t)
                    end
                end,
            })
            bind_actions() -- rows rendered before `keys` fires — bind what that pass collected
            if opts.on_keys then
                opts.on_keys(map, pan, st, t)
            end
        end,
        --- Surface teardown: kill the scrollbar provider, drop state, chain the consumer's hook.
        ---@param pan table
        on_close = function(pan)
            state.destroyed = true
            pcall(api.nvim_set_decoration_provider, ns_bar, {})
            if opts.on_close then
                pcall(opts.on_close, pan)
            end
            state.pan, state.st, state.map = nil, nil, nil
            state.rows, state.order = {}, {}
        end,
    }

    -- ─── the public API ────────────────────────────────────────────────────────

    --- Replace the top level: a LIST of top-level nodes, a single node, or a FACTORY re-run on every
    --- render (live re-decoration — the file-tree pattern). Repaints (coalesced).
    ---@param roots LvimUiTreeNode|LvimUiTreeNode[]|fun(): LvimUiTreeNode[]|nil
    function t.set_root(roots)
        if type(roots) == "table" and roots.id ~= nil then
            roots = { roots }
        end
        state.roots = roots
        t.refresh()
    end

    --- Repaint NOW (synchronous — e.g. right before `focus`).
    function t.render()
        render()
    end

    --- Coalesced repaint: any number of calls this tick collapse into ONE render on the next — and a
    --- SYNC `render()` in between satisfies the queue (the scheduled pass is skipped, not doubled).
    function t.refresh()
        if state.destroyed then
            return
        end
        state.dirty = true
        if state.queued then
            return
        end
        state.queued = true
        vim.schedule(function()
            state.queued = false
            if state.dirty then
                render()
            end
        end)
    end

    --- The node under the panel cursor (nil on a header row / no window).
    ---@return LvimUiTreeNode|nil
    function t.selected()
        local e = cur_entry()
        return e and e.node or nil
    end

    --- The node on buffer line `line` (nil on a header row).
    ---@param line integer
    ---@return LvimUiTreeNode|nil
    function t.node_at(line)
        local e = state.rows[line]
        return e and e.node or nil
    end

    --- The 1-based BUFFER line of the node `id`, or nil while it is not visible.
    ---@param id string
    ---@return integer|nil
    function t.row_of(id)
        for line, e in pairs(state.rows) do
            if e.node.id == id then
                return line
            end
        end
        return nil
    end

    --- The visible nodes in display order (the last render).
    ---@return LvimUiTreeNode[]
    function t.visible()
        local out = {}
        for i, e in ipairs(state.order) do
            out[i] = e.node
        end
        return out
    end

    --- Move the panel cursor onto the node `id` (must be visible — expand its ancestors first).
    ---@param id string
    ---@return boolean  whether the node was found
    function t.focus(id)
        local row = t.row_of(id)
        local pan = state.pan
        if row and pan and pan.win and api.nvim_win_is_valid(pan.win) then
            pcall(api.nvim_win_set_cursor, pan.win, { row, 0 })
            return true
        end
        return false
    end

    --- Whether the node `id` is currently expanded (override, else the instance default).
    ---@param id string
    ---@return boolean
    function t.expanded(id)
        return is_expanded(id)
    end

    --- Expand the node `id` (fires `on_expand`, repaints coalesced). No-op when already expanded.
    ---@param id string
    function t.expand(id)
        if is_expanded(id) then
            return
        end
        -- Explicit if/else: an `and nil or …` / `and false or …` chain silently falls through to the
        -- other branch (nil/false are falsy operands) and corrupts the fold state.
        if default_expanded then
            state.override[id] = nil -- back to the default (expanded)
        else
            state.override[id] = true
        end
        if opts.on_expand then
            local n = t.get(id)
            if n then
                opts.on_expand(n, t)
            end
        end
        t.refresh()
    end

    --- Collapse the node `id` (fires `on_collapse`, repaints coalesced). No-op when already collapsed.
    ---@param id string
    function t.collapse(id)
        if not is_expanded(id) then
            return
        end
        if default_expanded then
            state.override[id] = false
        else
            state.override[id] = nil -- back to the default (collapsed)
        end
        if opts.on_collapse then
            local n = t.get(id)
            if n then
                opts.on_collapse(n, t)
            end
        end
        t.refresh()
    end

    --- Toggle the node `id`'s fold.
    ---@param id string
    function t.toggle(id)
        if is_expanded(id) then
            t.collapse(id)
        else
            t.expand(id)
        end
    end

    --- Expand every KNOWN foldable node (lazy children of collapsed nodes are NOT loaded). Repaints.
    function t.expand_all()
        if default_expanded then
            state.override = {}
        else
            walk_known(top(), function(n)
                if expandable(n) then
                    state.override[n.id] = true
                end
            end)
        end
        t.refresh()
    end

    --- Collapse every KNOWN foldable node. Repaints.
    function t.collapse_all()
        if not default_expanded then
            state.override = {}
        else
            walk_known(top(), function(n)
                if expandable(n) then
                    state.override[n.id] = false
                end
            end)
        end
        t.refresh()
    end

    --- Whether every KNOWN foldable node currently resolves expanded.
    ---@return boolean
    function t.all_expanded()
        local all = true
        walk_known(top(), function(n)
            if expandable(n) and not is_expanded(n.id) then
                all = false
            end
        end)
        return all
    end

    --- Replace the WHOLE fold-override map in one step (an accordion/auto-fold recompute) — no
    --- per-node hooks, no repaint (call `render`/`refresh` after). Keys are node ids; a missing id
    --- resolves to the instance default.
    ---@param map table<string, boolean>
    ---@return boolean changed
    function t.set_expanded(map)
        map = map or {}
        if vim.deep_equal(state.override, map) then
            return false
        end
        local copy = {}
        for k, v in pairs(map) do
            copy[k] = v
        end
        state.override = copy
        return true
    end

    --- The live fold-override map (read-only; id → boolean, missing = the instance default).
    ---@return table<string, boolean>
    function t.expanded_state()
        return state.override
    end

    --- Find a node by `id` among the KNOWN nodes (see `walk_known` — never triggers a lazy load).
    ---@param id string
    ---@return LvimUiTreeNode|nil
    function t.get(id)
        -- The visible registry first (cheap, covers the common case), then the known walk.
        for _, e in pairs(state.rows) do
            if e.node.id == id then
                return e.node
            end
        end
        local found
        walk_known(top(), function(n)
            if n.id == id then
                found = n
            end
        end)
        return found
    end

    --- Mark ONE row (the outline's follow highlight) — a full-row `mark` tint re-applied on every
    --- repaint. `nil` clears it. `move_cursor` parks the panel cursor on the row when the panel is
    --- not the current window (so it never fights the user navigating inside it).
    ---@param id string|nil
    ---@param mopts? { move_cursor?: boolean }
    function t.mark(id, mopts)
        state.marked = id
        apply_mark(mopts and mopts.move_cursor == true)
    end

    --- Expand a collapsed node / activate — the canonical `l`/`<CR>` (exposed for consumer keymaps).
    function t.expand_or_activate()
        expand_or_activate()
    end

    --- Collapse an expanded node / jump to the parent row — the canonical `h`.
    function t.collapse_or_parent()
        collapse_or_parent()
    end

    --- The panel buffer (nil before the surface opened / after close).
    ---@return integer|nil
    function t.buf()
        return state.pan and state.pan.buf
    end

    --- The panel window (nil before the surface opened / after close).
    ---@return integer|nil
    function t.win()
        return state.pan and state.pan.win
    end

    --- Whether the tree's panel window is live.
    ---@return boolean
    function t.valid()
        local w = t.win()
        return w ~= nil and api.nvim_win_is_valid(w)
    end

    if opts.root ~= nil then
        local r = opts.root
        if type(r) == "table" and r.id ~= nil then
            r = {
                r --[[@as LvimUiTreeNode]],
            }
        end
        state.roots = r --[[@as LvimUiTreeNode[]|fun(): LvimUiTreeNode[] ]]
    end

    return t
end

return M
