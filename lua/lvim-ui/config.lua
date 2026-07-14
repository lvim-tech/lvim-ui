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
---@field hint               LvimUiHintConfig     Defaults for the shared `lvim-ui.hint` bar (a sub-mode's live key row)

---@class LvimUiHintConfig
---@field align         "left"|"center"|"right"  Item alignment inside the full-width row
---@field default_style string                   The ui.surface button KIND a hint record with no `style` uses
---@field fill_hl       string                   The continuous full-width strip under the items
---@field zindex        integer                  Window stack position of the hint row
---@field filetype      string                   Filetype set on the hint buffer

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
    -- "center" (the default — every framed window in the set centres its title), "left" (flush-left, counter
    -- flush-right) or "right". A single `surface.open` may override per-open with its own `title_pos`.
    -- NOTE the mechanisms differ: a content-ROW title is drawn by us and centres exactly, while Neovim's
    -- native BORDER-title rounds to `floor(free/2) + 1` — always a cell right of true centre. That is why the
    -- set's windows use the title row.
    title_pos = "center",

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
        -- The tree's chrome glyphs (Nerd Font carets + box-drawing guides). A consumer may still override
        -- them per-tree; these are what it gets when it does not.
        icons = {
            fold_open = "\u{f0d7}", --  nf-fa-caret_down
            fold_closed = "\u{f0da}", --  nf-fa-caret_right
            guide = "│", -- the ancestor indent column
            branch = "├", -- a leaf with siblings below it (connectors mode)
            branch_last = "└", -- the last leaf
        },
        -- The tree's OWN highlight roles. `accent` = the palette key (or "#rrggbb"); `tint` = how far it is
        -- blended toward the panel it sits on (the same scale as the shared chrome — see lvim-utils ui.tint).
        -- The guide is a fg blend, not a background.
        colors = {
            guide = { accent = "fg_dark", tint = 0.6 }, -- the │ indent guides + ├/└ connectors
            fold = { accent = "blue" }, -- the open/closed chevron (fg only)
            detail = { accent = "comment" }, -- the dim eol detail text
            mark = { accent = "blue", tint = 0.16 }, -- the MARKED (follow) row — an outline's current symbol
            empty = { accent = "comment" }, -- the "no entries" placeholder
            thumb = { accent = "blue", tint = 0.5 }, -- the scrollbar thumb
            track = { accent = "blue", tint = 0.1 }, -- its track
        },
    },

    -- ── The MENU primitive (the completion / candidate list) ─────────────────────────────────────────────
    -- A coloured cell is its own accent tinted toward the surface it SITS ON — for the menu that surface is
    -- the PANEL, never the editor bg (which may be lighter or darker and would make the cell read as a
    -- foreign patch). The selection is BG-ONLY, so each row's own fg colours (kind boxes, match chars)
    -- survive it.
    menu = {
        colors = {
            selection = { accent = "blue", tint = 0.4 }, -- the selected row (bg only)
            match = { accent = "red" }, -- the matched characters (bold)
            detail = { accent = "comment" }, -- an item's dim detail column
            thumb = { accent = "blue", tint = 0.5 }, -- the scrollbar thumb
            track = { accent = "blue", tint = 0.1 }, -- its track
        },
        separator = "│", -- the default glyph between menu groups (a consumer may pass its own)
    },

    -- ── Border presets ──────────────────────────────────────────────────────────────────────────────────
    -- The 8 characters nvim wants, clockwise from the top-left. A surface names one of these (`border =
    -- "rounded"`) or passes its own 8-element table.
    borders = {
        rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
        single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
        double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
        none = { "", "", "", "", "", "", "", "" },
    },

    -- ── Text chrome ─────────────────────────────────────────────────────────────────────────────────────
    text = {
        ellipsis = "…", -- what a clipped row ends with (its width is reserved before clipping)
    },

    -- ── The NON-FOCUSABLE hint BAR (lvim-ui.hint) ───────────────────────────────────────────────────────
    -- The full-width row a modal SUB-MODE (an interactive resize / move loop) pins above the statusline to
    -- announce its live keys. Its items are ordinary bar records, so only the row's own chrome is set here.
    hint = {
        align = "center", -- item alignment inside the row
        default_style = "action", -- the ui.surface button KIND a record with no `style` uses (key badge + label)
        fill_hl = "LvimUiBarFill", -- the continuous strip under the items (the buttons paint over it)
        zindex = 70, -- above the ordinary floats, below the message zone
        filetype = "lvim-ui-hint", -- the hint buffer's filetype
    },

    -- ── The FORM's key-hint legend (the footer line that follows the focused row) ────────────────────────
    -- Each row TYPE advertises what its keys do. The glyphs are the KEYS themselves as the user sees them,
    -- so they belong to the presentation, not to the logic.
    form_hints = {
        activate = "↵", -- <CR> on the focused row
        next = "↵/→", -- cycle a select/segmented row forward
        prev = "⌫/←", -- and back
        labels = {
            expand = "Expand",
            collapse = "Collapse",
            next = "Next",
            prev = "Prev",
            toggle = "Toggle",
            run = "Run",
            edit = "Edit",
        },
    },
}
