-- lvim-ui.bar: a responsive horizontal bar of `ui.button` ELEMENTS (buttons + separators).
--
-- Lays out a list of `items` (each a `button` or `separator` spec — see ui.button) into a single
-- width-bounded line: ALIGNED (left / center / right) when it fits, else SCROLLED inside the width with
-- chevron BOXES on the overflowing side(s) — keeping the focused item `sel` visible. Inter-item spacing
-- is NOT a bar setting: insert explicit `separator` items (a separator with no text = a pure gap).
--
-- Chevrons are the bar's OWN job: it ships default chevron boxes (glyph + padding + hl), reserves their
-- measured width on each side, draws them only on the side that actually overflows, and the caller may
-- override the glyph / padding / colour per bar. Each item's STATE is chosen here:
-- hover_active (hover ON the active button) > hover (opts.hover == i) > active (spec.active) > normal.
--
-- Returns the line plus, in BYTE columns of that line, the hl spans (incl. the chevrons' own colours),
-- the chevron ranges, and per-item visible ranges ({ c0, c1, spec }; c0/c1 nil = scrolled out) so the
-- caller can place extmarks, hit-test the mouse and draw its own selection overlay.
--
-- All glyphs are single display width, so a character column equals a display column.
--
---@module "lvim-ui.bar"

local button = require("lvim-ui.button")
local util = require("lvim-ui.util")

local M = {}

--- Default chevron boxes (a `separator`-shaped box each). The bar owns overflow, so these ship as
--- defaults; a caller overrides `chevrons.left` / `chevrons.right` (glyph via `text`, spacing via
--- `style.padding`, colour via `style.hl`) only when it wants something else.
--- The default chevron BOXES, built from the shared glyph config (`config.chevrons`). They used to ship with
--- `text = ""` — an EMPTY string — so every bar that did not pass its own chevrons drew INVISIBLE overflow
--- markers: the buttons were silently cut off with nothing to say so. Only a consumer that explicitly passed
--- `surface.chevrons(hl)` (the control center) ever showed them, which is why it looked like a per-panel quirk.
---@return table left, table right
local function default_chevrons()
    local g = require("lvim-ui.config").chevrons or {}
    local box = function(text)
        return { type = "separator", text = text, style = { padding = { 1, 1 }, hl = "LvimUiBarChevron" } }
    end
    return box(g.left or "❮"), box(g.right or "❯")
end

---@param c table|nil
---@return table left, table right
local function resolve_chevrons(c)
    c = c or {}
    local dl, dr = default_chevrons()
    local left = vim.tbl_deep_extend("force", dl, c.left or {})
    local right = vim.tbl_deep_extend("force", dr, c.right or {})
    return left, right
end

--- The natural display width of a bar = the sum of its rendered items (no inter-item gap — spacing is
--- expressed as explicit `separator` items). Lets a caller size a window to fit the bar un-scrolled.
---@param items LvimUiButtonSpec[]
---@return integer
function M.width(items)
    local total = 0
    for _, spec in ipairs(items or {}) do
        total = total + vim.fn.strdisplaywidth((button.render(spec, "normal")))
    end
    return total
end

---@param opts { items: LvimUiButtonSpec[], width: integer, align?: "left"|"center"|"right", chevrons?: table, sel?: integer, hover?: integer, off?: integer, title?: string, title_hl?: string }
---@return { line: string, spans: table[], chevrons: table[], items: table[], off: integer }
function M.render(opts)
    local W = opts.width or 0
    local align = opts.align or "center"

    -- An optional LEFT-anchored TITLE prefix (always visible): the items then lay out in the width AFTER it
    -- (e.g. a "Messages"/"Diagnostics" title with the buttons/counter aligned to the right). Prepended at the
    -- very end, with all item/chevron offsets shifted by it (in BYTES). the bar TITLE is shown UPPERCASE
    -- everywhere (the canon — via util.title_case, which also trims stray padding).
    -- Symmetric gutter: 1 cell before the title and 1 after (the single title-padding canon).
    local prefix = (opts.title and opts.title ~= "") and (" " .. util.title_case(opts.title) .. " ") or ""
    local pb = #prefix -- BYTE length — the offset the item/chevron/span byte ranges are shifted by below
    if pb > 0 then
        -- Reserve the prefix's DISPLAY width (NOT its byte length) from the layout width: a title with a
        -- nerd-font ICON is multibyte, so `#prefix` overshoots and would leave the row (and its fill strip)
        -- short of the right edge by (bytes − cells). strdisplaywidth measures the real columns it occupies.
        W = math.max(1, W - vim.fn.strdisplaywidth(prefix))
    end

    -- 1. Assemble the raw bar text, its hl spans and each item's raw byte range (with its spec). No
    -- inter-item gap: a `separator` item carries any spacing itself. Indices stay aligned with opts.items.
    local t, raw_spans, raw_items = "", {}, {}
    for i, spec in ipairs(opts.items or {}) do
        local state = (opts.hover == i and spec.active and "hover_active")
            or (opts.hover == i and "hover")
            or (spec.active and "active")
            or "normal"
        local itxt, ispans = button.render(spec, state)
        local base = #t
        for _, s in ipairs(ispans) do
            raw_spans[#raw_spans + 1] = { base + s[1], base + s[2], s[3] }
        end
        raw_items[i] = { base, base + #itxt, spec, sep = spec.type == "separator" }
        t = t .. itxt
    end

    -- 2. Place it into the width: aligned when it fits, else a scrolled window flanked by chevron boxes.
    local tw = vim.fn.strchars(t)
    local line, shift, lo, hi
    local chevrons, chev_spans = {}, {}
    if tw <= W then
        local pad = (align == "left" and 0) or (align == "right" and (W - tw)) or math.floor((W - tw) / 2)
        pad = math.max(0, pad)
        line = string.rep(" ", pad) .. t
        line = line .. string.rep(" ", math.max(0, W - vim.fn.strchars(line)))
        shift, lo, hi = pad, 0, tw
    else
        local lspec, rspec = resolve_chevrons(opts.chevrons)
        local ltxt, lsp = button.render(lspec, "normal")
        local rtxt, rsp = button.render(rspec, "normal")
        local lw, rw = vim.fn.strdisplaywidth(ltxt), vim.fn.strdisplaywidth(rtxt)

        -- Resolve the scroll offset AND which chevrons show TOGETHER: a chevron reserves its width ONLY on a
        -- side that is actually clipped, so the content GLUES to its alignment edge (right-align → flush right,
        -- left → flush left, centre → equal margins) with no reserved gap. A side turning on/off changes the
        -- inner width, so iterate to a stable set (settles in ≤ 3).
        local show_left, show_right, off, inner = false, false, 0, W
        for _ = 1, 3 do
            inner = math.max(1, W - (show_left and lw or 0) - (show_right and rw or 0))
            off = opts.off
            if off == nil then -- anchor by alignment when the caller does not persist a scroll position
                off = (align == "right" and (tw - inner)) or (align == "center" and math.floor((tw - inner) / 2)) or 0
            end
            local selitem = opts.sel and raw_items[opts.sel]
            if selitem then -- keep the focused item visible
                local s0 = vim.fn.strchars(string.sub(t, 1, selitem[1]))
                local s1 = vim.fn.strchars(string.sub(t, 1, selitem[2]))
                if s0 < off then
                    off = s0
                elseif s1 > off + inner then
                    off = s1 - inner
                end
            end
            off = math.max(0, math.min(off, tw - inner))
            local nl, nr = off > 0, (off + inner) < tw
            if nl == show_left and nr == show_right then
                break
            end
            show_left, show_right = nl, nr
        end
        opts.off = off

        local left_str = show_left and ltxt or ""
        local right_str = show_right and rtxt or ""
        local vis = vim.fn.strcharpart(t, off, inner)
        vis = vis .. string.rep(" ", math.max(0, inner - vim.fn.strchars(vis)))
        line = left_str .. vis .. right_str
        shift, lo, hi = (show_left and lw or 0) - off, off, off + inner

        -- Chevron boxes carry their OWN colour: emit their spans (byte-based, no char shift) + ranges.
        if show_left then
            for _, s in ipairs(lsp) do
                chev_spans[#chev_spans + 1] = { s[1], s[2], s[3] }
            end
            chevrons[#chevrons + 1] = { 0, #left_str }
        end
        if show_right then
            local rbase = #left_str + #vis
            for _, s in ipairs(rsp) do
                chev_spans[#chev_spans + 1] = { rbase + s[1], rbase + s[2], s[3] }
            end
            chevrons[#chevrons + 1] = { rbase, #line }
        end
    end

    -- 3. Map raw (byte) ranges in `t` to byte ranges in the final `line` (nil = scrolled out of view).
    local function vis_bytes(bc0, bc1)
        local c0 = math.max(vim.fn.strchars(string.sub(t, 1, bc0)), lo)
        local c1 = math.min(vim.fn.strchars(string.sub(t, 1, bc1)), hi)
        if c1 <= c0 then
            return nil
        end
        return vim.fn.byteidx(line, c0 + shift), vim.fn.byteidx(line, c1 + shift)
    end
    local spans, items = {}, {}
    for _, s in ipairs(raw_spans) do
        local b0, b1 = vis_bytes(s[1], s[2])
        if b0 then
            spans[#spans + 1] = { b0, b1, s[3] }
        end
    end
    for _, s in ipairs(chev_spans) do
        spans[#spans + 1] = s
    end
    for i, b in ipairs(raw_items) do
        local b0, b1 = vis_bytes(b[1], b[2])
        items[i] = { c0 = b0, c1 = b1, spec = b[3], sep = b.sep }
    end

    -- Prepend the title prefix + shift every item/chevron offset by it (the title carries its own span).
    if pb > 0 then
        local shifted = { { 0, pb, opts.title_hl or "LvimUiPeekTitle" } }
        for _, s in ipairs(spans) do
            shifted[#shifted + 1] = { pb + s[1], pb + s[2], s[3] }
        end
        spans = shifted
        for _, c in ipairs(chevrons) do
            c[1], c[2] = pb + c[1], pb + c[2]
        end
        for _, it in ipairs(items) do
            if it.c0 then
                it.c0, it.c1 = pb + it.c0, pb + it.c1
            end
        end
        line = prefix .. line
    end

    return { line = line, spans = spans, chevrons = chevrons, items = items, off = opts.off or 0 }
end

return M
