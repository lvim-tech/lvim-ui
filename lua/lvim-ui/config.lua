-- lvim-ui.config: the live config for the lvim-ui windowed-UI chassis — frame borders, surface geometry
-- per layout, the popup icons / labels / keys, the tint strengths, and the two-pane peek navigator. These are
-- THE single sources of truth read live at open time by every consumer (pickers, ui.tabs, lvim-lsp peeks, …),
-- so changing one key here re-frames them all on the next open. `setup()` merges the user's `ui = {…}` into
-- this table in place (via lvim-utils.utils.merge); readers `require("lvim-ui.config")`.
--
---@module "lvim-ui.config"

---@class LvimUiConfig
---@field border             string|string[]      Container frame border ("none" or an 8-element ring) — the single source for the outer frame
---@field content_border     string|string[]      Per-content-panel border ("none" or an 8-element ring) drawn around each data block
---@field separator          boolean|string|table Inter-panel divider between adjacent content panels ({ h, v, hl }; false to disable)
---@field group_border       string[]             Common ring around the data panels as a group (8-element; false to disable)
---@field separator_hl       string               Highlight group for the inter-panel divider
---@field chevrons           table                Overflow-chevron glyphs ({ left, right }) a bar shows when its buttons don't all fit
---@field size               table                Shared surface geometry per layout (float / area / bottom + auto_max)
---@field backdrop           table                Per-layout dim/darken veil behind an open surface ({ float, area, bottom } each { enabled, blend, hl })
---@field disable_completion boolean              Disable all completion sources (native, nvim-cmp, blink.cmp) for input popups
---@field position           string               Popup anchor ("editor")
---@field width              number               Default popup width (fraction of the editor)
---@field max_width          number               Maximum popup width (fraction)
---@field height             number               Default popup height (fraction)
---@field max_height         number               Maximum popup height (fraction)
---@field max_items          integer              Maximum list rows shown before scrolling
---@field filetype           string               Filetype set on the popup buffer
---@field close_keys         string[]             Keys that close the popup
---@field markview           boolean              Enable markview rendering in the popup
---@field title_line         string               Where a frame's title goes: "row" | "border" | "statusline"
---@field counter            string               Where a supplied count renders: "title" | "footer"
---@field title_pos          string               Title alignment: "left" | "center" | "right"
---@field tint               table                Background tint strengths (strong / body) for the themed chrome cells
---@field icons              table                Glyphs for the popup (booleans, select, kinds, markers, current pointer)
---@field labels             table                Footer-legend action labels (navigate / confirm / cancel / …)
---@field keys               table                Popup + chassis navigation keys (vim notation; strings or lists)

---@type LvimUiConfig
return {
    -- THE single source of truth for the windowed-UI frame CONTAINER border — "none": no outer frame at all.
    -- The title + counter live in a CONTENT row at the top (`title_line = "row"`), so no border-title is needed;
    -- the panels are framed by `group_border` and divided by `separator`. `ui.surface` binds its `FRAME_BORDER`
    -- marker to this value and resolves it LIVE at open time, so changing this ONE key re-frames every consumer
    -- (pickers, ui.tabs, lvim-lsp peeks, …) on the next open — no per-consumer edits. Any consumer may still
    -- pass its OWN `border` (an 8-element ring { tl,t,tr,r,br,b,bl,l }) — e.g. the image viewer's left/right " ".
    border = "none",
    -- THE single source of truth for the CONTENT-PANEL border — the per-panel ring drawn around EACH DATA block
    -- INSIDE the container (the picker's list + preview, lvim-space's list, the tabs content panel). The NAV
    -- bands (footer / filter / tab / search) are not content blocks and stay borderless. `ui.surface` binds its
    -- `CONTENT_BORDER` marker to this value and resolves it LIVE at open time, so changing this ONE key
    -- re-borders every content panel on the next open — independently of `border` (the container) and
    -- `group_border` (the common ring around the panel group). Set to `"none"` so the panels are BORDERLESS:
    -- the common `group_border` frames the two panels as a group and the `separator` divides them, so a second
    -- per-panel ring would just double the lines. Set to an 8-element ring to give each panel its own frame too.
    --   { topleft, top, topright, right, botright, bot, botleft, left }
    content_border = "none",
    -- THE single configurable source for the INTER-PANEL divider — the rule drawn BETWEEN adjacent content
    -- panels (a picker's list ↔ preview). The chassis reads it as the per-surface default, so changing it here
    -- re-divides every multi-panel surface on the next open. AUTO-ORIENTED: `h` is the glyph between side-by-side
    -- panels, `v` between stacked ones (a preview rotation flips it live); `hl` tints it (default the border
    -- tint, so it matches the rings). It only ever draws between panels (n-1 gaps), so a single-panel surface
    -- shows none. Set `separator = false` to disable the divider globally; a plain string is used verbatim for
    -- both axes; a surface may still override per-open (`separator = false` / a string / a { h, v } table).
    separator = { h = "│", v = "─", hl = "LvimUiPeekBorder" },
    -- THE single configurable source for the GROUP frame — a COMMON ring drawn around the DATA panels as a
    -- group (a picker's list + preview together), INSIDE the container but OUTSIDE the header / footer nav bands
    -- and air rows. It is the third, "unifying" ring: container (outer) › group (around the panels) › each
    -- panel's own `content_border`. Drawn ONLY when there are ≥2 content panels (a single panel needs no
    -- grouping). A 1-col gutter sits between the container and the group, and between the group and the panels,
    -- so no edge doubles. `hl` tints it like the other rings. Set `group_border = false` to disable it.
    --   { topleft, top, topright, right, botright, bot, botleft, left }
    group_border = { "", "", "", "", "", "", "", "", hl = "LvimUiPeekBorder" },
    -- The highlight group for that divider — default the blue-tinted peek border, so the rule matches the
    -- container / content rings. Override to restyle the divider everywhere.
    separator_hl = "LvimUiPeekBorder",
    -- THE shared OVERFLOW-CHEVRON glyphs — the ❮ ❯ a bar shows at its edges when its buttons don't all fit (tab
    -- bars, action footers, the tabs legend). ONE source, so every overflowing bar marks its hidden items with the
    -- SAME glyphs; each consumer keeps its own chevron COLOUR (its own highlight group). Consumers pair the glyphs
    -- with their colour via `surface.chevrons(hl)`. Set e.g. `{ left = "‹", right = "›" }` to restyle them all.
    chevrons = { left = "❮", right = "❯" },
    -- Shared surface GEOMETRY per LAYOUT — the SINGLE source read by every consumer (pickers, ui.tabs,
    -- lvim-shell, lvim-space) via `require("lvim-ui").size(layout)`, and edited live by lvim-utils' own
    -- config panel + lvim-control-center (persisted through the shared store, so both stay in sync).
    --   height / width — always a FRACTION 0.1–1.0 of the available space (a concrete number, never "auto").
    --   height_auto / width_auto — a boolean PER DIMENSION: false → the axis is EXACTLY the fraction (fixed);
    --                     true → the axis AUTO-FITS its content, with the fraction used as the MAX cap. Width
    --                     and height are independent (e.g. a float can fixed-width + auto-height).
    --   float  — a centred float: height AND width (each with its own `*_auto`).
    --   area   — the msgarea/cmdline dock (editor + statusline stay above it): height only (full-width).
    --   bottom — a plain bottom float dock: height only (full-width).
    -- The `area` height is the TOTAL dock height (drives the msgarea reserve cap); a STACKED preview SPLITS it
    -- (preview keeps its content-fit height, the list takes the rest) so the dock never exceeds it. Defaults are
    -- FIXED (auto off) — a full-bleed terminal / form has no content height to fit, so auto would collapse it;
    -- turn an axis's `*_auto` on for content that should shrink to fit (a short list) up to that cap.
    --
    -- Two per-layout BEHAVIOUR flags also live here (edited from the same panels):
    --   auto_hide  — close the surface when a file is opened FROM it. `float` closes (a modal is one-shot);
    --                `area`/`bottom` DON'T (a dock stays so you can open more). The dock is NOT torn down — the
    --                tool (which exits on select) is restarted IN PLACE, so the frame never flickers.
    --   keep_focus — after opening a file from an area/bottom dock that stayed, keep focus IN the dock (default)
    --                so you keep selecting, or move it to the opened file (false). Irrelevant to `float`.
    size = {
        float = { height = 0.85, width = 0.8, height_auto = false, width_auto = false, auto_hide = true },
        area = { height = 0.5, height_auto = false, auto_hide = false, keep_focus = true },
        bottom = { height = 0.4, height_auto = false, auto_hide = false, keep_focus = true },
    },
    -- The BACKDROP veil — a full-editor float drawn BEHIND an open surface so the rest of the editor dims, marking
    -- the surface as the focus. PER LAYOUT (3 independent settings), so each can dim differently (or not at all):
    --   enabled — false → no veil for that layout.
    --   hl      — the veil colour = the DARKEN amount: a dark bg group (LvimUiBackdrop, self-themed from the
    --             palette) darkens; a lighter/tinted group gives a softer haze.
    --   blend   — winblend 0–100 = the DIM amount: how much the editor SHOWS THROUGH. Low (30) → strong, near-
    --             opaque darken; high (75) → a light, smoky dim. So `hl` + `blend` together dial darken↔dim.
    -- A consumer may override its layout's veil per-open via `surface.open({ backdrop = { … } | false })`; absent →
    -- these defaults. The veil never takes focus and is torn down with the surface. `area`/`bottom` docks dim the
    -- editor ABOVE the dock (the dock stays bright on top).
    backdrop = {
        float = { enabled = true, blend = 85, hl = "LvimUiBackdrop" },
        area = { enabled = true, blend = 85, hl = "LvimUiBackdrop" },
        bottom = { enabled = true, blend = 85, hl = "LvimUiBackdrop" },
    },
    -- Disable all completion sources (native, nvim-cmp, blink.cmp) for input popups
    disable_completion = true,
    position = "editor",
    width = 0.8,
    max_width = 0.8,
    height = 0.8,
    max_height = 0.8,
    max_items = 15,
    filetype = "lvim-utils-ui",
    close_keys = { "q", "<Esc>" },
    markview = false,

    -- Shared chassis title/counter placement (a single `surface.open` may override either per-open):
    --   title_line — where a frame's TITLE goes: "row" (default — a CONTENT row at the top, drawn from column
    --                0 so the tinted title block is flush-left and the counter flush-right), "border" (the
    --                native LEFT-aligned border-title, which nvim insets 1 col for the corner), or "statusline"
    --                (publish to the chrome overlay, minibuffer style, suppressing both).
    --   counter    — where a supplied count (a frame's item / match total) renders: "title" (default —
    --                RIGHT-aligned on the same row/border as the title, so it reads "NAME …………… 8/62") or
    --                "footer" (a right-aligned native bottom border-FOOTER).
    title_line = "row",
    counter = "title",
    -- Title ALIGNMENT, shared by the content-row title (`title_line="row"`) AND the native border-title:
    -- "left" (default — flush-left, counter flush-right), "center", or "right". A single `surface.open` may
    -- override per-open with its own `title_pos`. Lets a panel (e.g. LvimControlCenter) center its title
    -- consistently without needing a border.
    title_pos = "left",

    -- Background tint strengths (blend factor toward c.bg) for the themed chrome cells,
    -- matching the notify/Messages look: `strong` paints prominent/active cells (title,
    -- active tab/button, key badge, active list row), `body` the secondary/inactive ones
    -- (subtitles, inactive, labels, the rest of the list). See config/highlight.lua.
    tint = {
        strong = 0.2,
        body = 0.05,
    },

    -- tab_hl, button_hl, footer_hl, item_hl, checkbox_hl have no defaults.
    -- When absent the rendering code falls back to the named LvimUi* groups.
    -- Set any of them in setup({ ui = { tab_hl = { active = { ... } } } })
    -- only when you want an inline HlDef instead of a named group.

    icons = {
        bool_on = "󰄬",
        bool_off = "󰍴",
        select = "󰘮",
        number = "",
        string = "",
        action = "",
        spacer = "   ──────",
        multi_selected = "󰄬",
        multi_empty = "󰍴",
        current = "➤",
    },

    labels = {
        navigate = "navigate",
        confirm = "confirm",
        cancel = "cancel",
        close = "close",
        toggle = "toggle",
        cycle = "cycle",
        edit = "edit",
        execute = "execute",
        tabs = "tabs",
    },

    keys = {
        down = "j",
        up = "k",
        confirm = "<CR>",
        cancel = "<Esc>",
        close = "q",

        -- ui.surface chassis NAVIGATION (the finder, the message zone, any windowed UI). Override globally,
        -- e.g. `setup({ ui = { keys = { sector_next = "<C-Down>" } } })`; a single surface can still override
        -- via its own `keys`. Each value is a lhs string OR a list of lhs strings.
        sector_next = "<C-j>", -- DOWN the vertical stack: header · center · footer (the preview is SKIPPED)
        sector_prev = "<C-k>", -- UP
        panel_toggle = "<Tab>", -- toggle the center panel (list ⇄ preview) — the only way onto the preview
        panel_next = "<C-l>", -- next center panel (right) — e.g. list → preview
        panel_prev = "<C-h>", -- previous center panel (left)
        menu_prev = { "h", "<Left>" }, -- move the selection within a focused button bar
        menu_next = { "l", "<Right>" },
        menu_confirm = { "<CR>", "<Space>" }, -- activate the focused button
        zone_escape = { "<C-k>", "<C-w>k" }, -- leave the message zone (blur back up) when focused in it

        tabs = {
            next = "l",
            prev = "h",
        },

        select = {
            confirm = "<CR>",
            cancel = "<Esc>",
        },

        multiselect = {
            toggle = "<Space>",
            confirm = "<CR>",
            cancel = "<Esc>",
        },

        list = {
            next_option = "<Tab>",
            prev_option = "<BS>",
        },
    },
}
