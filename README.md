# lvim-ui

The floating UI toolkit of the **lvim-tech** set — the surface/frame/button/bar chassis and a thin presenter
(`select` / `multiselect` / `input` / `confirm` / `tabs` / `info`). Every other lvim-tech plugin that draws a
window (pickers, the message zone, the control center, LSP peeks) builds on it, so the whole set frames
identically. It is a pure toolkit: it renders windows; it owns no feature of its own.

## Requirements

Requires **Neovim >= 0.12.x** and [lvim-utils](https://github.com/lvim-tech/lvim-utils) (palette / highlight /
cursor / merge helpers). [lvim-hud](https://github.com/lvim-tech/lvim-hud) is optional — a surface title can
publish to the statusline overlay when it is present.

## Installation

### lvim-installer (recommended)

Open the **Plugins** tab and install / update / pin it:

```vim
:LvimInstaller plugins
```

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
})
require("lvim-ui").setup({})
```

## Usage

```lua
local ui = require("lvim-ui")

ui.select({ title = "Pick", items = { "one", "two" } }, function(ok, index) end)
ui.multiselect({ title = "Toggle", items = { "a", "b" } }, function(ok, selected) end)
ui.input({ title = "Name" }, function(ok, value) end)
ui.confirm({ title = "Delete?" }, function(yes) end)
ui.tabs({ title = "Settings", tabs = {} }, function(ok, result) end)
local win = ui.info({ "read-only", "text" }, { title = "Info" })
local tree = ui.tree({ root = nodes }) -- shared tree content layer (see below)
```

`ui.tabs` can additionally host a PREVIEW panel beside the tab content: pass `preview = <provider>` (a
surface content provider, typically built on `require("lvim-ui.preview").new({ item = … })`) and an optional
`preview_side = "right"|"left"|"above"|"below"`. The block plugs into the chassis preview machinery — `<Tab>`
/ `<C-l>` move between the panels, `<C-e>` hides the preview, `<C-n>`/`<C-p>` rotate its side.

The low-level chassis is `require("lvim-ui.surface")` (framed floating/docked windows) with
`require("lvim-ui.button")` / `require("lvim-ui.bar")` for navigable button bars.

### Mouse

Every keyboard-activated element is also a **left-click** target — a click does exactly what pressing its key
does, and the keyboard behaviour is unchanged (click is purely additive; it is a no-op while `'mouse'` is
empty). This is built into the primitives, so it applies to every consumer automatically:

- **Header / footer / tab / filter bars** — click a button to fire it; click a tab header to switch to it;
  click a filter chip to apply it. Hit-testing uses the bar's own rendered spans, so a click that misses every
  button is ignored (it never steals the click).
- **`select` / `multiselect` lists** — click a row to focus it and confirm (`select`) or toggle its checkbox
  (`multiselect`), exactly as `<CR>` / `<Space>` do on the focused row.
- **`tabs` / form rows** — click a settings row to activate it per its type: toggle a boolean, cycle a
  select, expand an accordion section, run an action / menu item, or open the value editor for a text/number
  field. Click a toolbar-row button to run it.
- **`tree` rows** — click a row to select + activate it (open the file / jump to the symbol; a collapsed
  foldable node expands first); click the fold chevron — or double-click anywhere on the row — to toggle the
  fold.

The only element WITHOUT click support is the `menu` primitive (see below): it is a non-focusable, passive
overlay driven from insert mode, so it has no window to route a click to — accepting a completion stays a
keyboard action, by design.

### The `menu` primitive (cursor-anchored, non-focusable)

`ui.menu(opts)` creates the PASSIVE popup primitive — a completion-menu window redrawn per keystroke while
focus stays in the editing buffer (insert mode). Unlike every modal above it has no sectors, no close keys and
no cursor hiding: the consumer (e.g. **lvim-cmp**) drives the returned handle from its own machinery.

```lua
local menu = require("lvim-ui").menu({
    max_height = 12, -- visible rows cap (longer lists scroll)
    max_width = 60, -- content width cap (cells)
    min_width = 0, -- content width floor
    col_offset = 0, -- shift vs the anchor col (e.g. minus a lead box width)
    direction_priority = { "s", "n" }, -- below / above, tried in order
    scrollbar = true, -- right-edge thumb when overflowing
    zindex = 65,
    docs = { max_width = 80, max_height = 20 }, -- the sibling docs slot caps
})

-- rows are BOX lists: lead box + label + right-aligned detail; `positions` is a LAZY
-- matched-char callback the decoration provider calls only for VISIBLE rows; a box
-- with its OWN bg passes `sel_hl` — the group used while its row is SELECTED, so it
-- re-tints against the selection bar instead of punching a hole in it. A ROW may also
-- carry `hl` (a full-row background) and `sel_hl` (its background while selected, used
-- instead of the shared selection group) — e.g. to tint each row by its category.
menu.show({
    items = {
        {
            hl = "MyKindRow", -- full-row background (rest)
            sel_hl = "MyKindRowSel", -- full-row background while this row is selected
            boxes = {
                { text = " 󰊕 ", hl = "MyKindChip", sel_hl = "MyKindChipSel" },
                {
                    text = "read_file",
                    positions = function()
                        return { 1, 2, 6 }
                    end,
                },
                { text = " detail ", hl = "Comment", right = true },
            },
        },
    },
    anchor = { lnum = 10, col = 4 }, -- the matched keyword's START (no-shift while typing)
    selected = 1, -- preselect (nil = none)
})
menu.update(items, selected) -- per-keystroke re-rank (same anchor)
menu.move(anchor) -- re-anchor (new context)
menu.select(2) -- selection = full-row bg (persistent line highlight; auto-scrolls)
menu.select_move(1) -- wraps
menu.docs_show({ "docs…" }, { filetype = "markdown" }) -- the docked docs sibling
menu.docs_hide()
menu.docs_scroll(3) -- scroll the docs sibling by screen lines (< 0 = up)
menu.hide() -- keep the long-lived buffer
menu.close() -- destroy the handle
```

One long-lived window/buffer per handle (`focusable = false`, `noautocmd`, repositioned — never recreated);
all row colours (box highlights, matched chars, the scrollbar) are EPHEMERAL decoration-provider extmarks on
visible lines only. The window flips above the cursor near the screen edge per `direction_priority`. The docs
sibling docks FLUSH beside the menu (east, flipping/shrinking west near the edge) behind the canonical
inter-panel divider (`config.separator`, the same `│` rule the surface chassis draws between side-by-side
panels — no see-through gutter between the two panels). Groups: `LvimUiMenuNormal` / `Sel` / `Match` /
`Detail` / `Thumb` / `Track` (palette-bound; the selection bar and scrollbar tint over the PANEL shade).

### The `tree` primitive (shared tree panels)

`ui.tree(opts)` creates the generic node-provider TREE — the ONE content layer every lvim-tech tree panel
renders through (the lvim-files file tree, the lvim-lsp outline, and any future drawer/scopes panel), instead
of each hand-rolling fold state + indent guides + markers + extmarks on the surface. The tree is ONLY the
content: the handle's `tree.provider` is a surface content provider you plug into your own `surface.open`
(a persistent native split, a modal float, a provider tab) — the chassis keeps owning the window, dock,
cursor hiding, footer and teardown.

```lua
local tree = require("lvim-ui").tree({
    -- the node contract (lazy or eager children):
    root = {
        {
            id = "src", -- STABLE id: fold state / focus / mark are keyed by it
            label = "src",
            icon = "",
            icon_hl = "Directory",
            expandable = true, -- chevron before children are known (a lazy dir)
            children = function(node) -- called only while EXPANDED, per render
                return load_children(node)
            end,
            badges = { { "M ", "DiffAdd" } }, -- right-aligned virt-text cells
            data = anything, -- your payload, returned by selected()
        },
        { id = "file", label = "init.lua", detail = "1.2k", actions = { d = delete_node } },
    },
    default_expanded = false, -- true = an outline (nodes start unfolded)
    connectors = false, -- ├/└ on leaf rows (the outline look)
    elide_guides = true, -- stop the │ guide below a last child (false = solid)
    margin = 0, -- lead spaces
    icons = { fold_open = "", fold_closed = "", guide = "│", branch = "├", branch_last = "└" },
    hl = { guide = "…", fold = "…", detail = "…", mark = "…", empty = "…", thumb = "…", track = "…" },
    empty = " No entries",
    header = function(width) -- static rows ABOVE the tree (e.g. a root band);
        return { " ~/project" }, { { 0, 0, -1, "Title" } } -- the cursor is kept off them
    end,
    filetype = "my-panel", -- stamped on the buffer (cursor panel_ft registration)
    scrollbar = true, -- right-edge thumb when the tree overflows
    keys = { activate = { "l", "<CR>" }, collapse = "h" }, -- the canonical defaults (false = none)
    on_activate = function(node, t) end, -- l/<CR>/click on a leaf or an expanded node
    on_expand = function(node, t) end, -- lazy loads / watchers go here
    on_collapse = function(node, t) end,
    on_keys = function(map, pan, st, t) end, -- your own buffer keymaps (override on clashes)
    on_render = function(t) end, -- after every repaint (live footers/counters)
})

require("lvim-ui.surface").open({
    mode = "split",
    native = true,
    dock = "left",
    persistent = true,
    content = { blocks = { { id = "tree", provider = tree.provider } } },
})
```

The handle: `set_root(nodes | node | fun(): nodes)` (a FACTORY root is re-run per render — live
re-decoration), `render()` (sync), `refresh()` (coalesced), `selected()`, `node_at(line)`, `row_of(id)`,
`visible()`, `focus(id)`, `expanded(id)`, `expand(id)` / `collapse(id)` / `toggle(id)`, `expand_all()` /
`collapse_all()` / `all_expanded()`, `set_expanded(map)` (bulk fold replace — accordion/auto-fold),
`expanded_state()`, `get(id)`, `mark(id, { move_cursor })` (the follow-row tint), `expand_or_activate()` /
`collapse_or_parent()` (the canonical `l`/`h`, exposed for consumer keymaps), `buf()`, `win()`, `valid()`.

Built in, identically for every consumer: the canonical keys (`l`/`<CR>` expand-or-activate, `h`
collapse-or-parent), per-node `actions` bound lazily as they appear (a consumer's own key wins), the mouse
canon (row click = select + activate, chevron click / double-click = fold toggle; through the chassis
`on_click` seam in hide-cursor modals), a right-edge scrollbar (the menu's ephemeral decoration-provider
canon), and the `mark` row an outline uses to follow the source cursor. Groups: `LvimUiTreeGuide` / `Fold` /
`Detail` / `Mark` / `Empty` / `Thumb` / `Track` (palette-bound; per-tree overrides via `hl`).

## Configuration

`setup()` merges your options into the live config in place — every reader (`require("lvim-ui.config")`) sees
the effective values, and it is optional (the defaults below work as-is). The full default config:

```lua
require("lvim-ui").setup({
    -- Container frame border: "none" (no outer ring) or an 8-element ring { tl,t,tr,r,br,b,bl,l }.
    border = "none",
    -- Per-content-panel border drawn around each data block ("none" or an 8-element ring).
    content_border = "none",
    -- Inter-panel divider between adjacent content panels (auto-oriented: h = side-by-side, v = stacked);
    -- false disables it, a plain string is used for both axes.
    separator = { h = "│", v = "─", hl = "LvimUiPeekBorder" },
    -- Common ring around the data panels as a group (8-element; false disables it).
    group_border = { "", "", "", "", "", "", "", "", hl = "LvimUiPeekBorder" },
    -- Highlight group for the inter-panel divider.
    separator_hl = "LvimUiPeekBorder",
    -- Overflow-chevron glyphs a bar shows at its edges when its buttons don't all fit.
    chevrons = { left = "❮", right = "❯" },
    -- Shared surface geometry per layout. height/width = fraction 0.1–1.0; *_auto = fit-to-content up to that
    -- fraction (cap) when true, exact fraction when false. auto_hide / keep_focus are per-layout behaviour.
    size = {
        float = { height = 0.85, width = 0.8, height_auto = false, width_auto = false, auto_hide = true },
        area = { height = 0.5, height_auto = false, auto_hide = false, keep_focus = true },
        bottom = { height = 0.4, height_auto = false, auto_hide = false, keep_focus = true },
    },
    -- Per-layout dim/darken veil behind an open surface. enabled = false → no veil; hl = darken colour;
    -- blend = winblend 0–100 (how much shows through: low = strong darken, high = light haze).
    backdrop = {
        float = { enabled = true, blend = 85, hl = "LvimUiBackdrop" },
        area = { enabled = true, blend = 85, hl = "LvimUiBackdrop" },
        bottom = { enabled = true, blend = 85, hl = "LvimUiBackdrop" },
    },
    -- Disable all completion sources (native / nvim-cmp / blink.cmp) for input popups.
    disable_completion = true,
    position = "editor", -- popup anchor
    width = 0.8, -- default popup width (fraction)
    max_width = 0.8, -- maximum popup width (fraction)
    height = 0.8, -- default popup height (fraction)
    max_height = 0.8, -- maximum popup height (fraction)
    max_items = 15, -- list rows shown before scrolling
    filetype = "lvim-utils-ui", -- filetype set on the popup buffer
    close_keys = { "q", "<Esc>" }, -- keys that close the popup
    -- Modal focus trap: while a centred float popup is open, focus cannot leave it — a <C-w> jump OR a
    -- mouse click on another window bounces straight back, so the only way out is the popup's own keys.
    -- Default true (every centred float is modal); docked / hosted panels coexist and never trap. Set
    -- false to disable globally, or per popup via that surface's own `trap_focus`.
    trap_focus = true,
    markview = false, -- markview rendering in the popup
    -- Title placement: "row" (a top content row) | "border" (native border-title) | "statusline" (overlay).
    title_line = "row",
    -- Where a supplied count renders: "title" (right of the title) | "footer" (bottom border-footer).
    counter = "title",
    -- Title alignment: "left" | "center" | "right".
    title_pos = "left",
    -- Background tint strengths (blend toward the bg) for themed chrome cells: strong = active, body = rest.
    tint = { strong = 0.2, body = 0.05 },
    -- Popup glyphs.
    icons = {
        bool_on = "󰄬",
        bool_off = "󰍴",
        select = "󰘮",
        number = "",
        string = "",
        action = "",
        spacer = "   ──────",
        multi_selected = "󰄬",
        multi_empty = "󰍴",
        current = "➤",
    },
    -- Footer-legend action labels.
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
    -- Popup + chassis navigation keys (vim notation; each value is a string or a list of strings).
    keys = {
        down = "j",
        up = "k",
        confirm = "<CR>",
        cancel = "<Esc>",
        close = "q",
        sector_next = "<C-j>", -- header · center · footer (down); the preview is skipped
        sector_prev = "<C-k>", -- (up)
        panel_toggle = "<Tab>", -- toggle the center panel (list ⇄ preview)
        panel_next = "<C-l>", -- next center panel
        panel_prev = "<C-h>", -- previous center panel
        menu_prev = { "h", "<Left>" }, -- move within a focused button bar
        menu_next = { "l", "<Right>" },
        menu_confirm = { "<CR>", "<Space>" },
        zone_escape = { "<C-k>", "<C-w>k" }, -- leave the message zone when focused in it
        tabs = { next = "l", prev = "h" },
        select = { confirm = "<CR>", cancel = "<Esc>" },
        multiselect = { toggle = "<Space>", confirm = "<CR>", cancel = "<Esc>" },
        list = { next_option = "<Tab>", prev_option = "<BS>" },
    },
})
```

### Chrome that used to be hardcoded

Everything the UI *shows* is now config, not code — the primitives read their glyphs, colours and
strengths from `lvim-ui.config` (and the shared scale from `lvim-utils`'s `ui` spec):

```lua
require("lvim-ui").setup({
    -- The TREE primitive (the file tree, the LSP outline, the db drawer, the debug scopes)
    tree = {
        padding = { left = 1, right = 1 },
        scrollbar = false,
        icons = { fold_open = "", fold_closed = "", guide = "│", branch = "├", branch_last = "└" },
        -- each role: `accent` (a palette key or "#rrggbb") + `tint` (blended toward the panel)
        colors = {
            guide = { accent = "fg_dark", tint = 0.6 },
            fold = { accent = "blue" },
            detail = { accent = "comment" },
            mark = { accent = "blue", tint = 0.16 }, -- the "follow" row (an outline's current symbol)
            empty = { accent = "comment" },
            thumb = { accent = "blue", tint = 0.5 }, -- the scrollbar
            track = { accent = "blue", tint = 0.1 },
        },
    },
    -- The MENU primitive (the completion / candidate list)
    menu = {
        colors = {
            selection = { accent = "blue", tint = 0.4 }, -- bg-only, so each row keeps its own fg colours
            match = { accent = "red" },
            detail = { accent = "comment" },
            thumb = { accent = "blue", tint = 0.5 },
            track = { accent = "blue", tint = 0.1 },
        },
        separator = "│",
    },
    -- The 8 border characters nvim wants, clockwise from the top-left. A surface names a preset.
    borders = {
        rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
        single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
        double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
        none = { "", "", "", "", "", "", "", "" },
    },
    text = { ellipsis = "…" }, -- what a clipped row ends with
    -- The form's key-hint legend: the KEYS as the user sees them + their labels
    form_hints = {
        activate = "↵",
        next = "↵/→",
        prev = "⌫/←",
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
})
```

## License

BSD-3-Clause.
