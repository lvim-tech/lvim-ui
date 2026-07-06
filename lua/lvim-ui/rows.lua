-- lvim-ui.rows: the row TYPE SYSTEM for the popup/form — the Row/RowType class aliases plus the
-- display helpers, item accessors, and row-navigation utilities that turn a typed-row spec into rendered,
-- editable content. Centralised here so the presenter (form/surface) stays agnostic of how each row type
-- is shaped, valued, and moved between.
---@module "lvim-ui.rows"
local util = require("lvim-ui.util")
local button = require("lvim-ui.button")

local M = {}

-- ─── type annotations ─────────────────────────────────────────────────────────

---@alias RowType "bool"|"boolean"|"select"|"int"|"integer"|"float"|"number"|"string"|"text"|"action"|"spacer"|"spacer_line"|"bar"|"segmented"

--- Flat highlight definition: a named hl group string or an inline nvim hl attr table.
--- { bg?, fg?, bold?, italic?, sp?, underline?, ... }
---@alias HlDef string|table

---@class Row
---@field type     RowType
---@field name?    string
---@field label?   string
---@field icon?    string
---@field value?   any
---@field default? any
---@field options? string[]
---@field run?     fun(value: any, close?: fun(confirmed: boolean, result: any))
---@field top?     boolean
---@field bottom?  boolean
---@field hl?      { active?: HlDef, inactive?: HlDef }
---@field suffix?       string
---@field expanded?     boolean
---@field flat?         boolean  -- drop the lead type icon / expand caret (the row carries its own `icon`)
---@field tight?         boolean  -- a flat row: drop the 2-space lead entirely (content sits at the panel edge)
---@field children?     Row[]
---@field option_icons? table<string, string>
---@field bracket_key?  boolean
---@field center?       boolean   center the row text instead of left-padding
---@field dim_to?        integer   dim the first N bytes of the LABEL (e.g. a file row's path before the name)
---@field disabled?      boolean|fun(row: Row): boolean  inert in the current context → dimmed + struck through, no activate
---@field icon_hl?       string    action/accordion rows: highlight for the `icon` column
---@field text_hl?       string    action/accordion rows: highlight for the label/value text
---@field suffix_hl?     string    action/accordion rows: highlight for the trailing `suffix`
---@field items?         table[]   bar rows: the ui.bar button / separator specs
---@field align?         string    bar rows: "left" | "center" (default) | "right"
---@field _off?          integer   bar rows: persisted horizontal scroll offset (internal)
---@field _sel?          integer   bar rows: the keyboard-focused button index (internal)
---@field _cells?        table[]   bar rows: rendered per-button byte ranges for click hit-testing (internal)

--- Per-item hl state: either a flat HlDef (whole line) or split parts.
---@alias ItemHlState HlDef | { checkbox?: HlDef, icon?: HlDef, text?: HlDef }

---@class SelectItem
---@field label          string
---@field icon?          string
---@field checked_icon?   string
---@field unchecked_icon? string
---@field hl?   { active?: ItemHlState, inactive?: ItemHlState }

---@class Tab
---@field label   string
---@field name?   string   identifier matched by `tab_selector` (before label)
---@field icon?   string
---@field tab_hl? { active?: HlDef, inactive?: HlDef }  -- per-tab: only bg field is merged
---@field rows?   Row[]
---@field items?  (string|SelectItem)[]

-- ─── icons accessor ───────────────────────────────────────────────────────────

--- Convenience accessor for the configured icon set.
---@return table
function M.icons()
    return util.cfg().icons
end

-- ─── row helpers ──────────────────────────────────────────────────────────────

--- Return true when a row can receive keyboard focus.
---@param row Row
---@return boolean
function M.is_selectable(row)
    return row.type ~= "spacer" and row.type ~= "spacer_line"
end

--- The expand/collapse caret for a row that owns children.
---@param row Row
---@param ico table
---@return string
local function caret(row, ico)
    return row.expanded and (ico.expand_open or "") or (ico.expand_closed or "")
end

--- Build the display string for a typed row.
---@param row Row
---@return string
function M.row_display(row, ico)
    local t = row.type or "string"
    local label = row.label or row.name or ""
    local val = tostring(row.value ~= nil and row.value or row.default or "")
    ico = ico or M.icons()
    local ri = row.icon and (row.icon .. " ") or ""

    -- Expandable rows (accordion) show a caret instead of their type icon.
    if row.children then
        return (row.flat and "" or caret(row, ico)) .. "  " .. ri .. label
    end

    if t == "bool" or t == "boolean" then
        return (row.value and ico.bool_on or ico.bool_off) .. "  " .. ri .. label
    elseif t == "segmented" then
        local prefix, segs = M.segmented_segments(row, ico)
        local texts = {}
        for _, sg in ipairs(segs) do
            texts[#texts + 1] = sg.text
        end
        return prefix .. table.concat(texts, " ")
    elseif t == "select" then
        return ico.select .. "  " .. ri .. label .. ": " .. val
    elseif t == "int" or t == "integer" or t == "float" or t == "number" then
        return ico.number .. "  " .. ri .. label .. ": " .. val
    elseif t == "string" or t == "text" then
        return ico.string .. "  " .. ri .. label .. ": " .. val
    elseif t == "action" then
        -- a `tight` flat row drops the 2-space lead entirely (its own `icon` carries any leading marker) — a
        -- compact list (e.g. a picker's items) where the row content sits right at the panel edge.
        local lead = row.flat and (row.tight and "" or "  ") or (ico.action .. "  ")
        return lead .. ri .. label .. (row.suffix and (" " .. row.suffix) or "")
    elseif t == "spacer" then
        return (row.flat and "" or ico.spacer) .. "  " .. ri .. label .. (row.suffix and (" " .. row.suffix) or "")
    elseif t == "spacer_line" then
        return ""
    end
    return "   " .. label
end

--- Build a segmented row's prefix and its segment list (text + option), honouring
--- per-option icons (row.option_icons). The active option is shown in [brackets].
--- Shared by the renderer and the per-segment highlighter so offsets always match.
---@param row Row
---@param ico table
---@return string prefix, { text: string, opt: string }[]
function M.segmented_segments(row, ico)
    ico = ico or M.icons()
    local ri = row.icon and (row.icon .. " ") or ""
    local prefix = ri .. (row.label or "")
    if prefix ~= "" then
        prefix = prefix .. "  "
    end
    local segs = {}
    for _, opt in ipairs(row.options or {}) do
        local oicon = row.option_icons and row.option_icons[opt]
        -- bracket_key: box the shortcut letter as the hint ("[R]einstall") via the shared ui.button
        -- bracket convention; the active option is then shown by highlight (bold), not by brackets.
        local label = opt
        if row.bracket_key and #opt > 0 then
            local first = vim.fn.strcharpart(opt, 0, 1)
            local pos = button.key_pos(opt, first)
            local byte_pos = vim.str_byteindex(opt, "utf-32", pos - 1, false) + 1
            local next_byte = vim.str_byteindex(opt, "utf-32", pos, false) + 1
            label = opt:sub(1, byte_pos - 1) .. "[" .. opt:sub(byte_pos, next_byte - 1) .. "]" .. opt:sub(next_byte)
        end
        local inner = (oicon and (oicon .. " ") or "") .. label
        local text
        if row.bracket_key then
            text = " " .. inner .. " "
        else
            text = (opt == row.value) and ("[" .. inner .. "]") or (" " .. inner .. " ")
        end
        segs[#segs + 1] = { text = text, opt = opt }
    end
    return prefix, segs
end

--- Return the icon string and separator length for a row.
--- Layout in the buffer line: 2-byte indent | icon | sep | text | padding
---@param row Row
---@return string icon_str, integer sep_bytes
function M.row_icon_info(row, ico)
    local t = row.type or "string"
    ico = ico or M.icons()
    if row.flat then
        return "", 2 -- no lead icon; keep the 2-byte separator so the row's own `icon` column stays aligned
    end
    if row.children then
        return caret(row, ico), 2
    end
    if t == "bool" or t == "boolean" then
        return (row.value and ico.bool_on or ico.bool_off), 2
    elseif t == "segmented" or t == "select" then
        return ico.select, 2
    elseif t == "int" or t == "integer" or t == "float" or t == "number" then
        return ico.number, 2
    elseif t == "string" or t == "text" then
        return ico.string, 2
    elseif t == "action" then
        return ico.action, 2
    elseif t == "spacer" then
        return ico.spacer, 2
    end
    return "", 0
end

-- ─── item accessors ───────────────────────────────────────────────────────────

--- Return the display label of a select item (string or {label,...} table).
---@param item string|SelectItem
---@return string
function M.item_label(item)
    if type(item) == "table" then
        return tostring(item.label or "")
    end
    return tostring(item or "")
end

--- Return the icon string of a select item, or nil.
---@param item string|SelectItem
---@return string|nil
function M.item_icon(item)
    if type(item) == "table" then
        return item.icon
    end
    return nil
end

--- Return the hl table of a select item, or nil.
---@param item string|SelectItem
---@return table|nil
function M.item_hl(item)
    if type(item) == "table" then
        return item.hl
    end
    return nil
end

--- Return true when an ItemHlState uses the split { icon?, text? } format.
---@param state any
---@return boolean
function M.item_hl_is_split(state)
    return type(state) == "table" and (state.checkbox ~= nil or state.icon ~= nil or state.text ~= nil)
end

-- ─── accordion flattening ─────────────────────────────────────────────────────

--- Flatten a row tree into the visible row list: each row, followed by its
--- children when it is expanded (or always, when include_collapsed is true —
--- used for width measurement). Supports arbitrary nesting.
---@param tree Row[]
---@param include_collapsed? boolean
---@return Row[]
function M.flatten(tree, include_collapsed)
    local out = {}
    local function walk(list)
        for _, r in ipairs(list) do
            out[#out + 1] = r
            if r.children and (include_collapsed or r.expanded) then
                walk(r.children)
            end
        end
    end
    walk(tree or {})
    return out
end

-- ─── row navigation helpers ───────────────────────────────────────────────────

--- Return the 1-based index of the first selectable row, or 1 as fallback.
---@param rows Row[]
---@return integer
function M.first_selectable(rows)
    for i, r in ipairs(rows) do
        if M.is_selectable(r) then
            return i
        end
    end
    return 1
end

--- Return the next selectable row index in direction delta (+1 / -1),
--- or nil when the boundary is reached.
---@param rows  Row[]
---@param from  integer  Current 1-based index
---@param delta integer  +1 for down, -1 for up
---@return integer|nil
function M.next_selectable(rows, from, delta)
    local i = from + delta
    while i >= 1 and i <= #rows do
        if M.is_selectable(rows[i]) then
            return i
        end
        i = i + delta
    end
    return nil
end

--- Resolve the initial row_cursor from a hint (string name or 1-based index).
--- Falls back to first_selectable when the hint is absent or unmatched.
---@param rows Row[]
---@param hint string|integer|nil
---@return integer
function M.resolve_initial_row(rows, hint)
    if not hint then
        return M.first_selectable(rows)
    end
    if type(hint) == "number" then
        local idx = math.floor(hint)
        if idx >= 1 and idx <= #rows and M.is_selectable(rows[idx]) then
            return idx
        end
        return M.next_selectable(rows, idx - 1, 1) or M.first_selectable(rows)
    end
    for i, r in ipairs(rows) do
        if r.name == hint and M.is_selectable(r) then
            return i
        end
    end
    return M.first_selectable(rows)
end

return M
