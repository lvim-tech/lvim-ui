-- lvim-ui.filters: build a centered `ui.bar` band from filter GROUPS — the ONE filter-bar model shared
-- by the picker (its header filter bar) and `ui.tabs` (a tab's toolbar filter), so every filter bar across the
-- plugins is identical: one button per option, a `●` separator between GROUPS, a live count, the active
-- highlight, and the canonical 4-state button styling (normal/active/hover/hover_active).
--
-- A filter button is fired with `<CR>` on it (or a click) — it carries NO bracketed letter accelerator, so the
-- bar reads as plain captions and claims none of the panel's key space.
--
-- The BUTTON STYLE comes from the shared `surface.STYLES.hotkey`, so the
-- style FLAGS are defined in ONE place for every bar (action `surface.bar` + these filters); only the COLOURS
-- (the LvimUiPeekFilter* accents + per-button `hl`) live here. The consumer owns the SEMANTICS (what a filter
-- does, how its count is computed) and passes them in; this module owns the LOOK + the spec construction. See
-- `.claude/how-build-panels.md` §5.
--
---@module "lvim-ui.filters"

local M = {}

---@class LvimUiFilterButton
---@field id     string
---@field label  string
---@field key?   string                 -- IGNORED (kept so existing group specs still load): filter buttons are
---                                      -- fired with <CR>/click only — no bracketed letter, no accelerator
---@field predicate? fun(src: any): boolean
---@field hl?            string         -- inactive colour (default LvimUiPeekFilterInactive)
---@field hl_active?     string         -- active colour (default LvimUiPeekFilterActive)
---@field hl_hover_active? string       -- cursor-on-active colour (default: degrades to hover)

---@class LvimUiFilterGroup
---@field id      string
---@field active  string                -- the active button id in this group
---@field buttons LvimUiFilterButton[]

---@class LvimUiFilterAccents
---@field active?   string   -- default active colour (LvimUiPeekFilterActive)
---@field inactive? string   -- default inactive colour (LvimUiPeekFilterInactive)
---@field sep?      string   -- the `●` divider colour (LvimUiPeekFilterSep)

---@class LvimUiFilterOpts
---@field count?     fun(group: LvimUiFilterGroup, btn: LvimUiFilterButton): integer?
---@field on_select? fun(gi: integer, id: string)
---@field accents?   LvimUiFilterAccents

--- Build the filter band from the groups.
---@param filters LvimUiFilterGroup[]?  nil / empty → an empty band (iterated via `filters or {}`)
---@param opts LvimUiFilterOpts
---@return { band: table, sync: fun() }  -- band = { items, align="center" }; sync() re-evaluates the active flags
function M.bar(filters, opts)
    opts = opts or {}
    local A = opts.accents or {}
    local def_active = A.active or "LvimUiPeekFilterActive"
    local def_inactive = A.inactive or "LvimUiPeekFilterInactive"
    local sep_hl = A.sep or "LvimUiPeekFilterSep"
    -- Every button is built by the SHARED `surface.button` mapper with the `hotkey` KIND — the filter bar uses the
    -- EXACT same styling path as every other bar. Only the COLOURS stay consumer-owned (per-button `hl`/`hl_active`,
    -- defaults as fallback), passed as the record's `hl` box override; `meta` carries the group/id for `sync`.
    local surface = require("lvim-ui.surface")

    local specs = {}
    for gi, g in ipairs(filters or {}) do
        if gi > 1 then
            -- a `●` divider BETWEEN groups (never before the first)
            specs[#specs + 1] = { type = "separator", text = "●", style = { padding = { 3, 3 }, hl = sep_hl } }
        end
        for _, b in ipairs(g.buttons) do
            local accent = b.hl_active or def_active
            local dim = b.hl or def_inactive
            local ha = b.hl_hover_active -- nil → ui.button degrades hover_active to plain hover
            specs[#specs + 1] = surface.button({
                name = b.label,
                -- NO `key`: a filter button is activated by <CR> on it (or a click), never by a bare letter.
                -- Passing a key would BOTH bracket a letter of the caption (`[I]ssues`) and bind that letter as
                -- a direct accelerator — the bar reads cleaner, and stays out of the panel's key space, without
                -- it. (`LvimUiFilterButton.key` is accepted-but-ignored so existing group specs still load.)
                style = "hotkey",
                active = b.id == g.active,
                count = opts.count and function()
                    return opts.count(g, b)
                end or nil,
                run = function()
                    if opts.on_select then
                        opts.on_select(gi, b.id)
                    end
                end,
                meta = { gi = gi, id = b.id }, -- so sync() can re-evaluate `active` after a toggle
                hl = { -- consumer colours override the hotkey KIND default
                    icon = { padding = { 0, 0 }, normal = accent, active = accent, hover = accent, hover_active = ha },
                    text = { padding = { 1, 1 }, normal = dim, active = accent, hover = accent, hover_active = ha },
                },
            }, "hotkey")
        end
    end

    --- Re-sync each spec's `active` flag with its group (call after a filter toggles, before a re-render). The
    --- group/id ride in the shared button's `_meta` passthrough (set above).
    local function sync()
        for _, s in ipairs(specs) do
            local m = s._meta
            if m and filters and filters[m.gi] then
                s.active = filters[m.gi].active == m.id
            end
        end
    end

    return { band = { items = specs, align = "center" }, sync = sync }
end

return M
