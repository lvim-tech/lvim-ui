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

describe("multiselect: a list that opens with items already selected")

--- Open a multiselect, hand the rows and the key to the check, and close it.
local function with_multiselect(opts, check)
    local ui = require("lvim-ui")
    local result
    ui.multiselect(vim.tbl_extend("force", opts, {
        callback = function(confirmed, selected)
            result = { confirmed = confirmed, selected = selected }
        end,
    }))
    vim.wait(100)
    local rows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    check(rows)
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
    vim.wait(1000, function()
        return result ~= nil
    end)
    truthy(result, "the callback ran")
    return result
end

it("seeds plain strings from initial_selected, and confirming keeps them", function()
    local result = with_multiselect({
        title = "t",
        items = { "a", "b", "c" },
        initial_selected = { a = true, c = true },
    }, function(rows)
        local a = rows[1]:gsub("a.*$", "")
        local b = rows[2]:gsub("b.*$", "")
        truthy(a ~= b, "a selected row looks different: " .. vim.inspect(rows))
        eq(a, (rows[3]:gsub("c.*$", "")))
    end)
    eq(true, result.confirmed)
    eq({ a = true, c = true }, result.selected)
end)

it("opens with nothing selected when told nothing", function()
    local result = with_multiselect({ title = "t", items = { "a", "b" } }, function() end)
    eq({}, result.selected)
end)
