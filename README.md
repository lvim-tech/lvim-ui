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
ui.tabs({ title = "Settings", tabs = { … } }, function(ok, result) end)
local win = ui.info({ "read-only", "text" }, { title = "Info" })
```

The low-level chassis is `require("lvim-ui.surface")` (framed floating/docked windows) with
`require("lvim-ui.button")` / `require("lvim-ui.bar")` for navigable button bars.

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

## License

BSD-3-Clause.
