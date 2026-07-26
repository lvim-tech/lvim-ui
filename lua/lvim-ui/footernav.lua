-- lvim-ui.footernav: the tiny shared memory that makes the workspace footer bars a BIDIRECTIONAL layer in
-- the vertical (`<C-j>`/`<C-k>`) window chain.
--
-- Going DOWN is self-contained (a panel enters its own footer, the footer descends onto the window below),
-- but going back UP a full-width bottom window (a result grid spanning two columns) has no way to know
-- WHICH column it descended from, nor to stop on that window's footer bar on the way up. So every descent
-- past a footer records it here — the host window + a callable that re-enters its footer — and the bottom
-- window's `<C-k>` (its `on_escape_above`) calls `up()` to land back on THAT footer, layer by layer, in the
-- column the user actually came down from. A single most-recent slot is enough: you descend, then come up.
--
---@module "lvim-ui.footernav"

local M = {}

---@type { win: integer, enter: fun():boolean }?  the last footer descended THROUGH
local last = nil

--- Record a descent THROUGH a footer (called just before it steps onto the window below): `win` is the
--- footer's host window, `enter` re-focuses that footer (returns true if it actually did).
---@param win integer
---@param enter fun():boolean
function M.mark(win, enter)
    if win and type(enter) == "function" then
        last = { win = win, enter = enter }
    end
end

--- Step UP onto the footer of the window we last descended FROM, if that footer is still live. Consumes
--- the memory. Returns true when it landed on a footer (the caller then does nothing more).
---@return boolean
function M.up()
    local l = last
    last = nil
    if l and vim.api.nvim_win_is_valid(l.win) then
        return l.enter() == true
    end
    return false
end

--- Drop the memory (e.g. a footer's host window is closing).
function M.clear()
    last = nil
end

return M
