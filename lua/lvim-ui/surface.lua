-- lvim-ui.surface: the ONE windowed-UI chassis. A vertical stack of sectors —
--
--     header  (a STACK of bands: meta lines + ui.bar bars; PINNED, never scrolls)
--     center  (a horizontal row of 1..N panels, each a content provider; the ONLY scroll region)
--     footer  (a STACK of bands, usually one ui.bar of actions; PINNED, never scrolls)
--
-- Everything else in the UI is a `frame` config: a popup is 1 center panel, the peek is 2 (list +
-- preview), a git client is 3 (status · diff · log); the header stack carries tabs / filters / submenus
-- (Package Manager); the footer is the navigable action bar. The chrome (header bands, footer bands,
-- the divider columns between panels) is rendered into a single non-focusable CONTAINER buffer so it
-- stays pinned; the center panels are separate floating windows on top, so only they scroll.
--
-- The whole config is a nested tree:
--   { title (box), border, size = { width/height = { auto, min, max, fixed } },
--     header = { bars = { { items, align?, chevrons?, on_change? } | { text } } },
--     content = { blocks = { { id, provider, size = { width }, border } } },   -- 1..N
--     footer = { bars = { … } } }
-- Each bar holds `items` (button / separator boxes) and owns its overflow chevrons; each block hosts a
-- content provider, addressed by `id` (`st.focus_block`). Sizing is per axis — `auto` fits the content
-- within `[min, max]`, else `fixed` (a screen fraction ≤1 or an absolute count). Only the center scrolls.
--
-- Modes: `mode = "float"` (centred modal) · `mode = "split"` (docked-modal, e.g. the bottom peek — panels
-- still FLOAT over a container) · `mode = "split", native = true` (a single block as a REAL split window,
-- NOT a float — for a persistent NAVIGABLE side panel like the lsp outline, so `<C-w>` nav and buffer
-- redraw behave natively; title = winbar, no bars).
--
-- A `position = "cmdline"` float OWNS the command-line region (grows `cmdheight` so heirline / a global
-- statusline stay above it, floats over those rows). Optionally HOSTED: pass `host = fn(height) -> rect` and
-- the surface, instead of growing cmdheight itself, reserves `height` rows in that host zone (the msgarea,
-- which owns cmdheight) and lays out over the returned rect — so the host composes other content (messages)
-- BELOW it in the same region. Wire the host segment's reflow to `st.reposition(rect)` so the surface follows.
--
---@module "lvim-ui.surface"

local uibar = require("lvim-ui.bar")
local util = require("lvim-ui.util")
local cursor = require("lvim-utils.cursor")
local config = require("lvim-ui.config")

local api = vim.api
local NS = api.nvim_create_namespace("lvim_utils_ui_frame")

local M = {}

--- The single-character FIRST keys of the multi-key chords a panel bound itself (`g?` → `g`).
---@param bound table<string, boolean>  the lhs set the panel actually mapped
---@return table<string, boolean>
local function chord_prefixes(bound)
    local out = {}
    for lhs in pairs(bound) do
        local first = lhs:match("^(<[^>]+>)") or lhs:sub(1, 1)
        if #lhs > #first and #first == 1 then -- a SEQUENCE whose prefix is a plain key (g, m, z…)
            out[first] = true
        end
    end
    return out
end

--- Own a panel's chord PREFIXES instead of leaving them to `timeoutlen`.
---
--- A chord like `g?` is otherwise a lottery: Neovim waits `timeoutlen` (500ms by default) for the second key
--- and, if the user is slower than that, ABANDONS the mapping and runs the BUILTIN `g` — so `g?` typed fast
--- opens the help while `g?` typed at human speed runs rot13. Binding the prefix to a resolver that BLOCKS for
--- the next key takes the clock out of it: the chord is resolved by us, at any speed. An unknown continuation
--- is replayed WITHOUT remapping, so `gg` in an unlocked panel still scrolls to the top.
---@param buf integer
---@param bound table<string, boolean>
local function own_chord_prefixes(buf, bound)
    for prefix in pairs(chord_prefixes(bound)) do
        pcall(vim.keymap.set, "n", prefix, function()
            local ok, ch = pcall(vim.fn.getcharstr)
            if not ok or ch == "" then
                return
            end
            local lhs = prefix .. ch
            -- `m` = remap (our chord fires), `n` = no remap (the builtin does) — fed as ONE sequence, so
            -- nothing waits on a timeout.
            api.nvim_feedkeys(lhs, bound[lhs] and "m" or "n", false)
        end, { buffer = buf, nowait = true, silent = true, desc = "lvim-ui: chord prefix" })
    end
end

--- PUBLIC seam — own the chord prefixes of keys a CONSUMER bound ITSELF on `buf`, outside the chassis.
---
--- The chassis owns the prefixes of every key IT binds (see `own_chord_prefixes`), but a hosted buffer the
--- chassis never maps — a terminal swapped into a provider panel (lvim-term / lvim-shell), a native panel a
--- plugin keys up on its own — is out of that reach: its `g?` would be back at the mercy of `timeoutlen`
--- (typed fast it fires, typed at human speed the builtin `g` wins). Such a consumer passes the lhs list it
--- bound and gets the same, clock-free resolution. Idempotent per buffer.
---@param buf integer
---@param lhs_list string[]  the keys the consumer bound on `buf` (only multi-key chords matter)
function M.own_chords(buf, lhs_list)
    local bound = {}
    for _, l in ipairs(lhs_list or {}) do
        if type(l) == "string" and l ~= "" then
            bound[l] = true
        end
    end
    own_chord_prefixes(buf, bound)
end

-- The ONE canonical popup border lives in a SINGLE place — `config.border` (config/ui.lua), a FULL " "
-- ring on all four sides (top for the native border-title / brand, plus a " " gutter on the left, right AND
-- bottom; the two top corners are filled by `resolve_border`; the " " edges draw no glyph, just a 1-cell
-- breathing gutter so the content sits off the window edges and the border-title spans edge-to-edge).
--
-- `M.FRAME_BORDER` is the MARKER every chassis consumer passes (`border = surface.FRAME_BORDER`, re-exported
-- by lvim-ui). It is bound to that single source, and — crucially — `M.open` RESOLVES it (and a nil
-- border) to the LIVE `config.border` at open time (see below). So changing that one config key reflects
-- on the next open of EVERY consumer without touching their code; the marker only has to keep the identity
-- the consumers captured, which it does (it is never reassigned). Later phases delete the per-plugin copies.
---@type string[]
M.FRAME_BORDER = config.border --[[@as string[] ]]

-- A SECOND single-source ring — `config.content_border` — for the CONTENT PANELS ONLY: the DATA blocks
-- INSIDE the container (the picker's list / preview, lvim-space's list, the tabs content block). `M.CONTENT_BORDER`
-- is the MARKER a content BLOCK passes (`border = surface.CONTENT_BORDER`); `M.open` RESOLVES it to the LIVE
-- `config.content_border` at open time (mirroring FRAME_BORDER), so changing that one key re-borders every
-- content panel on the next open — independently of the container ring, without touching the consumers. The
-- NAVIGATION bands (footer / filter / tab / input) are bars, not blocks, so they are never affected. A block's
-- explicit "none" / custom border is honoured untouched.
---@type string[]
M.CONTENT_BORDER = config.content_border --[[@as string[] ]]

-- ─── cursor hiding ────────────────────────────────────────────────────────────
-- Hiding the hardware cursor is delegated to lvim-utils.cursor (the ONE cursor system): the chrome
-- container and every panel whose provider sets `hide_cursor` carry the `lvim-ui-frame` filetype,
-- registered as a CURRENT-ONLY panel ft. So the module hides the cursor only while one of those is the
-- focused window (a list panel, or the container while a bar sector is selected) and shows it in
-- editable panels (the input field, the real preview buffer) and outside the frame. `cursor.update()`
-- is called right after a programmatic focus change so it applies without a one-frame flash.
local FRAME_FT = "lvim-ui-frame"
local cursor_registered = false
-- The literal control codes `:normal!` needs for a half-screen scroll (`scroll_preview`). Written as escapes,
-- not "<C-d>": `:normal!` takes no key NOTATION — it would run the letters n-o-r-m-a-l on the buffer.
local CTRL_D = "\4"
local CTRL_U = "\21"

--- The currently-open cmdline / area-docked surface, if any. The msgarea/cmdline zone hosts ONE app at a time —
--- opening a new area dock EVICTS the previous (a picker gives way to a shell, and back). Module-level (there is
--- one zone). The picker ALSO self-replaces finder→finder via its own registry; this covers the cross-consumer
--- case (picker ↔ shell) too. Declared HERE (above every consumer) so the close handler and M.open share the
--- one upvalue — not a stray global.
---@type table?
local area_current = nil
-- FOCUS-AWARE backdrop: a DOCKED surface (control center, msgarea dock, …) lets you focus OUT to the editor
-- while it STAYS open. Its dim/darken of the editor must LIFT off the window you moved INTO and re-apply when a
-- surface window is focused again — that focus-awareness now lives ENTIRELY in `lvim-utils.dim.apply_backdrop`
-- (a single session WinEnter drives it there). The surface only tracks WHICH state currently owns THE surface
-- backdrop, so two coexisting surface docks share ONE veil (the second skips its own) and the close path knows
-- when to release it. One at a time; module-level.
---@type table?
local active_surface_bd = nil

--- Rebuild the surface's live backdrop namespace from the CURRENT global highlights, so windows veiled behind an
--- open surface track a LIVE theme change (e.g. the colorscheme picker preview) instead of freezing on the
--- palette captured at open. Pure delegation to the shared applier, which recomputes every live backdrop's
--- namespace in place (the dimmed windows re-read it — no re-apply needed).
---@return nil
function M.refresh_backdrop()
    require("lvim-utils.dim").refresh_backdrop()
end

--- The fraction-based surface `size` spec `{ height?, width? }` for a dock LAYOUT, resolved from the CENTRAL
--- geometry authority `lvim-utils.config.dock.geometry.<layout>`. This is the ONE place the fraction →
--- `{ auto = true, max = f }` / `{ fixed = f }` shape the chassis `axis_size` consumes is built: the surface
--- derives its OWN size from here when a consumer passes no `size`, and the lvim-ui modals call it too (so there
--- is a single canonical resolver — the old public `lvim-ui.M.size` is gone). FRACTIONS, not resolved cells, so
--- the surface re-fits on `VimResized`. `area`/`bottom` are full-width → no `width`; only `float` carries width.
---@param layout "float"|"area"|"bottom"
---@return { height?: table, width?: table }
function M.size_spec(layout)
    local ok, uconf = pcall(require, "lvim-utils.config")
    local g = (ok and uconf and uconf.dock and uconf.dock.geometry and uconf.dock.geometry[layout]) or {}
    local function dim(v, auto)
        if type(v) ~= "number" then
            return nil
        end
        return (auto == true) and { auto = true, max = v } or { fixed = v }
    end
    local out = {}
    if g.height ~= nil then
        out.height = dim(g.height, g.height_auto)
    end
    if layout == "float" and g.width ~= nil then
        out.width = dim(g.width, g.width_auto)
    end
    return out
end
--- Register the frame filetype as a CURRENT-ONLY cursor-hide panel ft with the lvim-utils cursor module,
--- once per session (idempotent via `cursor_registered`).
local function register_frame_ft()
    if not cursor_registered then
        cursor_registered = true
        pcall(cursor.setup, { panel_ft = { FRAME_FT } })
    end
end

-- A frame spans zindex [base, base+2] (container, panels, bands). A float opened FROM another surface (e.g. the
-- installer browser's Delete menu, or any modal over an open panel) must clear the opener's WHOLE span, else its
-- title/footer bands hide BEHIND the opener's higher panels (which sit at base+1) even though its content shows.
local FRAME_Z_SPAN = 3
--- Base zindex for a NON-DOCKED float that declares no explicit `zindex`: sit ABOVE every frame currently on
--- screen so a modal is never covered by its opener. Stateless — a scan of the LIVE frame windows, so CLOSED
--- popups never inflate it (a lone float over the editor stays at the 50 baseline). Docked surfaces pass an
--- explicit `cfg.zindex` (200/210) and never reach here.
---@return integer
local function auto_float_base()
    local base = 50
    for _, w in ipairs(api.nvim_list_wins()) do
        local ok, c = pcall(api.nvim_win_get_config, w)
        if ok and c.relative and c.relative ~= "" and c.zindex then
            local buf = api.nvim_win_get_buf(w)
            if api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == FRAME_FT and c.zindex + FRAME_Z_SPAN > base then
                base = c.zindex + FRAME_Z_SPAN
            end
        end
    end
    return base
end

-- Default keymaps for the chassis; the consumer may override via `cfg.keys`.
local DEFAULT_KEYS = {
    sector_next = "<C-j>", -- header · center · footer (down), from anywhere (the PREVIEW is skipped)
    sector_prev = "<C-k>", -- (up)
    panel_toggle = "<Tab>", -- toggle the center panel (list ⇄ preview) — the ONLY way onto the preview
    panel_next = "<C-l>", -- next center panel (right) — only while a center panel is focused
    panel_prev = "<C-h>", -- previous center panel (left)
    menu_prev = { "h", "<Left>" },
    menu_next = { "l", "<Right>" },
    menu_confirm = { "<CR>", "<Space>" },
    -- OPEN keys (open / open_split / open_vsplit / open_tab) are DELIBERATELY absent: opening a selection is a
    -- CONSUMER concern (each finder/panel owns which keys open, in which split, and where focus lands), so every
    -- consumer PASSES them via `cfg.keys` (nil here → the binding below no-ops). The chassis still owns the
    -- open(mode) MECHANISM (default_open → provider `selection()` by path/lnum/col, or `cfg.on_open(mode,item)`).
    -- ROTATE the preview through five positions (right → below → left → above → dynamic → …), live:
    preview_next = "<C-n>",
    preview_prev = "<C-p>",
    toggle_preview = "<C-e>", -- HIDE ↔ show the preview (no-op while the preview is `dynamic`)
    -- SCROLL the preview while the LIST keeps the focus (the fzf-lua / Magit model) — see `scroll_preview`.
    preview_scroll_down = "<C-d>", -- half a screen down
    preview_scroll_up = "<C-u>", -- half a screen up
}

--- The RESOLVED value of a chassis key `id` — DEFAULT_KEYS overlaid by the GLOBAL `config.keys`. For a hosted
--- consumer (picker / shell) that must reference a chassis key (bind it on its own buffer, or label it in a
--- footer) at a point where the surface `state` (with per-instance `cfg.keys`) does not yet exist. When the
--- instance IS live, read `state.keys` instead (it includes the per-instance overrides).
---@param id string
---@return string|string[]|nil
function M.key(id)
    local ok, cfg = pcall(require, "lvim-ui.config")
    local global = (ok and cfg and cfg.keys) or {}
    local v = global[id]
    if v == nil then
        v = DEFAULT_KEYS[id]
    end
    return v
end

-- The chassis' OWN footer entries: `id → { fields, name, action }`. A consumer opts a core key INTO its footer
-- by this `id` (the key stays bound regardless — listing it only DISPLAYS it). `fields` are the DEFAULT_KEYS
-- ids whose RESOLVED keys form the shown label (a pair → "C-k/C-j"); `action` names the chassis behaviour the
-- key triggers (the single {key, name, action} record — the keymap itself is bound by `set_keys`).
M.CORE_FOOTER = {
    sectors = { fields = { "sector_prev", "sector_next" }, name = "sectors", action = "sector_cycle" },
    panel = { fields = { "panel_toggle" }, name = "panel", action = "panel_toggle" },
    preview = { fields = { "preview_prev", "preview_next" }, name = "preview", action = "rotate_preview" },
    scroll = {
        fields = { "preview_scroll_up", "preview_scroll_down" },
        name = "scroll preview",
        action = "scroll_preview",
    },
    select = { fields = { "menu_confirm" }, name = "select", action = "open" },
}

--- A footer button spec `{ key, name }` for a CORE key `id` (see `M.CORE_FOOTER`) — its resolved key label +
--- name — or nil for an unknown id. Consumers include core keys in a footer by id; this supplies the display.
---@param id string
---@return { key: string, name: string }|nil
function M.core_footer_item(id)
    local meta = M.CORE_FOOTER[id]
    if not meta then
        return nil
    end
    local parts = {}
    for _, f in ipairs(meta.fields) do
        local v = M.key(f)
        local k = type(v) == "table" and v[1] or v
        if type(k) == "string" and k ~= "" then
            parts[#parts + 1] = (k:gsub("[<>]", ""))
        end
    end
    return { key = table.concat(parts, "/"), name = meta.name }
end

-- ─── config normalisation ─────────────────────────────────────────────────────

--- Default box style for a key-BADGE footer button: a blue key badge + a yellow name, padded 1 each side.
local FOOTER_STYLE = {
    icon = {
        padding = { 1, 1 },
        normal = "LvimUiFooterKey",
        active = "LvimUiFooterKey",
        hover = "LvimUiFooterKeyHover",
    },
    text = {
        padding = { 1, 1 },
        normal = "LvimUiFooterLabel",
        active = "LvimUiFooterLabel",
        hover = "LvimUiFooterLabelHover",
    },
}

--- Predefined BUTTON KINDS (extensible) — each a structural button TYPE: its ui.button render FLAGS
--- (`key_badge` / `key_brackets` / `icon`) PLUS its DEFAULT box `hl` (per-state colours). A bar record picks a
--- kind by name (its `style` field, the 4th element); the record's own `hl` (a partial box style, the 5th
--- element) OVERRIDES the kind's default colours per-button, falling back to the kind default when absent. The
--- KIND is the SHAPE; `hl` is the COLOUR — kept separate. Add an entry to introduce a new button TYPE.
---   action — the whole key as a lead BADGE (`<CR> open`; footer action bars)
---   hotkey — the accelerator letter bracketed WITHIN the name (`W[o]rkspace`; scope / severity filters)
---   tab    — an icon + label TAB button (ui.tabs / project tabs)
---   plain  — name only, no key
M.STYLES = {
    action = { key_badge = true, hl = FOOTER_STYLE },
    hotkey = {
        key_badge = false,
        key_brackets = true,
        hl = {
            icon = {
                padding = { 0, 0 },
                normal = "LvimUiPeekFilterActive",
                active = "LvimUiPeekFilterActive",
                hover = "LvimUiPeekFilterActive",
            },
            text = {
                padding = { 1, 1 },
                normal = "LvimUiPeekFilterInactive",
                active = "LvimUiPeekFilterActive",
                hover = "LvimUiPeekFilterActive",
            },
        },
    },
    tab = {
        key_badge = false,
        icon = true,
        hl = {
            icon = {
                padding = { 2, 2 },
                normal = "LvimUiTabIconInactive",
                active = "LvimUiTabIconActive",
                hover = "LvimUiTabIconHover",
            },
            text = {
                padding = { 2, 2 },
                normal = "LvimUiTabTextInactive",
                active = "LvimUiTabTextActive",
                hover = "LvimUiTabTextHover",
            },
        },
    },
    plain = {
        key_badge = false,
        hl = {
            text = {
                padding = { 1, 1 },
                normal = "LvimUiFooterLabel",
                active = "LvimUiFooterLabel",
                hover = "LvimUiFooterLabelHover",
            },
        },
    },
}

--- Turn ONE bar RECORD into a `ui.button` spec — the SINGLE place the shared button style is applied, so EVERY
--- bar builder (`M.bar`, `bar_items`, `ui.filters`, `ui.tabs`, notify, lvim-space, lvim-installer, …) produces a
--- byte-identical button and a change to the styling lands everywhere. A record:
---   `{ name, key?, style?, hl?, active?, count?, icon?, key_pos?, run?, no_hotkey?, meta? }`
--- `style` names an `M.STYLES` KIND (default `default_style` or "action") — its render FLAGS + default box colours;
--- `hl` is a PARTIAL box style (`{ icon = {...}, text = {...} }`) merged OVER the kind default, so a consumer
--- supplies its OWN colours per-button (severity tints, msg-level tints, installer accents); `meta` passes through
--- UNTOUCHED for consumer state (e.g. ui.filters' `sync`). The style box is DEEP-COPIED, so every spec owns it —
--- two bars in one place stay fully INDEPENDENT.
---@param rec table
---@param default_style? string
---@return table  a ui.button spec
function M.button(rec, default_style)
    local s = M.STYLES[rec.style or default_style or "action"] or M.STYLES.action
    local box = vim.deepcopy(s.hl or FOOTER_STYLE)
    if rec.hl then
        box = vim.tbl_deep_extend("force", box, rec.hl)
    end
    return {
        type = "button",
        key = rec.key,
        key_badge = s.key_badge,
        key_brackets = s.key_brackets,
        key_pos = rec.key_pos,
        icon = rec.icon, -- lead glyph for the `tab` kind (icon + label)
        text = rec.name,
        run = rec.run,
        active = rec.active,
        count = rec.count,
        no_hotkey = rec.no_hotkey,
        style = box,
        _meta = rec.meta, -- opaque passthrough for consumer state (filters sync, tab index, …)
    }
end

--- Build a `ui.bar` `chevrons` config from the SHARED glyphs (`config.chevrons`) paired with a consumer's own
--- colour — so every overflowing bar (tab bar, action footer, tabs legend) marks its hidden items with the SAME
--- ❮ ❯, each in its own accent. Pass the highlight group the chevrons should paint with.
---@param hl string  highlight group for both chevrons
---@return table  { left = { text, style = { hl } }, right = { text, style = { hl } } }
function M.chevrons(hl)
    local g = require("lvim-ui.config").chevrons or { left = "❮", right = "❯" }
    return {
        left = { text = g.left or "❮", style = { hl = hl } },
        right = { text = g.right or "❯", style = { hl = hl } },
    }
end

--- Build ONE bar band from a DECLARATIVE spec — a list of GROUPS, each a list of action IDs — for `opts.mode`.
--- Each id resolves to a RECORD: first from `registry` (the consumer's OWN actions), else the chassis CORE
--- (`M.core_footer_item`). A record is `{ name, key?|n?|i?, action?, style?, run?, active?, key_pos?, hl?,
--- no_hotkey? }`: `key` = one label for both modes, `n`/`i` = per-mode; `style` names an `M.STYLES` entry
--- (default `opts.style` or "action"); `hl` overrides the box colours; `key_pos` = which name char to bracket
--- (hotkey style); `active` marks the live toggle. Records with no usable key/name in the mode are dropped; a
--- `opts.separator` item (hl `LvimUiFooterSep`) divides non-empty groups. Returns a ui.bar band `{ items, align }`
--- — PLACE it in a frame's `header`/`footer` (`{ bars = { surface.bar(...), … } }`). The button LIST lives in the
--- CONSUMER's config; only the {key,name,action,style} records + the STYLES are shared. One bar concept, any
--- position, any buttons/style.
---@param groups string[][]
---@param registry table<string, table>
---@param opts { mode?: string, separator?: string, separator_hl?: string, separator_padding?: integer[], align?: string, style?: string, hl?: table, chevrons?: table }
---@return table  a ui.bar band { items, align, chevrons }
function M.bar(groups, registry, opts)
    opts = opts or {}
    local n = opts.mode == "n"
    local sep = opts.separator or "●"
    local sep_hl = opts.separator_hl or "LvimUiFooterSep" -- consumer overridable (e.g. lvim-space's own accent)
    local sep_pad = opts.separator_padding or { 1, 1 }
    local default_style = opts.style or "action"
    registry = registry or {}
    local items = {}
    for _, group in ipairs(groups or {}) do
        local resolved = {}
        for _, id in ipairs(group) do
            local rec = registry[id] or M.core_footer_item(id) -- consumer-own else chassis CORE
            if rec then
                local key = rec.key or (n and rec.n or rec.i) -- resolve the per-mode key, then delegate the spec
                if (type(key) == "string" and key ~= "") or (rec.name and rec.name ~= "") then
                    resolved[#resolved + 1] = M.button({
                        name = rec.name,
                        key = key,
                        style = rec.style,
                        hl = rec.hl or opts.hl, -- per-record colours, else the bar-level default (opts.hl)
                        active = rec.active,
                        count = rec.count,
                        icon = rec.icon,
                        key_pos = rec.key_pos,
                        run = rec.run,
                        no_hotkey = rec.no_hotkey,
                        meta = rec.meta,
                    }, default_style)
                end
            end
        end
        if #resolved > 0 then
            if #items > 0 then
                items[#items + 1] = { type = "separator", text = sep, style = { padding = sep_pad, hl = sep_hl } }
            end
            for _, it in ipairs(resolved) do
                items[#items + 1] = it
            end
        end
    end
    return { items = items, align = opts.align, chevrons = opts.chevrons }
end

--- Normalise a bar's `items` into button/separator specs. A FOOTER action shorthand `{ key, name|text,
--- run }` (no `type`) becomes a footer-styled key-badge button; everything else (full button / separator
--- specs, e.g. header tab buttons that carry their own style) passes through unchanged.
---@param items table[]|nil
---@param footer boolean
---@return LvimUiButtonSpec[]
local function bar_items(items, footer)
    local out = {}
    for i, it in ipairs(items or {}) do
        if it.type or not footer then
            out[i] = it -- full button / separator spec (or a non-footer bar) — passes through
        else
            -- footer action shorthand `{ key, name|text|label, run }` → the shared `action` KIND (via
            -- `M.button`); a caller-supplied `it.style` is a full BOX colour override, passed through as the
            -- button's `hl`. (The `action` kind is a KEY BADGE — its lead box is the key, so a chip's glyph
            -- belongs in the caption, not in `icon`.)
            out[i] = M.button({
                name = it.name or it.text or it.label or "",
                key = it.key,
                run = it.run,
                active = it.active,
                no_hotkey = it.no_hotkey,
                hl = it.style,
            }, "action")
        end
    end
    return out
end

--- Drop a blank "air" band that ENDS UP ADJACENT to a ringed content panel. The air row and the content
--- panel's border row do the same job (detach the data from the chrome), so whichever consumer supplied the
--- air — the frame itself (`header_air` / `footer_air`), the row-title's own air, or a hand-written
--- `{ text = "" }` band — a second blank row would stack on the ring's. Air BETWEEN bands (title ↔ tab bar,
--- filter ↔ prompt) is untouched: only the band touching the content goes. Enforced HERE, in the chassis, so
--- no panel can reintroduce the mismatch and turning the ring off restores the air by itself.
---@param bands table[]
---@param ringed boolean  the content panel's border already spaces this side
---@param footer boolean  footer bands touch the content at their FIRST row, headers at their LAST
local function trim_air(bands, ringed, footer)
    if not ringed or #bands <= 1 then
        -- A LONE band is the bar itself, not padding: lvim-space opens with an empty info footer
        -- (`{ bars = { { text = "" } } }`) and fills it right after, so trimming it away sized the container one
        -- row short and the action bar was drawn onto a row the window did not have.
        return
    end
    -- A `scope_panel` / `scope_id` input band takes NO row of its own (it overlays its panel's top row — the
    -- picker's prompt), so it is not what touches the content: step over it to reach the band that does.
    local i = footer and 1 or #bands
    while bands[i] and (bands[i].scope_panel or bands[i].scope_id) do
        i = i + (footer and 1 or -1)
    end
    local b = bands[i]
    if b and b.meta == "" and not b.buttons and not b.input and not b.title_counter then
        table.remove(bands, i)
    end
end

--- Build a band stack from `cfg.header` / `cfg.footer`. Each `bar` is a ui.bar `{ items, align, chevrons,
--- on_change, on_select }` OR a meta line `{ text = "...", hl }`. Internally a bar band keeps its element
--- list in `band.buttons` (the field name the machinery uses — it already holds buttons + separators).
--- The header leads with 1 blank "air" row (under the border-title); the footer gets 1 blank "air" row
--- ABOVE its content (so the action bar breathes off the center) — per the UI canon.
---@param spec table|nil
---@param footer boolean
---@return table[]
local function build_bands(spec, footer, add_air)
    spec = spec or {}
    local bands = {}
    for _, bar in ipairs(spec.bars or {}) do
        if bar.title_counter then
            -- A title + right-aligned counter CONTENT row (title left, count right) — a dynamic `count`
            -- function is re-evaluated on every chrome render. Passed through with its fields intact.
            bands[#bands + 1] = bar
        elseif bar.text ~= nil then
            -- `hls` (optional): per-part inline highlight spans `{ byte_c0, byte_c1, group }` into `text`, so a
            -- meta line can carry MULTIPLE colours (e.g. a repo band: branch / ahead / sha / subject) instead
            -- of one `hl` for the whole row.
            bands[#bands + 1] = {
                meta = bar.text,
                hl = bar.hl or (footer and "LvimUiSubtitle" or "LvimUiPeekTitle"),
                hls = bar.hls,
            }
        elseif bar.input then
            -- An editable INPUT band — a focusable 1-row editable window the frame creates over this row
            -- (see open_windows). It reserves a row like a meta line; the consumer drives it via
            -- `on_change(query)` (fired live on type) and the band's own insert-mode `keys(buf, st)`.
            bands[#bands + 1] = {
                input = true,
                prompt = bar.prompt,
                prompt_hl = bar.prompt_hl, -- the prompt badge highlight (else a neutral default)
                input_hl = bar.input_hl, -- the typed-area Normal highlight (else the peek normal)
                on_change = bar.on_change,
                keys = bar.keys,
                filetype = bar.filetype,
                scope_panel = bar.scope_panel, -- narrow the prompt to a single panel's columns (else full width)
                scope_id = bar.scope_id, -- … or to the panel with this id (rotation-safe — tracks it as it moves)
            }
        else
            -- Mutate the bar spec INTO its band (the machinery reads the element list as `band.buttons`),
            -- so a consumer that keeps a reference to the bar can drive its `_sel` / button `active` flags
            -- live (e.g. the project panel switching tabs from the content body).
            bar.buttons = bar_items(bar.items, footer)
            bar.align = bar.align or "center"
            bands[#bands + 1] = bar
        end
    end
    if footer then
        if #bands > 0 and add_air ~= false then
            table.insert(bands, 1, { meta = "" }) -- 1 air row ABOVE the footer content (skip when footer_air=false)
        end
    elseif add_air ~= false then
        table.insert(bands, 1, { meta = "" }) -- 1 air row under the (border-)title (skip when add_air=false)
    end
    return bands
end

--- Build the float border-title chunks (`{ { text, hl }, … }`) from the `title` box: an optional icon box
--- + a text box, each with its own padding + colour (static — one hl per box). A plain string is accepted
--- too (→ a single padded text chunk).
---@param title table|string|nil
---@return table[]|nil
local function title_chunks(title)
    local function box(content, bs, default_hl)
        if not content or content == "" then
            return nil
        end
        local f, b = 1, 1
        local pad = bs.padding
        if type(pad) == "number" then
            f, b = pad, pad
        elseif type(pad) == "table" then
            f, b = pad[1] or 1, pad[2] or 1
        end
        return { string.rep(" ", f) .. content .. string.rep(" ", b), util.resolve_hl(bs.hl or default_hl) }
    end
    -- titles render UPPERCASE everywhere (the canon — matches the ui.bar title bars); the icon glyph is left
    if type(title) == "string" then
        return title ~= "" and { box(title:upper(), {}, "LvimUiPeekTitle") } or nil
    end
    if type(title) ~= "table" then
        return nil
    end
    local st = title.style or {}
    local chunks = {}
    local ic = box(title.icon, st.icon or {}, "LvimUiPeekTitleIcon")
    local tc = box(title.text and tostring(title.text):upper() or nil, st.text or {}, "LvimUiPeekTitle")
    if ic then
        chunks[#chunks + 1] = ic
    end
    if tc then
        chunks[#chunks + 1] = tc
    end
    return #chunks > 0 and chunks or nil
end

--- Flatten a `title` box (or string) to a plain string (icon + text) — for a winbar / split content row.
---@param title table|string|nil
---@return string
local function title_text(title)
    if type(title) == "string" then
        return title
    end
    if type(title) ~= "table" then
        return ""
    end
    return ((title.icon and title.icon .. " ") or "") .. (title.text or "")
end

-- ─── title / counter placement (the single title path) ────────────────────────
-- The chassis owns WHERE a frame's title and item-count render, driven by two shared cfg keys (resolved in
-- M.open from the surface opts → `config` default): `title_line` ("row" | "statusline" | "border") and `counter`
-- ("title" | "footer"). These helpers are the ONE place the native border-title, the native border-FOOTER
-- counter, and the chrome-overlay title are built — consumers only supply `title` + an optional `count`.

--- Whether this frame is DOCKED in the cmdline / area host zone — the only place `title_line="statusline"`
--- moves the title onto the chrome overlay. (A `position="cmdline"` float, hosted or growing cmdheight.)
---@param cfg table
---@return boolean
local function is_area_dock(cfg)
    return cfg.position == "cmdline"
end

--- Resolve the consumer-supplied count for the title / footer counter. `cfg.count` is an integer, a
--- `{ current, total }` pair, or a function returning either; re-evaluated on every read so a live counter
--- (filter / tab change) tracks the content.
---@param cfg table
---@return integer current, integer total
local function resolve_count(cfg)
    local c = cfg.count
    if type(c) == "function" then
        local ok, r = pcall(c)
        c = ok and r or nil
    end
    local cur, tot = 0, 0
    if type(c) == "number" then
        tot = c
    elseif type(c) == "table" then
        cur, tot = c.current or 0, c.total or 0
    end
    -- `count_follows_cursor`: the FIRST content panel's cursor row IS the counter's `current`, so the counter
    -- reads "<row>/<total>" (a live "item N of M" indicator). `cfg._cursor_row` is kept up to date by the
    -- CursorMoved autocmd wired in open_windows; clamp it to the total so a stale row after a delete can't exceed.
    if cfg.count_follows_cursor and tot > 0 then
        cur = math.min(math.max(cfg._cursor_row or 1, 1), tot)
    end
    return cur, tot
end

--- The counter text ("8" or "3/8") from the resolved count, or nil when there is nothing to show (total 0).
---@param cfg table
---@return string|nil
local function counter_text(cfg)
    local cur, tot = resolve_count(cfg)
    if tot <= 0 then
        return nil
    end
    return cur > 0 and ("%d/%d"):format(cur, tot) or tostring(tot)
end

--- The row-title prefix bands for a `title_line = "row"` float: the `title_counter` title row + 1 blank air row
--- under it, to prepend as the FIRST header bands. Built HERE (not inline at open) so a later `set_header` — a
--- tab switch rebuilds the header from its spec — re-prepends the SAME title; otherwise the row title vanished
--- on the first tab change. Defined before `open_windows` (where set_header lives) so it is in scope there.
--- Returns nil when this frame has no row title.
---@param cfg table
---@return table[]?
local function row_title_bands(cfg)
    local row_title = cfg.mode ~= "split" and cfg.title_line == "row" and cfg.title and cfg.title ~= ""
    if not row_title then
        return nil
    end
    local t = cfg.title
    local text, thl
    if type(t) == "table" then
        text = (t.icon and t.icon .. " " or "") .. (t.text and tostring(t.text) or "")
        thl = (t.style and t.style.text and t.style.text.hl) or "LvimUiPeekTitle"
    else
        text = tostring(t)
        thl = "LvimUiPeekTitle"
    end
    return {
        {
            title_counter = true,
            text = text,
            -- the count formats to the canon "cur/tot" string; the band handler tostring()s whatever it gets
            count = function()
                return counter_text(cfg) or ""
            end,
            hl = thl,
            count_hl = "LvimUiPeekCounter",
            title_pos = cfg.title_pos, -- "left" (default) | "center" | "right"
        },
        { meta = "" }, -- 1 air row UNDER the title bar
    }
end

--- Build the native border-title chunks for this frame: the TITLE hugs the LEFT (`title_pos="left"`), and —
--- when `counter="title"` — the COUNTER is pushed to the RIGHT edge of the same top-border line by a fill
--- spacer (so the line reads `TITLE …………… 8/62`). The fill needs the title-line width (`width`, the container
--- content width); without it the counter just trails the title. Returns nil when the title must NOT render
--- in the border: no title, or an area dock with `title_line="statusline"` (it goes to the chrome overlay via
--- `publish_overlay_title`). The SINGLE place the border-title is built.
---@param state table
---@param width? integer  the title-line width (defaults to the live geom width)
---@return table[]|nil
local function build_brand(state, width)
    local cfg = state.cfg
    if is_area_dock(cfg) and cfg.title_line == "statusline" then
        return nil -- the title lives on the chrome overlay (suppress the border-title)
    end
    if cfg.title_line == "row" then
        return nil -- the title lives in a CONTENT row (a title_counter band), not the native border-title
    end
    local chunks = title_chunks(cfg.title) or {}
    if cfg.counter == "title" then
        local ct = counter_text(cfg)
        if ct then
            local count_chunk = { " " .. ct .. " ", util.resolve_hl("LvimUiPeekCounter") }
            width = width or (state._geom and state._geom.W)
            if width then
                -- Right-align the counter: pad between the title and the count so the count lands on the right
                -- edge. `used` is the display width of the title chunks + the count box; the spacer fills the gap.
                local used = util.dw(count_chunk[1])
                for _, c in ipairs(chunks) do
                    used = used + util.dw(c[1])
                end
                local fill = width - used
                if fill > 0 then
                    -- Fill with the TOP-border glyph (tinted like the border), NOT spaces: the brand is OVERLAID
                    -- on the native border, so a blank spacer would punch a gap in the top rule between the title
                    -- and the right-aligned count (the "top border vanishes when the count shows" bug).
                    local rb = util.resolve_border(cfg.border)
                    local top = (type(rb) == "table" and rb[2] ~= "" and rb[2]) or " "
                    chunks[#chunks + 1] = { string.rep(top, fill), util.resolve_hl("LvimUiPeekBorder") }
                end
            end
            chunks[#chunks + 1] = count_chunk
        end
    end
    return (#chunks > 0) and chunks or nil
end

--- Build the native border-FOOTER chunks (the right-aligned counter) when `counter="footer"` and a count
--- is present; else nil. This is the ONLY use of the native border-footer — a NAVIGABLE action bar is a
--- separate CONTENT band (`cfg.footer`), never conflated with this.
---@param state table
---@return table[]|nil
local function build_border_footer(state)
    if state.cfg.counter ~= "footer" then
        return nil
    end
    local ct = counter_text(state.cfg)
    if not ct then
        return nil
    end
    return { { " " .. ct .. " ", util.resolve_hl("LvimUiPeekCounter") } }
end

--- Publish the title (+ counter) to the chrome overlay for an area dock with `title_line="statusline"`;
--- a no-op otherwise. The SINGLE centralized overlay-TITLE path (consumers stop doing their own in later
--- phases). Cleared on close by the consumer / `chrome.overlay.clear()`.
---@param state table
local function publish_overlay_title(state)
    local cfg = state.cfg
    if not (is_area_dock(cfg) and cfg.title_line == "statusline") then
        return
    end
    local title = cfg.title
    if not (title and title ~= "") then
        return
    end
    local icon, text
    if type(title) == "table" then
        icon = title.icon
        text = title.text and tostring(title.text) or nil
    else
        text = tostring(title)
    end
    local cur, tot = resolve_count(cfg)
    pcall(function()
        require("lvim-hud.overlay").set({ title = text, icon = icon, current = cur, total = tot })
    end)
end

-- ─── inter-panel divider ──────────────────────────────────────────────────────
-- The rule the chassis draws BETWEEN adjacent content panels (a picker's list ↔ preview). Resolution, in
-- order: a per-surface `cfg.separator` overrides the configurable default `config.separator`; each is one
-- of `false`/"" (off), a plain string (verbatim, both axes), or a `{ h, v, hl }` table (per-axis glyph). The
-- glyph is AUTO-ORIENTED — `h`/"│" between side-by-side panels, `v`/"─" between stacked ones — so a runtime
-- preview rotation flips it. Returns nil when disabled (the caller then reserves no gap / draws nothing).

--- The divider glyph for `cfg` on the given axis, or nil when the divider is disabled.
---@param sep any      a per-surface override, or nil to fall back to `config.separator`
---@param vertical boolean  true → the glyph BETWEEN stacked panels ("─"); false → between side-by-side ("│")
---@return string|nil
local function resolve_divider(sep, vertical)
    if sep == nil then
        sep = config.separator
    end
    if sep == false or sep == "" then
        return nil
    end
    if type(sep) == "string" then
        return sep
    end
    if type(sep) == "table" then
        return (vertical and (sep.v or sep.vertical)) or (not vertical and (sep.h or sep.horizontal)) or nil
    end
    return vertical and "─" or "│"
end

--- The divider's highlight group — a per-surface `separator_hl`, else `config.separator.hl`, else the
--- canon border tint (so the rule matches the rings).
---@param cfg table
---@return string
local function divider_hl(cfg)
    local d = config.separator
    return cfg.separator_hl or (type(d) == "table" and d.hl) or "LvimUiPeekBorder"
end

-- ─── group frame (the "unifying ring" around the content-panel group) ──────────
-- A COMMON ring drawn around the DATA panels as one group (a picker's list + preview), INSIDE the container
-- but OUTSIDE the header / footer nav bands. Third ring level: container (outer) › group › each panel's own
-- content_border. Only when there are ≥2 content panels (one panel needs no grouping). Resolution: a per-surface
-- `cfg.group_border` overrides the configurable default `config.group_border` (false to disable, or an
-- 8-element border table `{ …, hl }`). The layout reserves a 1-col gutter on each side between the container and
-- the group, and between the group and the panels, so no edge doubles.

--- The resolved group-frame border (8-element) + its hl, or nil when disabled / fewer than 2 panels.
---@param cfg table
---@param n integer  the content-panel count
---@return string[]|nil border, string? hl
local function group_frame(cfg, n)
    if n < 2 then
        return nil
    end
    local g = cfg.group_border
    if g == nil then
        g = config.group_border
    end
    if g == false or g == "none" then
        return nil
    end
    local b = util.resolve_border(g)
    -- A border whose every edge is "" has ZERO insets — it draws nothing and must add NO geometry overhead
    -- (no gutters), else the content would sit inset from the edges for an invisible frame. Treat it as OFF so
    -- the panels lay out flush. (resolve_border keeps "" as 0-inset; " " is a real 1-inset blank edge.)
    local t, r, bo, l = util.insets(b)
    if (t + r + bo + l) == 0 then
        return nil
    end
    local hl = (type(g) == "table" and g.hl) or "LvimUiPeekBorder"
    return b, hl
end

-- ─── geometry ─────────────────────────────────────────────────────────────────

--- The largest `cmdheight` the current window layout can give up without "E36: Not enough room": the
--- non-floating windows must keep their minimum rows. Walks `winlayout()` — a "col" stacks rows (heights
--- ADD), a "row" sits side by side (heights are the MAX); each leaf needs `winminheight` + its statusline
--- (per-window when `laststatus` 1/2) + its winbar. Plus the global chrome (tabline, the `laststatus=3`
--- global statusline). The cmdline region can take everything left over.
---@return integer
local function max_cmdheight()
    local ls = vim.o.laststatus
    local per_win_status = (ls == 1 or ls == 2) and 1 or 0 -- a statusline on each window
    local wmh = math.max(1, vim.o.winminheight)
    local function need(node)
        if not node then
            return wmh + per_win_status
        end
        local kind, items = node[1], node[2]
        if kind == "leaf" then
            local win = items
            local wb = (api.nvim_win_is_valid(win) and vim.wo[win].winbar ~= "") and 1 or 0
            return wmh + per_win_status + wb
        end
        local n = 0
        for _, child in ipairs(items or {}) do
            local c = need(child)
            n = (kind == "col") and (n + c) or math.max(n, c)
        end
        return n
    end
    local tabs = vim.api.nvim_list_tabpages()
    local tabline = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #tabs > 1)) and 1 or 0
    local global_status = (ls == 3) and 1 or 0
    local reserve = need(vim.fn.winlayout()) + tabline + global_status
    return math.max(1, vim.o.lines - reserve)
end

--- Set `cmdheight` to `h`, clamped to what the layout allows (`max_cmdheight`), then DECREMENT on the rare
--- "E36: Not enough room" (the estimate is conservative but window minima can be quirky) until it sticks.
--- Returns the value actually applied — the geometry uses THAT so the container float matches the region.
---@param h integer
---@return integer
local function set_cmdheight(h)
    h = math.max(1, math.min(h, max_cmdheight()))
    vim.o.cmdheight = h
    return vim.o.cmdheight
end

--- Pure geometry: the container frame, the header/footer band rows, and every center-panel rect + the
--- divider columns. No window/buffer side effects. `place` overrides position/size for a SPLIT (docked)
--- frame whose container window already exists: `{ row, col, H }` (screen position + the split height).
---@param state table
---@param place? table
---@return table layout
local function compute_geom(state, place)
    local cfg = state.cfg
    -- A REAL native split container draws no border (its edge IS the split divider). A FLOAT keeps `cfg.border`
    -- even when `place` fixes its rect — a hosted cmdline/area zone (or a bottom dock, or a host reflow) still
    -- carries its (e.g. left/right inset) border WITHIN the reserved rect. So only force "none" for the split.
    local cbord = (place and cfg.mode == "split") and util.resolve_border("none") or util.resolve_border(cfg.border)
    local ct, cr, cb, cl = util.insets(cbord)

    local panels = state.panels
    local n = #panels
    -- Panels stack VERTICALLY (top→bottom, full width, height grows) when direction == "vertical"; else
    -- they sit side-by-side (the default). Used for the navigator's above/below preview.
    local vertical = cfg.direction == "vertical"
    -- 1 col/row reserved between panels for the divider when one is enabled on THIS axis (config-driven,
    -- per-surface overridable); 0 otherwise. Only consumed as `sep_w * (n - 1)`, so a single panel reserves none.
    local sep_w = resolve_divider(cfg.separator, vertical) and 1 or 0

    -- GROUP frame overhead (the common ring around the panel group). HORIZONTAL per side = outer gutter (1,
    -- container ↔ group) + the group border (its left/right inset) + inner gutter (1, group ↔ panels). VERTICAL
    -- = the group border's top + bottom inset, with NO row gutters (rows are sequential, so no doubling — this
    -- keeps the area short). `gh` is the per-SIDE horizontal overhead, `gv_t` / `gv_b` the top / bottom.
    local gbord, ghl = group_frame(cfg, n)
    local g_on = gbord ~= nil
    local git_t, git_r, git_b, git_l = util.insets(gbord or util.resolve_border("none"))
    local g_og = g_on and 1 or 0 -- outer gutter (container ↔ group)
    local g_ig = g_on and 1 or 0 -- inner gutter (group ↔ panels)
    local gh_l = g_og + git_l + g_ig -- left horizontal overhead
    local gh_r = g_ig + git_r + g_og -- right horizontal overhead
    local gh = gh_l + gh_r -- total horizontal overhead
    local gv_t, gv_b = git_t, git_b -- top / bottom overhead (group border only)
    local gv = gv_t + gv_b -- total vertical overhead

    -- Per-panel border insets + natural content size (provider.size()). Track BOTH axes so either layout
    -- direction can auto-size: sum along the stacking axis, max across it.
    local pin = {}
    local nat_w_sum, nat_w_max, nat_h_sum, nat_h_max = 0, 1, 0, 1
    local border_cols, border_rows, max_vborder, max_hborder = 0, 0, 0, 0
    for i, pan in ipairs(panels) do
        local b = util.resolve_border(pan.border or cfg.panel_border)
        local pt, pr, pbm, pl = util.insets(b)
        local sw, sh = 20, 1
        if pan.provider and pan.provider.size then
            local ok, w, h = pcall(pan.provider.size)
            if ok then
                sw, sh = w or sw, h or sh
            end
        end
        pin[i] = { b = b, t = pt, r = pr, bo = pbm, l = pl, nat_w = sw, nat_h = sh }
        nat_w_sum = nat_w_sum + pl + sw + pr
        nat_w_max = math.max(nat_w_max, pl + sw + pr)
        nat_h_sum = nat_h_sum + pt + sh + pbm
        -- Include the panel's OWN border rows (pt + pbm) in the cross-axis max, like nat_h_sum does on the
        -- stacking axis: for side-by-side (horizontal) panels the container content height is the tallest
        -- panel FOOTPRINT (content + its border), so a content-bordered panel reserves its +2 rows. Without
        -- this the container sizes to bare content and the per-panel `center_h - border` step squeezes the
        -- panel to 1 row. (Borderless panels keep pt = pbm = 0, so this is a no-op for them.)
        nat_h_max = math.max(nat_h_max, pt + sh + pbm)
        border_cols = border_cols + pl + pr
        border_rows = border_rows + pt + pbm
        max_vborder = math.max(max_vborder, pt + pbm) -- so min_content counts VISIBLE rows, not the border
        max_hborder = math.max(max_hborder, pl + pr)
    end

    -- Widest content drives auto_width: the widest bar band vs the panels' natural footprints.
    local bars_w = 0
    for _, band in ipairs(state.header_bands) do
        bars_w = math.max(bars_w, band.buttons and uibar.width(band.buttons) or util.dw(band.meta or ""))
    end
    local footer_w = 0
    for _, band in ipairs(state.footer_bands) do
        local bw = band.buttons and uibar.width(band.buttons) or 0
        bars_w = math.max(bars_w, bw)
        footer_w = math.max(footer_w, bw) -- the action footer must FIT (never scroll under the auto-width cap)
    end
    -- Stacking axis sums; cross axis is the max. Horizontal: width sums (+ column separators), height = the
    -- tallest panel. Vertical: width = the widest panel, height sums (+ row separators).
    -- The panel footprints carry the GROUP frame overhead too (gh), so auto-width reserves room for the ring.
    local content_w = vertical and math.max(bars_w, nat_w_max + gh)
        or math.max(bars_w, nat_w_sum + sep_w * (n - 1) + gh)

    -- Container CONTENT width/height (W excludes the container's own border columns). With `place` the rect is
    -- the OUTER footprint the host reserved (or the split window's actual size), so the container's own border
    -- insets come OUT of it — content + border fits the rect exactly. A split forces "none" (cl..cb all 0, so
    -- W == place.W unchanged); a hosted float with a left/right inset takes `place.W - cl - cr`.
    local W = place and (place.W - cl - cr)
        or util.axis_size(cfg.auto_width, cfg.width, cfg.max_width, content_w, vim.o.columns)
    if not place and cfg.min_width then
        local mw = cfg.min_width <= 1 and math.floor(vim.o.columns * cfg.min_width) or cfg.min_width
        W = math.max(W, math.floor(mw))
    end
    -- The footer action bar must fit: its buttons should never scroll just because the auto-width cap is
    -- tighter than them. Widen to the footer, up to the screen.
    if not place and footer_w > 0 then
        W = math.max(W, math.min(footer_w, vim.o.columns - 4))
    end
    -- A `scope_panel` / `scope_id` input band does NOT take its own header row — it overlays its panel's top
    -- (winbar) row instead, so it doesn't count toward the header height.
    local header_h = 0
    for _, b in ipairs(state.header_bands) do
        if not b.scope_panel and not b.scope_id then
            header_h = header_h + 1
        end
    end
    local footer_h = #state.footer_bands
    -- The center's natural height — 0 when there are NO content panels (a header-only surface like the input
    -- prompt: header bands + footer, no center), else the panel stack. Guarding `n == 0` avoids a phantom empty
    -- center row under the input (nat_h_max seeds to 1).
    local center_nat = (n == 0) and 0 or (vertical and (nat_h_sum + sep_w * (n - 1)) or nat_h_max)
    local content_h = header_h + footer_h + gv + center_nat
    -- A split takes the full height nvim gives it (place.H); a float sizes per auto/explicit height. The
    -- center never shrinks below `min_content_height` VISIBLE rows — counted on the panel content, so the
    -- panel borders are added on top (the header/footer bands are fixed-height). Stacked panels need room
    -- for ALL of them. `min_h` is the resulting minimum container height, exported for the resize clamp.
    -- No content panels → no center minimum (so a header-only input surface adds no blank row).
    local min_center = (n == 0) and 0
        or (
            gv
            + (
                vertical and (n * math.max(1, cfg.min_content_height or 1) + border_rows + sep_w * (n - 1))
                or (math.max(1, cfg.min_content_height or 1) + max_vborder)
            )
        )
    local min_h = header_h + footer_h + min_center
    local H = place and (place.H - ct - cb)
        or util.axis_size(cfg.auto_height, cfg.height, cfg.max_height, content_h, vim.o.lines)
    H = math.max(H, min_h)

    -- Float placement. Split: the container's actual screen position (passed in `place`). Otherwise by
    -- `cfg.position`: "cursor"/"win" via util.calc_pos (cursor = below the cursor when it fits, else above;
    -- win = centred in the current window), "bottom"/"top" docked to that edge (full width), else centred
    -- on the whole editor. calc_pos takes the TOTAL footprint (content + the container's border insets).
    local row, col
    if place then
        row, col = place.row, place.col
    elseif cfg.at then
        -- ANCHORED to an exact spot in a window: `at = { win, row, col }` in that window's 0-based text
        -- coordinates (row/col as `nvim_win_get_cursor`/`winsaveview` speak them, NOT screen cells).
        -- The reason it exists: an EDITOR over a cell — lvim-db's grid, where an input must sit ON the value
        -- it edits, not centred over the screen. "cursor" is not that: it follows the caret and drops BELOW
        -- it, so it covers the row you are editing.
        -- Translated through `nvim_win_text_height`-free arithmetic on purpose: `win_get_position` + the
        -- window's own scroll offsets is exact and needs no redraw to have happened yet.
        local aw = cfg.at.win
        if aw and api.nvim_win_is_valid(aw) then
            local wpos = api.nvim_win_get_position(aw)
            local view = api.nvim_win_call(aw, function()
                return vim.fn.winsaveview()
            end)
            -- A winbar steals the window's first screen row from the text area.
            local wb = (vim.wo[aw].winbar ~= "") and 1 or 0
            -- MINUS the container's own insets (`ct`/`cl`): `row`/`col` place the float's OUTER edge, while
            -- the caller means "put the CONTENT on this cell". Without this the content lands one row below
            -- its cell — the border eats the difference — which for a cell editor means sitting over the
            -- wrong row's data. Measured, not assumed: with a 1-row ring the field landed at 16 for a cell
            -- at 14.
            row = wpos[1] + wb + (cfg.at.row - (view.topline - 1)) - ct
            col = wpos[2] + (cfg.at.col - (view.leftcol or 0)) - cl
            -- Never let it hang off the screen: an anchored float is still a float, and a cell near the right
            -- edge would otherwise open a window nvim rejects.
            row = math.max(0, math.min(row, vim.o.lines - H - ct - cb - 1))
            col = math.max(0, math.min(col, vim.o.columns - W - cl - cr))
        else
            row, col = util.calc_pos(H + ct + cb, W + cl + cr, "cursor")
        end
    elseif cfg.position == "cursor" or cfg.position == "win" then
        row, col = util.calc_pos(H + ct + cb, W + cl + cr, cfg.position)
    elseif cfg.position == "bottom" or cfg.position == "top" then
        W = vim.o.columns - cl - cr
        col = 0
        row = cfg.position == "bottom" and math.max(0, vim.o.lines - H - ct - cb - 1) or 0
    elseif cfg.position == "left" or cfg.position == "right" then
        -- Dock to a side: full editor height (minus the cmdline row), fixed width (`size.width`) on that edge.
        H = math.max(min_h, vim.o.lines - ct - cb - 1)
        row = 0
        col = cfg.position == "right" and math.max(0, vim.o.columns - W - cl - cr) or 0
    elseif cfg.position == "cmdline" then
        -- The CMDHEIGHT region: full width, docked over the bottom `cmdheight` rows (grown to H in
        -- open_windows). Unlike "bottom" (which leaves the cmdline row free), the surface IS the cmdline
        -- area, so a global statusline / heirline stays above it — hence no `- 1`.
        W = vim.o.columns - cl - cr
        col = 0
        -- Clamp to the largest cmdheight the window layout can give up without "E36: Not enough room": the
        -- non-floating windows must keep their minimum rows. (A tall preview must not grow the area past the
        -- room available between the splits above it.)
        H = math.min(H, max_cmdheight())
        H = math.max(H, min_h)
        row = math.max(0, vim.o.lines - H - ct - cb)
    else
        row = math.max(1, math.floor((vim.o.lines - H) / 2 - 1))
        col = math.max(1, math.floor((vim.o.columns - W) / 2))
    end
    local cc_row, cc_col = row + ct, col + cl
    local center_top = cc_row + header_h
    local center_h = math.max(min_center, H - header_h - footer_h)

    -- Distribute the center across panels along the STACKING axis (width when horizontal, height when
    -- vertical): weighted panels take their share, weightless ones split the remainder (auto ⇒ each takes
    -- its natural size); the cross axis is the full center extent. `dividers` are column offsets when
    -- horizontal, row offsets when vertical (render_chrome draws them per `L.vertical`).
    local out, dividers = {}, {}
    local sep_top, sep_bot -- the divider's row span (container buffer lines) — the panels' content rows
    --- Share `avail` across the panels by weight / auto-natural / flex (the common allocation for both axes).
    ---@param avail integer
    ---@param natural fun(i: integer): integer
    ---@param auto boolean
    ---@return integer[]
    local function allocate(avail, natural, auto)
        local sizes, fixed, flex, auto_idx = {}, 0, {}, {}
        for i, pan in ipairs(panels) do
            local wgt = pan.weight
            -- A panel auto-sizes to its natural content when the WHOLE axis is auto (`auto`) OR the panel
            -- opted in via its own `size.<stack-axis>.auto` (`pan.auto_stack`) — so a single sector can hug
            -- its content (e.g. a 1-row toggle bar) while its neighbours stay fixed / flex.
            if (auto or pan.auto_stack) and not wgt then
                sizes[i] = natural(i)
                fixed = fixed + sizes[i]
                auto_idx[#auto_idx + 1] = i
            elseif wgt then
                sizes[i] = math.max(1, wgt <= 1 and math.floor(avail * wgt) or math.floor(wgt))
                fixed = fixed + sizes[i]
            else
                flex[#flex + 1] = i
            end
        end
        -- OVERFLOW: the natural (auto) panels together exceed `avail` — the area hit its height cap (e.g. a long
        -- list + a preview both wanting `max_rows`). Shrink the auto panels PROPORTIONALLY so the stack fits
        -- exactly, instead of spilling past the container (which pushed the divider + the scoped input band down
        -- into the list, and the last panel off-screen).
        if fixed > avail and #flex == 0 and #auto_idx > 0 then
            -- The auto panels together exceed `avail` (the stack hit the area cap / the room left between the
            -- splits). Shrink them to fit EXACTLY. `shrink_first` panels (e.g. a picker's list) give up rows BEFORE
            -- the rest, so a PROTECTED panel (the list) keeps its own content and its height never jumps as you
            -- navigate files of different lengths; within a group the shrink is proportional. Every panel keeps
            -- at least 1 row. (No marks ⇒ one proportional shrink over all of them, the old behaviour.)
            local first, rest = {}, {}
            for _, i in ipairs(auto_idx) do
                local g = panels[i].shrink_first and first or rest
                g[#g + 1] = i
            end
            -- Remove `amount` rows from `group`, proportional to each panel's room above 1; return the remainder.
            local function shrink(group, amount)
                local pool = 0
                for _, i in ipairs(group) do
                    pool = pool + (sizes[i] - 1)
                end
                local take = math.min(amount, math.max(0, pool))
                local acc = 0
                for k, i in ipairs(group) do
                    local share = (k < #group) and math.floor(take * (sizes[i] - 1) / math.max(1, pool)) or (take - acc) -- the last panel takes the remainder (no rounding gap)
                    sizes[i] = math.max(1, sizes[i] - share)
                    acc = acc + share
                end
                return amount - take
            end
            local over = shrink(first, fixed - avail)
            over = shrink(rest, over)
            fixed = avail + math.max(0, over)
        end
        local rest = math.max(0, avail - fixed)
        if #flex > 0 then
            local each = math.max(1, math.floor(rest / #flex))
            for _, i in ipairs(flex) do
                sizes[i] = each
            end
            sizes[flex[#flex]] = sizes[flex[#flex]] + (rest - each * #flex)
        elseif n > 0 then
            sizes[n] = sizes[n] + rest
        end
        return sizes
    end

    -- The panels lay out INSIDE the group frame: the available extent shrinks by the group overhead (gh / gv)
    -- and the origin shifts in by the LEFT / TOP overhead (gh_l / gv_t). With no group (g_on=false) every g* is
    -- 0, so this is identical to the un-grouped layout.
    if vertical then
        local heights = allocate(math.max(n, center_h - gv - border_rows - sep_w * (n - 1)), function(i)
            return pin[i].nat_h
        end, cfg.auto_height)
        -- Lay footprints top→bottom; each panel is full (grouped) center width; dividers sit in the row gaps.
        local y = center_top + gv_t
        for i = 1, n do
            local pi = pin[i]
            out[i] = {
                width = math.max(1, W - gh - pi.l - pi.r),
                height = heights[i],
                row = y,
                col = cc_col + gh_l,
                border = pi.b,
            }
            y = y + pi.t + heights[i] + pi.bo
            if i < n and sep_w > 0 then
                dividers[#dividers + 1] = y - center_top
                y = y + sep_w
            end
        end
    else
        local widths = allocate(math.max(n, W - gh - border_cols - sep_w * (n - 1)), function(i)
            return pin[i].nat_w
        end, cfg.auto_width)
        -- Lay footprints left→right; each panel's col is its LEFT-BORDER position; dividers sit in the gaps.
        local x = cc_col + gh_l
        for i = 1, n do
            local pi = pin[i]
            out[i] = {
                width = widths[i],
                height = math.max(1, center_h - gv - pi.t - pi.bo),
                row = center_top + gv_t,
                col = x,
                border = pi.b,
            }
            -- The rows the divider may occupy: the panels' CONTENT rows ONLY (as container buffer lines). A
            -- panel's ring rows are chrome, not data — a divider drawn through them pokes one row above and one
            -- below the content and fills the blank ring row under the panels, so the air reads as missing.
            -- Intersected across the panels, so a shorter neighbour clips it.
            local ct0 = out[i].row + pi.t - cc_row
            local cb0 = ct0 + out[i].height - 1
            sep_top = (sep_top == nil) and ct0 or math.max(sep_top, ct0)
            sep_bot = (sep_bot == nil) and cb0 or math.min(sep_bot, cb0)
            x = x + pi.l + widths[i] + pi.r
            if i < n and sep_w > 0 then
                dividers[#dividers + 1] = x - cc_col
                x = x + sep_w
            end
        end
    end

    return {
        W = W,
        H = H,
        min_h = min_h,
        row = row,
        col = col,
        cbord = cbord,
        ct = ct,
        cb = cb,
        header_h = header_h,
        footer_h = footer_h,
        center_h = center_h,
        sep_top = sep_top,
        sep_bot = sep_bot,
        panels = out,
        dividers = dividers,
        vertical = vertical, -- dividers are ROW offsets (a horizontal rule) when true, else column offsets
        -- The common GROUP ring around the panels (drawn by render_chrome), or nil when ungrouped. Coords are
        -- 0-based within the container buffer: `line0`..`line0+lines-1` rows, `col0`..`col0+cols-1` cols. `ptop`
        -- / `pbot` are the panel insets within it (so the divider rule spans only the panel rows, not the ring).
        group = g_on and {
            line0 = header_h,
            lines = center_h,
            col0 = g_og,
            cols = W - 2 * g_og,
            border = gbord,
            hl = ghl,
            ptop = gv_t,
            pbot = gv_b,
            pcol0 = gh_l, -- 0-based buffer col where the PANELS (and so the divider) start, inside the ring
            pcols = W - gh, -- the panel-area width inside the ring
        } or nil,
    }
end

-- ─── chrome render ────────────────────────────────────────────────────────────

--- Render the container buffer: the header band rows at the top, the footer band rows at the bottom,
--- blank center rows carrying the divider columns in between, plus all bar/meta highlights.
---@param state table
---@param L table
local function render_chrome(state, L)
    local W, H = L.W, L.H
    -- The inter-panel divider glyph for the current axis (config-driven via `config.separator`, per-surface
    -- overridable, auto-oriented "│" side-by-side / "─" stacked — so a runtime preview rotation flips it), or
    -- nil when the divider is disabled. See `resolve_divider`.
    local sep_char = resolve_divider(state.cfg.separator, L.vertical)
    local divider_set = {}
    for _, d in ipairs(L.dividers) do
        divider_set[d] = true
    end

    -- A center row (`i` 1-based buffer line). It carries, in this order, on a blank W-wide row:
    --  • the inter-panel DIVIDER — a vertical glyph at the divider COLUMNS (horizontal layout), drawn only on
    --    the PANEL rows; or a full panel-width rule on a divider ROW (vertical/stacked layout);
    --  • the common GROUP ring box (when `L.group`) — its corners / top-bottom rules / left-right verticals,
    --    drawn ON TOP so the ring edges always read cleanly around the panels.
    local grp = L.group
    local sep_hl = sep_char and util.resolve_hl(divider_hl(state.cfg)) or nil
    local grp_hl = grp and util.resolve_hl(grp.hl or "LvimUiPeekBorder") or nil
    -- Highlights for the center rows, keyed by 0-based buffer line → { { byte0, byte1, hl }, … }. We compute
    -- BYTE columns (not cell columns) because the group ring + divider glyphs are multi-byte, so a cell index is
    -- NOT its byte offset — emitting extmarks at cell indices would mis-place the tint.
    local center_hls = {}
    local function center_line(i)
        local i0 = i - 1 -- 0-based buffer line
        local center_off = i - L.header_h - 1 -- 0-based offset within the center (matches vertical dividers)
        local cells, chl = {}, {}
        for c = 1, W do
            cells[c] = " "
        end
        local pcol0 = grp and grp.pcol0 or 0 -- the panel-area column range (where the divider lives)
        local pcols = grp and grp.pcols or W
        if sep_char then
            if L.vertical then
                if divider_set[center_off] then
                    for c = pcol0, pcol0 + pcols - 1 do
                        cells[c + 1], chl[c + 1] = sep_char, sep_hl
                    end
                end
            else
                -- only on the panels' CONTENT rows — a grouped ring's top/bottom rows are not panel rows, and
                -- (L.sep_top/sep_bot) a panel's OWN ring rows are chrome too: a divider through them sticks out
                -- one row above and below the data and blots out the blank ring row under the panels.
                local in_panel = not grp or (i0 >= grp.line0 + grp.ptop and i0 <= grp.line0 + grp.lines - 1 - grp.pbot)
                if L.sep_top and (i0 < L.sep_top or i0 > L.sep_bot) then
                    in_panel = false
                end
                if in_panel then
                    for c = 0, W - 1 do
                        if divider_set[c] then
                            cells[c + 1], chl[c + 1] = sep_char, sep_hl
                        end
                    end
                end
            end
        end
        if grp then
            local gtop, gbot = grp.line0, grp.line0 + grp.lines - 1
            local gl, gr = grp.col0, grp.col0 + grp.cols - 1
            local b = grp.border -- { tl, t, tr, r, br, bo, bl, l }
            local function put(c, ch)
                if ch and ch ~= "" then
                    cells[c + 1], chl[c + 1] = ch, grp_hl
                end
            end
            if i0 == gtop then
                put(gl, b[1])
                put(gr, b[3])
                for c = gl + 1, gr - 1 do
                    put(c, b[2])
                end
            elseif i0 == gbot then
                put(gl, b[7])
                put(gr, b[5])
                for c = gl + 1, gr - 1 do
                    put(c, b[6])
                end
            elseif i0 > gtop and i0 < gbot then
                put(gl, b[8])
                put(gr, b[4])
            end
        end
        -- Convert the per-cell highlights to BYTE-accurate spans for this row.
        local hls, byte = {}, 0
        for c = 1, W do
            local w = #cells[c]
            if chl[c] then
                hls[#hls + 1] = { byte, byte + w, chl[c] }
            end
            byte = byte + w
        end
        if #hls > 0 then
            center_hls[i0] = hls
        end
        return table.concat(cells)
    end

    local lines = {}
    for i = 1, H do
        lines[i] = (i > L.header_h and i <= H - L.footer_h) and center_line(i) or string.rep(" ", W)
    end

    -- Place each header/footer band, recording where its bar buttons land (for the next layer's
    -- selection + hit-testing). `placements` holds post-write highlight ops { row0, c0, c1, hl, prio }.
    state.bands = {} -- flat sector list of the bar bands
    local placements = {}

    local function lay_band(ln, band, where)
        if band.input then -- an editable input band — its overlay window draws the row; leave it blank
            return
        end
        if band.title_counter then
            -- A title + a re-evaluated COUNTER. `title_pos` places the title: LEFT (default) renders THROUGH
            -- ui.bar (title = its left prefix, counter a right-aligned item) so it matches the message bar exactly;
            -- CENTER / RIGHT place the title by hand (ui.bar's title is prefix-only), with the counter still
            -- flush-right. UPPERCASE in every case (the title-bar canon).
            local cnt = band.count and tostring((type(band.count) == "function" and band.count()) or band.count) or ""
            -- A COUNTER forces the title LEFT: the pair reads as one bar (title anchored left, count anchored
            -- right — the message-bar canon), and only the left path renders through ui.bar, whose count is a
            -- real padded BUTTON box (a blank cell each side of the digits) instead of a bare string glued to the
            -- right edge. `title_pos` still places a COUNTER-LESS title (centered by default).
            local tpos = (cnt ~= "" and "left") or band.title_pos or "left"
            if tpos == "left" then
                local items = {}
                if cnt ~= "" then
                    items[1] = {
                        type = "button",
                        text = cnt,
                        style = { text = { padding = { 1, 1 }, normal = band.count_hl or "LvimUiSubtitle" } },
                    }
                end
                local res = uibar.render({
                    items = items,
                    width = W,
                    align = "right",
                    title = band.text,
                    title_hl = band.hl or "LvimUiPeekTitle",
                })
                lines[ln] = res.line
                placements[#placements + 1] = { ln - 1, 0, #res.line, "LvimUiBarFill", 150 } -- the continuous row strip
                for _, sp in ipairs(res.spans) do
                    placements[#placements + 1] = { ln - 1, sp[1], sp[2], sp[3], 200 }
                end
                return
            end
            -- CENTER / RIGHT: place the (uppercased) title manually. Leading run is spaces (1 byte = 1 cell), so
            -- the title's byte offset == its display column; the counter is appended flush-right after it.
            local title = tostring(band.text or ""):upper()
            local tw = util.dw(title)
            local cw = cnt ~= "" and util.dw(cnt) or 0
            local tcol = (tpos == "center") and math.max(0, math.floor((W - tw) / 2))
                or math.max(0, W - tw - (cw > 0 and cw + 1 or 0)) -- "right": sit before the counter
            local body = string.rep(" ", tcol) .. title
            local tstart, tend = tcol, tcol + #title
            local cstart, cend
            if cnt ~= "" then
                local ccol = math.max(util.dw(body), W - cw - 1) -- flush right, 1-col margin, never over the title
                body = body .. string.rep(" ", math.max(0, ccol - util.dw(body)))
                cstart = #body
                body = body .. cnt
                cend = #body
            end
            body = body .. string.rep(" ", math.max(0, W - util.dw(body)))
            lines[ln] = body
            placements[#placements + 1] = { ln - 1, 0, #body, "LvimUiBarFill", 150 }
            placements[#placements + 1] =
                { ln - 1, math.max(0, tstart - 1), math.min(#body, tend + 1), band.hl or "LvimUiPeekTitle", 200 }
            if cstart then
                placements[#placements + 1] = { ln - 1, cstart, cend, band.count_hl or "LvimUiPeekCounter", 200 }
            end
            return
        end
        if band.meta ~= nil then
            lines[ln] = util.center(band.meta, W)
            -- The centred text starts at `s` leading spaces (1 byte each), so a byte offset into `meta` maps
            -- to column `s + offset` on the row.
            local s = math.floor((W - util.dw(band.meta)) / 2)
            if band.hls then
                -- Per-part inline spans (a multi-colour meta line, e.g. the repo band).
                for _, sp in ipairs(band.hls) do
                    placements[#placements + 1] = { ln - 1, s + sp[1], s + sp[2], util.resolve_hl(sp[3]), 200 }
                end
            elseif band.meta ~= "" and band.hl then
                -- 1 space of padding on each side, so a title's bg chrome reads " LVIM LSP " not hugging.
                placements[#placements + 1] =
                    { ln - 1, math.max(0, s - 1), math.min(W, s + #band.meta + 1), band.hl, 200 }
            end
            return
        end
        -- When this bar is the focused sector, its `_sel` button drives BOTH the scroll-follow (`sel`,
        -- keeps it visible on a narrow frame) and the visible selection (`hover`, the button's hover
        -- styling). `_blurred` (focus left the whole frame) drops the selection so no button looks hovered
        -- while the user is back in a normal buffer.
        local focused = not state._blurred and state.focus and state.focus.kind == "bar" and state.focus.band == band
        local sel = focused and band._sel or nil
        -- A `_follow` band keeps its `_sel` in view even when UNFOCUSED — the TAB bar scrolls to the active tab
        -- when it's switched from the body (h/l), so an off-screen tab doesn't go active-but-hidden. The hover
        -- styling still only shows when focused (`hover = sel`); the active tab carries its own `active` styling.
        local scroll = sel or (band._follow and band._sel) or nil
        local res = uibar.render({
            items = band.buttons or {},
            width = W,
            align = band.align or "center",
            chevrons = band.chevrons or state.cfg.chevrons,
            sel = scroll,
            hover = sel,
            off = band._off,
        })
        band._off = res.off
        lines[ln] = res.line
        -- A continuous full-width bg STRIP under the buttons, so the whole bar row reads as one tinted bar
        -- (the buttons + chevrons sit ON it). Priority below the button/chevron spans (200) so they show through.
        -- `band.fill = false` drops the strip (the buttons then float on the bare panel bg). Two depths: the
        -- deeper `Hover` tint when this bar is the one you're ON (focused / cursor on its row), else the resting
        -- tint — the whole bar reads as "active" without any layout change (one bg, two tints).
        if band.fill ~= false then
            placements[#placements + 1] =
                { ln - 1, 0, #res.line, focused and "LvimUiBarFillHover" or "LvimUiBarFill", 150 }
        end
        local entry = { kind = where, row = ln, buttons = {}, band = band }
        for i, b in ipairs(res.items) do
            entry.buttons[i] = { c0 = b.c0, c1 = b.c1, spec = b.spec, sep = b.sep }
        end
        state.bands[#state.bands + 1] = entry
        -- The visible selection is the button's OWN `hover` style (each box's bg, stronger) — NO extra
        -- frame overlay (it bled a 1-col blue tint past the button on each side).
        -- res.spans already carry the chevron boxes' OWN colours (the bar renders them as boxes), so the
        -- frame no longer colourises chevron ranges separately.
        for _, sp in ipairs(res.spans) do
            placements[#placements + 1] = { ln - 1, sp[1], sp[2], sp[3], 200 }
        end
    end

    for i, band in ipairs(state.header_bands) do
        lay_band(i, band, "header")
    end
    for i, band in ipairs(state.footer_bands) do
        lay_band(H - L.footer_h + i, band, "footer")
    end

    vim.bo[state.container_buf].modifiable = true
    api.nvim_buf_set_lines(state.container_buf, 0, -1, false, lines)
    vim.bo[state.container_buf].modifiable = false
    api.nvim_buf_clear_namespace(state.container_buf, NS, 0, -1)

    for _, p in ipairs(placements) do
        pcall(api.nvim_buf_set_extmark, state.container_buf, NS, p[1], p[2], {
            end_col = p[3],
            hl_group = util.resolve_hl(p[4]),
            priority = p[5],
        })
    end
    -- The center-row tints (the GROUP ring + the divider), at BYTE-accurate columns computed in center_line.
    for line0, hls in pairs(center_hls) do
        for _, h in ipairs(hls) do
            pcall(api.nvim_buf_set_extmark, state.container_buf, NS, line0, h[1], {
                end_col = h[2],
                hl_group = h[3],
            })
        end
    end
end

--- Pull a panel's VIEW back onto its content. A re-render can SHRINK the buffer (the message zone drops its
--- title row the moment it loses focus, so 3 lines become 2) while the window keeps the topline it had —
--- which then points past the new content: the top row scrolls out of sight and a blank row appears at the
--- bottom. Nvim does not fix this for a window that is not current, so the frame must: clamp the topline to
--- the last position from which the content still fills the window.
---@param pan table
local function clamp_view(pan)
    if not (pan and pan.win and api.nvim_win_is_valid(pan.win) and pan.buf and api.nvim_buf_is_valid(pan.buf)) then
        return
    end
    local info = vim.fn.getwininfo(pan.win)[1]
    if not info then
        return
    end
    local max_top = math.max(1, api.nvim_buf_line_count(pan.buf) - api.nvim_win_get_height(pan.win) + 1)
    if info.topline > max_top then
        api.nvim_win_call(pan.win, function()
            vim.fn.winrestview({ topline = max_top, lnum = math.min(vim.fn.line("."), max_top) })
        end)
    end
end

--- Render a panel's provider content into its buffer.
---@param state table
---@param idx integer
local function render_panel(state, idx)
    local pan = state.panels[idx]
    if not (pan.buf and api.nvim_buf_is_valid(pan.buf)) then
        return
    end
    local L = state._geom.panels[idx]
    -- An `update` provider OWNS its window — it may swap in an external buffer (e.g. the peek preview
    -- showing the real file buffer with its own syntax). The frame does not write lines for it.
    if pan.provider and pan.provider.update then
        pcall(pan.provider.update, pan, L)
        clamp_view(pan)
        return
    end
    local lines, hls = {}, {}
    if pan.provider and pan.provider.render then
        local ok, rl, rh = pcall(pan.provider.render, L.width, L.height)
        if ok then
            lines, hls = rl or {}, rh or {}
        end
    end
    M.paint(pan, lines, hls)
    clamp_view(pan)
end

--- Paint `lines` + `hls` into a panel's buffer. Extracted from `render_panel` and PUBLIC because a
--- consumer that owns the `update` seam (the tabs delegate, which must host `render`-only providers as
--- tabs) has to paint exactly the way the frame does — same read-only handling, same namespace, same
--- full-row span semantics — instead of hand-rolling a second, subtly different painter.
---@param pan table
---@param lines string[]
---@param hls table[]  { row, col, end_col|-1, hl, priority? }
function M.paint(pan, lines, hls)
    if not (pan and pan.buf and api.nvim_buf_is_valid(pan.buf)) then
        return
    end
    vim.bo[pan.buf].modifiable = true
    api.nvim_buf_set_lines(pan.buf, 0, -1, false, lines)
    -- An `editable` provider (the input field) keeps its buffer writable; all others are read-only.
    vim.bo[pan.buf].modifiable = (pan.provider and pan.provider.editable) or false
    api.nvim_buf_clear_namespace(pan.buf, NS, 0, -1)
    for _, h in ipairs(hls or {}) do
        if h[3] == -1 then -- a FULL-ROW span: the bg reaches the window edge (hl_eol), for row striping
            pcall(api.nvim_buf_set_extmark, pan.buf, NS, h[1], 0, {
                end_row = h[1] + 1,
                hl_group = util.resolve_hl(h[4]),
                hl_eol = true,
                priority = h[5] or 200,
            })
        else
            pcall(api.nvim_buf_set_extmark, pan.buf, NS, h[1], h[2], {
                end_col = h[3],
                hl_group = util.resolve_hl(h[4]),
                priority = h[5] or 200,
            })
        end
    end
end

-- ─── sectors / focus / navigation ─────────────────────────────────────────────

--- The ordered sector list: each header bar band, then each center panel, then each footer bar band.
--- Meta header bands (title/subtitle) are NOT sectors. `_sel`/`_off` live on the band tables so the
--- selection + scroll persist across redraws.
---@param state table
---@return table[]
local function build_sectors(state)
    local s = {}
    for _, band in ipairs(state.header_bands) do
        if band.buttons then
            s[#s + 1] = { kind = "bar", band = band, where = "header" }
        end
    end
    -- The whole center (all N panels) is ONE vertical sector — `<C-j>`/`<C-k>` step header · center ·
    -- footer; `<C-l>`/`<C-h>` move between the panels INSIDE the center. With `center_panel_sectors` the
    -- center is instead split so EACH panel is its OWN `<C-j>`/`<C-k>` sector (a stacked multi-layer panel:
    -- e.g. lvim-replace's fields ⇄ results), each landed on directly by the vertical sector cycle.
    if #state.panels > 0 then
        if state.cfg.center_panel_sectors then
            for pi = 1, #state.panels do
                s[#s + 1] = { kind = "center", panel = pi }
            end
        else
            s[#s + 1] = { kind = "center" }
        end
    end
    for _, band in ipairs(state.footer_bands) do
        if band.buttons then
            s[#s + 1] = { kind = "bar", band = band, where = "footer" }
        end
    end
    return s
end

--- Focus center panel `i`: pick the cursor mode, focus its window, start insert for an editable panel,
--- fire on_focus. Records it as the current center panel.
---@param state table
---@param i integer
local function focus_panel_win(state, i)
    local pan = state.panels[i]
    if not pan then
        return
    end
    state.center_panel = i
    if pan.win and api.nvim_win_is_valid(pan.win) then
        api.nvim_set_current_win(pan.win)
    end
    -- The panel's filetype drives cursor visibility (hide-cursor panels carry FRAME_FT) — apply it now to
    -- avoid a one-frame flash.
    cursor.update()
    -- An editable panel (the input field) enters insert at the end of its line.
    if pan.provider and pan.provider.editable then
        vim.schedule(function()
            if pan.win and api.nvim_win_is_valid(pan.win) then
                api.nvim_set_current_win(pan.win)
                vim.cmd("startinsert!")
            end
        end)
    end
    if pan.provider and pan.provider.on_focus then
        pcall(pan.provider.on_focus)
    end
end

--- Focus sector `i`: the CENTER sector focuses its current panel (the panels are ONE vertical sector;
--- `<C-l>`/`<C-h>` move between them); a BAR sector focuses the container, hides the cursor + selects.
---@param state table
---@param i integer
local function focus_sector(state, i)
    local sec = state.sectors[i]
    if not sec then
        return
    end
    state.focus_idx = i
    if sec.kind == "center" then
        -- With `center_panel_sectors` each center sector names its OWN panel; else the single center sector
        -- lands on the tracked / primary panel.
        local p = sec.panel or state.center_panel or 1
        state.center_panel = p
        state.focus = { kind = "center", panel = p }
        focus_panel_win(state, p)
    else
        sec.band._sel = sec.band._sel or 1
        state.focus = { kind = "bar", band = sec.band, where = sec.where }
        if state.container_win and api.nvim_win_is_valid(state.container_win) then
            -- Mark this as a frame-driven focus so the container's WinEnter hook does NOT bounce us into
            -- the center (that bounce is only for a NATIVE `<C-w>j` entry). WinEnter fires synchronously
            -- inside nvim_set_current_win, so the flag is up while it runs.
            state._focusing_bar = true
            api.nvim_set_current_win(state.container_win)
            state._focusing_bar = false
        end
        cursor.update() -- container is current (FRAME_FT) → cursor hidden in bar-menu mode
    end
    render_chrome(state, state._geom)
end

--- The sector index of the CURRENTLY focused window — a panel by its window, else the tracked bar.
--- Reading the real window keeps `<C-j>`/`<C-k>` correct even if focus changed outside the frame.
---@param state table
---@return integer
local function current_sector(state)
    local w = api.nvim_get_current_win()
    -- A center panel window maps to its center sector: with `center_panel_sectors` the sector whose `panel`
    -- matches this window's index; else the single center sector (`sec.panel` nil ⇒ any panel).
    for pi, pan in ipairs(state.panels) do
        if pan.win == w then
            for si, sec in ipairs(state.sectors) do
                if sec.kind == "center" and (sec.panel == nil or sec.panel == pi) then
                    return si
                end
            end
        end
    end
    return state.focus_idx or 1
end

--- At a vertical EDGE of a docked split, hand focus OUT to the neighbouring real window instead of
--- wrapping inside the frame: step OUT toward the editor in the given wincmd direction. The caller picks
--- the direction to MATCH the dock — currently only the VERTICAL sector escape uses it (`<C-k>` from the
--- top sector steps up to the editor above a bottom-docked peek). The function stays direction-generic, so
--- a future float side-dock could pass `h`/`l`. The frame stays open — in split mode it is non-modal;
--- float frames are modal, so they never escape (they keep wrapping). Returns true when focus moved out.
---@param state table
---@param nav string  "h"|"j"|"k"|"l" — the wincmd direction to the neighbouring editor window
---@return boolean
local function escape_to_neighbor(state, nav)
    if state.cfg.mode ~= "split" then
        return false
    end
    if not (state.container_win and api.nvim_win_is_valid(state.container_win)) then
        return false
    end
    -- The panels are floats (off the window layout), so resolve the neighbour from the container split.
    -- `winnr(nav)` returns the container's OWN number when there is no window in that direction.
    local target = api.nvim_win_call(state.container_win, function()
        return vim.fn.win_getid(vim.fn.winnr(nav))
    end)
    if target == 0 or target == state.container_win or not api.nvim_win_is_valid(target) then
        return false
    end
    api.nvim_set_current_win(target)
    cursor.update() -- the editor (normal ft) is current now → cursor visible again
    return true
end

--- Whether this surface TRAPS focus: while it is open, focus cannot leave to a real (non-float) window —
--- a native `<C-w>` jump OR a mouse click into the editor bounces straight back into the frame, so a modal
--- popup genuinely cannot be escaped except through its own keys (`q`/`<Esc>`/an action). Neovim has no
--- native window-modality, so the WinEnter bounce below IS the canonical mechanism.
---
--- Resolution: the per-open `cfg.trap_focus` wins; else the GLOBAL `config.trap_focus`; else true. Only a
--- CENTRED float is modal by default — a `split`, or a docked / hosted / escape-declaring surface
--- (`host` / `position` / `on_escape_*`) is meant to COEXIST with the editor, so it never traps unless the
--- consumer sets `trap_focus = true` explicitly.
---@param state table
---@return boolean
local function traps_focus(state)
    local cfg = state.cfg
    local opt = cfg.trap_focus
    if opt == nil then
        local ok, gc = pcall(require, "lvim-ui.config")
        opt = (ok and gc and gc.trap_focus)
        if opt == nil then
            opt = true
        end
    end
    if not opt or cfg.mode ~= "float" then
        return false
    end
    if cfg.host or cfg.position or cfg.on_escape_above or cfg.on_escape_below then
        return cfg.trap_focus == true -- a coexisting dock/host: trap only on an explicit per-open opt-in
    end
    return true
end

--- Move focus to the next/prev sector, starting from the actually-focused window. At the top/bottom edge
--- of a docked split it steps OUT to the neighbouring editor window (see `escape_to_neighbor`); otherwise
--- it wraps around the frame.
---@param state table
---@param dir integer
local function sector_cycle(state, dir)
    local n = #state.sectors
    if n == 0 then
        return
    end
    local cur = current_sector(state)
    -- DYNAMIC peek: the float sits ABOVE everything, so `<C-k>` from the TOP sector would step INTO it. Whether
    -- it is a stop at all is the CHASSIS-WIDE `config.peek_enter` (default false — the float is there to be read
    -- while you move through the list, so the cursor goes straight out to the real buffer); a surface may
    -- override it with `cfg.peek_enter`. When it IS enterable, one more `<C-k>` from the top sector lands in it.
    local peek_enter = state.cfg.peek_enter
    if peek_enter == nil then
        peek_enter = config.peek_enter == true
    end
    if
        peek_enter
        and state.preview_side == "dynamic"
        and dir < 0
        and cur == 1
        and state.dyn
        and state.dyn.win
        and api.nvim_win_is_valid(state.dyn.win)
    then
        api.nvim_set_current_win(state.dyn.win)
        return
    end
    if (dir < 0 and cur == 1) or (dir > 0 and cur == n) then
        -- Top/bottom edge of a docked split → step VERTICALLY out to the editor (matches a below/above dock).
        if escape_to_neighbor(state, dir < 0 and "k" or "j") then
            return
        end
        -- Bottom edge of a HOSTED float → hand focus DOWN to the host zone below it (the messages composed
        -- under a finder). Remember THIS sector (the footer) so when focus returns, we land back on it (not on
        -- the header, the WinEnter default) — symmetric up/down navigation.
        if dir > 0 and state.cfg.on_escape_below then
            state._return_sector = cur
            if state.cfg.on_escape_below() then
                return
            end
            state._return_sector = nil
        end
        -- Top edge → hand focus UP to the editor above (the mirror of on_escape_below): stop here instead of
        -- WRAPPING down to the footer. Without a handler we still stop (no wrap) rather than jump to the bottom.
        if dir < 0 and state.cfg.on_escape_above then
            state.cfg.on_escape_above()
            return
        end
        -- A DOCKED float (an `area` / `bottom` panel) sits UNDER the editor, so stepping off its TOP band walks
        -- back into the window it was opened from — the same chain the user came down: buffer → bands → content
        -- → footer, and back. A plain FLOAT is modal chrome hovering over everything: there is no "out", and it
        -- must never hand focus away.
        if dir < 0 and state.cfg.position and state.origin and api.nvim_win_is_valid(state.origin) then
            api.nvim_set_current_win(state.origin)
            cursor.update() -- a normal buffer is current again → the hardware cursor comes back
            return
        end
        return -- at an edge with no escape handler → STOP (never WRAP around to the opposite end)
    end
    local target = ((cur - 1 + dir) % n) + 1
    -- Entering the CENTER lands on that sector's OWN panel (`center_panel_sectors`), else the PRIMARY panel
    -- (1); the preview beside it is reached by panel-nav.
    local tsec = state.sectors[target]
    if tsec and tsec.kind == "center" then
        state.center_panel = tsec.panel or 1
    end
    focus_sector(state, target)
end

--- Toggle the focused CENTER panel (list ⇄ preview, cycling when there are more) — `panel_toggle` (Tab). The
--- vertical sector nav always lands on panel 1, so this is the ONLY way onto the preview.
---@param state table
local function panel_toggle(state)
    local np = #state.panels
    if np <= 1 then
        return
    end
    state.center_panel = ((state.center_panel or 1) % np) + 1
    for si, sec in ipairs(state.sectors) do
        if sec.kind == "center" then
            focus_sector(state, si) -- focus_sector reads center_panel
            return
        end
    end
end

--- Move the focused bar's selection by `dir`, skipping non-interactive separators; redraw (which
--- scrolls the selection into view on a narrow frame).
---@param state table
---@param dir integer
local function menu_move(state, dir)
    if not (state.focus and state.focus.kind == "bar") then
        return
    end
    local btns = state.focus.band.buttons or {}
    local n = #btns
    if n == 0 then
        return
    end
    local i = state.focus.band._sel or 1
    repeat
        i = i + (dir > 0 and 1 or -1)
    until i < 1 or i > n or btns[i].type ~= "separator"
    if i >= 1 and i <= n then
        state.focus.band._sel = i
        render_chrome(state, state._geom)
        -- A "live" bar (e.g. the tab bar) reacts to every selection move, not just <CR>.
        if state.focus.band.on_change then
            state.focus.band.on_change(btns[i], state)
        end
    end
end

--- Fire the focused bar's selected button: `spec.run(state)` if present, else `band.on_select(spec,
--- state)`.
---@param state table
local function menu_confirm(state)
    if not (state.focus and state.focus.kind == "bar") then
        return
    end
    local band = state.focus.band
    local spec = (band.buttons or {})[band._sel or 1]
    if not spec or spec.type == "separator" then
        return
    end
    if spec.run then
        spec.run(state)
    elseif band.on_select then
        band.on_select(spec, state)
    end
end

--- Activate a bar button by a MOUSE CLICK — the exact equivalent of navigating the focused bar's selection
--- onto button `i` (menu_move, which fires a live bar's `on_change` — e.g. a tab switch) and then confirming
--- it (menu_confirm — a footer/affordance button's `run`, or `band.on_select`). Reuses the SAME dispatch as
--- the keyboard, so a click does exactly what the keys do; a separator is a no-op. `entry` is a `state.bands`
--- record (`{ band, buttons, row }`).
---@param state table
---@param entry table
---@param i integer
local function bar_click_activate(state, entry, i)
    local band = entry.band
    local spec = (band.buttons or {})[i]
    if not spec or spec.type == "separator" then
        return
    end
    -- Focus this bar's sector (matches h/l landing on it): correct hover styling + subsequent key nav start here.
    for si, sec in ipairs(state.sectors) do
        if sec.kind == "bar" and sec.band == band then
            band._sel = i
            focus_sector(state, si) -- re-renders the chrome with `i` selected
            break
        end
    end
    -- A "live" bar reacts to the selection landing on `i` (the tab bar switches tabs) — mirror menu_move.
    if band.on_change then
        band.on_change(spec, state)
    end
    -- …then confirm the button (a footer / affordance `run`, or the band's `on_select`) — mirror menu_confirm.
    if spec.run then
        spec.run(state)
    elseif band.on_select then
        band.on_select(spec, state)
    end
end

--- The item the focused selection points at — the first center panel whose provider exposes `selection()`
--- (the list; the preview has none). Drives the default `open`.
---@param state table
---@return table? item
local function focused_selection(state)
    for _, pan in ipairs(state.panels) do
        if pan.provider and pan.provider.selection then
            local ok, it = pcall(pan.provider.selection)
            if ok and it then
                return it
            end
        end
    end
    return nil
end

--- Default OPEN action — open the focused selection in `mode` ("window"|"split"|"vsplit"|"tab"). A consumer
--- overrides the whole behaviour with `cfg.on_open(mode, item)`; otherwise an item carrying `path` (+ optional
--- `lnum`/`col`) is opened with `nvim_win_set_buf` (NOT `:edit`, so an unsaved editable preview can't block it
--- with E37) in the origin window, or a fresh split/vsplit/tab. The frame closes first either way.
---@param state table
---@param mode string
local function default_open(state, mode)
    local item = focused_selection(state)
    local origin = state.origin
    if state.cfg.on_open then
        state.close()
        state.cfg.on_open(mode, item)
        return
    end
    if not (item and item.path) then
        return
    end
    state.close()
    if origin and api.nvim_win_is_valid(origin) then
        api.nvim_set_current_win(origin)
    end
    if mode == "split" then
        vim.cmd("split")
    elseif mode == "vsplit" then
        vim.cmd("vsplit")
    elseif mode == "tab" then
        vim.cmd("tabnew")
    end
    local buf = vim.fn.bufadd(item.path)
    vim.fn.bufload(buf)
    api.nvim_win_set_buf(0, buf)
    pcall(api.nvim_win_set_cursor, 0, { item.lnum or 1, math.max(0, (item.col or 1) - 1) })
    pcall(vim.cmd, "normal! zz")
end

--- The dock LAYOUT a surface belongs to — the key its geometry (height / width / backdrop) is read under in the
--- central `lvim-utils.config.dock.geometry`. Declared here because both the height resolver below and the
--- backdrop resolver further down need it.
---@param cfg table
---@return "area"|"bottom"|"float"
local function backdrop_layout(cfg)
    if cfg.position == "cmdline" then
        return "area"
    elseif cfg.position == "bottom" then
        return "bottom"
    end
    return "float"
end

--- Set the DOCKED container height from `cfg.preview_heights.horizontal` (a value ≤ 1 is a fraction of the
--- screen, > 1 an absolute row count) — the height of the dock itself, whose panels always sit side by side.
--- (`preview_heights.vertical` is a different thing: the cap of the `dynamic` peek FLOAT — see `dyn_geom`.)
--- No-op for a float or when the consumer didn't ask for managed heights.
---@param state table
---@param side string  the preview's current side (kept for the call sites; the docked height is one number now)
local function apply_dock_height(state, side)
    local _ = side
    if not (state.cfg.host or state.cfg.mode == "split") then
        return -- only the DOCKED layouts (hosted msgarea zone, or a non-hosted bottom/area split) have a height
    end
    local hs = state.cfg.preview_heights
    local v = hs and hs.horizontal
    if type(v) ~= "number" then
        return
    end
    local rows = math.max(1, v <= 1 and math.floor(vim.o.lines * v) or math.floor(v))
    -- FIT or FIXED — the user's own choice, not ours. `height_auto` (the control center's "height auto (fit)"
    -- row, living in the central `dock.geometry.<layout>`) says whether the configured height is a MAXIMUM the
    -- panel content-fits up to, or an EXACT height. This used to force `auto_height = true` unconditionally,
    -- which silently overrode a user who had turned the fit OFF (their fixed panel re-sized itself anyway).
    --   auto  → content-fit up to `rows`; when the pair does not fit, the shrink in compute_geom takes the rows
    --           from the PREVIEW (`shrink_first`), so the list's height never jumps as you scroll files.
    --   fixed → exactly `rows`, always; nothing re-fits.
    -- (cfg.size is normalised once at open, so we set the fields compute_geom reads directly; relayout
    -- re-reserves the host.)
    local auto = true
    local ok_c, uconf = pcall(require, "lvim-utils.config")
    if ok_c then
        local g = (((uconf or {}).dock or {}).geometry or {})[backdrop_layout(state.cfg)]
        if g and g.height_auto ~= nil then
            auto = g.height_auto == true
        end
    end
    if auto then
        state.cfg.auto_height = true
        state.cfg.height = nil
        state.cfg.max_height = rows
    else
        state.cfg.auto_height = false
        state.cfg.height = rows
        state.cfg.max_height = nil
    end
end

--- Nop the mouse events that would SELECT in a panel (and, for a fit-to-window modal, the wheel too). The rule
--- and the event list are the ecosystem's — `lvim-utils.mouse` — so every panel behaves identically, whether it
--- comes from this chassis or a plugin's own window. See that module for WHY (a fast click emits
--- `<2-/<3-/<4-LeftMouse>`, which natively select the word / line / block and start Visual).
---@param buf integer
---@param used_lhs? table<string, true>  lhs already bound by the panel/provider — never overwrite those
---@param scroll? boolean  also nop the wheel (a fit-to-window float); omit on a docked, scrollable panel
local function nop_mouse(buf, used_lhs, scroll)
    require("lvim-utils.mouse").lock(buf, { used = used_lhs, scroll = scroll })
end

--- Install the chassis keymaps. Panel buffers get sector cycling + the provider's own keys; the
--- container buffer (bar-menu mode) gets selection move / confirm + sector cycling. `cfg.close_keys`
--- close a modal frame from anywhere.
---@param state table
local function set_keys(state)
    -- Precedence: the hardcoded fallback < the GLOBAL `ui.keys` config < this surface's own `cfg.keys`.
    local ok_cfg, cfg = pcall(require, "lvim-ui.config")
    local global_keys = (ok_cfg and cfg and cfg.keys) or {}
    local K = vim.tbl_extend("force", DEFAULT_KEYS, global_keys, state.cfg.keys or {})
    -- Expose the RESOLVED chassis keys so a hosted-terminal consumer (picker / shell) can rebind the frame nav
    -- (sector cycling) on ITS own buffer with the SAME keys, instead of hardcoding them — one source of truth.
    state.keys = K
    local used = {} -- used[buf][lhs] = true — the keys we actually bind, so `lock_keys` can <Nop> the rest
    local function map(buf, lhs, fn)
        used[buf] = used[buf] or {}
        for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
            vim.keymap.set("n", l, fn, { buffer = buf, nowait = true, silent = true })
            used[buf][l] = true
        end
    end
    -- `lock_panel`: a MODAL panel — only the keys we bound act; every other normal-mode key (motions,
    -- scrolls, edits, search) is `<Nop>`-ed so a stray press can't move the cursor / scroll / edit the panel.
    -- The DEFAULT for every surface. Per-open: `cfg.lock_keys = false` (no lock) or `"light"` (a READABLE
    -- panel — chrome locked, content keyboard free; see the call site). A key the USER bound globally as a
    -- CHORD is never nopped in any mode (see `global_chords`).
    -- The cmdline `:` is kept as an escape hatch. Run AFTER the panel binds (so `used` is populated) and BEFORE
    -- map_hotkeys (so a button hotkey re-maps OVER the `<Nop>`).
    -- The keys the USER has bound GLOBALLY as CHORDS (`<C-c>`, `<A-l>`, …). A modal panel must never nop
    -- these: they are the user's own commands — quit, window nav, their leader chords — and swallowing them
    -- means a focused panel can trap the editor (the lock took `<C-c>` and even `<C-w>`). Plain letters are
    -- NOT exempted even when globally mapped: those are the panel's own alphabet (its actions, its rows), and
    -- letting a global `s`/`f` fire inside a picker is exactly the collision the lock exists to prevent.
    --- The exempt set is keyed by the chord's FIRST key, not the whole lhs: a user chord is often a SEQUENCE
    --- (`<C-c>e` = quit), and nopping its PREFIX (`<C-c>`) kills it just as dead as nopping the whole thing —
    --- the sequence can never start.
    ---@return table<string, boolean>
    local function global_chords()
        local out = {}
        for _, m in ipairs(api.nvim_get_keymap("n")) do
            -- `m.lhs` is ALREADY textual here ("<C-C>e"); running it through `keytrans` would escape its
            -- leading `<` into `<lt>` and the match would never fire.
            local first = m.lhs:match("^(<[^>]+>)") or m.lhs:sub(1, 1)
            if first:match("^<[CAMSDcamsd]%-") then
                out[first:lower()] = true
            end
        end
        return out
    end

    local chords = global_chords()

    local function lock_panel(buf)
        local u = used[buf] or {}
        local own_prefix = chord_prefixes(u)
        local function nop(lhs)
            if u[lhs] or chords[lhs:lower()] or own_prefix[lhs] then
                return
            end
            pcall(vim.keymap.set, "n", lhs, "<Nop>", { buffer = buf, nowait = true, silent = true })
        end
        for i = 33, 126 do
            local ch = string.char(i)
            if ch ~= ":" then -- single printable keys (a stray `g`/`z` prefix is killed too → no `gg`/`zz`)
                nop(ch)
            end
        end
        for i = string.byte("a"), string.byte("z") do
            nop("<C-" .. string.char(i) .. ">") -- the Ctrl-letter combos (scroll, etc.)
        end
        for _, sk in ipairs({ "<Up>", "<Down>", "<Left>", "<Right>", "<PageUp>", "<PageDown>", "<Home>", "<End>" }) do
            nop(sk)
        end
        -- Mouse scroll/drag (the shared rule — see `nop_mouse`): a drag must never start Visual, and on a
        -- fit-to-window float the wheel must not pull the view. `<LeftMouse>` stays live (rows/bar buttons).
        nop_mouse(buf, u, true)
    end
    for _, pan in ipairs(state.panels) do
        -- Panels: vertical sector cycling (header·center·footer) AND horizontal panel nav (left/right);
        -- the panel keys are ONLY here (not on the container), so `<C-l>`/`<C-h>` are inert in a bar.
        map(pan.buf, K.sector_next, function()
            sector_cycle(state, 1)
        end)
        map(pan.buf, K.sector_prev, function()
            sector_cycle(state, -1)
        end)
        map(pan.buf, K.panel_next, function()
            state.panel(1)
        end)
        map(pan.buf, K.panel_prev, function()
            state.panel(-1)
        end)
        map(pan.buf, K.panel_toggle, function()
            panel_toggle(state)
        end)
        -- OPEN the focused selection (a provider's own `keys` below may still override these, e.g. <CR>)
        map(pan.buf, K.open, function()
            default_open(state, "window")
        end)
        map(pan.buf, K.open_split, function()
            default_open(state, "split")
        end)
        map(pan.buf, K.open_vsplit, function()
            default_open(state, "vsplit")
        end)
        map(pan.buf, K.open_tab, function()
            default_open(state, "tab")
        end)
        -- ROTATE the preview position (live reflow of the floats)
        map(pan.buf, K.preview_next, function()
            state.rotate_preview(1)
        end)
        map(pan.buf, K.preview_prev, function()
            state.rotate_preview(-1)
        end)
        -- HIDE ↔ show the preview (no-op while `dynamic`)
        map(pan.buf, K.toggle_preview, function()
            if state.toggle_preview then
                state.toggle_preview()
            end
        end)
        -- SCROLL the preview from here, WITHOUT giving it the focus. Bound through `map` (not around the
        -- lock): that records them in `used`, so `lock_panel` leaves exactly these two Ctrl keys live and
        -- keeps nopping every other stray scroll.
        map(pan.buf, K.preview_scroll_down, function()
            if state.scroll_preview then
                state.scroll_preview(1)
            end
        end)
        map(pan.buf, K.preview_scroll_up, function()
            if state.scroll_preview then
                state.scroll_preview(-1)
            end
        end)
        -- HIDE-CURSOR list movement: on a hide-cursor panel the native cursor keys are locked
        -- (lock_panel nops every unbound printable), so the CHASSIS moves the hidden cursor —
        -- cursorline is the selection (a simple `M.select` list, a help/ops list provider). A
        -- provider that binds its own K.down/K.up (the form) overrides these below.
        if pan.provider and pan.provider.hide_cursor and not pan.provider.editable then
            local function list_move(delta)
                if pan.win and api.nvim_win_is_valid(pan.win) then
                    local line = api.nvim_win_get_cursor(pan.win)[1]
                    local target = math.max(1, math.min(line + delta, api.nvim_buf_line_count(pan.buf)))
                    api.nvim_win_set_cursor(pan.win, { target, 0 })
                end
            end
            -- K.down/K.up may be a single lhs or a list — flatten with the arrow synonym appended.
            local function plus_arrow(keys, arrow)
                local out = {}
                for _, l in ipairs(type(keys) == "table" and keys or { keys }) do
                    out[#out + 1] = l
                end
                out[#out + 1] = arrow
                return out
            end
            map(pan.buf, plus_arrow(K.down, "<Down>"), function()
                list_move(1)
            end)
            map(pan.buf, plus_arrow(K.up, "<Up>"), function()
                list_move(-1)
            end)
            -- MOUSE: a left-click on a hide-cursor list row MOVES the (hidden) selection onto that row, then
            -- runs the provider's `on_click(pan, state, line)` — the SAME action its confirm key runs (select →
            -- pick, multiselect → toggle). A provider without `on_click` just gets the selection moved (a plain
            -- help/ops list). Bound BEFORE `provider.keys`, so a provider that binds its OWN `<LeftMouse>` (the
            -- form's per-button hit-testing) overrides this. No-op while `mouse` is disabled.
            map(pan.buf, "<LeftMouse>", function()
                if vim.o.mouse == "" then
                    return
                end
                local m = vim.fn.getmousepos()
                if m.winid ~= pan.win or m.line < 1 or not (pan.win and api.nvim_win_is_valid(pan.win)) then
                    return
                end
                local line = math.min(m.line, api.nvim_buf_line_count(pan.buf))
                local col0 = math.max(0, m.column - 1)
                -- Column 0, ALWAYS — never the clicked column. A panel row is a rendered widget, not text: the
                -- column carries no meaning, and parking the cursor ON A WORD makes every word-based highlighter
                -- (LSP document-highlight, cursorword) paint that word — so a click on "dir" left a selection
                -- patch over the label on top of the row bar. Keyboard nav already lands on column 0, which is
                -- exactly why j/k never showed it. `col0` is still passed to `on_click` below, so a
                -- column-addressable provider (a calendar day grid, a fold chevron) can still hit-test it.
                pcall(api.nvim_win_set_cursor, pan.win, { line, 0 })
                if pan.provider and pan.provider.on_click then
                    -- `line` is the 1-based clicked buffer row; `col0` the 0-based byte column — a provider
                    -- with column-addressable content (e.g. a calendar day grid) hit-tests with both.
                    pan.provider.on_click(pan, state, line, col0)
                end
            end)
        end
        if pan.provider and pan.provider.keys then
            pcall(pan.provider.keys, function(lhs, fn)
                map(pan.buf, lhs, fn)
            end, pan, state)
        end
        for _, ck in ipairs(state.cfg.close_keys or {}) do
            map(pan.buf, ck, state.close)
        end
    end
    map(state.container_buf, K.menu_prev, function()
        menu_move(state, -1)
    end)
    map(state.container_buf, K.menu_next, function()
        menu_move(state, 1)
    end)
    map(state.container_buf, K.menu_confirm, function()
        menu_confirm(state)
    end)
    map(state.container_buf, K.sector_next, function()
        sector_cycle(state, 1)
    end)
    map(state.container_buf, K.sector_prev, function()
        sector_cycle(state, -1)
    end)
    -- The panel-nav keys belong to the CONTAINER too, not only to the panels. The bands live on the container,
    -- and leaving `<C-l>`/`<C-h>` unbound there lets them fall through to whatever the USER has them on
    -- globally (window navigation) — so a bar focused inside the frame threw focus out to the editor. A frame
    -- owns its keyboard on every one of its buffers.
    map(state.container_buf, K.panel_next, function()
        state.panel(1)
    end)
    map(state.container_buf, K.panel_prev, function()
        state.panel(-1)
    end)
    -- MOUSE: a left-click on any header/footer bar button acts exactly like navigating the selection onto it
    -- and confirming (tab switch / filter / footer action). Hit-test the click's row+column against the live
    -- `state.bands` render metadata (each button's byte range `c0..c1`), so it is pixel-accurate and never
    -- steals a click that misses every button. No-op when `mouse` is disabled. Additive — the keys are intact.
    map(state.container_buf, "<LeftMouse>", function()
        if vim.o.mouse == "" then
            return
        end
        local m = vim.fn.getmousepos()
        if m.winid ~= state.container_win then
            return
        end
        local col0 = m.column - 1
        for _, entry in ipairs(state.bands or {}) do
            if entry.row == m.line then
                for i, b in ipairs(entry.buttons or {}) do
                    if not b.sep and b.c0 and col0 >= b.c0 and col0 < b.c1 then
                        bar_click_activate(state, entry, i)
                        return
                    end
                end
            end
        end
    end)
    for _, ck in ipairs(state.cfg.close_keys or {}) do
        map(state.container_buf, ck, state.close)
    end

    -- Extra consumer keymaps, each a `{ key = lhs|lhs[], run = fn(state), scope? }`. By default they fire from
    -- ANYWHERE in the frame (every panel + the container) — e.g. the Quit dialog's `q`. `scope = "panel"` binds
    -- them on the PANELS ONLY: the container is where the BARS live, and a key that manipulates CONTENT (the
    -- calendar's `h`/`l` = previous/next day) must not fire while a bar is focused — there `h`/`l` belong to
    -- the bar's own button selection, and binding over them makes a focused bar unusable.
    -- The MOVEMENT keys are NEVER surrendered to a consumer keymap. A frame-wide keymap is bound after the
    -- provider's own keys (above) and so silently won — which turned `k` (up) into whatever the consumer keyed
    -- `k`: in lvim-git's transients that was Checkout / Drop / Reset / Abort, and on the stash panel a stash
    -- DROP. Navigating a list with `k` then rewrote the user's working tree with no confirmation (four stray
    -- detached checkouts in one session, from nothing but cursor movement). Moving the cursor is the most basic
    -- interaction a panel has: it must always mean movement, so the collision is resolved HERE, once, for every
    -- consumer — rather than trusting each popup to avoid two letters. A colliding key is skipped and reported,
    -- because a row that still ADVERTISES it (a transient renders `key` as its badge) is a lie the consumer
    -- must fix at its own call site.
    local nav_reserved = {}
    for _, group in ipairs({ K.down, K.up, "<Down>", "<Up>" }) do
        for _, l in ipairs(type(group) == "table" and group or { group }) do
            nav_reserved[l] = true
        end
    end
    for _, km in ipairs(state.cfg.keymaps or {}) do
        local fn = function()
            km.run(state)
        end
        local clashes = {}
        for _, l in ipairs(type(km.key) == "table" and km.key or { km.key }) do
            if nav_reserved[l] then
                clashes[#clashes + 1] = l
            end
        end
        if #clashes > 0 then
            vim.notify(
                ("lvim-ui: keymap %q shadows the navigation keys (%s) — not bound; re-key it"):format(
                    table.concat(clashes, ", "),
                    table.concat(vim.tbl_keys(nav_reserved), "/")
                ),
                vim.log.levels.WARN
            )
        else
            for _, pan in ipairs(state.panels) do
                map(pan.buf, km.key, fn)
            end
            if km.scope ~= "panel" then
                map(state.container_buf, km.key, fn)
            end
        end
    end

    -- MOUSE SELECTION is never wanted on ANY panel — independent of `lock_keys` and of `hide_cursor`. A
    -- cursor-VISIBLE panel (the LSP outline, a scrollable list) is still a rendered surface: a click there must
    -- move the row selection, never start a Visual selection over the label. `lock_panel` below only covers
    -- hide-cursor panels, which is exactly why the outline stayed selectable. Run AFTER the provider's keys are
    -- bound, so a provider's own `<2-LeftMouse>` (the tree's fold toggle) is preserved; the wheel is nopped only
    -- for a fit-to-window modal (hide_cursor), never on a scrollable panel.
    for _, pan in ipairs(state.panels) do
        local prov = pan.provider or {}
        if not prov.editable and vim.bo[pan.buf].buftype ~= "terminal" then
            nop_mouse(pan.buf, used[pan.buf], prov.hide_cursor == true)
        end
    end
    nop_mouse(state.container_buf, used[state.container_buf], true)

    -- `lock_keys`: true/nil = MODAL (default — every unbound key is a no-op on the panels AND the chrome
    -- container) · "light" = a READABLE panel (the message zone's scrollback, a console): the CHROME stays
    -- locked but the CONTENT keeps its keyboard, so the text can be navigated, selected and yanked — the
    -- mouse lock above still stops a drag from starting a Visual selection, which was the actual problem the
    -- modal lock was introduced for · false = no lock at all.
    local light = state.cfg.lock_keys == "light"
    -- EVERY panel owns its own chord prefixes (`g` for a `g?` help), locked or not — a chord must not depend
    -- on how fast the user types. See `own_chord_prefixes`.
    for _, pan in ipairs(state.panels) do
        own_chord_prefixes(pan.buf, used[pan.buf] or {})
    end
    if state.cfg.lock_keys ~= false then
        for _, pan in ipairs(state.panels) do
            local prov = pan.provider or {}
            -- Lock a CONTENT panel only when its cursor is HIDDEN: there the cursor is NOT the interaction — the
            -- provider has bound every real key — so any other press must be inert (the picker's stray H/L, a gg,
            -- a `/`, a `dd`). A VISIBLE-cursor panel navigates / scrolls by the NATIVE cursor (j/k/arrows, C-d/C-u
            -- on a scrollable float or a cursor-driven list) — locking would freeze it — so it keeps its keys (it
            -- may still bind its own maps AFTER open, e.g. lvim-space's `enable_base_maps`).
            if not light and prov.hide_cursor and not prov.editable and vim.bo[pan.buf].buftype ~= "terminal" then
                lock_panel(pan.buf)
                state._locked[pan.buf] = true -- map_hotkeys restores <Nop> (not a bare del) on a stale hotkey here
            end
        end
        -- the container is the chrome buffer (bar-menu mode), never cursor-navigated — h/l move a Sel stripe (re-
        -- bound below), so lock it ALWAYS: a stray `<C-f>`/`<C-d>` on a focused bar scrolled it, pushing the
        -- header (title + bar) off the top and the footer up into its place
        lock_panel(state.container_buf)
        state._locked[state.container_buf] = true
    end

    -- Header button hotkeys work from EVERYWHERE: on every panel (all keys) and the container (all but
    -- the menu nav keys, so `h`/`l` still move the selection while a bar is focused). The (buf, reserved)
    -- targets are RECORDED so `remap_hotkeys` can re-derive the set when the header bands are swapped at
    -- runtime (set_header — a tabbed surface switching tabs carries per-tab filter hotkeys).
    for _, pan in ipairs(state.panels) do
        state._hotkey_targets[#state._hotkey_targets + 1] = { buf = pan.buf, reserved = {} }
    end
    local reserved = {}
    for _, group in ipairs({ K.menu_prev, K.menu_next, K.menu_confirm }) do
        for _, l in ipairs(type(group) == "table" and group or { group }) do
            reserved[#reserved + 1] = l
        end
    end
    state._hotkey_targets[#state._hotkey_targets + 1] = { buf = state.container_buf, reserved = reserved }
    state.remap_hotkeys()
end

--- The CONTENT rect of a laid-out panel `pl` (`L.panels[i]` — `{row,col,width,height,border}`). nvim draws a
--- bordered float's border ON the given row/col, so the content begins at `row+top_inset`, `col+left_inset`
--- (width/height are already the content size). Use it to place anything that must sit INSIDE a panel's border
--- (e.g. the scoped input band over the LIST's first / winbar row) — recompute via this whenever a panel moves,
--- so the position tracks the panel's border insets instead of landing on the border.
---@param pl table
---@return integer row, integer col, integer width, integer height
local function panel_content_rect(pl)
    local t, _, _, l = util.insets(util.resolve_border(pl.border))
    return pl.row + t, pl.col + l, pl.width, pl.height
end

--- Move the center panels + editable input bands to a computed layout `L`, then repaint the chrome. NO
--- container/cmdheight side effects — the caller has already placed the container — so it is safe to call on
--- a host-zone reflow (`reposition`) without re-reserving (which would loop).
---@param state table
---@param L table
local function place_panels(state, L)
    state._geom = L
    for i, pan in ipairs(state.panels) do
        local pl = L.panels[i]
        if pan.win and api.nvim_win_is_valid(pan.win) then
            pcall(api.nvim_win_set_config, pan.win, {
                relative = "editor",
                width = pl.width,
                height = pl.height,
                row = pl.row,
                col = pl.col,
                border = pl.border,
            })
        end
    end
    -- Re-fit the editable input bands so they follow the moved panels / header (else a resize leaves the
    -- prompt stranded). A `scope_panel` band tracks its panel's top row; a plain header band its header row.
    local _, _, _, rcl = util.insets(L.cbord)
    local hbi = 0
    for _, band in ipairs(state.header_bands) do
        -- a `scope_id` band tracks the CURRENT index of the panel with that id (rotation-safe — the input
        -- always sits over the LIST panel however the preview is rotated); else the fixed `scope_panel` index.
        local scope = band.scope_panel
        if band.scope_id then
            for i, pan in ipairs(state.panels) do
                if pan.id == band.scope_id then
                    scope = i
                    break
                end
            end
        end
        if band.input and band.win and api.nvim_win_is_valid(band.win) then
            local iw, icol, irow = L.W, L.col + rcl, L.row + L.ct + hbi
            if scope and L.panels[scope] then
                -- the band overlays the LIST panel's first content row — inside its border, via the shared helper
                local prow, pcol, pwidth = panel_content_rect(L.panels[scope])
                iw, icol, irow = pwidth, pcol, prow
            end
            pcall(api.nvim_win_set_config, band.win, {
                relative = "editor",
                row = irow,
                col = icol,
                width = iw,
                height = 1,
            })
        end
        if not scope then
            hbi = hbi + 1
        end
    end
    render_chrome(state, L)
end

--- Resolve the geometry of a `cmdline`-position surface, growing the command-line region to fit it. Two
--- modes: UNHOSTED grows OUR `cmdheight` (saving the user's once, to restore on close) and floats over those
--- rows. HOSTED (`cfg.host`) instead reserves `L.H` rows in a host zone (the msgarea, which owns cmdheight)
--- and re-lays-out over the rect it hands back — so the host can compose messages BELOW us in the same
--- region. Returns the (possibly re-placed) layout.
---@param state table
---@param L table
---@return table
local function host_geom(state, L)
    -- The container float docks at the screen-bottom cmdline zone and now carries the chassis ring, so its
    -- on-screen footprint is `content + ct + cb`. Reserve those border rows too (`pad`): reserving only the
    -- content left the bottom border past the screen edge → nvim clamped the whole container UP a row while the
    -- editor-relative panels stayed put (the no-result area divider then sat a row above its panels). We grow
    -- only the RESERVED zone, not the content: `compute_geom` is still handed `H = L.H`, so the panels keep
    -- their natural size — only the room the container border needs is added to the zone.
    local pad = (L.ct or 0) + (L.cb or 0)
    if state.cfg.host then
        local rect = state.cfg.host(L.H + pad) -- reserve content + the container border; host grows cmdheight + returns our rect
        if rect then
            -- Fill the reserved rect EXACTLY: hand compute_geom the rect's own height (rect.height when the host
            -- reports it, else the amount we asked for) so the container total = the reserved zone — no blank
            -- rows left below the bottom border, and the content keeps its natural size (rect.height - border).
            local rh = rect.height or (L.H + pad)
            return compute_geom(state, { row = rect.row, col = rect.col, W = rect.width, H = rh })
        end
        return L
    end
    if state.base_cmdheight == nil then
        state.base_cmdheight = vim.o.cmdheight -- save the user's cmdheight once, to restore on close
    end
    -- Grow the cmdline region to the content + the container border; the helper clamps to the room the splits
    -- leave + steps down on a stray E36 (`L.H` is already clamped in compute_geom, so it normally sets as-is).
    set_cmdheight(L.H + pad)
    return L
end

--- (HOSTED) Re-place the surface over a NEW host-zone rect (the msgarea handed us a fresh one because it
--- reflowed — a message appeared / cleared below us). Lays out over the rect WITHOUT re-reserving, so it
--- cannot trigger another reflow (which would loop). No-op unless the surface is open.
---@param state table
---@param rect table?  { win, row, col, width, height }
local function reposition(state, rect)
    if state._closed or not rect or not (state.container_win and api.nvim_win_is_valid(state.container_win)) then
        return
    end
    local L = compute_geom(state, { row = rect.row, col = rect.col, W = rect.width, H = rect.height })
    pcall(api.nvim_win_set_config, state.container_win, {
        relative = "editor",
        width = L.W,
        height = L.H,
        row = L.row,
        col = L.col,
    })
    place_panels(state, L)
end

--- Re-fit the floating panels to the container's CURRENT size and re-render the chrome. Called when the
--- docked split is resized (or the editor on `VimResized`): the header/footer bands keep their fixed
--- heights, so the CENTER absorbs the change, and the panel floats follow instead of staying put.
---@param state table
local function relayout(state)
    if state._closed or not (state.container_win and api.nvim_win_is_valid(state.container_win)) then
        return
    end
    local L
    if state.cfg.mode == "split" then
        -- The split was resized by the user. `compute_geom` floors the center at `min_content_height`
        -- VISIBLE rows and reports the matching minimum container height — if the user shrank below it,
        -- snap the split back up so the center keeps its rows, then re-fit.
        local function geom()
            local pos = api.nvim_win_get_position(state.container_win)
            return compute_geom(state, {
                row = pos[1],
                col = pos[2],
                W = api.nvim_win_get_width(state.container_win),
                H = api.nvim_win_get_height(state.container_win),
            })
        end
        L = geom()
        if api.nvim_win_get_height(state.container_win) < L.min_h then
            pcall(api.nvim_win_set_height, state.container_win, L.min_h)
            L = geom()
        end
    else
        -- A float reflows to the (possibly resized) screen; move the container float too.
        L = compute_geom(state)
        if state.cfg.position == "cmdline" then
            L = host_geom(state, L) -- HOSTED: reserve our rows in the host zone (it owns cmdheight); else grow it
        end
        pcall(api.nvim_win_set_config, state.container_win, {
            relative = "editor",
            width = L.W,
            height = L.H,
            row = L.row,
            col = L.col,
        })
    end
    place_panels(state, L)
    -- place_panels re-rendered only the chrome bands; a width change must ALSO re-flow each content panel
    -- provider (e.g. a toolbar `ui.bar` recomputing its overflow chevrons), so re-render them too.
    for i = 1, #state.panels do
        render_panel(state, i)
    end
end

-- ─── open / close ─────────────────────────────────────────────────────────────

-- forward declarations: `open_panel_win`'s `pan.refresh` and the state methods inside `open_windows` reference
-- these (the dynamic peek / restack helpers); their definitions follow below.
local dyn_geom, dyn_update, dyn_show, dyn_hide, dyn_enable, dyn_disable, restack_panels, apply_preview_side, refocus_list

--- Open (or re-open) ONE center panel's window over its computed rect + apply the window-local chrome. Used
--- both at open and when a panel is re-docked at runtime (the preview returning from a `hide`/`dynamic` state).
--- The scratch buffer persists across hide/show (`bufhidden = "hide"`), so its keymaps survive a close+reopen.
---@param state table
---@param pan table
---@param i integer  its index in `state.panels` (drives render_panel)
---@param pl table   the panel rect from compute_geom (`L.panels[i]`)
---@param has_input boolean
---@param docked boolean
local function open_panel_win(state, pan, i, pl, has_input, docked)
    if not (pan.buf and api.nvim_buf_is_valid(pan.buf)) then
        pan.buf = api.nvim_create_buf(false, true)
        vim.bo[pan.buf].bufhidden = "hide" -- keep the scratch buffer alive while hidden; deleted in close()
        if pan.provider and pan.provider.hide_cursor then
            vim.bo[pan.buf].filetype = FRAME_FT
        end
    end
    -- Open the panel UNFOCUSED, then focus it AFTER the `w:lvim_frame` mark below. Entering it inside
    -- `nvim_open_win` (enter=true) fires WinEnter WHILE the mark is still unset — a foreign WinEnter hook (e.g.
    -- lvim-space's auto-close, which tears down every window it doesn't recognise) would then treat the panel as
    -- a stray and close it mid-open → "Window was closed immediately". Mark first, focus second, so by the time
    -- WinEnter fires those hooks already see it's a managed frame.
    local want_focus = i == 1 and state.cfg.enter ~= false and not has_input
    -- Floor the dimensions at 1: a TIGHT layout (a tall preview in a nearly-full editor / dashboard) can compute
    -- a 0-or-negative panel height/width, which `nvim_open_win` rejects with `E36: Not enough room`. A 1-cell
    -- floor keeps the panel openable (squished, not crashed) in that pathological case; a no-op when it fits.
    pan.win = api.nvim_open_win(pan.buf, false, {
        relative = "editor",
        width = math.max(1, pl.width or 1),
        height = math.max(1, pl.height or 1),
        row = pl.row,
        col = pl.col,
        border = pl.border,
        style = "minimal",
        focusable = not docked,
        zindex = not docked and (state.zindex + 1) or nil,
    })
    -- Mark EVERY panel window (float-mode too, not just docked) as managed UI — same as the container — so a
    -- generic "close all floating windows" / "focus next float" helper skips it instead of tearing the panel
    -- out from under the frame.
    vim.w[pan.win].lvim_frame = true
    if want_focus then
        pcall(api.nvim_set_current_win, pan.win)
    end
    vim.wo[pan.win].wrap = false
    -- A panel is a self-contained UI whose content is sized to fit its window — it must NEVER scroll. Pin
    -- scrolloff/sidescrolloff to 0 so the (often hidden) cursor reaching the last row can't push the top rows
    -- (a picker's preview swatch, its mode/output header) off the top under the user's global `scrolloff`.
    vim.wo[pan.win].scrolloff = 0
    vim.wo[pan.win].sidescrolloff = 0
    -- A provider may name the group its window wears as Normal (`normal_hl`) — the input FIELD does, so the
    -- field itself carries its own wash. The BORDER keeps the frame's group: a block whose blank " " side
    -- border is its gutter must show the POPUP's background there, else the tinted field bleeds to the popup
    -- edge and the gutter disappears.
    local normal = (pan.provider and pan.provider.normal_hl) or "LvimUiPeekNormal"
    local fbord = "LvimUiPeekBorder"
    if pan.provider and pan.provider.cursorline then
        -- The cursorline group: a provider-named one (a string), else the NEUTRAL bg-only `LvimUiCursorLine`
        -- so the focused row is marked by a background wash ALONE — a rich menu's per-segment fg colours
        -- (a commit id, a topic title) survive on the cursor row. The full-row yellow `LvimUiPeekCursorLine`
        -- (which overrides fg) is opt-IN, requested by name only by the simple pickers (`M.select` /
        -- `M.multiselect`), whose rows carry no colours of their own.
        local cl = (type(pan.provider.cursorline) == "string" and pan.provider.cursorline) or "LvimUiCursorLine"
        vim.wo[pan.win].winhighlight = ("Normal:%s,FloatBorder:%s,CursorLine:%s"):format(normal, fbord, cl)
        vim.wo[pan.win].cursorline = true
    else
        -- FloatBorder → LvimUiPeekBorder so a content-panel ring (config.content_border) paints with the same
        -- bg/fg as the container ring, reading as one nested frame instead of the unthemed default FloatBorder.
        vim.wo[pan.win].winhighlight = ("Normal:%s,FloatBorder:%s"):format(normal, fbord)
    end
    pan.refresh = function() -- a provider re-renders its own panel after a state change (toggle, …)
        -- find the panel's CURRENT index by identity — `state.panels` is reordered/shrunk by the preview
        -- rotation / hide / dynamic, so the open-time `i` goes stale (a parked panel drops out entirely).
        for idx, p in ipairs(state.panels) do
            if p == pan then
                render_panel(state, idx)
                return
            end
        end
        -- PARKED preview in `dynamic`: the consumer's selection-change refresh re-renders the peek FLOAT
        -- instead (so it follows the list — its cursor lands on the new entry's location), since the picker
        -- moves a Sel stripe, not the window cursor, so the float's own CursorMoved trigger never fires.
        if pan == state.preview_panel and state.preview_side == "dynamic" then
            dyn_show(state)
        end
    end
    pan.frame = state -- providers reach the frame (focus_panel / close / cfg) through their panel
    render_panel(state, i)
end

--- The effective backdrop veil for this surface, sourced from the CENTRAL `lvim-utils.dock` geometry authority:
--- `dock.slot(layout, { backdrop = cfg.backdrop }).backdrop` resolves the layout default AND applies the
--- consumer's per-open `cfg.backdrop` anchored override (a `{ enabled?, mode, dim, darken }` table merged over
--- the central spec, or `false` to force it OFF — `dock.slot` turns that into `{ enabled = false }`). Returns
--- nil when no veil applies (disabled / off / a transparent editor).
---@param cfg table
---@return { mode: string, amount: number, bg: string }?
local function resolve_backdrop(cfg)
    local bd = require("lvim-utils.dock").slot(backdrop_layout(cfg), { backdrop = cfg.backdrop }).backdrop
    if not bd or bd.enabled == false then
        return nil
    end
    -- Skip on a TRANSPARENT editor: with no solid `Normal` bg there is nothing to darken (and transparency's
    -- point is to show the wallpaper). Detected from the LIVE `Normal` highlight (no bg = transparent) — the
    -- palette's own `transparent` flag lags.
    local nb = vim.api.nvim_get_hl(0, { name = "Normal" })
    if not (nb and nb.bg) then
        return nil
    end
    -- The backdrop mutes the windows BEHIND the surface through a shared highlight namespace (lvim-utils.dim) —
    -- NO covering window, so a terminal graphics image (kitty) composited under the surface stays visible.
    --   • "darken" (default) — foreground + background toward black (a uniform darker look)
    --   • "dim"              — foreground only (lighter)
    -- Each mode carries its OWN `amount` sub-table (`bd.dim.amount` / `bd.darken.amount`); pick the LIVE mode's.
    -- `bg` is the editor bg (the fg-mute target for "dim").
    local mode = bd.mode == "dim" and "dim" or "darken"
    local sub = (mode == "dim" and bd.dim or bd.darken) or {}
    return {
        mode = mode,
        amount = sub.amount or 0.5,
        bg = string.format("#%06x", nb.bg),
    }
end

--- Apply the BACKDROP: dim/darken the windows behind the surface through the SHARED focus-aware applier
--- (`lvim-utils.dim.apply_backdrop` — no covering window, so an image composited under the surface stays
--- visible). No-op when none applies. The applier keys the mute to CURRENT focus at apply time; at THIS point
--- the editor is still current (panels are focused AFTER open_backdrop), so the veil starts lifted and the
--- applier's own WinEnter drops it in when a surface window is focused — matching the old lazy behaviour.
---@param state table
local function open_backdrop(state)
    -- A float auto-stacked ABOVE another frame (a modal opened FROM the browser etc.) must NOT lay its own
    -- backdrop — the opener's own backdrop already covers the editor behind the whole stack.
    if state.skip_backdrop then
        return
    end
    -- A surface backdrop is ALREADY active for another open surface (two coexisting docks: area + bottom, each
    -- with an EXPLICIT zindex — the auto-zindex skip above never covers them). Do NOT install a second: the
    -- existing veil already covers the editor behind both, and letting THIS surface own the tracker would orphan
    -- the first's veil when this one closes. Mirrors the auto-zindex "stacked above a frame ⇒ skip our own".
    if active_surface_bd and active_surface_bd ~= state then
        state.skip_backdrop = true
        return
    end
    local bd = resolve_backdrop(state.cfg)
    if not bd then
        return
    end
    active_surface_bd = state
    -- `protect(win)` = this surface's OWN windows (the container + every panel carry the `lvim_frame` window
    -- marker, or the FRAME_FT filetype for a panel whose buffer a consumer swapped) — never muted. Keyed by the
    -- state's identity so several backdrops could coexist in the shared applier (here one at a time).
    require("lvim-utils.dim").apply_backdrop(tostring(state), {
        enabled = true,
        mode = bd.mode,
        amount = bd.amount,
        bg = bd.bg,
        protect = function(w)
            return api.nvim_win_is_valid(w)
                and (vim.w[w].lvim_frame == true or vim.bo[api.nvim_win_get_buf(w)].filetype == FRAME_FT)
        end,
    })
end

--- Build the container + the N panel windows from a computed layout.
---@param state table
local function open_windows(state)
    register_frame_ft() -- ensure lvim-utils.cursor knows FRAME_FT (current-only) for cursor hiding
    if state.cfg.zindex then
        state.zindex = state.cfg.zindex
    else
        -- Z-ORDER only: stack above whatever frames are live, so a modal is never covered by its opener.
        -- This used to ALSO mean "skip my backdrop" (`zindex > 50`), which conflated two different questions.
        -- Stacking above a frame says nothing about veils: the msgarea ZONE is a frame and is open all session,
        -- so every float opened over it — a picker, a modal — silently dropped its own backdrop and the editor
        -- behind stayed bright. The real rule is the one below in `open_backdrop`: skip only when ANOTHER
        -- surface's backdrop is already covering the editor (`active_surface_bd`), which is the case the "opened
        -- FROM a browser" comment was actually about.
        state.zindex = auto_float_base()
    end
    open_backdrop(state) -- the dim/darken veil BEHIND everything (no-op when this layout's backdrop is off)
    state.container_buf = api.nvim_create_buf(false, true)
    -- The chrome container hides the hardware cursor while a bar sector is focused (it becomes current).
    vim.bo[state.container_buf].filetype = FRAME_FT

    local L
    if state.cfg.mode == "split" then
        -- A docked split: `dock` left/right = a vertical split (fixed width from sizing, full height),
        -- below/above = a horizontal split (fixed height, full width). The chrome lives in this split's
        -- buffer; the panels float over its center rows at its ACTUAL screen position / size.
        local g0 = compute_geom(state)
        local dock = state.cfg.dock or "right"
        local horiz = dock == "below" or dock == "above"
        state.container_win = api.nvim_open_win(state.container_buf, false, {
            split = dock,
            win = -1,
            width = (not horiz) and g0.W or nil,
            height = horiz and g0.H or nil,
            style = "minimal",
            -- Focusable so native window nav can ENTER the docked peek: the panels are floats off the
            -- layout, but this chrome split IS in the layout, so `<C-w>j`/`<C-w>k` from the surrounding
            -- editor land here — a WinEnter hook then bounces focus into the content panel. (Horizontal
            -- `<C-w>l`/`<C-w>h` between the editor splits is unaffected: the split is below them, not beside.)
            focusable = true,
        })
        local pos = api.nvim_win_get_position(state.container_win)
        L = compute_geom(state, {
            row = pos[1],
            col = pos[2],
            W = api.nvim_win_get_width(state.container_win),
            H = api.nvim_win_get_height(state.container_win),
        })
        if horiz then
            vim.wo[state.container_win].winfixheight = true
        else
            vim.wo[state.container_win].winfixwidth = true
        end
    else
        L = compute_geom(state)
        -- A `cmdline` surface OWNS the command-line region: UNHOSTED grows `cmdheight` to its height so the
        -- editor (and heirline / a global statusline) reflow ABOVE it, then floats over those rows; HOSTED
        -- reserves its rows in the host zone (which owns the cmdheight) so messages compose below it.
        if state.cfg.position == "cmdline" then
            L = host_geom(state, L)
        end
        -- The brand is the window's TOP-border title (needs a top border, ct > 0), built by `build_brand`
        -- from the `title` box: TITLE left, COUNTER right (`counter="title"`) on the same top-border line —
        -- UNLESS an area dock routes the title to the chrome overlay (`title_line="statusline"`), where
        -- build_brand returns nil and `publish_overlay_title` posts it instead. `title_pos` is LEFT (so the
        -- counter's fill reaches the right edge); it must only be set WITH a title — nvim errors otherwise.
        -- (`counter="footer"` instead rides the BOTTOM border, needs cb > 0, as a right-aligned footer.)
        local brand = L.ct > 0 and build_brand(state, L.W) or nil
        local bfooter = (L.cb or 0) > 0 and build_border_footer(state) or nil
        state.container_win = api.nvim_open_win(state.container_buf, false, {
            relative = "editor",
            width = L.W,
            height = L.H,
            row = L.row,
            col = L.col,
            border = L.cbord,
            style = "minimal",
            focusable = false,
            zindex = state.zindex,
            title = brand,
            title_pos = brand and (state.cfg.title_pos or "left") or nil,
            footer = bfooter,
            footer_pos = bfooter and "right" or nil,
        })
        publish_overlay_title(state)
    end
    state._geom = L
    local docked = state.cfg.mode == "split"
    -- The CONTAINER holds only chrome and is never directly interacted with — always mark it so generic
    -- float helpers ("close all floats" / "focus next float") skip it and land on the content panel.
    vim.w[state.container_win].lvim_frame = true
    vim.wo[state.container_win].winhighlight = "Normal:LvimUiPeekNormal,FloatBorder:LvimUiPeekBorder"

    render_chrome(state, L)

    -- An editable input band (see below) takes the initial focus instead of a panel.
    local has_input = false
    for _, band in ipairs(state.header_bands) do
        if band.input then
            has_input = true
            break
        end
    end

    for i, pan in ipairs(state.panels) do
        open_panel_win(state, pan, i, L.panels[i], has_input, docked)
    end

    -- Live "item N of M" counter: when the consumer opts into `count_follows_cursor`, the FIRST content panel's
    -- cursor row drives the counter's `current` (read in resolve_count via `cfg._cursor_row`). Seed it now and
    -- refresh it on every CursorMoved (set_counter re-renders the title/border/overlay counter). A per-buffer
    -- augroup clears on re-open so the panel's reused scratch buffer never stacks duplicate autocmds.
    if state.cfg.count_follows_cursor and state.panels[1] and state.panels[1].buf then
        local pbuf, pwin = state.panels[1].buf, state.panels[1].win
        state.cfg._cursor_row = (pwin and api.nvim_win_is_valid(pwin)) and api.nvim_win_get_cursor(pwin)[1] or 1
        local grp = api.nvim_create_augroup("LvimSurfaceCounter_" .. pbuf, { clear = true })
        api.nvim_create_autocmd("CursorMoved", {
            group = grp,
            buffer = pbuf,
            callback = function()
                if not (pwin and api.nvim_win_is_valid(pwin)) then
                    return
                end
                state.cfg._cursor_row = api.nvim_win_get_cursor(pwin)[1]
                if state.set_counter then
                    state.set_counter(state.cfg.count)
                end
            end,
        })
    end

    -- Editable INPUT bands: a focusable 1-row editable window over each input band's header row. The frame
    -- creates it + wires a live on_change; the consumer drives the panels from on_change + the band's keys
    -- (insert-mode), like a fuzzy-finder prompt. Not part of the normal-mode sector nav — it is always
    -- focused (insert) while open, so there is no mode clash with the chassis keymaps.
    do
        local _, _, _, cl = util.insets(L.cbord)
        for bi, band in ipairs(state.header_bands) do
            if band.input then
                band.buf = api.nvim_create_buf(false, true)
                vim.bo[band.buf].bufhidden = "hide"
                vim.bo[band.buf].modifiable = true -- it is a typed field
                if band.filetype then
                    vim.bo[band.buf].filetype = band.filetype
                end
                -- `scope_panel` narrows the input to a single panel and overlays that panel's TOP (winbar)
                -- row — a finder whose prompt sits over its LIST, level with the other panels' titles, not on
                -- a separate full-width header row. Otherwise it spans the full container width on its header
                -- row.
                local iw, icol, irow = L.W, L.col + cl, L.row + L.ct + (bi - 1)
                if band.scope_panel and L.panels[band.scope_panel] then
                    -- inside the LIST panel's border (shared helper), not on the border row
                    local prow, pcol, pwidth = panel_content_rect(L.panels[band.scope_panel])
                    iw, icol, irow = pwidth, pcol, prow
                end
                band.win = api.nvim_open_win(band.buf, false, {
                    relative = "editor",
                    row = irow,
                    col = icol,
                    width = iw,
                    height = 1,
                    style = "minimal",
                    focusable = true,
                    zindex = state.zindex + 2, -- above the container (z) and the panels (z+1)
                })
                -- This window belongs to the FRAME: mark it like the container and the panels. The backdrop
                -- applier reads this mark to know which windows are the surface's own — it must not mute them,
                -- and it drops the veil in when one of them is focused. Unmarked, a picker (which opens ON its
                -- prompt) looked to the applier like the editor still had focus: the veil never came down, so a
                -- float picker showed NO backdrop at all.
                vim.w[band.win].lvim_frame = true
                -- The typed area uses `input_hl` (the row's Normal bg); the prompt badge uses `prompt_hl`.
                vim.wo[band.win].winhighlight = "Normal:" .. (band.input_hl or "LvimUiPeekNormal")
                -- No wrap/continuation chrome on the 1-row prompt (a long query scrolls horizontally; a
                -- 'showbreak' / wrap continuation marker must never leak into the field).
                vim.wo[band.win].wrap = false
                vim.wo[band.win].list = false
                vim.wo[band.win].showbreak = ""
                if band.prompt and band.prompt ~= "" then
                    -- `prompt` is a STRING (one badge chunk) or a LIST of `{ text, hl }` chunks (e.g. a badge
                    -- + a gap on a different tint).
                    local vt = type(band.prompt) == "table" and band.prompt
                        or { { band.prompt, band.prompt_hl or "LvimUiMsgAreaItemKind" } }
                    pcall(api.nvim_buf_set_extmark, band.buf, NS, 0, 0, {
                        virt_text = vt,
                        virt_text_pos = "inline",
                        right_gravity = false,
                    })
                end
                if band.on_change then
                    api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
                        buffer = band.buf,
                        callback = function()
                            band.on_change(api.nvim_buf_get_lines(band.buf, 0, 1, false)[1] or "")
                        end,
                    })
                end
                if band.keys then
                    pcall(band.keys, band.buf, state)
                end
            end
        end
        -- Enter the FIRST input band on open (insert), unless the consumer opted out of focusing.
        if state.cfg.enter ~= false then
            for _, band in ipairs(state.header_bands) do
                if band.input and band.win and api.nvim_win_is_valid(band.win) then
                    api.nvim_set_current_win(band.win)
                    vim.cmd("startinsert!")
                    break
                end
            end
        end
    end

    -- Wire interaction: the sector list, the keymaps, and the initial focus (the first center panel).
    state.refresh_chrome = function() -- re-render the header/footer bands (e.g. after a tab switch)
        render_chrome(state, state._geom)
    end
    -- Re-fit the frame to its providers' CURRENT content size (auto width/height) and re-centre — for an
    -- auto-sized frame whose content changed at runtime (e.g. a tab switch swapping the form's row count).
    state.relayout = function()
        relayout(state)
    end
    state.preview_side = state.cfg.preview_side -- the live preview position (rotate_preview cycles it)
    -- Capture the persistent list + preview panel refs, so the preview can be DROPPED (hide / dynamic) and
    -- RE-DOCKED at runtime without losing them (the scratch buffers outlive their windows).
    for _, pan in ipairs(state.panels) do
        if pan.id == "preview" then
            state.preview_panel = pan
        else
            state.list_panel = state.list_panel or pan
        end
    end
    apply_dock_height(state, state.preview_side) -- the configured docked height for the INITIAL stack direction
    --- Rotate the preview through its THREE positions (right → left → dynamic → …), LIVE. The two docked sides
    --- reflow the floats in place; `dynamic` drops the docked preview to a full-width list + a transient peek
    --- float ABOVE it (`apply_preview_side` handles both). No-op without a "preview" panel.
    ---
    --- Vertical DOCKED stacking (above/below) is deliberately NOT in the rotation: the two panels then split the
    --- dock's rows, so a preview worth reading leaves the list a few rows — and with the dock anchored to the
    --- screen bottom, re-fitting it to each file moved the list up and down while you merely scrolled. The float
    --- ("dynamic") is the answer for a tall preview: the list keeps the dock, the file gets the screen.
    ---@param dir integer  +1 next position, -1 previous
    state.rotate_preview = function(dir)
        if not state.preview_panel then
            return
        end
        -- `dynamic` (the peek FLOAT above the list) is a DOCKED-surface position only: it lives in the editor's
        -- space above the dock. A centred FLOAT has no such space — it sits in the middle of the screen, so the
        -- peek would be squeezed against its top edge (and, holding the file's real buffer, would take the file's
        -- own autocmds down with it: `E36: Not enough room`). A float rotates between the two docked sides.
        local docked = state.cfg.host ~= nil or state.cfg.position ~= nil or state.cfg.mode == "split"
        local order = docked and { "right", "left", "dynamic" } or { "right", "left" }
        local ci = 1
        for i, s in ipairs(order) do
            if s == (state.preview_side or "right") then
                ci = i
            end
        end
        state.preview_side = order[((ci - 1 + dir) % #order) + 1]
        state.preview_hidden = false -- rotating always un-hides
        apply_preview_side(state)
        refocus_list(state)
    end
    --- SCROLL the preview WITHOUT focusing it — the fzf-lua / Magit model, and the ONLY way to read past a
    --- preview's first screen from the list. A preview panel is `hide_cursor`: it has no cursor to scroll
    --- with, and `lock_panel` nops the native `<C-d>`/`<C-u>` on the list by design (a stray scroll must not
    --- drift a fitted panel) — so without this the content below the fold was simply unreachable unless you
    --- spent a `panel_toggle` (Tab) to move the focus there and another to come back.
    --- Scrolls whichever window HOLDS the preview right now: the docked panel, or the `dynamic` peek float.
    --- No-op while the preview is hidden, or when the surface has none.
    ---@param dir integer  +1 half a screen down, -1 half a screen up
    state.scroll_preview = function(dir)
        local win
        if state.preview_side == "dynamic" then
            win = state.dyn and state.dyn.win
        elseif not state.preview_hidden and state.preview_panel then
            win = state.preview_panel.win
        end
        if not (win and api.nvim_win_is_valid(win)) then
            return
        end
        -- `nvim_win_call` + the REAL `<C-d>`/`<C-u>`, rather than a hand-computed `winrestview` topline: the
        -- native keys already clamp at both buffer ends and honour that window's own height / `scroll`, and
        -- `win_call` fires no Win/BufEnter — so the cursor module never sees a focus change and the list keeps
        -- the hardware cursor. Redraw explicitly: nothing else marks a non-current, non-focusable float dirty.
        api.nvim_win_call(win, function()
            vim.cmd("normal! " .. (dir > 0 and CTRL_D or CTRL_U))
        end)
        api.nvim__redraw({ win = win, flush = true })
    end
    --- Toggle the preview HIDDEN ↔ shown (the `hide` position). A no-op while `dynamic` (its peek owns the
    --- preview); only the docked sides hide. The last docked side returns on un-hide.
    state.toggle_preview = function()
        if not state.preview_panel or state.preview_side == "dynamic" then
            return
        end
        state.preview_hidden = not state.preview_hidden
        apply_preview_side(state)
        refocus_list(state)
    end
    -- Opened directly into a non-docked preview state (open_windows built BOTH panels): drop the docked preview
    -- now. `hide` as an initial side = start hidden on the default side.
    if state.preview_panel and (state.preview_side == "dynamic" or state.preview_side == "hide") then
        if state.preview_side == "hide" then
            state.preview_side = "right"
            state.preview_hidden = true
        end
        apply_preview_side(state)
    end
    --- Swap the HEADER bands at runtime — a tabbed surface changing a tab's toolbar bars (each becomes its own
    --- C-j/C-k sector). Regular bar bands are container LINES (not windows), so this just re-derives the band +
    --- sector lists and relayouts (recomputes the header height, repositions the content, re-renders). When a
    --- BAR sector is focused, it is re-established on the rebuilt band (its `_sel` lands on the active button,
    --- so a just-applied filter reads as hover_active); a center focus needs nothing (the center persists).
    ---@param spec table  the new `header` spec ({ bars = { … } })
    state.set_header = function(spec)
        local on_bar = state.focus and state.focus.kind == "bar"
        -- What the user had SELECTED before the rebuild — its identity, not its index: a rebuilt band may hold
        -- a different button count (a nav label widens, a filter appears). Restoring the ACTIVE button instead
        -- (the old behaviour) throws the cursor back to button 1 on every repaint, so pressing `›` (next month)
        -- moved the month and then bounced the selection onto `‹` — the bar became unusable by keyboard.
        local prev_id, prev_idx
        if on_bar and state.focus.band then
            prev_idx = state.focus.band._sel
            local b = (state.focus.band.buttons or {})[prev_idx or 0]
            if b then
                prev_id = b.name or b.key or (type(b.text) == "string" and b.text) or nil
            end
        end
        -- Re-prepend the row title (a `title_line="row"` float): build_bands rebuilds from `spec` ONLY, so the
        -- title (inserted at open, outside `spec`) would vanish on the first tab switch. Mirror open's air:
        -- the row title supplies its own air row, so suppress build_bands' header air when it's present.
        local tb = row_title_bands(state.cfg)
        local header_air = state.cfg.header_air
        if tb then
            header_air = false
        end
        state.header_bands = build_bands(spec, false, header_air)
        if tb then
            for i = #tb, 1, -1 do
                table.insert(state.header_bands, 1, tb[i])
            end
        end
        trim_air(state.header_bands, state.cfg._ring_top == true, false)
        state.sectors = build_sectors(state)
        if on_bar then
            local fi = math.max(1, math.min(state.focus_idx or 1, #state.sectors))
            local sec = state.sectors[fi]
            if sec and sec.kind == "bar" then
                local btns = sec.band.buttons or {}
                -- 1) the SAME button the user was on (matched by identity), 2) failing that its old index
                -- (clamped), 3) failing that the active one, 4) else the first.
                local as
                if prev_id then
                    for bi, b in ipairs(btns) do
                        local id = b.name or b.key or (type(b.text) == "string" and b.text) or nil
                        if id and id == prev_id then
                            as = bi
                            break
                        end
                    end
                end
                if not as and prev_idx and btns[prev_idx] then
                    as = prev_idx
                end
                if not as then
                    as = 1
                    for bi, b in ipairs(btns) do
                        if b.active then
                            as = bi
                        end
                    end
                end
                sec.band._sel = as
                state.focus_idx = fi
                state.focus = { kind = "bar", band = sec.band, where = sec.where }
            end
        end
        -- The swapped bands carry their own button hotkeys (per-tab filter keys) — re-derive the mapped
        -- set on every panel + the container, so a stale key can't fire a dropped band's action.
        state.remap_hotkeys()
        relayout(state)
    end
    --- Live-repaint the INPUT prompt badge + the typed-area tint WITHOUT rebuilding the input band — the buffer,
    --- its query text, cursor and `on_change` wiring are all untouched; only the badge extmark and the window
    --- highlight are re-drawn. For a mode indicator on the search bar (e.g. the picker's grep⇄filter toggle).
    ---@param prompt string|table       the new badge (a string, or a list of `{ text, hl }` chunks)
    ---@param prompt_hl? string         badge highlight (when `prompt` is a bare string)
    ---@param input_hl? string          the typed area's Normal background
    state.set_prompt = function(prompt, prompt_hl, input_hl)
        for _, band in ipairs(state.header_bands or {}) do
            if band.input and band.buf and api.nvim_buf_is_valid(band.buf) then
                band.prompt = prompt
                band.prompt_hl = prompt_hl or band.prompt_hl
                band.input_hl = input_hl or band.input_hl
                api.nvim_buf_clear_namespace(band.buf, NS, 0, 1) -- the input line's only NS mark is the badge
                if prompt and prompt ~= "" then
                    local vt = type(prompt) == "table" and prompt
                        or { { prompt, band.prompt_hl or "LvimUiMsgAreaItemKind" } }
                    pcall(api.nvim_buf_set_extmark, band.buf, NS, 0, 0, {
                        virt_text = vt,
                        virt_text_pos = "inline",
                        right_gravity = false,
                    })
                end
                if band.win and api.nvim_win_is_valid(band.win) then
                    vim.wo[band.win].winhighlight = "Normal:" .. (band.input_hl or "LvimUiPeekNormal")
                end
            end
        end
    end
    --- Rebuild the FOOTER band(s) in place — for a live key-hint legend that tracks the focused row. The legend
    --- is a constant-height bar, so it just re-paints the chrome (render_chrome re-derives the footer line from
    --- the new bands and writes the CONTAINER buffer); the body float is untouched.
    ---@param spec table
    state.set_footer = function(spec)
        state.cfg.footer = spec
        local before = #state.footer_bands
        state.footer_bands = build_bands(spec, true, state.cfg.footer_air)
        trim_air(state.footer_bands, state.cfg._ring_bottom == true, true)
        state.sectors = build_sectors(state)
        -- the swapped footer carries its own button hotkeys (per-tab clear actions) — re-derive the mapped
        -- set so a stale key can't fire a dropped band's action, same as set_header
        state.remap_hotkeys()
        -- A footer with a DIFFERENT number of rows changes the frame's height: repainting alone would draw the
        -- new band onto a row the container does not have (it is clipped, and the bar simply never appears).
        -- Re-fit instead — the same path an auto-sized frame takes when its content grows.
        if before ~= #state.footer_bands then
            relayout(state)
        elseif state._geom then
            render_chrome(state, state._geom)
        end
    end
    --- Update the surface TITLE in place — re-applies the border-title brand (via `build_brand`, so the
    --- counter / `title_line="statusline"` routing is respected) to the live container window, re-publishes
    --- the chrome overlay where applicable, and re-paints the chrome — so a consumer can retitle without a
    --- teardown + reopen. Accepts the same `title` shape as `surface.open` (string | { text, icon }).
    ---@param title any
    state.set_title = function(title)
        state.cfg.title = title
        if
            state.container_win
            and api.nvim_win_is_valid(state.container_win)
            and state._geom
            and state._geom.ct > 0
        then
            local brand = build_brand(state, state._geom.W)
            pcall(api.nvim_win_set_config, state.container_win, {
                title = brand,
                title_pos = brand and (state.cfg.title_pos or "left") or nil,
            })
        end
        -- `title_line = "row"`: the title lives in a title_counter HEADER BAND whose text was
        -- derived at build time — re-derive it here so a live retitle (a breadcrumb following
        -- navigation) shows without a full header rebuild.
        for _, band in ipairs(state.header_bands or {}) do
            if band.title_counter then
                local t = state.cfg.title
                band.text = type(t) == "table" and ((t.icon and t.icon .. " " or "") .. tostring(t.text or ""))
                    or tostring(t or "")
                break
            end
        end
        publish_overlay_title(state)
        if state._geom then
            render_chrome(state, state._geom)
        end
    end
    --- Update the COUNT (the title / footer counter) in place — re-applies it to the live container window
    --- per the active `counter` placement: a chunk in the border-title (`counter="title"`), the right-aligned
    --- native border-FOOTER (`counter="footer"`), and/or the chrome overlay (area dock + `title_line=
    --- "statusline"`). The navigable ACTION footer bar is separate (`set_footer`) and untouched here. `count`
    --- is the same shape as `cfg.count` (integer | { current, total } | fun()).
    ---@param count any
    state.set_counter = function(count)
        state.cfg.count = count
        if state.container_win and api.nvim_win_is_valid(state.container_win) and state._geom then
            if state._geom.ct > 0 then
                local brand = build_brand(state, state._geom.W)
                pcall(api.nvim_win_set_config, state.container_win, {
                    title = brand,
                    title_pos = brand and (state.cfg.title_pos or "left") or nil,
                })
            end
            if (state._geom.cb or 0) > 0 then
                local bfooter = build_border_footer(state)
                pcall(api.nvim_win_set_config, state.container_win, {
                    footer = bfooter,
                    footer_pos = bfooter and "right" or nil,
                })
            end
        end
        -- title_line="row": the count lives in the title_counter CONTENT row, so re-render the chrome to refresh
        -- it (the band re-evaluates its `count` closure, which reads the live state).
        if state.cfg.title_line == "row" and state._geom then
            render_chrome(state, state._geom)
        end
        publish_overlay_title(state)
    end
    -- (HOSTED) Re-place over a fresh host-zone rect WITHOUT re-reserving (the host called us because it
    -- reflowed). Wired by the caller as the host segment's `on_rect`, so the surface follows the zone.
    state.reposition = function(rect)
        reposition(state, rect)
    end
    state.sectors = build_sectors(state)
    state.center_panel = 1
    local function center_idx()
        for si, sec in ipairs(state.sectors) do
            if sec.kind == "center" then
                return si
            end
        end
    end
    --- Focus center panel `i` (used by a panel hosting an external buffer — the preview — and the
    --- "preview" footer action) through the proper sector model.
    ---@param i integer
    state.focus_panel = function(i)
        state.center_panel = math.max(1, math.min(i, #state.panels))
        local ci = center_idx()
        if ci then
            focus_sector(state, ci)
        end
    end
    --- Focus a SECTOR by index (1 = the first header bar / the filter bar, … the center, … the footer). Lets a
    --- consumer land focus on the TOP bar on a descend from above, instead of skipping into the center.
    ---@param i integer
    state.focus_sector = function(i)
        focus_sector(state, i)
    end
    --- Focus a center BLOCK by its `id` (`content.blocks[i].id`) — order-independent (no numeric index).
    ---@param id any
    state.focus_block = function(id)
        for i, pan in ipairs(state.panels) do
            if pan.id == id then
                state.focus_panel(i)
                return
            end
        end
    end
    --- Move LEFT/RIGHT between the center panels (`dir` = +1 / -1). Only meaningful inside the center.
    --- Reads the REAL focused window (not just the tracked `center_panel`), so it works even when the
    --- preview was focused without going through `focus_panel` (e.g. its own buffer keymaps).
    ---
    --- When the panels are stacked VERTICALLY, left/right never means "another panel" (that is `<C-j>`/
    --- `<C-k>` between the stacked sectors) — so `<C-h>`/`<C-l>` step OUT to the neighbouring editor window
    --- instead, letting a side-docked vertical stack (e.g. lvim-replace) escape to the code beside it. A
    --- docked split with no neighbour on that side is a no-op; a horizontal layout keeps the panel-to-panel
    --- move unchanged.
    ---@param dir integer  +1 (right) / -1 (left)
    state.panel = function(dir)
        if state.cfg.direction == "vertical" then
            -- Remember the sector we are leaving from, so native nav BACK into the container (the WinEnter
            -- hook) returns focus to THIS sector instead of resetting to the first — a side-docked stack
            -- reopens on the row you left.
            state._return_sector = current_sector(state)
            escape_to_neighbor(state, dir < 0 and "h" or "l")
            return
        end
        local w = api.nvim_get_current_win()
        local base = state.center_panel or 1
        for i, pan in ipairs(state.panels) do
            if pan.win == w then
                base = i
                break
            end
        end
        local i = math.max(1, math.min(base + dir, #state.panels))
        if i ~= base then
            focus_panel_win(state, i)
        end
    end
    --- Cycle the focused sector header · center · footer (exposed so an external-buffer panel can drive
    --- the same navigation from its own keymaps).
    ---@param dir integer  +1 (down) / -1 (up)
    state.sector = function(dir)
        sector_cycle(state, dir)
    end
    --- Toggle the focused CENTER panel (list ⇄ preview) — the `panel_toggle` (Tab) action, exposed for the
    --- same reason `panel`/`sector` are: a panel showing an EXTERNAL buffer (a terminal — lvim-tasks' live
    --- output, lvim-term) carries none of the chassis' own keymaps, so it must be able to bind the toggle
    --- itself. `panel(dir)` is NOT a substitute: it CLAMPS at the ends, so from the last panel (the preview)
    --- `panel(1)` is a no-op — the key that walked IN would not walk back OUT, stranding the user there.
    state.panel_toggle = function()
        panel_toggle(state)
    end
    --- Focus the frame's FIRST sector (its header — e.g. a tab bar) — the landing point when DESCENDING
    --- into the frame from an OUTSIDE editor window (the dock's global descend). A further `<C-j>` then
    --- steps down into the content, the mirror of the `<C-k>` escape-UP from the top sector.
    state.enter = function()
        focus_sector(state, 1)
    end
    --- How many SECTORS the frame has (the zone below asks, so it can enter the dock at its LAST one — its
    --- footer — when the user walks UP out of the messages; the mirror of `enter`).
    ---@return integer
    state.sector_count = function()
        return #state.sectors
    end
    --- Focus the window the frame was opened from (the editor), keeping the frame open. The WinEnter
    --- hook restores the cursor there.
    state.to_origin = function()
        if state.origin and api.nvim_win_is_valid(state.origin) then
            api.nvim_set_current_win(state.origin)
        end
    end
    --- Map every BAR button's hotkey (header AND footer) on `buf` (firing its `run`), so filter keys and
    --- footer actions (e.g. the per-server form's `a`/`A`/`b`) work from anywhere — not only by navigating
    --- to the bar. `reserved` lists extra keys to SKIP (the container's menu nav, so `h`/`l` still move the
    --- selection there); `<CR>`/`<Space>` are ALWAYS skipped — a content provider owns them (e.g. the list
    --- `<CR>` jump). Called on each panel buffer, the container, and the preview's file buffer.
    --- Re-runnable: the bands are SWAPPED at runtime (set_header — per-tab filter hotkeys), so the keys this
    --- buffer got LAST time are re-derived first — a stale key goes back to the `<Nop>` a locked panel had
    --- under it (or is deleted on an unlocked buffer), then the live set maps over.
    state.map_hotkeys = function(buf, reserved)
        if not (buf and api.nvim_buf_is_valid(buf)) then
            return
        end
        local skip = { ["<CR>"] = true, ["<Space>"] = true }
        for _, r in ipairs(reserved or {}) do
            skip[r] = true
        end
        local live = {}
        for _, sec in ipairs(state.sectors) do
            if sec.kind == "bar" then
                for _, spec in ipairs(sec.band.buttons or {}) do
                    -- `no_hotkey` marks a DISPLAY button (e.g. a key-hint LEGEND like "j/k", "h/l") — it is shown
                    -- and mouse-clickable, but its `key` is a label, NOT a real keymap: registering a multi-char
                    -- label ("j/k") would make its first char ("j") a mapping PREFIX → nvim waits `timeoutlen` on
                    -- every "j" press. The real keys are already mapped by the content/frame.
                    if
                        spec.key
                        and spec.run
                        and spec.type ~= "separator"
                        and not spec.no_hotkey
                        and not skip[spec.key]
                    then
                        live[spec.key] = true
                        vim.keymap.set("n", spec.key, function()
                            spec.run(state)
                        end, { buffer = buf, nowait = true, silent = true })
                    end
                end
            end
        end
        for key in pairs(state._hotkey_mapped[buf] or {}) do
            if not live[key] then
                if state._locked[buf] then
                    pcall(vim.keymap.set, "n", key, "<Nop>", { buffer = buf, nowait = true, silent = true })
                else
                    pcall(vim.keymap.del, "n", key, { buffer = buf })
                end
            end
        end
        state._hotkey_mapped[buf] = live
    end
    --- Re-derive the bar hotkeys on every recorded target (each panel + the container) from the LIVE
    --- sectors — called at open and by `set_header`, so per-tab filter keys stay correct across tab switches.
    state.remap_hotkeys = function()
        for _, t in ipairs(state._hotkey_targets) do
            state.map_hotkeys(t.buf, t.reserved)
        end
    end
    --- Toggle the first header bar sector (the "menu" shortcut): focus it, or return to the center if it
    --- is already focused. Returns true when it lands ON the header bar.
    state.toggle_header = function()
        for si, sec in ipairs(state.sectors) do
            if sec.kind == "bar" and sec.where == "header" then
                if state.focus and state.focus.kind == "bar" and state.focus_idx == si then
                    local ci = center_idx()
                    if ci then
                        focus_sector(state, ci)
                    end
                    return false
                end
                focus_sector(state, si)
                return true
            end
        end
        return false
    end
    set_keys(state)
    -- A non-focusing float (`enter == false`) leaves the cursor in the editor — record the center panel but
    -- do NOT focus it; the consumer focuses later (e.g. a hover entered on the 2nd keypress).
    if state.cfg.enter == false then
        state.center_panel = center_idx() or 1
    elseif has_input then
        state.center_panel = center_idx() or 1 -- the input band (focused above, in insert) owns the keyboard
    else
        focus_sector(state, center_idx() or 1)
    end

    -- Closing any frame window externally (`:q`, a programmatic close) tears the whole frame down once.
    state.augroup = api.nvim_create_augroup("LvimUiFrame_" .. tostring(state.container_win), { clear = true })
    local watch = { state.container_win }
    for _, pan in ipairs(state.panels) do
        watch[#watch + 1] = pan.win
    end
    for _, band in ipairs(state.header_bands) do
        if band.input and band.win then
            watch[#watch + 1] = band.win
        end
    end
    api.nvim_create_autocmd("WinClosed", {
        group = state.augroup,
        callback = function(ev)
            local w = tonumber(ev.match)
            for _, ww in ipairs(watch) do
                if ww == w then
                    state.close()
                    return
                end
            end
        end,
    })
    -- Re-fit on resize. Only relayout when the CONTAINER itself was resized (the user dragging the split):
    -- relayout then resizes the floats, whose own WinResized events DON'T include the container, so there
    -- is no feedback loop. VimResized (terminal size change) always reflows.
    api.nvim_create_autocmd("WinResized", {
        group = state.augroup,
        callback = function()
            -- A `cmdline` surface grows `cmdheight` itself, which RESIZES the container float and so fires
            -- WinResized on it — but it already re-fits via its own content refresh (refresh_surface →
            -- relayout), so this WinResized relayout is redundant; skip it.
            if state._closed or state.cfg.position == "cmdline" then
                return
            end
            for _, w in ipairs(vim.v.event.windows or {}) do
                if w == state.container_win then
                    relayout(state)
                    return
                end
            end
        end,
    })
    api.nvim_create_autocmd("VimResized", {
        group = state.augroup,
        callback = function()
            if not state._closed then
                relayout(state)
            end
        end,
    })
    -- Drop / restore the focused-bar selection highlight as focus leaves / re-enters the frame, so a
    -- header button never looks hovered while the user is back in a normal buffer.
    local function set_blur(b)
        if state._blurred ~= b then
            state._blurred = b
            render_chrome(state, state._geom)
        end
    end
    -- Resolved ONCE at open: a modal float traps focus (the WinEnter bounce below). `state._trap_return` tracks
    -- the last frame window focused, so a bounce lands the user back where they were, not on an arbitrary sector.
    local trap = traps_focus(state)
    -- Cursor hygiene: the frame hides the hardware cursor while a list panel is focused, so when focus
    -- moves OUT of the frame (e.g. `<C-w>w` to the editor above a docked split) the cursor must come
    -- back, and re-hide on return. A list-style panel hides it; any other window shows it; the bar-menu
    -- container manages its own.
    api.nvim_create_autocmd("WinEnter", {
        group = state.augroup,
        callback = function()
            if state._closed then
                return
            end
            local w = api.nvim_get_current_win()
            if w == state.container_win then
                set_blur(false)
                state._trap_return = w
                -- Native window nav landed on the chrome split (e.g. `<C-w>j` from the editor above) — the
                -- user means "step into the panel". Land on the FIRST sector (the top header bar) so entry
                -- is step-by-step (header → center → footer via `<C-j>`), not a jump straight to the center.
                -- EXCEPT when focus is RETURNING from the host zone below (`_return_sector` set by sector_cycle):
                -- land back on the footer it descended from, so up/down nav is symmetric. A frame-driven bar
                -- focus sets `_focusing_bar`, so it stays on the chrome as intended.
                if not state._focusing_bar then
                    vim.schedule(function()
                        if not state._closed and api.nvim_get_current_win() == state.container_win then
                            focus_sector(state, state._return_sector or 1)
                            state._return_sector = nil
                        end
                    end)
                end
                return
            end
            for _, pan in ipairs(state.panels) do
                if pan.win == w then
                    set_blur(false)
                    state._trap_return = w
                    cursor.update() -- panel ft decides (hide-cursor list vs editable preview)
                    return
                end
            end
            -- Focus left the frame's container/panels. A FLOAT target (a child dialog this modal spawned, an
            -- input-band overlay, a sub-popup) is legitimate and allowed. A REAL window (the editor / a split)
            -- means the user tried to LEAVE — and a trapping modal forbids that: bounce focus straight back so
            -- the popup cannot be escaped by a `<C-w>` jump OR a mouse click on another field. Scheduled (never
            -- synchronous inside WinEnter) and guarded by `_trapping` so it can't recurse.
            -- ONLY within the frame's OWN tabpage. A trap means "you cannot leave this popup for the editor
            -- BEHIND it" — and that editor lives in the frame's tabpage. Another tabpage is a different screen
            -- on which the popup is not even drawn, so bouncing focus out of it traps nothing and merely fights
            -- whoever opened it: an action that opens a view in a new tab (lvim-git's `View diff`, which the
            -- status popup launches) landed there and was yanked straight back, so the diff appeared to never
            -- open — it was open all along, one tabpage away, with the popup stealing the focus back three
            -- times in a row.
            local same_tab = api.nvim_win_get_tabpage(w) == state.tabpage
            if trap and same_tab and not state._trapping then
                local ok_cfg, wc = pcall(api.nvim_win_get_config, w)
                if ok_cfg and wc.relative == "" then
                    local back = (state._trap_return and api.nvim_win_is_valid(state._trap_return))
                            and state._trap_return
                        or (api.nvim_win_is_valid(state.container_win) and state.container_win)
                        or nil
                    if back then
                        state._trapping = true
                        vim.schedule(function()
                            state._trapping = false
                            if not state._closed and api.nvim_win_is_valid(back) then
                                pcall(api.nvim_set_current_win, back)
                            end
                        end)
                        return
                    end
                end
            end
            -- Focus left the frame entirely → clear the selection highlight; the cursor module shows the
            -- cursor again (the editor's normal-ft buffer is current now).
            set_blur(true)
            cursor.update()
        end,
    })
end

-- ─── preview side: hide + dynamic ─────────────────────────────────────────────
-- Two preview states beyond the four docked sides: `hide` (no preview — list full-width, toggled by a key)
-- and `dynamic` (list full-width + a TRANSIENT preview FLOAT above it, shown only while the picker is focused
-- and following the list cursor — the native-qf peek). Both drop the docked preview panel; `dynamic` then
-- drives its own float.

-- A single BOTTOM rule (no top/side border) — the SAME look as the docked `above` preview: the file winbar
-- marks the top, a red rule (`LvimUiPickerSeparator`) divides it from what's below. Full container width.
local DYN_BORDER = { "", "", "", "", "", "─", "", "" }

--- The dynamic float's column/width, the container top, and the CONTENT-height cap. The float floats over the
--- editor, so it is capped to LEAVE the top of the editor + its statusline VISIBLE (so you can still navigate to
--- the real buffer): its bottom rule sits 1 row above the statusline (`top - 2`), and the top stays below a
--- `keep_top` margin.
---@param state table
---@return table
function dyn_geom(state)
    local L = state._geom or compute_geom(state)
    local hs = state.cfg.preview_heights
    local capf = (hs and hs.vertical) or 0.5
    local cfgcap = math.max(3, capf <= 1 and math.floor(vim.o.lines * capf) or math.floor(capf))
    local top = L.row -- the container's top screen row (the editor statusline sits at top-1)
    -- The peek floats ABOVE the DOCK, in the editor's own space (that is the whole point: the list keeps the
    -- dock, the file gets the screen). It needs REAL room — it shows the file's own buffer, so every plugin
    -- hooked on that buffer (LSP, breadcrumbs, the lightbulb) runs in this window, and a 1–2 row slit makes them
    -- throw `E36: Not enough room` on each cursor move. Under MIN_PEEK rows the peek is not shown at all.
    local MIN_PEEK = 5
    local keep_top = math.floor(vim.o.lines * 0.4) -- leave the top ~40% of the editor visible
    local cap = math.min(cfgcap, top - 2 - keep_top)
    return {
        col = L.col,
        width = L.W,
        top = top,
        cap = cap,
        min = MIN_PEEK, -- the peek never shrinks below this, however short the file is
        row = top - cap - 2, -- its bottom rule lands at top-2, so the editor statusline (top-1) stays visible
        fits = cap >= MIN_PEEK,
    }
end

--- Render the preview provider into the dynamic float for the current list selection (no-op while the float
--- itself is focused — the provider leaves an in-progress edit alone).
---@param state table
function dyn_update(state)
    local d = state.dyn
    if not (d and d.win and api.nvim_win_is_valid(d.win)) then
        return
    end
    local prov = state.preview_panel and state.preview_panel.provider
    if prov and prov.update then
        pcall(prov.update, { win = d.win, buf = api.nvim_win_get_buf(d.win), frame = state })
    end
end

--- Show (or reposition) the dynamic float + refresh its content.
---@param state table
function dyn_show(state)
    local d = state.dyn
    if not d or state._closed or d._positioning then
        return
    end
    local g = dyn_geom(state)
    if not g.fits then
        -- No honest room for a peek (a small window, or a float with little space around it). Showing it anyway
        -- meant a 1-row window holding a REAL file buffer, where that buffer's own autocmds (LSP, breadcrumbs,
        -- the lightbulb) throw `E36: Not enough room` on every cursor move.
        dyn_hide(state)
        return
    end
    if not (d.win and api.nvim_win_is_valid(d.win)) then
        if not (d.buf and api.nvim_buf_is_valid(d.buf)) then
            d.buf = api.nvim_create_buf(false, true)
            vim.bo[d.buf].bufhidden = "hide"
        end
        local peek_enter = state.cfg.peek_enter
        if peek_enter == nil then
            peek_enter = config.peek_enter == true
        end
        d.win = api.nvim_open_win(d.buf, false, {
            relative = "editor",
            row = g.row, -- above the container (its bottom rule at top-2), or under it when the room is there
            col = g.col,
            width = g.width,
            height = g.cap,
            style = "minimal",
            border = DYN_BORDER,
            -- Not focusable unless the peek is an enterable stop (`config.peek_enter`) — a read-only peek must
            -- not swallow a click or a window-nav key either.
            focusable = peek_enter,
            zindex = (state.zindex or 50) + 1,
        })
        vim.w[d.win].lvim_frame = true -- a frame window (see the input band): never muted, and it holds the veil
        vim.wo[d.win].winhighlight = "Normal:LvimUiPeekNormal,FloatBorder:LvimUiPickerSeparator"
        vim.wo[d.win].wrap = false
        -- a FRESH window has no winbar; make the provider re-assert the file title bar on the next update
        local prov = state.preview_panel and state.preview_panel.provider
        if prov and prov.reset then
            prov.reset()
        end
    end
    dyn_update(state)
    -- AUTO-FIT the float to the file (a peek), capped at `g.cap`; the bottom rule lands at top-2 (above the
    -- editor statusline), and the cap keeps the top of the editor visible.
    if d.win and api.nvim_win_is_valid(d.win) then
        local lines = api.nvim_buf_line_count(api.nvim_win_get_buf(d.win))
        local wb = vim.wo[d.win].winbar
        -- Fit the file, but never below `g.min`: this window holds the file's REAL buffer, so a 1–2 row slit is
        -- where its own autocmds (LSP, breadcrumbs, the lightbulb) throw `E36: Not enough room` on every cursor
        -- move. A short file simply shows blank rows under it.
        local h = math.max(g.min, math.min(lines + ((wb and wb ~= "") and 1 or 0), g.cap))
        pcall(api.nvim_win_set_config, d.win, {
            relative = "editor",
            row = g.top - h - 2,
            col = g.col,
            width = g.width,
            height = h,
            border = DYN_BORDER,
        })
    end
    -- A non-current FLOAT ignores cursor positioning (it always shows from line 1). Briefly FOCUS the float to
    -- place its cursor on the entry, then restore focus — synchronous, so nothing redraws in between.
    -- `_positioning` makes the focus-change autocmds' dyn_show re-entry a no-op (so it can't reset what we set).
    local prov = state.preview_panel and state.preview_panel.provider
    local it = prov and prov.item and prov.item()
    if it and it.filename and it.lnum and d.win and api.nvim_win_is_valid(d.win) then
        local prev = api.nvim_get_current_win()
        if prev ~= d.win then
            d._positioning = true
            pcall(api.nvim_set_current_win, d.win)
            local cnt = api.nvim_buf_line_count(api.nvim_win_get_buf(d.win))
            pcall(
                api.nvim_win_set_cursor,
                d.win,
                { math.max(1, math.min(it.lnum, cnt)), math.max(0, (it.col or 1) - 1) }
            )
            pcall(vim.cmd, "normal! zz")
            if api.nvim_win_is_valid(prev) then
                pcall(api.nvim_set_current_win, prev)
            end
            d._positioning = false
        end
    end
end

--- Hide the dynamic float (its buffer + the editable file stay alive; only the window closes).
---@param state table
function dyn_hide(state)
    local d = state.dyn
    if d and d.win and api.nvim_win_is_valid(d.win) then
        pcall(api.nvim_win_close, d.win, true)
    end
    if d then
        d.win = nil
    end
end

--- Turn the dynamic peek ON: a `CursorMoved` on the list follows the selection; a global `WinEnter` shows the
--- float while any picker window is focused and hides it when focus leaves the picker. Entering the float binds
--- `<C-j>` (on the editable file buffer, while focused) to drop back to the list.
---@param state table
function dyn_enable(state)
    state.dyn = state.dyn or {}
    if state.dyn.aug then
        return -- already on
    end
    local list = state.list_panel
    local aug = api.nvim_create_augroup("LvimUiSurfaceDyn_" .. tostring(state.container_win), { clear = true })
    state.dyn.aug = aug
    if list and list.buf and api.nvim_buf_is_valid(list.buf) then
        api.nvim_create_autocmd("CursorMoved", {
            group = aug,
            buffer = list.buf,
            callback = function()
                dyn_show(state)
            end,
        })
    end
    api.nvim_create_autocmd("WinEnter", {
        group = aug,
        callback = function()
            if state._closed then
                return
            end
            local w = api.nvim_get_current_win()
            local on_float = state.dyn.win and w == state.dyn.win
            local mine = on_float or (list and w == list.win) or (w == state.container_win)
            for _, b in ipairs(state.header_bands or {}) do
                if b.win == w then
                    mine = true
                end
            end
            if on_float then
                -- editing the peek → `<C-j>` drops back to the list, `<C-k>` steps UP out to the editor (the
                -- opener) — bound on the real file buffer only while the float is focused.
                local fb = api.nvim_win_get_buf(w)
                state.dyn._navbuf = fb
                pcall(vim.keymap.set, "n", "<C-j>", function()
                    if list and list.win and api.nvim_win_is_valid(list.win) then
                        api.nvim_set_current_win(list.win)
                    end
                end, { buffer = fb, nowait = true, silent = true })
                pcall(vim.keymap.set, "n", "<C-k>", function()
                    if state.cfg.on_escape_above then
                        state.cfg.on_escape_above()
                    end
                end, { buffer = fb, nowait = true, silent = true })
            else
                if state.dyn._navbuf and api.nvim_buf_is_valid(state.dyn._navbuf) then
                    pcall(vim.keymap.del, "n", "<C-j>", { buffer = state.dyn._navbuf })
                    pcall(vim.keymap.del, "n", "<C-k>", { buffer = state.dyn._navbuf })
                end
                state.dyn._navbuf = nil
                if mine then
                    dyn_show(state)
                else
                    dyn_hide(state)
                end
            end
        end,
    })
    dyn_show(state)
end

--- Turn the dynamic peek OFF: drop the autocmds + close the float.
---@param state table
function dyn_disable(state)
    local d = state.dyn
    if not d then
        return
    end
    if d.aug then
        pcall(api.nvim_del_augroup_by_id, d.aug)
        d.aug = nil
    end
    if d._navbuf and api.nvim_buf_is_valid(d._navbuf) then
        pcall(vim.keymap.del, "n", "<C-j>", { buffer = d._navbuf })
        pcall(vim.keymap.del, "n", "<C-k>", { buffer = d._navbuf })
        d._navbuf = nil
    end
    dyn_hide(state)
end

--- Re-derive the DOCKED center panels from the live preview state (side / hidden / dynamic) and reflow: a
--- single full-width list for `hide`/`dynamic`, the re-docked list+preview otherwise. The dropped preview is
--- PARKED behind the list (never closed — a WinClosed would bounce focus to the editor via the user's window
--- managers); re-docking just returns it to `state.panels`. No-op on a surface without a "preview" panel.
---@param state table
function restack_panels(state)
    local pv, list = state.preview_panel, state.list_panel
    if not (pv and list) then
        return
    end
    -- The docked preview sits BESIDE the list — `left` puts it first, anything else second. Vertical stacking
    -- (above/below) is gone: the two panels then split the dock's rows, so neither is readable; a preview that
    -- needs the screen is the `dynamic` peek FLOAT instead.
    local undocked = state.preview_hidden or state.preview_side == "dynamic"
    local docked = undocked and { list } or ((state.preview_side == "left") and { pv, list } or { list, pv })
    state.panels = docked
    for _, pan in ipairs(docked) do
        pan.weight = pan.size and (pan.size.width or {}).fixed or nil
    end
    apply_dock_height(state, state.preview_side)
    state.sectors = build_sectors(state)
    relayout(state) -- positions the docked panels (place_panels)
    -- The DROPPED preview is PARKED (not closed) behind the list: a WinClosed would fire the user's window
    -- managers (BufSurf, …) and bounce focus to the editor. Re-docking just returns it to `state.panels`, so the
    -- next relayout repositions it. (The list float — higher zindex + opaque — fully covers the parked one.)
    if undocked and pv.win and api.nvim_win_is_valid(pv.win) then
        local lp = state._geom and state._geom.panels and state._geom.panels[1]
        if lp then
            pcall(api.nvim_win_set_config, pv.win, {
                relative = "editor",
                row = lp.row,
                col = lp.col,
                width = math.max(1, lp.width),
                height = math.max(1, lp.height),
                zindex = state.zindex or 50,
            })
        end
    end
end

--- Pull focus back to the list AFTER the event loop (closing a preview float bounces focus to the editor on a
--- DEFERRED tick, so a synchronous re-focus is undone). Used by the runtime rotate / hide toggle — never at
--- open, where the input band should keep focus.
---@param state table
function refocus_list(state)
    vim.schedule(function()
        if state._closed then
            return
        end
        local w = state.list_panel and state.list_panel.win
        if w and api.nvim_win_is_valid(w) then
            pcall(api.nvim_set_current_win, w)
        end
    end)
end

--- Apply the live `preview_side` (+ `preview_hidden`): reflow the docked panels, then arm/disarm the dynamic
--- peek. The single entry point for both the rotation and the hide toggle.
---@param state table
function apply_preview_side(state)
    restack_panels(state)
    if state.preview_side == "dynamic" then
        dyn_enable(state)
    else
        dyn_disable(state)
    end
    -- re-render the preview next tick: a just re-docked panel (un-hide / rotate back) can read empty until the
    -- next selection change, and the dynamic float needs its content after the windows settle.
    vim.schedule(function()
        if state._closed then
            return
        end
        local pv = state.preview_panel
        if pv and pv.provider and pv.provider.reset then
            pv.provider.reset()
        end
        if pv and pv.refresh then
            pv.refresh()
        end
    end)
end

--- Tear the frame down: close every window, restore the cursor + focus, fire `cfg.on_close` once.
---@param state table
local function close(state)
    if state._closed then
        return
    end
    state._closed = true
    -- Whether WE hold focus must be decided BEFORE the windows go: closing a focused float makes Neovim pick a
    -- fallback window on the spot (the editor), so a check made afterwards always answers "no" and the origin
    -- restore below never runs. That is why a popup opened from a panel dropped the user into the buffer behind
    -- it instead of back into the panel.
    local held_focus = false
    do
        local cur = api.nvim_get_current_win()
        held_focus = cur == state.container_win
        if not held_focus then
            for _, p in ipairs(state.panels or {}) do
                if p.win == cur then
                    held_focus = true
                    break
                end
            end
        end
    end
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
    end
    -- The native-split footer window (owned by the surface) — drop its focus-bounce autocmd and close it
    -- before the panel windows (its reserved row returns to the panel).
    if state._footer_augroup then
        pcall(api.nvim_del_augroup_by_id, state._footer_augroup)
        state._footer_augroup = nil
    end
    if state._footer_win and api.nvim_win_is_valid(state._footer_win) then
        pcall(api.nvim_win_close, state._footer_win, true)
    end
    if state._footer_buf and api.nvim_buf_is_valid(state._footer_buf) then
        pcall(api.nvim_buf_delete, state._footer_buf, { force = true })
    end
    dyn_disable(state) -- close the dynamic peek float + its autocmds, if armed
    -- Let providers release any external state before we drop the windows (the frame's own scratch panel
    -- buffers are deleted below, taking their keymaps/extmarks with them, but a provider may hold things
    -- outside them — e.g. autocommands, or keymaps on a real buffer).
    for _, pan in ipairs(state.panels or {}) do
        if pan.provider and pan.provider.on_close then
            pcall(pan.provider.on_close, pan)
        end
    end
    -- A PARKED preview (hidden / dynamic) is not in `state.panels`, so close it explicitly too.
    if state.preview_panel and state.preview_panel.win and api.nvim_win_is_valid(state.preview_panel.win) then
        local docked = false
        for _, p in ipairs(state.panels or {}) do
            if p == state.preview_panel then
                docked = true
            end
        end
        if not docked then
            pcall(api.nvim_win_close, state.preview_panel.win, true)
        end
    end
    for _, pan in ipairs(state.panels or {}) do
        if pan.win and api.nvim_win_is_valid(pan.win) then
            pcall(api.nvim_win_close, pan.win, true)
        end
        if pan.buf and api.nvim_buf_is_valid(pan.buf) then
            pcall(api.nvim_buf_delete, pan.buf, { force = true })
        end
    end
    if state.preview_panel and state.preview_panel.buf and api.nvim_buf_is_valid(state.preview_panel.buf) then
        pcall(api.nvim_buf_delete, state.preview_panel.buf, { force = true })
    end
    for _, band in ipairs(state.header_bands or {}) do -- editable input bands' overlay windows
        if band.input then
            if band.win and api.nvim_win_is_valid(band.win) then
                pcall(api.nvim_win_close, band.win, true)
            end
            if band.buf and api.nvim_buf_is_valid(band.buf) then
                pcall(api.nvim_buf_delete, band.buf, { force = true })
            end
        end
    end
    if state.container_win and api.nvim_win_is_valid(state.container_win) then
        pcall(api.nvim_win_close, state.container_win, true)
    end
    -- Backdrop: tear down this surface's veil through the shared applier (restores every window it muted to its
    -- original namespace and resumes the colorscheme dim manager) and release the surface's ownership tracker.
    require("lvim-utils.dim").clear_backdrop(tostring(state))
    if active_surface_bd == state then
        active_surface_bd = nil
    end
    if state.base_cmdheight ~= nil then -- a `cmdline` surface grew cmdheight; restore the user's value
        vim.o.cmdheight = state.base_cmdheight
    end
    -- Restore focus to the window this surface opened from — but ONLY when WE currently hold focus. A surface
    -- closing in the BACKGROUND (e.g. the msgarea zone auto-hiding, or any dock torn down while the user has
    -- moved on to ANOTHER float) must not yank focus to its own origin: that would steal it from whatever is
    -- focused now (reported: opening the installer stole its focus back to the editor via the msgarea zone's
    -- close). If focus is already elsewhere, leave it.
    if held_focus and state.origin and api.nvim_win_is_valid(state.origin) then
        pcall(api.nvim_set_current_win, state.origin)
    end
    cursor.update() -- the frame's hide-cursor buffers are gone → show the cursor in the editor again
    if state._host_release then -- release our auto-hosted zone rows so it shrinks back (or closes)
        pcall(state._host_release)
    end
    if area_current == state then -- this area dock is gone; the zone is free for the next
        area_current = nil
    end
    if state.cfg.on_close then
        pcall(state.cfg.on_close)
    end
end

--- NATIVE split panel: a single block as a REAL split window (NOT a float over a container). For a
--- persistent, navigable side tree (e.g. the lsp outline) this keeps the panel IN the native window
--- layout, so `<C-w>h/j/k/l/w` moves in and out of it AND buffer changes redraw like any window (a float
--- panel reflects neither reliably). 1 block only — the title is a centred winbar; there are no header/
--- footer bars in this mode. The provider interface (render / update / keys / cursorline / filetype /
--- on_close) is reused verbatim, only the WINDOW is real instead of a float.
---@param state table
local function open_native_split(state)
    register_frame_ft()
    local cfg = state.cfg
    local pan = state.panels[1]
    if not pan then
        return
    end
    local dock = cfg.dock or "right"
    local horiz = dock == "below" or dock == "above"

    -- Size from the provider's natural size ⊕ the explicit cfg.width/height (fraction ≤1 or a count).
    local sw, sh = 20, 1
    if pan.provider and pan.provider.size then
        local ok, w, h = pcall(pan.provider.size)
        if ok then
            sw, sh = w or sw, h or sh
        end
    end
    local function dim(fixed, nat, total)
        if not fixed then
            return nat
        end
        return fixed <= 1 and math.floor(total * fixed) or math.floor(fixed)
    end
    local width = math.max(1, dim(cfg.width, sw, vim.o.columns))
    local height = math.max(1, dim(cfg.height, sh, vim.o.lines))

    pan.buf = api.nvim_create_buf(false, true)
    vim.bo[pan.buf].bufhidden = "wipe"
    -- The provider names its filetype (drives cursor hiding via the user's panel_ft + filetype detection);
    -- else a hide_cursor provider gets FRAME_FT so the cursor module hides while it is current.
    if pan.provider and pan.provider.filetype then
        vim.bo[pan.buf].filetype = pan.provider.filetype
    elseif pan.provider and pan.provider.hide_cursor then
        vim.bo[pan.buf].filetype = FRAME_FT
    end

    pan.win = api.nvim_open_win(pan.buf, cfg.enter == true, {
        split = dock,
        win = -1, -- pin to the far edge of the tabpage
        width = (not horiz) and width or nil,
        height = horiz and height or nil,
        style = "minimal",
    })
    if horiz then
        vim.wo[pan.win].winfixheight = true
    else
        vim.wo[pan.win].winfixwidth = true
    end
    vim.wo[pan.win].wrap = false
    vim.wo[pan.win].scrolloff = 0 -- a fit-to-window panel must never scroll its content off (see open_panel_win)
    vim.wo[pan.win].sidescrolloff = 0
    -- The panel's Normal group: the float/peek bg (`LvimUiPeekNormal`) by default, or a caller-chosen group
    -- via `cfg.normal_hl` — e.g. a persistent DOCKED side panel (the outline) passes "NormalSB" so it wears the
    -- opaque SIDEBAR background (matching neo-tree) instead of the transparency-following float bg.
    local normal_hl = cfg.normal_hl or "LvimUiPeekNormal"
    if pan.provider and pan.provider.cursorline then
        -- A native docked panel (the outline) uses the NEUTRAL cursorline, not the popup-list yellow.
        vim.wo[pan.win].winhighlight = "Normal:" .. normal_hl .. ",CursorLine:LvimUiCursorLine"
        vim.wo[pan.win].cursorline = true
    else
        vim.wo[pan.win].winhighlight = "Normal:" .. normal_hl
    end
    -- Title → a centred winbar (the whole bar carries the blue peek-title tint).
    local tt = title_text(cfg.title)
    if tt ~= "" then
        vim.wo[pan.win].winhighlight = vim.wo[pan.win].winhighlight
            .. ",WinBar:LvimUiPeekTitle,WinBarNC:LvimUiPeekTitle"
        vim.wo[pan.win].winbar = "%=" .. tt .. "%="
    end

    state._geom =
        { panels = { { width = api.nvim_win_get_width(pan.win), height = api.nvim_win_get_height(pan.win) } } }
    pan.refresh = function()
        render_panel(state, 1)
    end
    pan.frame = state
    -- A footer float overlays the panel's bottom row: reserve it BEFORE the first render (the content provider
    -- reads `pan.footer_reserve`), so the last row never lands under the bar even on the opening paint. No
    -- footer configured ⇒ no reserve ⇒ the panel fills its whole height exactly as before.
    if cfg.footer then
        pan.footer_reserve = 1
        vim.wo[pan.win].scrolloff = 1
    end
    render_panel(state, 1)

    -- Native FOOTER: a 1-row overlay float sitting on the panel's last USABLE row (`relative = "win"`). A native
    -- panel is ONE real window — no chrome container to host a footer band, and stacking a second window for one
    -- would force a statusline SEPARATOR row between them (drawn even at laststatus=0), a gap the panel must not
    -- have. So the panel instead RESERVES the row(s) the float overlays (`pan.footer_reserve` + `scrolloff`) — the
    -- content provider keeps that many trailing blank rows and the last REAL row stays above the bar, so a `j`
    -- onto it can never drop it under the float. A consumer passes `footer = { bars = { { items = …, align = … }}}`
    -- and refreshes its labels via `state.set_footer`.
    --
    -- POSITION is split from PAINT: `place_footer` (geometry → float config + reserve) must re-run whenever the
    -- panel's height changes, which happens WITHOUT a content change — a global statusline toggles (laststatus),
    -- the cmdline grows/shrinks (cmdheight), the view scrolls. So it is driven by its own light autocmds below,
    -- not only by `set_footer`. It is config-INDEPENDENT: with `laststatus=3` the global statusline is a NATIVE
    -- row OUTSIDE the panel (the panel's own bottom row is already above it); but a bottom msgarea at
    -- `laststatus=0` lays a FLOAT over the very bottom screen row, INSIDE the panel's extent — so it detects a
    -- thin bottom float covering the panel's bottom row over its columns and sits ONE row higher, reserving that
    -- extra row too, so the footer never lands on the statusline.
    local function place_footer()
        if state._closed or not (pan.win and api.nvim_win_is_valid(pan.win)) then
            return
        end
        if not (state._footer_buf and api.nvim_buf_is_valid(state._footer_buf)) then
            return -- nothing painted yet (no footer configured)
        end
        local fw = api.nvim_win_get_width(pan.win)
        -- The TEXT-area height, not `nvim_win_get_height` (which counts the winbar the panel title rides): the
        -- footer is a `relative="win"` float and its `row = 0` is the first TEXT row (below the winbar), so its
        -- last row is `text_h - 1`. `getwininfo().height` is winbar-exclusive; `winrow` is the frame top, so the
        -- text top adds a row when a winbar is present.
        local wi = vim.fn.getwininfo(pan.win)[1]
        local text_h = wi.height
        local psp = vim.fn.win_screenpos(pan.win)
        local pc = psp[2]
        local text_top = wi.winrow + (((vim.wo[pan.win].winbar or "") ~= "") and 1 or 0)
        local panel_bottom = text_top + text_h - 1
        local chrome = 0 -- extra bottom rows owned by an overlapping msgarea/statusline float
        for _, w in ipairs(api.nvim_list_wins()) do
            if w ~= state._footer_win and w ~= pan.win then
                local c = api.nvim_win_get_config(w)
                if c.relative and c.relative ~= "" then
                    local fh = api.nvim_win_get_height(w)
                    if fh <= 3 then -- a bar, never a full-height backdrop
                        local sp = vim.fn.win_screenpos(w)
                        local fr, fc, fwid = sp[1], sp[2], api.nvim_win_get_width(w)
                        local col_overlap = fc <= (pc + fw - 1) and (fc + fwid - 1) >= pc
                        local covers_bottom = fr <= panel_bottom and (fr + fh - 1) >= panel_bottom
                        if col_overlap and covers_bottom then
                            chrome = 1
                            break
                        end
                    end
                end
            end
        end
        local reserve = 1 + chrome
        local fpos = {
            relative = "win",
            win = pan.win,
            row = math.max(0, text_h - 1 - chrome),
            col = 0,
            width = fw,
            height = 1,
        }
        if state._footer_win and api.nvim_win_is_valid(state._footer_win) then
            pcall(api.nvim_win_set_config, state._footer_win, fpos)
        else
            fpos.focusable = false
            fpos.style = "minimal"
            fpos.zindex = 60
            fpos.noautocmd = true
            state._footer_win = api.nvim_open_win(state._footer_buf, false, fpos)
            vim.wo[state._footer_win].winhighlight = "Normal:" .. normal_hl
            vim.wo[state._footer_win].wrap = false
            vim.wo[state._footer_win].cursorline = false
        end
        -- Only re-render the provider when the reserve COUNT actually changes (footer added, or the bottom-chrome
        -- situation flipped) — this runs on scroll/resize, and an unconditional refresh would recurse forever.
        local need_reserve = pan.footer_reserve ~= reserve
        pan.footer_reserve = reserve
        vim.wo[pan.win].scrolloff = reserve
        if need_reserve and pan.refresh then
            pan.refresh() -- apply the trailing reserved row(s) immediately (once)
        end
    end
    local function render_native_footer(spec)
        local bar = spec and spec.bars and spec.bars[1]
        if not (bar and bar.items and pan.win and api.nvim_win_is_valid(pan.win)) then
            return
        end
        if not (state._footer_buf and api.nvim_buf_is_valid(state._footer_buf)) then
            state._footer_buf = api.nvim_create_buf(false, true)
            vim.bo[state._footer_buf].bufhidden = "wipe"
            -- Clicks go through the GLOBAL mouse layer (by window under the pointer), NOT a buffer-local
            -- <LeftMouse>: the footer is a NON-focusable float, so focus never enters it and a buffer-local map
            -- would never fire. `register_click` hit-tests the clicked column against the rendered item boxes.
            require("lvim-utils.mouse").register_click(state._footer_buf, function(_line, col0)
                if vim.o.mouse == "" then
                    return
                end
                for _, it in ipairs(state._footer_items or {}) do
                    if it.c0 and col0 >= it.c0 and col0 < it.c1 and it.spec and it.spec.run then
                        it.spec.run()
                        return
                    end
                end
            end)
        end
        local fw = api.nvim_win_get_width(pan.win)
        local band = require("lvim-ui.bar").render({ items = bar.items, width = fw, align = bar.align or "center" })
        state._footer_items = band.items
        vim.bo[state._footer_buf].modifiable = true
        api.nvim_buf_set_lines(state._footer_buf, 0, -1, false, { band.line })
        vim.bo[state._footer_buf].modifiable = false
        api.nvim_buf_clear_namespace(state._footer_buf, NS, 0, -1)
        pcall(api.nvim_buf_set_extmark, state._footer_buf, NS, 0, 0, {
            end_row = 1,
            hl_eol = true,
            hl_group = "LvimUiBarFill",
            priority = 90,
        })
        for _, s in ipairs(band.spans) do
            pcall(
                api.nvim_buf_set_extmark,
                state._footer_buf,
                NS,
                0,
                s[1],
                { end_col = s[2], hl_group = s[3], priority = 200 }
            )
        end
        place_footer()
    end
    --- Rebuild + repaint the native footer bar (live counts / labels).
    ---@param spec table
    state.set_footer = function(spec)
        state.cfg.footer = spec
        render_native_footer(spec)
    end
    if cfg.footer then
        render_native_footer(cfg.footer)
    end

    -- Focus / block accessors. Navigation is NATIVE (`<C-w>`) — no sectors, bars or chrome to drive.
    state.center_panel = 1
    state.focus_panel = function()
        if pan.win and api.nvim_win_is_valid(pan.win) then
            api.nvim_set_current_win(pan.win)
            cursor.update()
        end
    end
    state.focus_block = function()
        state.focus_panel()
    end
    state.focus_sector = function()
        state.focus_panel()
    end
    state.panel = function() end
    state.sector = function() end
    state.refresh_chrome = function() end
    state.map_hotkeys = function() end
    state.remap_hotkeys = function() end
    state.toggle_header = function()
        return false
    end
    state.to_origin = function()
        if state.origin and api.nvim_win_is_valid(state.origin) then
            api.nvim_set_current_win(state.origin)
        end
    end

    -- Keys: the provider's own keys + close_keys + consumer keymaps on the panel buffer. No sector/menu
    -- nav keys — the panel is a real window, so `<C-w>` already moves in and out of it.
    -- Track what the panel binds: a docked panel owns its chord PREFIXES too (see `own_chord_prefixes`).
    local bound = {}
    local function map(lhs, fn)
        for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
            bound[l] = true
            vim.keymap.set("n", l, fn, { buffer = pan.buf, nowait = true, silent = true })
        end
    end
    -- A docked panel is a REAL window, so it never goes through `set_keys`/`lock_panel` (the float path) — but
    -- it is still a rendered UI surface, not a text buffer. Without this, a real mouse click (which jitters a
    -- pixel → `<LeftDrag>`) starts VISUAL and "selects" the row's label, replacing the full-width cursorline bar
    -- with a `Visual` bg over the text only. Bound BEFORE the provider's keys, so a provider may override.
    nop_mouse(pan.buf)
    if pan.provider and pan.provider.keys then
        pcall(pan.provider.keys, map, pan, state)
    end
    for _, ck in ipairs(cfg.close_keys or {}) do
        map(ck, state.close)
    end
    for _, km in ipairs(cfg.keymaps or {}) do
        map(km.key, function()
            km.run(state)
        end)
    end
    -- Bound LAST, once every key is known: the panel owns the prefixes of its own chords (a `g?` help), so the
    -- chord no longer depends on how fast the user types (see `own_chord_prefixes`).
    own_chord_prefixes(pan.buf, bound)

    -- Tear down when the window closes; re-render content on resize (the window itself resizes natively).
    state.augroup = api.nvim_create_augroup("LvimUiFrameNative_" .. pan.win, { clear = true })
    api.nvim_create_autocmd("WinClosed", {
        group = state.augroup,
        pattern = tostring(pan.win),
        callback = function()
            state.close()
        end,
    })
    local function refit_native()
        state._geom.panels[1] = { width = api.nvim_win_get_width(pan.win), height = api.nvim_win_get_height(pan.win) }
        render_panel(state, 1)
        -- Re-pin the native FOOTER float to the panel's NEW last row. The footer is anchored at a row computed
        -- from the window height at render time (`content_h - 1`); a resize changes that height, but re-rendering
        -- the panel content alone leaves the footer stranded at its old row — the gap the user sees below it. The
        -- surface owns the float, so it must keep it pinned: re-render it from the live `cfg.footer` spec here.
        if state.cfg.footer then
            render_native_footer(state.cfg.footer)
        end
    end
    -- WinResized fires session-wide for EVERY resized window; only re-render when OUR split was one of them
    -- (mirror the float path's `vim.v.event.windows` filter) so an unrelated split drag never re-renders us.
    api.nvim_create_autocmd("WinResized", {
        group = state.augroup,
        callback = function()
            if state._closed or not (pan.win and api.nvim_win_is_valid(pan.win)) then
                return
            end
            for _, w in ipairs(vim.v.event.windows or {}) do
                if w == pan.win then
                    refit_native()
                    return
                end
            end
        end,
    })
    -- A terminal-size change (VimResized) always reflows — every window is affected.
    api.nvim_create_autocmd("VimResized", {
        group = state.augroup,
        callback = function()
            if not state._closed and pan.win and api.nvim_win_is_valid(pan.win) then
                refit_native()
            end
        end,
    })
    -- The footer float pins to the panel's last USABLE row — a geometry that shifts WITHOUT a content change:
    -- `laststatus`/`cmdheight` toggle the panel's height (a global statusline or the cmdline appears/disappears —
    -- a bottom msgarea drives these live), the view SCROLLS, focus moves. Any of these can strand the footer a
    -- row too high or low (e.g. ON the statusline). `place_footer` is cheap (a set_config), so re-run it on all
    -- of them — scheduled, because the window's new height is applied AFTER the option set / scroll settles.
    local function schedule_place()
        vim.schedule(function()
            if not state._closed and pan.win and api.nvim_win_is_valid(pan.win) then
                place_footer()
            end
        end)
    end
    api.nvim_create_autocmd("OptionSet", {
        group = state.augroup,
        pattern = { "laststatus", "cmdheight" },
        callback = schedule_place,
    })
    api.nvim_create_autocmd("WinScrolled", {
        group = state.augroup,
        pattern = tostring(pan.win),
        callback = schedule_place,
    })
end

--- What a host provider binds a cmdline surface to: a reserve `host` function, a `release` teardown closure,
--- and (optional) the `on_escape_below` action (descend from the dock into the zone's content below it).
---@class lvim-ui.HostBinding
---@field host fun(h: integer): table  reserve `h` rows in the host zone; returns the placement rect
---@field release fun()                release the reserved rows (the zone shrinks back / closes)
---@field on_escape_below? fun()       descend from the dock into the zone below (the C-j-off-bottom action)

--- A host provider: given a surface `state` + its `cfg`, returns a HostBinding — or `nil` to skip hosting
--- (the dock then grows cmdheight itself).
---@alias lvim-ui.HostProvider fun(state: table, cfg: table): lvim-ui.HostBinding?

-- The auto-host provider for a `position="cmdline"` surface. Registered by the msgarea zone (via
-- M.set_host_provider) so the surface ENGINE never references the zone — the dependency is inverted, so
-- ui has no coupling to msgarea. nil ⇒ no zone registered ⇒ a hostless cmdline dock grows cmdheight itself.
---@type lvim-ui.HostProvider?
local host_provider = nil

-- Zone hooks registered by the host zone (msgarea) — the same inversion as the host provider, so a docked
-- consumer can trigger zone-level behaviour WITHOUT requiring the zone. `handoff`: coalesce a reflow across a
-- zone teardown+rebuild into one repaint. nil ⇒ no zone ⇒ the consumer's `fn` just runs.
---@type { handoff?: fun(fn: fun()) }|nil
local zone_hooks = nil

-- The public METHOD names a `state` handle exposes (every `state.<name> = function` below). Used by the
-- cmdwin-deferred stub so it can answer a method call with a no-op while leaving DATA fields nil.
---@type table<string, true>
local DEFERRED_METHODS = {
    close = true,
    focus_block = true,
    focus_panel = true,
    focus_sector = true,
    map_hotkeys = true,
    panel = true,
    refresh_chrome = true,
    relayout = true,
    reposition = true,
    rotate_preview = true,
    sector = true,
    set_counter = true,
    set_footer = true,
    set_header = true,
    set_title = true,
    toggle_header = true,
    toggle_preview = true,
    to_origin = true,
}

--- Open a frame.
---@param cfg table  the frame config (see the module header)
---@return table state
function M.open(cfg)
    cfg = cfg or {}
    -- `nvim_open_win` is forbidden in the command-line window (q: / q/ / q?), so a frame opened from there
    -- (e.g. an installer prompt that fires while `q:` is open) would raise E11. Defer the whole open until
    -- the cmdwin closes and return a no-op stub, so the caller never crashes on the missing handle.
    if vim.fn.getcmdwintype() ~= "" then
        vim.api.nvim_create_autocmd("CmdwinLeave", {
            once = true,
            callback = function()
                vim.schedule(function()
                    M.open(cfg)
                end)
            end,
        })
        -- Stub only the STATE METHODS as no-ops; every other key (data fields like `cfg` / `keys` / `panels` /
        -- `sectors`) reads nil, not a function — a caller reading a data field off the deferred handle must not
        -- get a function back (it would then be indexed/called as a table and crash).
        return setmetatable({ deferred = true }, {
            __index = function(_, k)
                return DEFERRED_METHODS[k] and function() end or nil
            end,
        })
    end
    cfg.mode = cfg.mode or "float"
    -- Shared title / counter placement: per-open override < `config` default < the hardcoded fallback.
    -- `title_line` ("row" | "statusline" | "border") places the title: a CONTENT row at the top (the canon —
    -- flush-left, counter flush-right), the chrome overlay (area minibuffer style), or the native border-title.
    -- The hardcoded fallback is "row", NOT "border": the native border-title has visual quirks (nvim's 1-col
    -- corner inset, and it vanishes when the container border is "none"), so it is opt-in only, never a default.
    -- `counter` ("title" | "footer") places a supplied `count` beside the title or in the native border-footer.
    local ui_conf = config or {}
    cfg.title_line = cfg.title_line or ui_conf.title_line or "row"
    cfg.counter = cfg.counter or ui_conf.counter or "footer"
    -- Title ALIGNMENT (shared by the content-row title AND the native border-title): per-open override <
    -- `config.title_pos` < "left". "left" | "center" | "right".
    cfg.title_pos = cfg.title_pos or ui_conf.title_pos or "left"
    -- Inter-panel divider: LEFT as the consumer passed it (nil = use the configurable default `config.separator`,
    -- resolved live at render via `resolve_divider`; false / a string / a { h, v } table = a per-surface override).
    -- It only ever draws between adjacent panels (n-1 gaps), so a single-panel surface (select / info / input /
    -- tabs) shows none; a multi-panel one (a picker's list + preview) gets the rule between each pair.
    -- Resolve the canonical frame border to the LIVE `config.border` (the SINGLE source) at open time: a
    -- consumer that passed the `FRAME_BORDER` marker (or no border at all) is asking for "the one config-driven
    -- ring", so a runtime change to that key reflects here on the next open of every consumer — without editing
    -- any of them. An explicit "rounded" / "none" / custom border (e.g. a true float) is left untouched.
    if cfg.border == nil or cfg.border == M.FRAME_BORDER then
        cfg.border = ui_conf.border or M.FRAME_BORDER
    end
    -- Modal frames close on q / <Esc> from anywhere; a `persistent` frame (e.g. a docked outline) sets
    -- its own close_keys (or none) and is never auto-closed.
    if cfg.close_keys == nil and not cfg.persistent then
        cfg.close_keys = { "q", "<Esc>" }
    end

    -- Sizing SOURCE — the rule: NO explicit `cfg.size` ⇒ the CENTRAL dock slot; an explicit `cfg.size` ⇒ the
    -- consumer's OWN size (untouched). A consumer that passed no size is a 3-layout DOCK consumer, so derive its
    -- size from the central geometry authority (`lvim-utils.config.dock.geometry`) through the `lvim-ui.size`
    -- façade — which returns the fraction-based `{ height, width = { auto/fixed, max } }` shape `axis_size`
    -- resolves ITSELF (read the config's fractions + auto flags, never the already-resolved cells, so we don't
    -- double-resolve). A consumer that DID pass `cfg.size` (a content-fit SPECIAL float: hover, image viewer,
    -- cheatsheet, the select / input modals) keeps that size verbatim. `cfg.slot` is an optional per-open
    -- ANCHORED override (height / width ≤ 1 = a fraction, > 1 = an absolute count; `*_auto` picks fixed vs
    -- content-fit-up-to-max) that WINS over the central defaults for THIS open only.
    if cfg.size == nil then
        local layout = backdrop_layout(cfg) -- "cmdline"→area, "bottom"→bottom, else float (same signal as sizing)
        cfg.size = M.size_spec(layout)
        if cfg.slot then
            if cfg.slot.height ~= nil then
                cfg.size.height = (cfg.slot.height_auto == true) and { auto = true, max = cfg.slot.height }
                    or { fixed = cfg.slot.height }
            end
            if layout == "float" and cfg.slot.width ~= nil then
                cfg.size.width = (cfg.slot.width_auto == true) and { auto = true, max = cfg.slot.width }
                    or { fixed = cfg.slot.width }
            end
        end
    end
    -- PREVIEW HEIGHTS, from the ONE central authority — no consumer passes these. `dock.geometry.<layout>` carries
    -- `height` (the DOCK's own height — the preview sits beside the list and they share it) and `height_peek` (the
    -- cap of the `dynamic` PEEK FLOAT, which floats ABOVE the list instead of sharing the dock). `apply_dock_height`
    -- re-derives the row count from the CURRENT window height on every rotation / resize; a consumer may still pass
    -- its own `preview_heights` to override.
    -- ONLY for a surface that HAS a preview: these numbers exist to size the preview pair. Deriving them for
    -- every frame made `apply_dock_height` re-assert auto/max height on panels that never asked for it (the
    -- installer, the control center …) — they opened, then re-fitted a row later, which reads as a flicker.
    if cfg.preview_heights == nil and cfg.preview_side ~= nil then
        local ok_c, uconf = pcall(require, "lvim-utils.config")
        local g = (ok_c and uconf and uconf.dock and uconf.dock.geometry and uconf.dock.geometry[backdrop_layout(cfg)])
            or {}
        if type(g.height) == "number" or type(g.height_peek) == "number" then
            cfg.preview_heights = {
                horizontal = g.height, -- the DOCKED preview (beside the list) — the dock's own height
                vertical = g.height_peek or g.height, -- the `dynamic` PEEK FLOAT above the list (dyn_geom's cap)
            }
        end
    end

    -- `cfg.size = { width/height = { auto, min, max, fixed } }` → the per-axis fields the geometry uses. `auto`
    -- fits the content (within max); else `fixed`; each a screen fraction ≤1 or an absolute count. `height.min` =
    -- minimum VISIBLE content rows; `width.min` clamps the float width.
    local size = cfg.size or {}
    local sw, sh = size.width or {}, size.height or {}
    cfg.auto_width, cfg.width, cfg.max_width, cfg.min_width = sw.auto, sw.fixed, sw.max, sw.min
    cfg.auto_height, cfg.height, cfg.max_height, cfg.min_content_height = sh.auto, sh.fixed, sh.max, sh.min

    -- content.blocks → panels: each block carries an `id`, a `provider`, its share along the STACKING axis
    -- (`size.width.fixed` when horizontal / `size.height.fixed` when vertical = a weight; absent = flex/
    -- auto), and an optional `border`.
    local panels = {}
    local stack_axis = cfg.direction == "vertical" and "height" or "width"
    for i, blk in ipairs((cfg.content or {}).blocks or {}) do
        local bw = (blk.size or {})[stack_axis] or {}
        -- Resolve the CONTENT_BORDER marker to the LIVE `config.content_border` (the single source for the
        -- content-PANEL ring) at open time, so changing that one key re-borders this block on the next open —
        -- exactly like FRAME_BORDER does for the container. An explicit "none" / "rounded" / custom table is the
        -- consumer's own choice and is left untouched (so the nav bars / borderless select lists stay borderless).
        local blk_border = blk.border
        if blk_border == M.CONTENT_BORDER then
            blk_border = config.content_border or M.CONTENT_BORDER
        end
        panels[i] = {
            id = blk.id,
            provider = blk.provider,
            size = blk.size,
            weight = bw.fixed,
            auto_stack = bw.auto, -- fit this panel to its natural content along the stacking axis (per-panel auto)
            border = blk_border,
            shrink_first = blk.shrink_first, -- give up rows before protected panels when the stack overflows
        }
    end

    -- AIR IS DERIVED FROM THE RING, never added on top of it. A content panel's border (the canon `" "` ring —
    -- `config.content_border`) ALREADY draws a blank row above and below the data. The frame's own air rows exist
    -- to give that same breathing room when a panel has NO ring; adding both stacks TWO blank rows on that side
    -- (the calendar's grid sat 1 row under the nav band but 2 above the footer). So: a side the ring already
    -- spaces gets no air row from the frame. Only the UNSET (nil) case is derived — an explicit
    -- `header_air` / `footer_air` from the consumer still wins — and it re-derives whenever the ring changes, so
    -- turning the border on or off can never reintroduce the mismatch.
    local ring_top, ring_bottom = false, false
    for _, p in ipairs(panels) do
        local it, _, ib = util.insets(util.resolve_border(p.border or cfg.panel_border))
        ring_top = ring_top or it > 0
        ring_bottom = ring_bottom or ib > 0
    end
    if cfg.header_air == nil and ring_top then
        cfg.header_air = false
    end
    if cfg.footer_air == nil and ring_bottom then
        cfg.footer_air = false
    end
    -- Remembered on the cfg: `set_header` / `set_footer` rebuild their bands from the spec alone (a tab switch),
    -- and must trim the content-adjacent air exactly like the open path does.
    cfg._ring_top, cfg._ring_bottom = ring_top, ring_bottom

    -- A FLOAT carries the brand as its border title (built in open_windows). A SPLIT has no border, so the
    -- title becomes the top CONTENT row of the chrome instead (the icon + text, flattened).
    -- The SURFACE owns the title-row air: when the title is a CONTENT row, IT adds the single air row below the
    -- title (the `elseif` branch) and suppresses build_bands' own header air, so a consumer never has to manage
    -- it and the result is exactly ONE blank row under the title — no matter what `header_air` the consumer set.
    local row_title = cfg.mode ~= "split" and cfg.title_line == "row" and cfg.title and cfg.title ~= ""
    -- (NB: `row_title and false or cfg.header_air` is the Lua ternary trap — `and false` always falls through to
    -- the `or`; use an explicit guard so the row-title genuinely suppresses build_bands' own header air.)
    local header_air = cfg.header_air
    if row_title then
        header_air = false
    end
    local hbands = build_bands(cfg.header, false, header_air)
    if cfg.mode == "split" then
        local t = cfg.title
        -- UPPERCASE the title text (the canon), keep the icon glyph
        local s
        if type(t) == "table" then
            s = (t.icon and t.icon .. " " or "") .. (t.text and tostring(t.text):upper() or "")
        else
            s = t and tostring(t):upper() or ""
        end
        if s ~= "" then
            table.insert(hbands, 1, { meta = s, hl = "LvimUiPeekTitle" })
        end
    elseif row_title then
        -- The title (+ counter) as the FIRST content rows — a `title_counter` band + air row, drawn from column
        -- 0 (flush-left; the native border-title reserves a 1-col corner margin). build_border_title returns nil
        -- for "row", so the title is NOT also on the border; `set_title`/`set_counter`/`set_header` re-render this
        -- band. Built by row_title_bands so `set_header` (a tab switch) re-prepends the SAME title.
        local tb = row_title_bands(cfg)
        if tb then
            for i = #tb, 1, -1 do
                table.insert(hbands, 1, tb[i])
            end
        end
    end

    -- An explicit `header_air = true`, the row title's OWN air row, or a consumer's `{ text = "" }` band can all
    -- leave a blank band touching the (ringed) content — trim_air drops exactly that one.
    trim_air(hbands, ring_top, false)

    local state = {
        cfg = cfg,
        -- Where focus RETURNS when the frame closes. Normally the window that was current at open — but a
        -- consumer may name it (`cfg.origin`), and it must: a popup opened from ANOTHER frame's callback (the
        -- calendar's month picker → its year input) opens while the first frame is already tearing down, so
        -- "the current window" is whatever the teardown happened to leave behind — the editor. The chain then
        -- dumps the user out of the panel they were working in.
        origin = cfg.origin or api.nvim_get_current_win(),
        -- The tabpage the frame lives on. The focus TRAP is scoped to it (see the WinEnter hook): a modal
        -- popup owns its own screen, never another tab's.
        tabpage = api.nvim_get_current_tabpage(),
        panels = panels,
        header_bands = hbands,
        footer_bands = (function()
            local fb = build_bands(cfg.footer, true, cfg.footer_air)
            trim_air(fb, ring_bottom, true)
            return fb
        end)(),
        -- hotkey bookkeeping (map_hotkeys / remap_hotkeys): the (buf, reserved) targets, the keys each
        -- buffer currently carries, and which buffers are <Nop>-locked (a stale hotkey restores the <Nop>)
        _hotkey_targets = {},
        _hotkey_mapped = {},
        _locked = {},
    }
    state.close = function()
        close(state)
    end
    -- (SINGLE AREA OCCUPANT) A cmdline dock that HOSTS in the zone (auto-host `host == nil`, or an explicit host
    -- fn) is the ONE app the zone holds at a time: opening a new one EVICTS the previous (a picker gives way to a
    -- shell, and back). EXCLUDE `host == false` — that is the msgarea zone's OWN surface, which merely GROWS
    -- cmdheight for the zone and must never be treated as an occupant (evicting it would tear down the zone). The
    -- picker also self-replaces finder→finder via its own registry; this is the cross-consumer safety net.
    if cfg.position == "cmdline" and cfg.host ~= false then
        if area_current and area_current ~= state and not area_current._closed and area_current.close then
            pcall(area_current.close)
        end
        area_current = state
    end
    -- (AUTO-HOST area dock) A `position = "cmdline"` surface with NO explicit `host` auto-homes itself in the
    -- msgarea zone when that zone is enabled: the ENGINE (not the consumer) creates the reserve segment, derives
    -- the stacked-row count from `preview_side`, and wires the descend + reflow-follow. So a consumer only asks
    -- for `position = "cmdline"` — the zone owns the HEIGHT (its `reserve` clamps to `max_height * rows`) and the
    -- placement; nobody passes a host. A consumer that DOES pass its own `cfg.host` still wins (this fills the
    -- gap only). Hosting must sit ABOVE the zone's own panels (~200), so force the container zindex to 210 — a
    -- hostless `cmdline` dock left at a lower zindex renders BEHIND the zone (mis-placed, half-height). The
    -- closures read state.reposition / state.focus_sector / state.preview_side LAZILY (assigned in open_windows,
    -- below), so at the initial reserve they may be nil — the guarded calls simply no-op until they exist.
    -- Ask the registered host provider (the msgarea zone) to home this cmdline dock in its zone. The provider
    -- returns a `host` fn + a `release` closure (or nil to skip); the surface engine stays zone-agnostic.
    -- Hosting must sit ABOVE the zone's own panels, so force zindex 210 when a host is supplied.
    if cfg.position == "cmdline" and cfg.host == nil and host_provider then
        local bind = host_provider(state, cfg)
        if bind and bind.host then
            cfg.zindex = 210
            cfg.host = bind.host
            state._host_release = bind.release
            -- Descend into the zone below the dock (a consumer's explicit on_escape_below still wins).
            if cfg.on_escape_below == nil then
                cfg.on_escape_below = bind.on_escape_below
            end
        end
    end
    -- A `native` split is a REAL window (not a float over a container) — for a navigable persistent side
    -- panel; everything else (modal float, docked-modal peek) uses the float chassis.
    if cfg.mode == "split" and cfg.native then
        open_native_split(state)
    elseif cfg.host then
        -- HOSTED in the zone: open inside the zone's reflow-coalescing handoff, so the whole open — the segment
        -- reserve, the cmdheight growth it causes, every window placement — paints as ONE frame. Without it the
        -- editor watched the zone climb through the intermediate heights of a half-built frame (measured: 1 → 2
        -- → 7 → 31 rows), which is the flicker on opening a docked panel. The pickers did this by hand around
        -- their own open; doing it HERE gives it to every hosted surface, and a consumer that already wraps its
        -- open in a handoff just nests (the zone counts the batch depth).
        M.zone_handoff(function()
            open_windows(state)
        end)
    else
        open_windows(state)
    end
    return state
end

--- Register the auto-host provider for `position="cmdline"` surfaces — called ONCE by the msgarea zone so
--- the surface engine can home a cmdline dock in the zone without ever requiring it (inverted dependency).
--- `fn(state, cfg)` returns `{ host, release }` — the `host` reserve function + a teardown closure — or nil
--- to skip hosting (the dock then grows cmdheight on its own).
---@param fn lvim-ui.HostProvider
function M.set_host_provider(fn)
    host_provider = fn
end

--- Register the host zone's hooks (msgarea calls this once). See `M.zone_handoff`.
---@param hooks { handoff?: fun(fn: fun()) }
function M.set_zone_hooks(hooks)
    zone_hooks = hooks
end

--- Run `fn` inside the host zone's reflow-coalescing handoff when a zone is registered (so a docked
--- consumer's teardown+rebuild paints as ONE frame), else just run `fn`. Lets a consumer (a docked picker)
--- coalesce a zone swap without requiring msgarea — the dependency stays inverted.
---@param fn fun()
function M.zone_handoff(fn)
    if zone_hooks and zone_hooks.handoff then
        zone_hooks.handoff(fn)
    else
        fn()
    end
end

return M
