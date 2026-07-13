-- lvim-ui.config: the live config for the lvim-ui windowed-UI chassis — frame borders, the popup icons /
-- labels / keys, the tint strengths, and the two-pane peek navigator. (Surface GEOMETRY + BACKDROP per layout
-- are NOT here — they live in the single central authority `lvim-utils.config.dock.geometry`, read at open time
-- via `lvim-ui.surface.size_spec(layout)` and `lvim-utils.dock.slot(layout)`.) These are
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
---@field disable_completion boolean              Disable all completion sources (native, nvim-cmp, blink.cmp) for input popups
---@field position           string               Popup anchor ("editor")
---@field max_items          integer              Maximum list rows shown before scrolling (content-fit list cap)
---@field filetype           string               Filetype set on the popup buffer
---@field close_keys         string[]             Keys that close the popup
---@field markview           boolean              Enable markview rendering in the popup
---@field icon_provider       string               File-icon provider for previews: "auto"|"lvim"|"devicons"|"mini" (via lvim-utils.icons)
---@field icon_color_mode     string?              lvim-icons colour mode for the preview icon: "theme"|"brand"|"theme_brand"; nil = the lvim-icons default
---@field title_line         string               Where a frame's title goes: "row" | "border" | "statusline"
---@field counter            string               Where a supplied count renders: "title" | "footer"
---@field title_pos          string               Title alignment: "left" | "center" | "right"
---@field tint               table                Background tint strengths (strong / body) for the themed chrome cells
---@field icons              table                Glyphs for the popup (booleans, select, kinds, markers, current pointer)
---@field labels             table                Footer-legend action labels (navigate / confirm / cancel / …)
---@field keys               table                Popup + chassis navigation keys (vim notation; strings or lists)
---@field tree               LvimUiTreeConfig     Defaults for the shared `lvim-ui.tree` primitive (padding / scrollbar)

---@class LvimUiTreeConfig
---@field padding   { left?: integer, right?: integer }  Blank columns around the tree ROWS (the header/title band
---                 spans the full width and is never padded). When the scrollbar is shown, ONE more right column
---                 is reserved for the thumb, so it never sits on the content — and the reserve disappears again
---                 when the content fits. Consumers (the file tree, the LSP outline, …) may override per-tree.
---@field scrollbar boolean  Right-edge thumb while the content overflows the window (opt-in).

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
    -- Surface GEOMETRY and BACKDROP per layout (float / area / bottom) are NOT defined here — they live in the
    -- SINGLE central authority `lvim-utils.config.dock.geometry`, read live at open time by `lvim-ui.surface`
    -- through `lvim-ui.surface.size_spec(layout)` (size) and `lvim-utils.dock.slot(layout)` (backdrop). That is the
    -- one place control-center's "Utils" panel edits; keeping a second copy here would fork the source of truth.
    -- Disable all completion sources (native, nvim-cmp, blink.cmp) for input popups
    disable_completion = true,
    position = "editor",
    -- No `width/max_width/height/max_height`: a modal's OUTER (float) geometry now comes from the CENTRAL
    -- authority `lvim-utils.config.dock.geometry.float` (via `dock.slot` / the surface's derivation). Only the
    -- content-fit list cap stays here.
    max_items = 15,
    filetype = "lvim-utils-ui",
    close_keys = { "q", "<Esc>" },
    -- MODAL focus trap: while a CENTRED float popup/panel is open, focus cannot leave it — a `<C-w>` window
    -- jump OR a mouse click on another field bounces straight back into the frame, so the only way out is the
    -- popup's own keys (`q`/`<Esc>`/an action). Default true (every centred float is modal). A split, or a
    -- docked / hosted surface that means to coexist with the editor (it sets `host`/`position`/`on_escape_*`),
    -- never traps unless it passes `trap_focus = true` explicitly. Turn it off globally with `trap_focus = false`,
    -- or per popup via that surface's own `trap_focus`.
    trap_focus = true,
    markview = false,
    -- Which icon plugin supplies the preview winbar file icon (resolved through lvim-utils.icons):
    -- "auto" prefers lvim-icons, then nvim-web-devicons, then mini.icons, else no icon.
    icon_provider = "auto",
    -- lvim-icons colour mode for the preview icon (ignored by devicons/mini): "theme"|"brand"|
    -- "theme_brand". nil = lvim-icons' own default.
    icon_color_mode = nil,

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

    -- Defaults for the shared `lvim-ui.tree` primitive (the file tree, the LSP outline, any future tree panel).
    -- A consumer may override either per-tree; when it does not, THESE are what it gets.
    tree = {
        -- Blank columns around the tree ROWS. The header (a title band) is never padded — it spans the full
        -- width. When `scrollbar` is on, ONE more right column is reserved for the thumb, so the bar never sits
        -- on the content; the reserve disappears again when the content fits and no bar is drawn.
        padding = { left = 1, right = 1 },
        -- Right-edge thumb while the content overflows the window.
        scrollbar = false,
    },
}
