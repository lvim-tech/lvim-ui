-- lvim-ui.util: shared low-level helpers for the UI layer — inline-hl registration/caching,
-- display-width-aware string clipping/padding, border resolution, accent tinting, and axis/position
-- math. Pure functions with no window state, so every UI module (and standalone plugin floats) can
-- share ONE implementation of these size/border/highlight primitives.
---@module "lvim-ui.util"
local config = require("lvim-ui.config")
local highlight = require("lvim-utils.highlight")
local api = vim.api

local M = {}

M.NS = api.nvim_create_namespace("lvim_utils_ui_ns")
M.FT = "lvim-utils-ui"

-- ─── resolve_hl ───────────────────────────────────────────────────────────────

--- Accept either a highlight group name (string) or an inline hl definition (table).
--- Tables are registered as dynamic groups and their name is cached.
local _hl_cache = {}
local _hl_count = 0
function M.resolve_hl(val)
    if type(val) == "string" then
        return val
    end
    if type(val) ~= "table" then
        return nil
    end
    -- A flat, order-stable key from the def's own fields — cheaper than `vim.inspect` (no pretty-printer)
    -- on this hot path, and still collision-free (every field is folded in, sorted so key order is stable).
    local parts = {}
    for k, v in pairs(val) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
    table.sort(parts)
    local key = table.concat(parts, ",")
    if not _hl_cache[key] then
        _hl_count = _hl_count + 1
        local name = "LvimUiInline_" .. _hl_count
        highlight.register({ [name] = val }, true)
        _hl_cache[key] = name
    end
    return _hl_cache[key]
end

-- ─── config accessor ──────────────────────────────────────────────────────────

--- Convenience accessor for the live UI config table.
---@return table
function M.cfg()
    return config
end

-- ─── string / display helpers ─────────────────────────────────────────────────

--- Return the display width of a value (handles multi-byte / wide characters).
---@param s any
---@return integer
function M.dw(s)
    return api.nvim_strwidth(tostring(s or ""))
end

--- Clip `s` to at most `width` DISPLAY cells, appending an ellipsis ("…") when it is clipped. Multibyte /
--- wide-char aware (splits on grapheme boundaries and counts display width). Used so a row whose content is
--- wider than its panel never spills past the border — its full-line background would otherwise overflow.
---@param s     any
---@param width integer
---@return string
function M.truncate(s, width)
    s = tostring(s or "")
    if width <= 0 then
        return ""
    end
    if M.dw(s) <= width then
        return s
    end
    local ell = "…"
    local budget = width - M.dw(ell) -- reserve room for the ellipsis
    if budget <= 0 then
        return M.dw(ell) <= width and ell or ""
    end
    -- Walk the UTF-8 codepoint boundaries natively (one pass, no `vim.fn.split` regex + no per-char VimL
    -- round-trip): `str_utf_pos` gives the 1-based byte offset of every codepoint start; slice each and
    -- accumulate display width until the budget is spent.
    local out, w = {}, 0
    local starts = vim.str_utf_pos(s)
    for i = 1, #starts do
        local a = starts[i]
        local b = starts[i + 1] and (starts[i + 1] - 1) or #s
        local ch = s:sub(a, b)
        local cw = M.dw(ch)
        if w + cw > budget then
            break
        end
        out[#out + 1] = ch
        w = w + cw
    end
    return table.concat(out) .. ell
end

--- Return s centered within width columns, padded with spaces on both sides (clipped if it overflows).
---@param s     any
---@param width integer
---@return string
function M.center(s, width)
    s = tostring(s or "")
    local len = M.dw(s)
    if len > width then
        s = M.truncate(s, width)
        len = M.dw(s)
    end
    if len >= width then
        return s
    end
    local l = math.floor((width - len) / 2)
    return string.rep(" ", l) .. s .. string.rep(" ", width - len - l)
end

--- Return s left-padded with indent spaces and right-padded to fill width (clipped if it overflows, so the
--- row — and its full-line background — never exceed `width`).
---@param s      any
---@param width  integer
---@param indent integer  Number of leading spaces (default 2)
---@return string
function M.lpad(s, width, indent)
    s = string.rep(" ", indent or 2) .. tostring(s or "")
    local len = M.dw(s)
    if len > width then
        s = M.truncate(s, width)
        len = M.dw(s)
    end
    return len >= width and s or (s .. string.rep(" ", width - len))
end

-- ─── highlight helpers ────────────────────────────────────────────────────────

--- Apply a full-line highlight group to a buffer row via an extmark.
---@param buf   integer
---@param row   integer  0-based line number
---@param group string|nil  Highlight group name; no-op when nil
function M.hl_line(buf, row, group)
    if not group then
        return
    end
    api.nvim_buf_set_extmark(buf, M.NS, row, 0, { line_hl_group = group, priority = 200 })
end

-- ─── hl merge helper ──────────────────────────────────────────────────────────

--- Merge two hl defs, taking ONLY the bg field from overlay.
--- Used for per-item overrides (tab, button) where fg/bold come from the global level.
--- base can be a string (named group) or a table; overlay must be a table with a bg field.
---@param base    string|table|nil
---@param overlay string|table|nil
---@return string|table|nil
function M.merge_bg(base, overlay)
    if not overlay then
        return base
    end
    local new_bg = type(overlay) == "table" and overlay.bg or nil
    if not new_bg then
        return base
    end
    if type(base) == "string" then
        local attrs = api.nvim_get_hl(0, { name = base, link = false })
        attrs.bg = new_bg
        return attrs
    elseif type(base) == "table" then
        return vim.tbl_extend("force", base, { bg = new_bg })
    end
    return { bg = new_bg }
end

-- ─── border helpers ───────────────────────────────────────────────────────────

M.BORDERS = {
    rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
    single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
    double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
    none = { "", "", "", "", "", "", "", "" },
}

--- Resolve a border spec to a concrete 8-element table.
--- Normalizes custom tables: corners between non-empty edges cannot be "".
---@param b string|table
---@return table
function M.resolve_border(b)
    if type(b) ~= "table" then
        return M.BORDERS[b] or M.BORDERS.rounded
    end
    local t = vim.list_extend({}, b)
    -- corners: {1=TL,3=TR,5=BR,7=BL}, adjacent edges: TL={8,2}, TR={2,4}, BR={4,6}, BL={6,8}
    local adj = { { 8, 2 }, { 2, 4 }, { 4, 6 }, { 6, 8 } }
    for i, edges in ipairs(adj) do
        if t[i * 2 - 1] == "" and (t[edges[1]] ~= "" and t[edges[2]] ~= "") then
            t[i * 2 - 1] = " "
        end
    end
    return t
end

--- The shared FRAME border, resolved from the single `config.border` (default "none") to the 8-element
--- form `nvim_open_win` accepts. ONE source for every plugin that opens its own float (lvim-keys-helper,
--- lvim-qf-loc, lvim-shell) instead of each re-resolving the config — so the frame border is consistent
--- everywhere. Standalone callers (lvim-utils absent) keep their own fallback by guarding the require.
---@return table  an 8-element resolved border
function M.frame_border()
    local ok, conf = pcall(require, "lvim-ui.config")
    local b = (ok and conf and conf.border) or "none"
    return M.resolve_border(b)
end

--- The border for a NATIVE float that carries its own TITLE / action FOOTER on the border (hover / diagnostic
--- peeks, the keys cheatsheet). It follows the shared `config.border`, BUT when that is "none" (the chassis
--- panels are borderless because they put the title in a CONTENT row) it returns an INVISIBLE all-" " padding
--- ring — a native border-title / footer cannot render without a border, so this keeps them VISIBLE while still
--- looking borderless (the padding draws no glyph). A real configured ring is used as-is.
---@return table  an 8-element resolved border
function M.chrome_border()
    local fb = M.frame_border()
    for _, e in ipairs(fb) do
        if e ~= "" then
            return fb -- a real (visible) border is configured — use it
        end
    end
    return M.resolve_border({ " ", " ", " ", " ", " ", " ", " ", " " }) -- borderless → invisible padding ring
end

--- Per-side insets (top, right, bottom, left) of a resolved 8-element border: 1 cell for any side
--- whose element is a non-empty string (a glyph OR a " " pad), 0 for an empty "" side.
---@param b table|nil  a border resolved by M.resolve_border ({ tl, t, tr, r, br, b, bl, l })
---@return integer top, integer right, integer bottom, integer left
function M.insets(b)
    if type(b) ~= "table" then
        return 0, 0, 0, 0
    end
    local function on(i)
        local e = b[i]
        local s = type(e) == "table" and e[1] or e
        return (s and s ~= "") and 1 or 0
    end
    return on(2), on(4), on(6), on(8)
end

--- Define highlight `out` as a TINT of `accent`'s foreground blended toward the panel bg
--- (`LvimUiPeekNormal`) by `t` (0 = bg, 1 = the full accent); when `fg_too`, the fg is the accent too
--- (bold). For chrome cells / selections coloured by their own accent. Returns `out`, or nil when the
--- accent has no resolvable fg.
---@param accent? string
---@param t number
---@param out string
---@param fg_too? boolean
---@return string|nil
function M.tint_hl(accent, t, out, fg_too)
    local af = accent and api.nvim_get_hl(0, { name = accent, link = false })
    local fg = af and af.fg
    if not fg then
        return nil
    end
    local nb = api.nvim_get_hl(0, { name = "LvimUiPeekNormal", link = false })
    local bg = nb.bg or 0
    local function comp(c, sh)
        return math.floor(c / sh) % 256
    end
    local function mix(a, b)
        return math.floor(a * t + b * (1 - t) + 0.5)
    end
    local rgb = mix(comp(fg, 65536), comp(bg, 65536)) * 65536
        + mix(comp(fg, 256), comp(bg, 256)) * 256
        + mix(comp(fg, 1), comp(bg, 1))
    api.nvim_set_hl(0, out, { bg = rgb, fg = fg_too and fg or nil, bold = fg_too or nil })
    return out
end

-- ─── sizing helper ────────────────────────────────────────────────────────────

--- Resolve one axis size. When `auto` is true, fit `content` (capped by `cap`); otherwise use the
--- EXPLICIT value (a fraction ≤ 1 of `screen`, or an absolute count), falling back to `content` when
--- it is unset. `cap` itself may be a fraction ≤ 1 of `screen` or an absolute count. Always ≥ 1.
---@param auto boolean|nil
---@param explicit number|nil
---@param cap number|nil
---@param content integer
---@param screen integer
---@return integer
function M.axis_size(auto, explicit, cap, content, screen)
    local function abs(v)
        return v <= 1 and math.floor(screen * v) or math.floor(v)
    end
    local v
    if auto then
        v = content
        if cap then
            v = math.min(v, abs(cap))
        end
    elseif explicit then
        v = abs(explicit)
    else
        v = content
    end
    return math.max(1, v)
end

-- ─── position helper ──────────────────────────────────────────────────────────

--- Compute the (row, col) for nvim_open_win (both 0-based, relative = "editor").
--- "editor" → centered in the full Neovim editor area.
--- "win"    → centered within the current window.
--- "cursor" → below the cursor when space allows, otherwise above.
---@param height   integer
---@param width    integer
---@param position "editor"|"win"|"cursor"|nil
---@return integer row, integer col
function M.calc_pos(height, width, position)
    if position == "cursor" then
        local sr = vim.fn.screenrow() - 1
        local sc = vim.fn.screencol() - 1
        local lines = vim.o.lines
        local cols = vim.o.columns
        local row
        if sr + 2 + height <= lines then
            row = sr + 1
        else
            row = math.max(0, sr - height - 1)
        end
        local col = math.min(sc, math.max(0, cols - width - 2))
        return row, col
    end
    if position == "win" then
        local src_win = vim.api.nvim_get_current_win()
        local wpos = vim.api.nvim_win_get_position(src_win)
        local wh = vim.api.nvim_win_get_height(src_win)
        local ww = vim.api.nvim_win_get_width(src_win)
        local row = wpos[1] + math.max(0, math.floor((wh - height) / 2))
        local col = wpos[2] + math.max(0, math.floor((ww - width) / 2))
        return row, col
    end
    if position == "bottom" then
        -- Anchored just above the cmdline, horizontally centred (≈ full width when wide).
        local row = math.max(0, vim.o.lines - height - vim.o.cmdheight - 1)
        local col = math.max(0, math.floor((vim.o.columns - width) / 2))
        return row, col
    end
    -- "editor": full editor area (default)
    return math.floor((vim.o.lines - height) / 2), math.floor((vim.o.columns - width) / 2)
end

return M
