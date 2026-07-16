-- lvim-ui.form: a `frame` center provider for typed, EDITABLE rows — bool (toggle), select /
-- segmented (cycle), int / number / string / text (edit via vim.ui.input), action (run), and
-- expandable tree rows. Reuses the rows.lua row model (row_display / navigation). Non-selectable rows
-- (spacers) are skipped by j/k; the focused row is shown via the panel's cursorline.
--
-- A `form` is the center of the `tabs` / popup-style frames; switching a tab swaps the row set in place
-- (`set_rows`), and because the row tables are mutated IN PLACE, a consumer's captured rows (e.g. the
-- Quit dialog's action closures) always see the current values.
--
---@module "lvim-ui.form"

local rows = require("lvim-ui.rows")
local config = require("lvim-ui.config")
local util = require("lvim-ui.util")
local bar = require("lvim-ui.bar")

local api = vim.api

local M = {}

--- Create a form provider.
---@param opts { rows: Row[], on_change?: fun(row: Row), ico?: table, cursorline_hl?: string, pad?: integer, initial_row?: integer|string, on_move?: fun(row: Row?), on_cursor?: fun(), on_action_close?: fun(confirmed: boolean|nil, result: any) }
---       cursorline_hl: name a cursorline highlight group (e.g. a bg-only one) so the hover changes only the
---       background and a row's own fg highlights survive; default = the frame's yellow "list hover".
---@return table provider
function M.new(opts)
    local model = opts.rows or {}
    local ico = opts.ico or rows.icons()
    local on_change = opts.on_change
    local pan

    -- The visible rows (tree flattened, collapsed children hidden). The window line N maps to flat[N].
    -- Memoized: `flat()` is called ≥2× per keystroke (move / bar_nav / cycle / activate / render / CursorMoved
    -- / hints / cursor_name), and re-flattening the whole tree each time is pure waste. Only the SET (set_rows)
    -- and an accordion's EXPAND/COLLAPSE change the flattening — value edits do not — so we rebuild only when
    -- `invalidate_flat()` is called at those two seams.
    ---@type Row[]?
    local flat_cache
    local function flat()
        if not flat_cache then
            flat_cache = rows.flatten(model, false)
        end
        return flat_cache
    end
    local function invalidate_flat()
        flat_cache = nil
    end
    local function refresh()
        if pan and pan.refresh then
            pan.refresh()
        end
    end
    local function cur_line()
        if pan and pan.win and api.nvim_win_is_valid(pan.win) then
            return api.nvim_win_get_cursor(pan.win)[1]
        end
        return 1
    end

    --- A row is DISABLED when its `disabled` field is `true`, or a PREDICATE that returns true — evaluated LIVE
    --- (so it tracks a parent toggle, e.g. relative line numbers being inert while "show line numbers" is off).
    --- A disabled row renders dimmed + struck through and does not activate; its value is never changed.
    ---@param row Row|nil
    ---@return boolean
    local function is_disabled(row)
        local d = row and row.disabled
        if type(d) == "function" then
            ---@cast d fun(row: Row): boolean
            local ok, res = pcall(d, row)
            return ok and res == true
        end
        return d == true
    end
    local function move(delta)
        if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
            return
        end
        local nxt = rows.next_selectable(flat(), cur_line(), delta)
        if nxt then
            pcall(api.nvim_win_set_cursor, pan.win, { nxt, 0 })
        end
    end

    --- If the cursor sits on a `bar` row, move its focused button by `delta` (wrapping, skipping separators)
    --- and refresh; return true (handled). Else return false so the caller can act (e.g. switch tabs on h/l).
    ---@param delta integer
    ---@return boolean
    local function bar_nav(delta)
        local row = flat()[cur_line()]
        if not (row and row.type == "bar") then
            return false
        end
        local items = row.items or {}
        local n = #items
        if n == 0 then
            return true
        end
        -- Start from the keyboard cursor, or (first move) from the currently-active button.
        local i = row._sel
        if i == nil then
            i = 1
            for j, it in ipairs(items) do
                if it.active then
                    i = j
                end
            end
        end
        for _ = 1, n do
            i = (i + delta - 1) % n + 1
            if (items[i].type or "button") ~= "separator" then
                break
            end
        end
        row._sel = i
        refresh()
        return true
    end

    --- Cycle a SELECT / SEGMENTED row's value by `delta` options (wrapping both ways). Returns true if it
    --- acted on such a row. The ONE engine for forward (<CR>) and backward (<BS>) value cycling.
    ---@param delta integer
    ---@return boolean
    local function cycle_value(delta)
        local row = flat()[cur_line()]
        if not (row and (row.type == "select" or row.type == "segmented")) then
            return false
        end
        local list = row.options or {}
        if #list == 0 then
            return false
        end
        local cur = 1
        for i, o in ipairs(list) do
            if o == row.value then
                cur = i
                break
            end
        end
        row.value = list[((cur - 1 + delta) % #list) + 1]
        if row.run then
            row.run(row.value)
        end
        if on_change then
            on_change(row)
        end
        refresh()
        return true
    end

    --- Context hints for the focused row: `{ { key, label }, … }` describing what the keys do on THIS row
    --- (the dynamic RIGHT half of a footer legend). Empty for a spacer / nil row.
    ---@param row Row|nil
    ---@return { key: string, label: string, act: string }[]  `act`: "next" | "prev" | "activate" (for clicks)
    local function row_hints(row)
        if not row then
            return {}
        end
        -- The key glyphs and the labels are PRESENTATION (`config.form_hints`), not logic — the user sees
        -- them, so they belong in the config with everything else the panel shows.
        local H = config.form_hints or {}
        local K_ACT, K_NEXT, K_PREV = H.activate or "↵", H.next or "↵/→", H.prev or "⌫/←"
        local L = H.labels or {}
        if row.children then
            local label = row.expanded and (L.collapse or "Collapse") or (L.expand or "Expand")
            return { { key = K_ACT, label = label, act = "activate" } }
        end
        local t = row.type
        if t == "select" or t == "segmented" then
            return {
                { key = K_NEXT, label = L.next or "Next", act = "next" },
                { key = K_PREV, label = L.prev or "Prev", act = "prev" },
            }
        elseif t == "bool" or t == "boolean" then
            return { { key = K_ACT, label = L.toggle or "Toggle", act = "activate" } }
        elseif t == "action" then
            -- only a RUNNABLE action advertises its key; display-only action rows (e.g. a package's State /
            -- Status / Version detail fields carry `type = "action"` for styling but no `run`) advertise nothing.
            return row.run and { { key = K_ACT, label = L.run or "Run", act = "activate" } } or {}
        elseif t == "int" or t == "integer" or t == "float" or t == "number" or t == "string" or t == "text" then
            return { { key = K_ACT, label = L.edit or "Edit", act = "activate" } }
        end
        return {}
    end

    --- Act on the focused row by type. `st` is the frame state (for action rows that close).
    ---@param st table
    local function activate(st)
        local row = flat()[cur_line()]
        if not row or is_disabled(row) then
            return -- a disabled setting is inert: no toggle / cycle / edit / run
        end
        if row.type == "bar" then
            -- Run the keyboard-focused button (h/l / ←/→), or the active one if not navigated yet.
            local sel = row._sel
            if sel == nil then
                sel = 1
                for j, it in ipairs(row.items or {}) do
                    if it.active then
                        sel = j
                    end
                end
            end
            local btn = (row.items or {})[sel]
            if btn and btn.run then
                btn.run()
            end
            return
        end
        local t = row.type
        if row.children then
            row.expanded = not row.expanded
            invalidate_flat()
            refresh()
            if on_change then
                on_change(row) -- an accordion FOLD is a change (a consumer may re-count / persist collapse)
            end
        elseif t == "bool" or t == "boolean" then
            row.value = not row.value
            if row.run then
                row.run(row.value) -- the row's own setter (e.g. writes into the pending settings)
            end
            if on_change then
                on_change(row)
            end
            refresh()
        elseif t == "select" or t == "segmented" then
            cycle_value(1) -- forward; <BS> calls cycle_value(-1) for backward
        elseif t == "int" or t == "integer" or t == "float" or t == "number" or t == "string" or t == "text" then
            local numeric = t ~= "string" and t ~= "text"
            require("lvim-ui").input({
                prompt = row.label or row.name or "",
                default = tostring(row.value ~= nil and row.value or row.default or ""),
                callback = function(confirmed, input)
                    if confirmed ~= true then
                        return
                    end
                    if numeric then
                        local n = tonumber(input)
                        if not n then
                            vim.notify("Invalid number: " .. tostring(input), vim.log.levels.WARN)
                            return
                        end
                        row.value = n
                    else
                        row.value = input
                    end
                    if row.run then
                        row.run(row.value)
                    end
                    if on_change then
                        on_change(row)
                    end
                    refresh()
                end,
            })
        elseif t == "action" and row.run then
            row.run(row.value, function(confirmed, result)
                st.close()
                if opts.on_action_close then
                    opts.on_action_close(confirmed, result)
                end
            end)
        end
    end

    return {
        hide_cursor = true,
        cursorline = opts.cursorline_hl or true,
        --- Exposed for an external footer legend: the focused row's context hints, plus the actions a hint click
        --- runs (cycle a value by ±1; activate = run/toggle/edit the focused row).
        ---@return { key: string, label: string, act: string }[]
        hints = function()
            return row_hints(flat()[cur_line()])
        end,
        --- Cycle the focused select/segmented row's value by a delta (±1). Returns false when the row is not
        --- cyclable (so a caller can fall back to e.g. moving a toolbar button). See `cycle_value`.
        cycle = cycle_value,
        --- Activate the focused row (toggle / edit / run), per its type; takes the frame state. See `activate`.
        act = activate,
        --- Content size the frame should allocate: the widest rendered row (+4 padding) and the row count.
        ---@return integer width, integer height
        size = function()
            local fr = flat()
            local w = 1
            for _, r in ipairs(fr) do
                w = math.max(w, util.dw(rows.row_display(r, ico)) + 4)
            end
            return w, math.max(1, #fr)
        end,
        --- Render the current rows to `width` columns: returns the line strings plus the highlight spans
        --- (`{ row, col_start, col_end, group, priority? }`) the panel applies.
        ---@param width integer
        ---@return string[] lines, table[] hls
        render = function(width)
            local fr = flat()
            local lines, hls = {}, {}
            local lead = opts.pad or 2
            for i, r in ipairs(fr) do
                -- row_display owns the row layout and hands back its byte anchors: `icon_at` (offset of
                -- `r.icon` within `disp`, tracking `tight`/`flat`) and `type_w` (the leading auto-glyph width).
                -- The per-part colouring below just adds the body lpad (`lead`) — it never re-derives the layout.
                local disp, icon_at, type_w = rows.row_display(r, ico)
                if r.type == "bar" then
                    -- A toolbar row rendered through the SHARED ui.bar: centered button boxes that own their
                    -- overflow chevrons (so a wide bar scrolls instead of clipping). Three button states:
                    -- NORMAL, ACTIVE (the applied button — `active=true`), and HOVER (the keyboard cursor
                    -- `_sel`, shown ONLY while the cursor is on THIS row, so off the bar only `active` shows).
                    -- `_cells` (per-button byte ranges) is stashed for the click handler.
                    local items = r.items or {}
                    local active_idx
                    for j, it in ipairs(items) do
                        if it.active then
                            active_idx = j
                        end
                    end
                    -- While the cursor is on this row, the HOVER follows `_sel` (the navigated button), or — if
                    -- it hasn't been navigated yet (e.g. just after activating: the rebuild resets `_sel`) —
                    -- the ACTIVE button, so the just-applied button reads as hover_active (cursor on active).
                    local focused = cur_line() == i
                    local res = bar.render({
                        items = items,
                        width = width,
                        align = r.align or "center",
                        sel = r._sel or active_idx, -- scroll-anchor (keep the cursor / active button in view)
                        hover = focused and (r._sel or active_idx) or nil,
                        off = r._off,
                    })
                    r._off = res.off
                    r._cells = res.items
                    lines[i] = res.line
                    -- A continuous full-width bg strip under the bar — what the surface paints under header
                    -- bands (LvimUiBarFill) but which ui.bar itself does NOT emit; at a lower priority so the
                    -- button spans (incl. a hover_active bg) read on top.
                    hls[#hls + 1] = { i - 1, 0, -1, "LvimUiBarFill", 150 }
                    for _, s in ipairs(res.spans) do
                        hls[#hls + 1] = { i - 1, s[1], s[2], s[3] }
                    end
                elseif not rows.is_selectable(r) then
                    lines[i] = r.center and util.center(disp, width) or util.lpad(disp, width, lead)
                    -- A spacer / divider row (the `──────` between groups) takes the separator colour — UNLESS it
                    -- carries an explicit `hl` (e.g. a wrapped value's continuation SPACER), in which case honour
                    -- hl.inactive so the wrap matches its field's value instead of taking the separator colour.
                    if r.type == "spacer" or r.type == "spacer_line" then
                        local sep = (r.hl and type(r.hl.inactive) == "string") and r.hl.inactive or "LvimUiSeparator"
                        hls[#hls + 1] = { i - 1, 0, #lines[i], sep }
                    end
                elseif is_disabled(r) then
                    -- A DISABLED setting: dim (fg muted toward bg) + strike through the WHOLE row, with NO
                    -- per-part colours — it reads as present but inert (its value is never changed).
                    lines[i] = util.lpad(disp, width, lead)
                    hls[#hls + 1] = { i - 1, 0, #lines[i], "LvimUiRowDisabled", 250 }
                else
                    lines[i] = util.lpad(disp, width, lead)
                    -- A FULL-WIDTH background strip (edge to edge, hl_eol) under the whole row — a section
                    -- header reads as one solid band. Low priority (100) so the per-part fg spans below
                    -- (icon_hl / text_hl, default priority 200) render on top. `row_hl` may be a plain group
                    -- or a `{ inactive, active }` pair — the `active` band shows only while THIS window is
                    -- focused AND the cursor is on the row (a real HOVER, like the cursorline: it must not
                    -- linger when focus leaves for another sector). Re-rendered on cursor move + win focus change.
                    if r.row_hl then
                        local rhl = r.row_hl
                        if type(rhl) == "table" then
                            local hovered = cur_line() == i
                                and pan
                                and pan.win
                                and api.nvim_get_current_win() == pan.win
                            rhl = hovered and rhl.active or rhl.inactive
                        end
                        if rhl then
                            hls[#hls + 1] = { i - 1, 0, -1, rhl, 100 }
                        end
                    end
                    -- Colour the leading type icon (the auto glyph row_display places at the row start); the
                    -- rest reads on the panel background. `type_w` is that glyph's width straight from
                    -- row_display — never re-derived, so it can't drift (e.g. segmented rows, which have no
                    -- type glyph, report 0 and are correctly left alone).
                    if type_w > 0 then
                        hls[#hls + 1] = { i - 1, lead, lead + type_w, "LvimUiRowIconInactive" }
                    end
                    -- Per-part colours an action / accordion row can request: `icon_hl` on its `icon` column,
                    -- `text_hl` on the label/value, `suffix_hl` on the trailing suffix. Offsets come from
                    -- `icon_at` (row_display's own layout) + the body lpad `lead` — never re-derived here, so a
                    -- `tight` row (which drops the 2-space separator) colours correctly at any `pad`.
                    if
                        (r.type == "action" or r.children) and (r.icon_hl or r.text_hl or r.suffix_hl or r.label_spans)
                    then
                        local base = lead + (icon_at or 0)
                        local ricon = (r.icon and r.icon ~= "") and r.icon or nil
                        if ricon and r.icon_hl then
                            hls[#hls + 1] = { i - 1, base, base + #ricon, r.icon_hl }
                        end
                        local label = r.label or r.name or ""
                        local ls = base + (ricon and (#ricon + 1) or 0)
                        if r.label_spans and label ~= "" then
                            -- Per-SEGMENT label colours: a list of `{ c0, c1, hl }` BYTE offsets INTO the label
                            -- (so a row can paint e.g. its location one colour and its snippet another). Takes
                            -- precedence over the single `text_hl`. CLAMP each span's end to the rendered line —
                            -- a `tabs`/menu row truncates a long label (with `…`), so a span reaching past the cut
                            -- would be an out-of-range extmark that nvim REJECTS, silently dropping the colour of
                            -- the whole segment (e.g. a long reflog description losing its yellow).
                            local line_len = #lines[i]
                            for _, sp in ipairs(r.label_spans) do
                                local c0, c1 = ls + sp[1], math.min(ls + sp[2], line_len)
                                if c1 > c0 then
                                    hls[#hls + 1] = { i - 1, c0, c1, sp[3] }
                                end
                            end
                        elseif r.text_hl and label ~= "" then
                            -- Clamped to the rendered line for the same reason as `label_spans` above: a long
                            -- label is truncated, and a span reaching past the cut is an out-of-range extmark
                            -- that nvim rejects — silently dropping the row's colour entirely.
                            local c1 = math.min(ls + #label, #lines[i])
                            if c1 > ls then
                                hls[#hls + 1] = { i - 1, ls, c1, r.text_hl }
                            end
                        end
                        if r.suffix and r.suffix ~= "" and r.suffix_hl then
                            local suffix_start = math.max(lead, math.min(#lines[i], lead + #disp - #r.suffix))
                            hls[#hls + 1] =
                                { i - 1, suffix_start, math.min(#lines[i], suffix_start + #r.suffix), r.suffix_hl }
                        end
                    end
                    -- A file row's label = "<dimmed path>/<bright name>". `r.dim_to` is a byte count into the
                    -- LABEL (the SUFFIX of `disp`); anchored at the label's real start (body lpad + the row's
                    -- icon offset + the icon column), clamped to the rendered line. Dim the path, brighten the
                    -- name, so the name stands out.
                    if r.dim_to and r.dim_to > 0 and type(r.label) == "string" then
                        local lstart = lead + (icon_at or 0) + ((r.icon and r.icon ~= "") and (#r.icon + 1) or 0)
                        local dim_end = math.min(lstart + r.dim_to, #lines[i])
                        if dim_end > lstart then
                            hls[#hls + 1] = { i - 1, lstart, dim_end, "LvimUiPathDim" }
                        end
                        local name_start, name_end = lstart + r.dim_to, math.min(lstart + #r.label, #lines[i])
                        if name_end > name_start then
                            hls[#hls + 1] = { i - 1, name_start, name_end, "LvimUiPathName" }
                        end
                    end
                end
            end
            return lines, hls
        end,
        --- Install the panel's keymaps and cursor autocmds: j/k navigation, ↵ activate, ←/→ cycle-or-bar-nav,
        --- ⌫ cycle-back, and toolbar click hit-testing. `map(lhs, fn)` binds keys on the panel; `p` is the
        --- panel handle (`.win` / `.buf`); `st` is the frame state passed through to activate.
        ---@param map fun(lhs: string|string[], fn: fun())
        ---@param p table
        ---@param st table
        keys = function(map, p, st)
            pan = p
            local fr = flat()
            -- Honour an `initial_row` hint (a row `name` or 1-based index) so a caller can open
            -- FOCUSED on a specific row (e.g. jump-to-setting); falls back to the first selectable.
            local first = rows.resolve_initial_row(fr, opts.initial_row)
            vim.schedule(function()
                if p.win and api.nvim_win_is_valid(p.win) then
                    pcall(api.nvim_win_set_cursor, p.win, { first, 0 })
                    local r0 = flat()[first]
                    vim.wo[p.win].cursorline = not (r0 ~= nil and r0.type == "bar")
                end
            end)
            map({ "j", "<Down>" }, function()
                move(1)
            end)
            map({ "k", "<Up>" }, function()
                move(-1)
            end)
            map({ "<CR>" }, function()
                activate(st)
            end)
            -- ←/→ cycle a select/segmented value (← back, → forward); on a toolbar `bar` row they instead move
            -- the focused button. ⌫ also cycles a value backward (the documented key).
            map({ "<Left>" }, function()
                if not cycle_value(-1) then
                    bar_nav(-1)
                end
            end)
            map({ "<Right>" }, function()
                if not cycle_value(1) then
                    bar_nav(1)
                end
            end)
            map({ "<BS>" }, function()
                cycle_value(-1)
            end)
            -- Click a toolbar (`type="bar"`) button: hit-test the click column against the row's rendered
            -- button cells and run that button. Any other click falls back to plain cursor positioning.
            map({ "<LeftMouse>" }, function()
                local mp = vim.fn.getmousepos()
                if mp.winid ~= p.win or mp.line < 1 then
                    return
                end
                local r = flat()[mp.line]
                if r and r.type == "bar" and r._cells then
                    local col0 = mp.column - 1
                    for _, cell in ipairs(r._cells) do
                        if cell.c0 and cell.c1 and col0 >= cell.c0 and col0 < cell.c1 then
                            if cell.spec and cell.spec.run then
                                cell.spec.run()
                            end
                            return
                        end
                    end
                    return
                end
                if r and rows.is_selectable(r) and p.win and api.nvim_win_is_valid(p.win) then
                    pcall(api.nvim_win_set_cursor, p.win, { mp.line, math.max(0, mp.column - 1) })
                    -- Click = focus the row AND do exactly what <CR> does on it: `activate` reads the row now
                    -- under the cursor and dispatches by type — accordion fold, checkbox toggle, select cycle,
                    -- action run (a menu item / footer-less button), numeric/string edit. It self-guards a
                    -- disabled or non-actionable row (a display-only detail field), so a stray click is inert.
                    activate(st)
                end
            end)
            -- On a `bar` row, suppress the full-row cursorline (only the button HOVER should read) and
            -- re-render so the hover follows the cursor; off a bar row, restore cursorline. A row with a
            -- `{ inactive, active }` `row_hl` (a hover band, e.g. a section header) likewise needs a re-render
            -- as the cursor enters / leaves it. Refresh only on such a boundary cross, so plain list
            -- navigation stays cheap.
            local was_bar = false
            local was_hover = false
            local last_hint_sig -- the footer legend's last hint SIGNATURE — re-notify only when the hints change
            api.nvim_create_autocmd("CursorMoved", {
                buffer = p.buf,
                callback = function()
                    if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
                        return
                    end
                    local r = flat()[cur_line()]
                    if opts.on_move then
                        opts.on_move(r) -- raw, every move (no dedup) — drives an item-list picker's live preview
                    end
                    local is_bar = r ~= nil and r.type == "bar"
                    local is_hover = r ~= nil and type(r.row_hl) == "table"
                    vim.wo[pan.win].cursorline = not is_bar
                    if is_bar or was_bar or is_hover or was_hover then
                        refresh()
                    end
                    was_bar = is_bar
                    was_hover = is_hover
                    -- The footer legend's RIGHT half tracks the row's hints, which depend only on the row TYPE
                    -- (+ an accordion's expand state) — so re-notify only when THAT changes, not on every row.
                    if opts.on_cursor then
                        -- Signature of the row's HINTS — re-notify the footer only when it changes. It is the row
                        -- TYPE, plus an accordion's expand state, plus an action row's run-ness (a runnable action
                        -- advertises ↵ Run, a display-only one advertises nothing — so they must differ here).
                        local sig
                        if not r then
                            sig = ""
                        elseif r.children then
                            sig = "acc:" .. tostring(r.expanded)
                        elseif r.type == "action" then
                            sig = "act:" .. tostring(r.run ~= nil)
                        else
                            sig = r.type or ""
                        end
                        if sig ~= last_hint_sig then
                            last_hint_sig = sig
                            opts.on_cursor()
                        end
                    end
                end,
            })
            -- A `{ inactive, active }` row_hl (a hover band) is gated on THIS window being current, so it must
            -- be repainted when focus LEAVES for another sector (drop the lingering hover) and when it RETURNS
            -- (restore it). Buffer-scoped, so it costs nothing for other windows; `vim.schedule` so the current
            -- window reflects the completed switch.
            api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
                buffer = p.buf,
                callback = function()
                    vim.schedule(function()
                        if pan and pan.win and api.nvim_win_is_valid(pan.win) then
                            refresh()
                        end
                    end)
                end,
            })
        end,
        --- Swap the row set in place (tab switch) and re-render; land the cursor on the first selectable
        --- row of the new set (else it lingers on a now-stale / non-selectable line).
        ---@param new_rows Row[]
        set_rows = function(new_rows)
            model = new_rows
            invalidate_flat()
            refresh()
            if pan and pan.win and api.nvim_win_is_valid(pan.win) then
                pcall(api.nvim_win_set_cursor, pan.win, { rows.first_selectable(flat()) or 1, 0 })
            end
        end,
        --- The `name` of the row under the cursor (nil for an unnamed / empty row). A consumer handle uses
        --- it to dispatch actions on the focused row.
        ---@return string?
        cursor_name = function()
            local r = flat()[cur_line()]
            return r and r.name or nil
        end,
        --- The 1-based window line of the cursor — a stable index to restore after a rebuild.
        ---@return integer
        cursor_index = function()
            return cur_line()
        end,
        --- Move the cursor to the FIRST row whose `name` matches, expanding the target's collapsed ancestors
        --- so a nested (e.g. detail / action) row becomes visible first.
        ---@param name string
        ---@return boolean
        focus_name = function(name)
            if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
                return false
            end
            -- Expand the ancestor chain of the target (each parent on the path to a matching descendant).
            local function expand_to(list)
                for _, r in ipairs(list) do
                    if r.name == name then
                        return true
                    end
                    if r.children and expand_to(r.children) then
                        r.expanded = true
                        return true
                    end
                end
                return false
            end
            if expand_to(model) then
                invalidate_flat()
                refresh()
            end
            for i, r in ipairs(flat()) do
                if r.name == name then
                    pcall(api.nvim_win_set_cursor, pan.win, { i, 0 })
                    return true
                end
            end
            return false
        end,
        --- Move the cursor to (a clamped) window line `i`.
        ---@param i integer
        ---@return boolean
        focus_index = function(i)
            if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
                return false
            end
            local n = #flat()
            if n == 0 then
                return false
            end
            pcall(api.nvim_win_set_cursor, pan.win, { math.max(1, math.min(i, n)), 0 })
            return true
        end,
        --- Re-paint the current rows in place (after a consumer mutated row values, without changing the set).
        rerender = function()
            refresh()
        end,
        --- Move a focused toolbar's button when the cursor is on a `bar` row; return true if handled (so a
        --- caller's own h/l — e.g. a tab switch — is suppressed while on a bar row).
        ---@param delta integer
        ---@return boolean
        bar_nav = function(delta)
            return bar_nav(delta)
        end,
        --- Fold/unfold the accordion row under the cursor: `open=true` expands a collapsed section,
        --- `open=false` collapses an expanded one. Returns true only when it ACTED (the cursor is on an
        --- accordion AND its state changed) — so a caller can chain h/l as "unfold, else switch tab" (the
        --- cursor already at the target state falls through). Fires on_change like the other fold paths.
        ---@param open boolean
        ---@return boolean
        fold = function(open)
            local row = flat()[cur_line()]
            if not (row and row.children) or is_disabled(row) or row.expanded == open then
                return false
            end
            row.expanded = open
            invalidate_flat()
            refresh()
            if on_change then
                on_change(row)
            end
            return true
        end,
    }
end

return M
