-- Row navigation: which row the cursor may land on, and which one it starts on.
--
-- Every panel in the set drives its cursor through these four functions, and a spacer row is the
-- trap in all of them: it is drawn but must never be selected, so a list that begins or ends with
-- one, or is nothing but spacers, is where an off-by-one or an unbounded walk would show.

local rows = require("lvim-ui.rows")

---@param name string
---@return table
local function row(name)
    return { name = name, type = "action" }
end

local function spacer()
    return { type = "spacer" }
end

describe("lvim-ui.rows.is_selectable")

it("rejects the two spacer shapes and accepts everything else", function()
    eq(false, rows.is_selectable({ type = "spacer" }))
    eq(false, rows.is_selectable({ type = "spacer_line" }))
    eq(true, rows.is_selectable({ type = "action" }))
    eq(true, rows.is_selectable({}), "a row with no type is still a row")
end)

describe("lvim-ui.rows.flatten")

it("walks into an expanded node only", function()
    local tree = {
        { name = "open", expanded = true, children = { row("a"), row("b") } },
        { name = "shut", expanded = false, children = { row("c") } },
    }
    eq({ "open", "a", "b", "shut" }, vim.tbl_map(function(r)
        return r.name
    end, rows.flatten(tree)))
end)

it("walks into everything when asked for the collapsed rows too", function()
    local tree = {
        { name = "shut", expanded = false, children = { row("c") } },
    }
    eq({ "shut", "c" }, vim.tbl_map(function(r)
        return r.name
    end, rows.flatten(tree, true)))
end)

it("handles no tree at all", function()
    eq({}, rows.flatten(nil))
    eq({}, rows.flatten({}))
end)

it("keeps nesting order depth-first", function()
    local tree = {
        { name = "a", expanded = true, children = { { name = "a1", expanded = true, children = { row("a1x") } } } },
        row("b"),
    }
    eq({ "a", "a1", "a1x", "b" }, vim.tbl_map(function(r)
        return r.name
    end, rows.flatten(tree)))
end)

describe("lvim-ui.rows.first_selectable")

it("skips the spacers at the top", function()
    eq(3, rows.first_selectable({ spacer(), spacer(), row("a") }))
end)

it("falls back to 1 when nothing can be selected", function()
    eq(1, rows.first_selectable({ spacer(), spacer() }))
    eq(1, rows.first_selectable({}))
end)

describe("lvim-ui.rows.next_selectable")

it("steps over the spacers in between", function()
    local list = { row("a"), spacer(), spacer(), row("b") }
    eq(4, rows.next_selectable(list, 1, 1))
    eq(1, rows.next_selectable(list, 4, -1))
end)

it("says nothing at the boundary instead of wrapping", function()
    local list = { row("a"), row("b") }
    eq(nil, rows.next_selectable(list, 2, 1), "past the end")
    eq(nil, rows.next_selectable(list, 1, -1), "before the start")
end)

it("terminates on a list of nothing but spacers", function()
    local list = { spacer(), spacer(), spacer() }
    eq(nil, rows.next_selectable(list, 1, 1))
    eq(nil, rows.next_selectable(list, 3, -1))
end)

describe("lvim-ui.rows.resolve_initial_row")

local list = { spacer(), row("first"), row("second"), spacer() }

it("finds a row by name", function()
    eq(3, rows.resolve_initial_row(list, "second"))
end)

it("takes an index when that row can be selected", function()
    eq(2, rows.resolve_initial_row(list, 2))
end)

it("moves on from an index that lands on a spacer", function()
    eq(2, rows.resolve_initial_row(list, 1), "row 1 is a spacer: the next selectable one is 2")
end)

it("falls back to the first selectable row for a name nobody has", function()
    eq(2, rows.resolve_initial_row(list, "no-such-row"))
    eq(2, rows.resolve_initial_row(list, nil))
    eq(2, rows.resolve_initial_row(list, 99), "an index past the end")
end)
