-- lvim-ui.transient: the declarative TRANSIENT command ENGINE — the plugin-agnostic spine behind Magit's
-- signature popup. A transient is DATA: a prefix (id + title) with grouped INFIXES (switches `-x` and
-- options `=val`) and ACTIONS (the suffix commands). This engine owns the DATA + the arg math + the
-- persistence; the lvim-ui `M.transient` PRESET (init.lua) owns the RENDERING (the same clean data-vs-render
-- split the select/tabs presets use). `engine:open(id, ctx)` builds the preset's groups from a def, seeds
-- each infix from the session default, and wires set/save/reset/level back to the engine.
--
-- This is the EXTRACTED, parameterized form of a per-plugin engine (the `lvim-utils.store` extraction
-- precedent): the only host couplings a consumer once baked in are (1) the table that holds per-prefix
-- SESSION defaults, (2) the on-disk defaults store, (3) how a repo/project ROOT is derived, and (4) the
-- live config values (enabled / default level / layout). `M.new{…}` takes all four as parameters, so the
-- engine is VCS- and plugin-agnostic: lvim-git and lvim-forge each instantiate their OWN engine over their
-- OWN state table + store, and share this one implementation + the one preset.
--
-- Per-prefix arg state lives in the consumer-owned `state` table, keyed "<id>@<root>": the SESSION default a
-- fresh open starts from (Magit's `set`). `save` writes the same snapshot to the consumer's `store` handle
-- (an `lvim-utils.store` live table, or nil to disable persistence). Visibility LEVELS 1-7 hide advanced
-- infixes/actions like Magit.
--
---@module "lvim-ui.transient"

local M = {}

-- ── types ───────────────────────────────────────────────────────────────────

---@class LvimUiTransientInfix
---@field kind    "switch"|"option"
---@field key     string        the direct hotkey (also the state key)
---@field label   string        the human description
---@field flag?   string        switch: the argv flag it toggles (e.g. "--force-with-lease")
---@field arg?    string        option: the argv name it sets (e.g. "--max-count")
---@field choices? string[]     option: a fixed value set (cycled instead of typed)
---@field default? any          the initial value (switch: boolean; option: string)
---@field level?  integer       visibility level (default 1)

---@class LvimUiTransientActionSpec
---@field key    string
---@field label  string
---@field level? integer
---@field run    fun(args: string[], ctx: LvimUiTransientCtx)  execute with the assembled argv + scope

---@class LvimUiTransientGroup
---@field title? string
---@field infix?   LvimUiTransientInfix[]
---@field actions? LvimUiTransientActionSpec[]

---@class LvimUiTransientDef
---@field id     string
---@field title  string
---@field groups LvimUiTransientGroup[]

---@class LvimUiTransientSnap
---@field switches table<string, boolean>  key → on/off
---@field options  table<string, any>      key → value (nil/"" = unset)
---@field level?   integer                 the remembered visible level for this prefix

---@class LvimUiTransientCtx
---@field id     string                 the prefix id
---@field root   string?                the repo/project root (nil outside one)
---@field lens?  any                    a one-off lens/scope override carried to the actions
---@field args?  string[]               extra positional args from the command line
---@field selection? any                the "thing at point" the actions operate on
---@field rows   table<string, table>   key → the live infix ui-row spec (its `.value` is the working copy)

---@class LvimUiTransientEngineOpts
---@field name?        string           notify prefix for user messages (default "lvim-ui")
---@field state?       table            consumer-owned table holding per-prefix snapshots, keyed "<id>@<root>"
---@field store?       table?           an `lvim-utils.store` live handle (or nil to disable persistence)
---@field level?       integer|fun():integer  the default visible level a fresh open starts at (default: max_level — every level shown until the user lowers it)
---@field layout?      string|fun():string    the preset layout ("float"|"cursor"|"bottom")
---@field enabled?     boolean|fun():boolean   gate `open` (default true)
---@field resolve_root? fun(ctx: table?): string?  derive the root when `ctx.root` is absent
---@field min_level?   integer          lowest selectable level (default 1)
---@field max_level?   integer          highest selectable level (default 7)

-- ── helpers ──────────────────────────────────────────────────────────────────

--- Resolve a value-or-function option to its current value (a live-config value or a zero-arg getter).
---@param v any  a value, or a zero-arg function returning one
---@return any
local function resolved(v)
    if type(v) == "function" then
        return v()
    end
    return v
end

--- The state key for a prefix in a root.
---@param id string
---@param root string?
---@return string
local function skey(id, root)
    return id .. "@" .. (root or "GLOBAL")
end

--- Assemble the argv list from a snapshot: each ON switch → its flag; each set option → `--arg=value`
--- (a `--long` name) or `arg value` (anything else).
---@param def LvimUiTransientDef
---@param snap { switches: table<string, boolean>, options: table<string, any> }
---@return string[]
local function assemble(def, snap)
    local out = {}
    for _, g in ipairs(def.groups or {}) do
        for _, ix in ipairs(g.infix or {}) do
            if ix.kind == "switch" then
                if snap.switches[ix.key] and ix.flag then
                    out[#out + 1] = ix.flag
                end
            else
                local v = snap.options[ix.key]
                if v ~= nil and v ~= "" and ix.arg then
                    if ix.arg:sub(1, 2) == "--" then
                        out[#out + 1] = ix.arg .. "=" .. tostring(v)
                    else
                        out[#out + 1] = ix.arg
                        out[#out + 1] = tostring(v)
                    end
                end
            end
        end
    end
    return out
end

--- The built-in default snapshot for a def (from each infix's `default`).
---@param def LvimUiTransientDef
---@return LvimUiTransientSnap
local function defaults_of(def)
    local snap = { switches = {}, options = {} }
    for _, g in ipairs(def.groups or {}) do
        for _, ix in ipairs(g.infix or {}) do
            if ix.kind == "switch" then
                snap.switches[ix.key] = ix.default == true
            else
                snap.options[ix.key] = ix.default
            end
        end
    end
    return snap
end

--- Snapshot a table of live ui-row values (the working copy) back into a plain `{ switches, options }`.
---@param rows table<string, table>
---@return LvimUiTransientSnap
local function snapshot_rows(rows)
    local snap = { switches = {}, options = {} }
    for key, row in pairs(rows) do
        if row.kind == "switch" then
            snap.switches[key] = row.value == true
        else
            snap.options[key] = row.value
        end
    end
    return snap
end

-- ── the engine instance ──────────────────────────────────────────────────────

---@class LvimUiTransientEngine
---@field name      string
---@field state     table
---@field store     table?
---@field min_level integer
---@field max_level integer
---@field defs      table<string, LvimUiTransientDef>
---@field _level?   integer|fun():integer
---@field _layout?  string|fun():string
---@field _enabled? boolean|fun():boolean
---@field _resolve_root? fun(ctx: table?): string?
local Engine = {}
Engine.__index = Engine

--- Register (or replace) a transient definition. Consumers call this from their own module load.
---@param def LvimUiTransientDef
function Engine:define(def)
    self.defs[def.id] = def
end

--- Whether a transient id is registered.
---@param id string
---@return boolean
function Engine:has(id)
    return self.defs[id] ~= nil
end

--- The registered def for an id (nil when unknown).
---@param id string
---@return LvimUiTransientDef?
function Engine:def(id)
    return self.defs[id]
end

--- Resolve the root for an invocation: `ctx.root` first, else the configured `resolve_root`, else nil
--- (the "GLOBAL" bucket).
---@param ctx? { root?: string, buf?: integer }
---@return string?
function Engine:root(ctx)
    if ctx and ctx.root then
        return ctx.root
    end
    if self._resolve_root then
        return self._resolve_root(ctx)
    end
    return nil
end

--- The built-in default snapshot for a def id (from each infix's `default`).
---@param id string
---@return LvimUiTransientSnap
function Engine:defaults(id)
    local def = self.defs[id]
    return def and defaults_of(def) or { switches = {}, options = {} }
end

--- The SESSION default snapshot for a prefix — the committed args a fresh open starts from. Lazily
--- seeded from the on-disk store (if any) else the built-in defaults, then cached in the state table.
---@param id string
---@param root string?
---@return LvimUiTransientSnap
function Engine:snapshot(id, root)
    local def = self.defs[id]
    if not def then
        return { switches = {}, options = {} }
    end
    local key = skey(id, root)
    local snap = self.state[key]
    if snap then
        return snap
    end
    local persisted = self.store and self.store[key] or nil
    snap = persisted and vim.deepcopy(persisted) or defaults_of(def)
    self.state[key] = snap
    return snap
end

--- Assemble the argv for a def id from an arbitrary snapshot.
---@param id string
---@param snap LvimUiTransientSnap
---@return string[]
function Engine:assemble(id, snap)
    local def = self.defs[id]
    if not def then
        return {}
    end
    return assemble(def, snap)
end

--- The assembled argv for a prefix's SESSION default (for callers invoking a verb WITHOUT opening the
--- popup).
---@param id string
---@param root? string
---@return string[]
function Engine:args(id, root)
    local def = self.defs[id]
    if not def then
        return {}
    end
    return assemble(def, self:snapshot(id, root))
end

--- The remembered visible level for a prefix this session, else the engine's default level.
---@param id string
---@param root? string
---@return integer
function Engine:level(id, root)
    local snap = self:snapshot(id, root)
    return snap.level or resolved(self._level) or self.max_level
end

--- Promote a snapshot to the prefix's SESSION default (Magit's `set`). Caches it in the state table.
---@param id string
---@param root string?
---@param snap LvimUiTransientSnap
function Engine:set(id, root, snap)
    self.state[skey(id, root)] = snap
end

--- Write a snapshot to the on-disk store AND the session default (Magit's `save`). Returns whether it was
--- persisted (false when no store is configured).
---@param id string
---@param root string?
---@param snap LvimUiTransientSnap
---@return boolean persisted
function Engine:save(id, root, snap)
    self.state[skey(id, root)] = snap
    if self.store then
        self.store[skey(id, root)] = vim.deepcopy(snap)
        return true
    end
    return false
end

--- The base snapshot a `reset` drops back to: the persisted store value if any, else the built-in
--- defaults.
---@param id string
---@param root string?
---@return LvimUiTransientSnap
function Engine:base(id, root)
    local persisted = self.store and self.store[skey(id, root)] or nil
    return persisted and vim.deepcopy(persisted) or self:defaults(id)
end

-- ── open ─────────────────────────────────────────────────────────────────────

--- Open a transient prefix's popup through the lvim-ui `transient` preset. `ctx` carries the invoking
--- scope (root/buf, an optional lens override, extra args, the selection the actions operate on). Unknown
--- ids notify cleanly (a verb whose def lands in a later phase).
---@param id string
---@param ctx? { root?: string, buf?: integer, lens?: any, args?: string[], selection?: any }
function Engine:open(id, ctx)
    ctx = ctx or {}
    if self._enabled ~= nil and not resolved(self._enabled) then
        return
    end
    local def = self.defs[id]
    if not def then
        vim.notify(self.name .. ": transient `" .. tostring(id) .. "` is not available yet", vim.log.levels.WARN)
        return
    end

    local root = self:root(ctx)
    local snap = self:snapshot(id, root)

    ---@type LvimUiTransientCtx
    local tctx = {
        id = id,
        root = root,
        lens = ctx.lens,
        args = ctx.args,
        selection = ctx.selection,
        rows = {},
    }

    -- Build the preset groups from the def, seeding each infix's value from the session snapshot. Keep a
    -- reference to every infix ui-row in `tctx.rows` so set/save/reset/args read the working values and
    -- reset can rewrite them in place.
    local ui_groups = {}
    for _, g in ipairs(def.groups or {}) do
        local ui_rows = {}
        for _, ix in ipairs(g.infix or {}) do
            local value
            if ix.kind == "switch" then
                value = snap.switches[ix.key]
                if value == nil then
                    value = ix.default == true
                end
            else
                value = snap.options[ix.key]
                if value == nil then
                    value = ix.default
                end
            end
            local row = {
                kind = ix.kind,
                key = ix.key,
                label = ix.label,
                flag = ix.flag,
                arg = ix.arg,
                choices = ix.choices,
                value = value,
                level = ix.level or 1,
            }
            tctx.rows[ix.key] = row
            ui_rows[#ui_rows + 1] = row
        end
        for _, ac in ipairs(g.actions or {}) do
            ui_rows[#ui_rows + 1] = {
                kind = "action",
                key = ac.key,
                label = ac.label,
                level = ac.level or 1,
                run = function()
                    ac.run(assemble(def, snapshot_rows(tctx.rows)), tctx)
                end,
            }
        end
        ui_groups[#ui_groups + 1] = { title = g.title, rows = ui_rows }
    end

    -- The preset is the renderer; require it here (inline) to avoid a load-time cycle with lvim-ui/init.
    require("lvim-ui").transient({
        title = def.title,
        groups = ui_groups,
        level = snap.level or resolved(self._level) or self.max_level,
        min_level = self.min_level,
        max_level = self.max_level,
        layout = resolved(self._layout),
        -- live edits mutate the ui-row `.value` (the working copy) — nothing to persist until set/save.
        on_toggle = function() end,
        on_option = function() end,
        on_level = function(lvl)
            snap.level = lvl -- remember the level per prefix for this session
        end,
        -- set: promote the working copy to the session default (Magit's `set`).
        on_set = function()
            local s = snapshot_rows(tctx.rows)
            s.level = snap.level
            self:set(id, root, s)
            snap = s
            vim.notify(self.name .. ": " .. def.title .. " args set for this session", vim.log.levels.INFO)
        end,
        -- save: write the working copy to the on-disk store AND the session default (Magit's `save`).
        on_save = function()
            local s = snapshot_rows(tctx.rows)
            s.level = snap.level
            snap = s
            if self:save(id, root, s) then
                vim.notify(self.name .. ": " .. def.title .. " args saved", vim.log.levels.INFO)
            else
                vim.notify(self.name .. ": saving defaults is disabled", vim.log.levels.WARN)
            end
        end,
        -- reset: drop the working copy back to the saved (store) or built-in defaults, rewriting each live
        -- ui-row's value in place so the popup re-renders from them.
        on_reset = function()
            local base = self:base(id, root)
            for key, row in pairs(tctx.rows) do
                if row.kind == "switch" then
                    row.value = base.switches[key] == true
                else
                    row.value = base.options[key]
                end
            end
        end,
    })
end

-- ── constructor ───────────────────────────────────────────────────────────────

--- Create a transient engine instance over a consumer-owned state table + optional store. Every option
--- that once coupled the engine to a host (the session-snapshot table, the persistence store, the default
--- level / layout, how a root is derived, whether the engine is enabled) is a parameter here, so lvim-git
--- and lvim-forge each own an independent engine sharing this one implementation + the lvim-ui preset.
---@param opts? LvimUiTransientEngineOpts
---@return LvimUiTransientEngine
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Engine)
    self.name = opts.name or "lvim-ui"
    self.state = opts.state or {}
    self.store = opts.store
    self._level = opts.level
    self._layout = opts.layout
    self._enabled = opts.enabled
    self._resolve_root = opts.resolve_root
    self.min_level = opts.min_level or 1
    self.max_level = opts.max_level or 7
    self.defs = {}
    return self
end

return M
