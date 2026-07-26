-- lvim-ui.workspace: the shared dedicated-TABPAGE full-screen shell.
--
-- The "move the whole client into its own fullscreen tab, never over your code" pattern was built FOUR
-- times independently (lvim-git + lvim-forge — forge a literal copy of git's host — plus lvim-db's and
-- lvim-rest's tiled workspaces). This is the ONE home for it, so every consumer becomes a thin caller.
--
-- Two usage modes over ONE tab lifecycle:
--   * FULLSCREEN slot — the tab hosts a single centred surface that FILLS it: the consumer opens its
--     `lvim-ui` surface with `slot = M.slot()`. (lvim-git / lvim-forge status/log/diff views.)
--   * REGION tiling — the tab is tiled into a left SIDEBAR + an EDITOR pane + a response/result DOCK.
--     The shell owns the tab + the editor window; the consumer opens its OWN sidebar/dock panels via the
--     `sidebar`/`dock` callbacks (it keeps its providers). (lvim-db workspace, lvim-rest workbench.)
--
-- INVARIANTS (carried over from the proven git/db hosts — do not regress):
--   * The tab is marked with a tab-scoped var (`t:lvim_ui_workspace = <id>`) and ALWAYS found by that
--     marker, NEVER by a stored handle — a stray `:tabclose` from elsewhere can't dangle it. Only the
--     ORIGIN tab (return-focus target) is remembered.
--   * The consumer keeps the DATA; a `close`→`open` (toggle) rebuilds the windows, the model persists.
--   * The tiled layout forces `laststatus = 3` (a global statusline) and re-asserts it on TabEnter —
--     else per-window statuslines split mid-screen above a docked result (the lvim-db bug).
--
-- PUBLIC: open / close / toggle / is_open / tab_for / current / focus / editor / slot.
--
---@module "lvim-ui.workspace"

local api = vim.api

local M = {}

-- The tab-scoped marker var; its value is the workspace id.
local MARK = "lvim_ui_workspace"
-- The window-scoped marker on the EDITOR pane; its value is the workspace id (so `editor(id)` re-finds
-- the pane by marker, robust to a re-open or a stray layout change — same discipline as the tab marker).
local EDITOR_MARK = "lvim_ui_workspace_editor"

---@class LvimUiWorkspaceState
---@field origin integer?  the tabpage to return focus to on close
---@field spec table?      the open spec (kept for on_close)
---@type table<string, LvimUiWorkspaceState>
local ws = {}

-- Re-entry guard: a hosted surface's close callback can re-enter `close`, and `tabclose` fires WinClosed
-- which may bounce back here. Keyed by id.
---@type table<string, boolean>
local closing = {}

-- The two-STATE region layout, per id: "stacked" (state 1 — sidebar full-height, the editor and dock
-- STACKED in the right column) | "full" (state 2 — the dock spans FULL width across the bottom, sidebar
-- + editor on top). One key/command toggles between them; the geometry lives in `dock_split` so every
-- consumer (rest / db / git) gets the SAME two arrangements. Default "stacked".
---@type table<string, "stacked"|"full">
local layouts = {}

-- The chrome-guard augroup (shared): re-asserts `laststatus = 3` whenever ANY tiled workspace tab is
-- current. One group for all ids — the callback checks the current tab's marker.
local guard_group = nil
---@type integer?  the user's `laststatus` before the first tiled workspace forced 3
local prev_laststatus = nil

--- The tabpage hosting `id`, found by its marker var (never a cached handle). nil when not open.
---@param id string
---@return integer? tabpage
function M.tab_for(id)
    for _, t in ipairs(api.nvim_list_tabpages()) do
        local ok, v = pcall(api.nvim_tabpage_get_var, t, MARK)
        if ok and v == id then
            return t
        end
    end
    return nil
end

--- The workspace id hosted by the CURRENT tabpage (if it is a workspace), else nil.
---@return string?
function M.current()
    local ok, v = pcall(api.nvim_tabpage_get_var, api.nvim_get_current_tabpage(), MARK)
    return (ok and type(v) == "string") and v or nil
end

--- Whether `id` has an open workspace tab.
---@param id string
---@return boolean
function M.is_open(id)
    return M.tab_for(id) ~= nil
end

--- The EDITOR pane window of workspace `id` (the marked window inside its tab), or nil. Survives a
--- re-open — it is found by the window marker, never a stored handle.
---@param id string
---@return integer?
function M.editor(id)
    local tab = M.tab_for(id)
    if not tab then
        return nil
    end
    for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
        local ok, v = pcall(api.nvim_win_get_var, w, EDITOR_MARK)
        if ok and v == id and api.nvim_win_is_valid(w) then
            return w
        end
    end
    return nil
end

--- Focus the workspace tab for `id` (no-op when it is not open).
---@param id string
function M.focus(id)
    local t = M.tab_for(id)
    if t and api.nvim_tabpage_is_valid(t) then
        api.nvim_set_current_tabpage(t)
    end
end

--- The ANCHORED geometry that makes a centred-float surface FILL the tab (fullscreen mode) — pass as
--- `slot` to `lvim-ui.tabs` / `surface.open`. Available rows = lines − tabline(1) − statusline(1) −
--- cmdheight, so the float spans tabline→statusline with no gap.
---@return { width: number, height: integer }
function M.slot()
    local avail = vim.o.lines - vim.o.cmdheight - 2
    return { width = 1.0, height = math.max(10, avail) }
end

-- ── the two-state region layout (shared across consumers) ───────────────────

--- The current region-layout state of `id`: "stacked" (dock under the editor, sidebar full-height) or
--- "full" (dock full-width across the bottom, sidebar+editor on top). Defaults to "stacked".
---@param id string
---@return "stacked"|"full"
function M.layout(id)
    return layouts[id] or "stacked"
end

--- Set the region-layout state of `id` (no rebuild — the caller reopens its dock).
---@param id string
---@param state "stacked"|"full"
function M.set_layout(id, state)
    layouts[id] = state
end

--- The dock-split geometry for `id`'s CURRENT layout state — the ONE place the two arrangements are
--- decided, so every consumer's dock lands identically. State "stacked" anchors the split UNDER the
--- editor window (sidebar stays full-height), sized as a fraction of the editor COLUMN; state "full"
--- docks at the tabpage's far bottom edge (full width, under sidebar+editor), sized as a fraction of the
--- WHOLE tab. Feed the result straight into `surface.open` (`dock` / `anchor` / `size`).
---@param id string
---@param editor integer  the editor window (the "stacked" state anchors to it)
---@param sizes { stacked?: number, full?: number }  per-state height fraction (defaults 0.66 / 0.34)
---@return { dock: string, anchor: integer?, size: table }
function M.dock_split(id, editor, sizes)
    sizes = sizes or {}
    if M.layout(id) == "full" then
        local rows = math.max(3, math.floor((vim.o.lines - vim.o.cmdheight - 2) * (sizes.full or 0.34)))
        return { dock = "below", anchor = nil, size = { height = { fixed = rows } } }
    end
    local h = (editor and api.nvim_win_is_valid(editor)) and api.nvim_win_get_height(editor)
        or (vim.o.lines - vim.o.cmdheight - 2)
    local rows = math.max(3, math.floor(h * (sizes.stacked or 0.66)))
    return { dock = "below", anchor = editor, size = { height = { fixed = rows } } }
end

--- Flip `id`'s layout state ("stacked" ⟷ "full") and run `on_rebuild(new_state)` — which reopens the
--- consumer's dock in the new arrangement (its geometry from `dock_split`). This is THE shared toggle:
--- one implementation, every workspace consumer inherits the same State-1 ⟷ State-2 switch.
---@param id string
---@param on_rebuild fun(state: "stacked"|"full")
function M.toggle_layout(id, on_rebuild)
    layouts[id] = (M.layout(id) == "full") and "stacked" or "full"
    if on_rebuild then
        pcall(on_rebuild, layouts[id])
    end
end

--- Force + re-assert `laststatus = 3` for a tiled workspace (see the module header). Idempotent: one
--- shared augroup re-asserts whenever a workspace tab becomes current. The user's own value is captured
--- on the FIRST guard so `M.close` can put it back once the last workspace is gone — a global option
--- must not stay mutated for the rest of the session because a panel was opened once.
local function guard_chrome()
    if prev_laststatus == nil then
        prev_laststatus = vim.o.laststatus
    end
    vim.o.laststatus = 3
    if guard_group then
        return
    end
    guard_group = api.nvim_create_augroup("LvimUiWorkspaceChrome", { clear = true })
    api.nvim_create_autocmd("TabEnter", {
        group = guard_group,
        callback = function()
            if M.current() then
                vim.o.laststatus = 3
            end
        end,
    })
end

--- Strip window chrome off a backdrop window (fullscreen mode) so the ~4% margin around a fill-slot
--- surface float shows nothing — no line number, `~` tildes, sign/fold columns.
---@param win integer
local function strip_chrome(win)
    for opt, val in pairs({
        number = false,
        relativenumber = false,
        signcolumn = "no",
        foldcolumn = "0",
        statuscolumn = "",
        colorcolumn = "",
        cursorline = false,
        list = false,
        winfixbuf = true, -- the fill-slot float owns the tab; the backdrop window must not swap buffers
    }) do
        pcall(function()
            vim.wo[win][opt] = val
        end)
    end
    pcall(function()
        vim.wo[win].fillchars = "eob: "
    end)
end

--- Put the editor buffer into `win`: the consumer's buffer (or a factory), else a named scratch backdrop
--- (fullscreen mode / a placeholder). Returns the buffer used.
---@param win integer
---@param id string
---@param editor table?  spec.editor
---@return integer bufnr
local function set_editor_buf(win, id, editor)
    editor = editor or {}
    local buf = editor.buf
    if type(buf) == "function" then
        buf = buf()
    end
    if not buf then
        buf = api.nvim_create_buf(false, true)
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].swapfile = false
        -- Name it so the tabline reads the workspace title instead of "[No Name]".
        pcall(api.nvim_buf_set_name, buf, editor.name or (id:gsub("^%l", string.upper)))
        if editor.placeholder then
            api.nvim_buf_set_lines(buf, 0, -1, false, editor.placeholder)
            vim.bo[buf].modifiable = false
        end
        if editor.filetype then
            vim.bo[buf].filetype = editor.filetype
        end
    end
    pcall(api.nvim_win_set_buf, win, buf)
    return buf
end

---@class LvimUiWorkspaceEditor
---@field buf? integer|fun():integer  The buffer to place (or a factory); nil = a named scratch backdrop.
---@field placeholder? string[]       Lines for the scratch backdrop (rendered read-only).
---@field name? string                Buffer name (shown in the tabline); defaults to the capitalized id.
---@field filetype? string            Filetype for the scratch backdrop (e.g. "http" for highlighting).

---@class LvimUiWorkspaceSpec
---@field id string                       Unique key — the marker var value; also the tab title default.
---@field editor? LvimUiWorkspaceEditor   The editor / backdrop pane's initial buffer.
---@field layout? "stacked"|"full"        Initial region-layout state (see `M.layout`); default "stacked".
---@field menu? { name?: string, icon?: string }  How this workspace appears in the shared `<Leader>m` dock menu (name defaults to `editor.name`/id).
---@field restore? fun()                   How to REOPEN this workspace after it was closed — lets the dock menu restore it, not just focus it while open. Omit ⇒ the menu lists it only while its tab is open.
---@field sidebar? fun(ctx: { id: string, editor: integer }): any  Open the LEFT panel (consumer owns it). Return value is stored on the handle as `.sidebar`.
---@field dock? fun(editor: integer): any  Open the response/result DOCK (consumer owns it; typically anchored to the editor window). Return value stored as `.dock`.
---@field tiled? boolean                  Force the `laststatus = 3` chrome guard (default: true when `sidebar` or `dock` is set, false for a bare fullscreen slot).
---@field enter_editor? boolean           Focus the editor pane after building (default true).

---@class LvimUiWorkspaceHandle
---@field id string
---@field tab integer
---@field editor integer   the editor pane window
---@field existing boolean  true when an already-open tab was reused (refresh, don't rebuild)
---@field sidebar any       whatever `spec.sidebar` returned
---@field dock any          whatever `spec.dock` returned

--- Open (or focus) the workspace tab for `spec.id`. Creates a dedicated tab, marks it, parks the editor
--- buffer, runs the `sidebar` then `dock` builders, and (unless `enter_editor == false`) leaves the
--- cursor in the editor pane. Re-opening an already-open workspace just focuses it (`existing = true`).
---@param spec LvimUiWorkspaceSpec
---@return LvimUiWorkspaceHandle
function M.open(spec)
    local id = spec.id
    local existing = M.tab_for(id)
    if existing and api.nvim_tabpage_is_valid(existing) then
        api.nvim_set_current_tabpage(existing)
        return {
            id = id,
            tab = existing,
            editor = M.editor(id) or api.nvim_get_current_win(),
            existing = true,
        }
    end

    ws[id] = { origin = api.nvim_get_current_tabpage(), spec = spec }
    layouts[id] = spec.layout or "stacked"
    vim.cmd("tabnew")
    local tab = api.nvim_get_current_tabpage()
    api.nvim_tabpage_set_var(tab, MARK, id)

    local editor = api.nvim_get_current_win()
    api.nvim_win_set_var(editor, EDITOR_MARK, id)
    -- `tabnew` parked a fresh [No Name] here; `set_editor_buf` swaps the real buffer in and ORPHANS it.
    -- Wipe that orphan so repeated toggles don't leak a dead [No Name] per cycle.
    local blank = api.nvim_get_current_buf()
    local buf = set_editor_buf(editor, id, spec.editor)
    if api.nvim_buf_is_valid(blank) and blank ~= buf then
        local name = api.nvim_buf_get_name(blank)
        if name == "" and not vim.bo[blank].modified and #vim.fn.win_findbuf(blank) == 0 then
            pcall(api.nvim_buf_delete, blank, {})
        end
    end

    local tiled = spec.tiled
    if tiled == nil then
        tiled = spec.sidebar ~= nil or spec.dock ~= nil
    end
    if tiled then
        guard_chrome()
    else
        strip_chrome(editor)
    end

    -- Register this workspace in the shared `<Leader>m` dock menu (a COEXISTING tab entry), so every
    -- workspace — rest / db / git / forge — is reachable from one place. `show` focuses the tab when open,
    -- else restores it (when the consumer gave a `restore`). Registered once per id; the closures read live
    -- state. Guarded: no lvim-utils.dock (or an older one) ⇒ silently skip.
    do
        local ok_dock, dock = pcall(require, "lvim-utils.dock")
        if ok_dock and type(dock.register_tab) == "function" then
            local restore = spec.restore
            pcall(dock.register_tab, {
                id = id,
                name = (spec.menu and spec.menu.name) or (spec.editor and spec.editor.name) or id,
                icon = spec.menu and spec.menu.icon,
                show = function()
                    if M.is_open(id) then
                        M.focus(id)
                    elseif restore then
                        restore()
                    end
                end,
                is_current = function()
                    return M.current() == id
                end,
                is_alive = function()
                    return M.is_open(id) or restore ~= nil
                end,
            })
        end
    end

    local handle = { id = id, tab = tab, editor = editor, existing = false }
    if spec.sidebar then
        handle.sidebar = spec.sidebar({ id = id, editor = editor })
    end
    if spec.dock and api.nvim_win_is_valid(editor) then
        handle.dock = spec.dock(editor)
    end

    -- Building the sidebar/dock may have moved focus (a panel that enters itself); put it back.
    if spec.enter_editor ~= false and api.nvim_win_is_valid(editor) then
        pcall(api.nvim_set_current_win, editor)
    end
    return handle
end

--- Close the workspace tab for `id`: return to the origin tabpage, then drop the tab. Found by marker,
--- so it is robust to a stray `:tabclose`. Idempotent + re-entry safe. `on_close` runs BEFORE teardown
--- so the consumer can reset its own module state deterministically.
---@param id string
---@param on_close? fun()  consumer cleanup, run before the tab is torn down
function M.close(id, on_close)
    if closing[id] then
        return
    end
    closing[id] = true
    if on_close then
        pcall(on_close)
    end
    local t = M.tab_for(id)
    local origin = (ws[id] or {}).origin
    if t and api.nvim_tabpage_is_valid(t) then
        -- Leave the tab BEFORE closing it so focus lands where the user came from, not nvim's neighbour.
        if api.nvim_get_current_tabpage() == t and origin and api.nvim_tabpage_is_valid(origin) then
            pcall(api.nvim_set_current_tabpage, origin)
        end
        pcall(function()
            vim.cmd(api.nvim_tabpage_get_number(t) .. "tabclose")
        end)
    end
    if origin and api.nvim_tabpage_is_valid(origin) and api.nvim_get_current_tabpage() ~= origin then
        pcall(api.nvim_set_current_tabpage, origin)
    end
    ws[id] = nil
    layouts[id] = nil
    closing[id] = nil
    -- The LAST tiled workspace closing hands `laststatus` back. The TabEnter guard is gated on
    -- `M.current()`, so it cannot re-assert 3 once there is no workspace left.
    if prev_laststatus ~= nil and next(ws) == nil then
        vim.o.laststatus = prev_laststatus
        prev_laststatus = nil
    end
end

--- Open when closed, close when open — the single-launcher toggle.
---@param spec LvimUiWorkspaceSpec
---@param on_close? fun()
---@return LvimUiWorkspaceHandle?
function M.toggle(spec, on_close)
    if M.is_open(spec.id) then
        M.close(spec.id, on_close)
        return nil
    end
    return M.open(spec)
end

return M
