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

`ui.input` takes `height > 1` for a multiline field (Enter inserts a newline, `<C-s>` confirms),
`filetype` to highlight the value, and `completion = "<kind>"` — any `getcompletion()` kind, e.g.
`"file"` or `"dir"` — which makes `<Tab>` complete the value in place: one candidate is inserted,
several extend to their longest common prefix and then list.

`ui.tabs` can additionally host a PREVIEW panel beside the tab content: pass `preview = <provider>` (a
surface content provider, typically built on `require("lvim-ui.preview").new({ item = … })`) and an optional
`preview_side = "right"|"left"|"dynamic"` (`"hide"` starts it parked — see below). The block plugs into the chassis preview machinery — `<Tab>`
/ `<C-l>` move between the panels, `<C-e>` hides the preview, `<C-n>`/`<C-p>` rotate its side, and
`<C-d>`/`<C-u>` scroll it half a screen **without leaving the list** — a preview panel hides its
cursor, so this is the only way to read past its first screen without spending a `<Tab>`.

A surface with a preview block can also **dock or park it from code**, on a LIVE surface:
`st.set_preview_visible(visible, side?)` — idempotent (unlike the interactive `<C-e>` toggle) and
focus-neutral. It exists for a consumer that swaps the CONTENT of one surface between views where only some
views have a preview (lvim-space's files list vs its projects / workspaces / tabs lists): the preview panel
is built once at open — pass `preview_side = "hide"` to start parked — so a view change neither creates nor
destroys a window.

A TABBED panel reaches the same seam through its handle: `handle.set_preview_visible(visible, side?)`.
Pair it with `on_tab_change = function(index, id) … end` — a distinct event from `on_item_change`, which
is cursor movement: switching tabs need not move the cursor, so chrome that depends on WHICH tab is
shown must hang off the tab event or it lags a beat behind. lvim-vault uses both to park its location
preview on the Macros tab, whose rows are key sequences and have nothing to preview.

The low-level chassis is `require("lvim-ui.surface")` (framed floating/docked windows) with
`require("lvim-ui.button")` / `require("lvim-ui.bar")` for navigable button bars.

Three more presenters share the same chassis:

```lua
-- The keymap CHEATSHEET — the canonical `?` window. `items` are `{ key, description }` pairs already
-- resolved to the plugin's live keys; rows are a key box + a description box, striped, cursor hidden.
ui.help({ title = "lvim-x keys", items = { { "q", "close" }, { "<CR>", "open" } } })
--   opts: title?, items, close_keys?, width?, height?, footer? (a full frame footer spec; default a `q close` bar)

-- A COLLAPSIBLE SECTION HEADER row for a `tabs` form (an accordion whose children share one accent):
-- the band is `accent` tinted onto the bg, the label reads in the accent fg; the caller owns the caret box.
local row = ui.section({
    name = "local", icon = "▸", box_hl = "LvimVaultMarkLocal", label = "Local", accent = "blue",
    expanded = true, children = child_rows, count = #child_rows, -- count → "Local (3)"
})

-- An INSTANCE with per-open defaults: every option you pass is merged UNDER each call's opts (the call
-- wins); `highlights` is applied at once as a forced group registration. Returns bound
-- select / multiselect / input / confirm / tabs / info.
local mine = ui.new({ width = false, highlights = { LvimUiTitle = { fg = "#ff0000" } } })
mine.select({ title = "Pick", items = { "a", "b" }, callback = function(ok, i) end })
```

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

### The `hint` primitive (a sub-mode's live keys, non-focusable)

`ui.hint(opts)` creates the NON-FOCUSABLE key-hint BAR — one full-width row pinned above the statusline that
announces what the keys do while a modal SUB-MODE owns the keyboard (an interactive resize / move loop). It
is the sanctioned surface for "show the live keys" — never an `echo`, never a hand-rolled float.

```lua
local hint = require("lvim-ui").hint({ fill_hl = "MyPluginHintFill" })

hint:show({
    { name = "RESIZE", icon = "󰩨", style = "tab" },
    { key = "h", name = "left" },
    { key = "l", name = "right" },
    { type = "separator", text = "➤" },
    { name = "80 x 24", style = "plain" },
})
hint:update(items) -- same window, re-rendered (no flicker) — call on every state change
hint:hide() -- keep the handle
hint:close() -- destroy it
```

Focus never leaves the user's real window (the sub-mode's keys act ON it, and it repaints under an explicit
`redraw` inside a blocking `getcharstr`), so — like `menu` — this is a passive projection, not a chassis
modal. Its items are ordinary bar records rendered through `ui.surface.button` + `ui.bar`, so a hint key badge
is byte-identical to a footer one and the overflow chevrons come for free. Defaults (align, the button kind, the
fill strip, zindex, filetype) live in `config.hint`.

### The `title_band` primitive (the one title bar in the set)

`require("lvim-ui.bar").title_band(spec)` builds a TITLE BAND row. Every title bar in the set comes
from here, because the same band is PLACED in structurally different spots: a surface frame's chrome
row (a `title_counter` header band), a docked zone's per-segment content row (a zone stacks several
segments, each with its own title interleaved with the content, so those can never be frame chrome),
and a content row that also carries buttons (the `:Messages` filter bar). The builder owns everything
that makes a band a band:

- the strip has TWO depths — resting, and one step deeper while `focused`,
- the title text is fg-ONLY over that strip, so the row is one solid block at either depth,
- the title is UPPERCASE with a 1-cell gutter each side; a counter is a padded box flush right,
- a counter (or any buttons) anchors the title LEFT; a bare title honours `pos`.

It returns the row, its spans in BYTE columns, and the `fill` group for the full-row strip — the
caller places those however its own layer does (an eol extmark, a frame placement, …).

```lua
local band = require("lvim-ui.bar").title_band({
    text = "schoolexams ➤ questions",
    width = width,
    count = function()
        return "1-50/536"
    end,
    focused = true, -- deeper strip while this panel holds the cursor
})
-- band.line, band.spans ({ c0, c1, hl }), band.fill (the full-row strip group)
```

A band that names its own `fill_hl` without a `fill_hl_focus` keeps that one tint: a deeper variant
of an arbitrary group cannot be invented, and only the default pair is known here.

### The `winband` primitive (a button bar for a REAL window)

`require("lvim-ui.winband").attach(win, { items, side, align })` pins the canonical button BAR — a
`ui.bar` of `ui.button` chips on an `LvimUiBarFill` row — to an edge of a window the surface chassis
does NOT own: a genuine editable buffer in a tiled window (lvim-db's query editor), or a window
Neovim itself opens and closes (the quickfix window, whose buffer must stay the real
`buftype=quickfix` one).

`side` picks the edge, and the two differ in what they cost the host:

- **`"bottom"`** (default) rides the host's last text row, so the host keeps `scrolloff >= 1` and the
  cursor line can never sit under the bar;
- **`"top"`** rides the host's **winbar** row — chrome, not text — so it costs the host no line at
  all: nothing scrolls under it and a real buffer keeps every one of its rows. The band claims that
  row and restores the host's own winbar on close.

The 1-row float follows the host through resizes and layout shifts, closes itself with the host
window, and hit-tests clicks against the chips through the global mouse layer.

With `nav_through` the bar is a real LAYER in the window chain rather than a legend: `enter` steps
from the host into it, `h` / `l` move between chips, `<CR>` runs one, the chord pointing back at the
host steps out, and the one pointing past the bar runs `nav_through` (the host's own `wincmd j` /
`wincmd k`) — so the chain is host → band → the window beyond, in both directions. Pass `enter_key`
and the band binds the step-in key on the host buffer itself, which is what makes it beat a global
window-navigation mapping. `lvim-winnav` also consults the band registry, so a move INTO the window
lands on the band first.

```lua
local surface = require("lvim-ui.surface")
local bar = require("lvim-ui.winband").attach(win, {
    side = "top",
    align = "left",
    enter_key = "<C-k>",
    nav_through = function()
        vim.cmd("wincmd k")
    end,
    suffix = function()
        return " 12 items "
    end,
    items = {
        surface.button({ name = "open", key = "CR", style = "action", run = open }, "action"),
        surface.button({ name = "help", key = "g?", style = "action", run = help }, "action"),
    },
})
bar.set(items) -- replace the chips (re-rendered in place)
bar.close() -- tear down (automatic when the host window closes)
```

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
    padding = { left = 1, right = 1 }, -- blank columns around the rows (`margin` = the old left-only alias)
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
the effective values, and it is optional (the defaults below work as-is). The full default config, kept in
sync with `lua/lvim-ui/config.lua`:

```lua
require("lvim-ui").setup({
    -- Container frame border: "none" (no outer ring) or an 8-element ring { tl,t,tr,r,br,b,bl,l }.
    border = "none",
    -- Per-content-panel border drawn around each data block ("none" or an 8-element ring). A blank " " ring
    -- is a 1-cell inset on every side — geometry the frame draws, not padding baked into the rows — and the
    -- frame derives its air rows from it (a side the ring spaces gets no extra blank row).
    content_border = { " ", " ", " ", " ", " ", " ", " ", " " },
    -- Inter-panel divider between adjacent content panels (auto-oriented: h = side-by-side, v = stacked);
    -- false disables it, a plain string is used for both axes.
    separator = { h = "│", v = "─", hl = "LvimUiPeekBorder" },
    -- Common ring around the data panels as a group (8-element; false disables it).
    group_border = { "", "", "", "", "", "", "", "", hl = "LvimUiPeekBorder" },
    -- Highlight group for the inter-panel divider.
    separator_hl = "LvimUiPeekBorder",
    -- Overflow-chevron glyphs a bar shows at its edges when its buttons don't all fit.
    chevrons = { left = "❮", right = "❯" },
    -- May the user ENTER the `dynamic` peek float (the position <C-n>/<C-p> rotate into)? Default false: the
    -- float is there to be read while moving through the list; true makes it a focusable stop.
    peek_enter = false,
    -- Surface GEOMETRY and BACKDROP per layout (float / area / bottom) are NOT here — they live in the single
    -- central authority `lvim-utils.config.dock.geometry` (control-center's Utils tab), read live at open time.
    -- Disable all completion sources (native / nvim-cmp / blink.cmp) for input popups.
    disable_completion = true,
    position = "editor", -- popup anchor
    max_items = 15, -- list rows shown before scrolling
    filetype = "lvim-utils-ui", -- filetype set on the popup buffer
    close_keys = { "q", "<Esc>" }, -- keys that close the popup
    -- Modal focus trap: while a centred float popup is open, focus cannot leave it — a <C-w> jump OR a
    -- mouse click on another window bounces straight back, so the only way out is the popup's own keys.
    -- Default true (every centred float is modal); docked / hosted panels coexist and never trap. Set
    -- false to disable globally, or per popup via that surface's own `trap_focus`.
    trap_focus = true,
    markview = false, -- markview rendering in the popup

    -- Hand Neovim's own entry points to this toolkit. Opt-in: `vim.ui.select` is a global another
    -- plugin may already own, so a UI library must not take it just by being loaded.
    -- `require("lvim-ui.bridge").restore()` gives it back. There is no `ui_input` — a PROMPT belongs
    -- to the message zone, and lvim-hud bridges `vim.ui.input` from there.
    bridge = { ui_select = false },
    -- File-icon provider for previews (via lvim-utils.icons): "auto" (lvim-icons → nvim-web-devicons →
    -- mini.icons) | "lvim" | "devicons" | "mini".
    icon_provider = "auto",
    -- lvim-icons colour mode for the preview icon (ignored by devicons/mini): "theme" | "brand" |
    -- "theme_brand"; nil = the lvim-icons default.
    icon_color_mode = nil,
    -- Title placement: "row" (a top content row) | "border" (native border-title) | "statusline" (overlay).
    title_line = "row",
    -- Where a supplied count renders: "title" (right of the title) | "footer" (bottom border-footer).
    counter = "title",
    -- Title alignment: "left" | "center" | "right".
    title_pos = "center",
    -- Background tint strengths (blend toward the bg) for themed chrome cells: strong = active, body = rest.
    tint = { strong = 0.2, body = 0.05 },
    -- Popup glyphs.
    icons = {
        bool_on = "󰄬",
        bool_off = "󰍴",
        select = "󰘮",
        number = "\u{f292}",
        string = "\u{f031}",
        action = "\u{eb2c}",
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
        panel_toggle = "<Tab>", -- toggle the center panel (list ⇄ preview) — the only way onto the preview
        panel_next = "<C-l>", -- next center panel (right)
        panel_prev = "<C-h>", -- previous center panel (left)
        menu_prev = { "h", "<Left>" }, -- move within a focused button bar
        menu_next = { "l", "<Right>" },
        menu_confirm = { "<CR>", "<Space>" },
        zone_escape = { "<C-k>", "<C-w>k" }, -- leave the message zone when focused in it
        -- The PREVIEW keys, all live from the LIST (the preview never takes the focus for these):
        preview_next = "<C-n>", -- rotate the preview's side: right → left → dynamic → …
        preview_prev = "<C-p>", -- rotate the other way
        toggle_preview = "<C-e>", -- hide ↔ show the preview (no-op while it is `dynamic`)
        preview_scroll_down = "<C-d>", -- scroll the preview half a screen down — the list keeps the cursor
        preview_scroll_up = "<C-u>", -- …and up
        tabs = { next = "l", prev = "h" },
        select = { confirm = "<CR>", cancel = "<Esc>" },
        multiselect = { toggle = "<Space>", confirm = "<CR>", cancel = "<Esc>" },
        list = { next_option = "<Tab>", prev_option = "<BS>" },
    },
    -- The TREE primitive (the file tree, the LSP outline, the db drawer, the debug scopes).
    tree = {
        -- Blank columns around the tree ROWS (the header band is never padded). With `scrollbar` on, ONE more
        -- right column is reserved for the thumb only while the content overflows.
        padding = { left = 1, right = 1 },
        scrollbar = false, -- right-edge thumb while the content overflows the window (opt-in)
        icons = { fold_open = "\u{f0d7}", fold_closed = "\u{f0da}", guide = "│", branch = "├", branch_last = "└" },
        -- each role: `accent` (a palette key or "#rrggbb") + `tint` (blended toward the panel)
        colors = {
            guide = { accent = "fg_dark", tint = 0.6 }, -- the │ indent guides + ├/└ connectors
            fold = { accent = "blue" }, -- the open/closed chevron (fg only)
            detail = { accent = "comment" }, -- the dim eol detail text
            mark = { accent = "blue", tint = 0.16 }, -- the "follow" row (an outline's current symbol)
            empty = { accent = "comment" }, -- the "no entries" placeholder
            thumb = { accent = "blue", tint = 0.5 }, -- the scrollbar thumb
            track = { accent = "blue", tint = 0.1 }, -- its track
        },
    },
    -- The MENU primitive (the completion / candidate list). A coloured cell is its accent tinted toward
    -- the PANEL it sits on; the selection is bg-only, so each row keeps its own fg colours.
    menu = {
        colors = {
            selection = { accent = "blue", tint = 0.4 },
            match = { accent = "red" },
            detail = { accent = "comment" },
            thumb = { accent = "blue", tint = 0.5 },
            track = { accent = "blue", tint = 0.1 },
        },
        separator = "│", -- the default glyph between menu groups
    },
    -- The 8 border characters nvim wants, clockwise from the top-left. A surface names a preset
    -- (`border = "rounded"`) or passes its own 8-element table.
    borders = {
        rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
        single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
        double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
        none = { "", "", "", "", "", "", "", "" },
    },
    text = { ellipsis = "…" }, -- what a clipped row ends with (its width is reserved before clipping)
    -- The NON-FOCUSABLE hint BAR (`ui.hint`): the full-width row a modal sub-mode pins above the statusline.
    hint = {
        align = "center", -- item alignment inside the row
        default_style = "action", -- the ui.surface button KIND a record with no `style` uses
        fill_hl = "LvimUiBarFill", -- the continuous strip under the items
        zindex = 70, -- above the ordinary floats, below the message zone
        filetype = "lvim-ui-hint", -- the hint buffer's filetype
    },
    -- The form's key-hint legend: the KEYS as the user sees them + their labels.
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
})
```

## License

BSD-3-Clause.
