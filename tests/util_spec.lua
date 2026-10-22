-- The string helpers every panel in the set lays its rows out with.
--
-- The invariant that matters: a row string handed to the painter must be EXACTLY as wide as the
-- panel. One cell too many and the full-line background spills past the border; one too few and
-- the background stops short of it. Both are visible, and neither is catchable by reading code —
-- so `center` and `lpad` are checked as a property over a table of awkward inputs: wide CJK, a
-- combining accent, an emoji, a Nerd Font glyph, Cyrillic, and the empty string.

local util = require("lvim-ui.util")

local AWKWARD = {
    "",
    "a",
    "plain text",
    "ляво дясно", -- Cyrillic, 1 cell per char
    "日本語のテキスト", -- 2 cells per char
    "mixed 日本語 text",
    "e\204\129", -- `e` + combining acute: two codepoints, one cell
    "👍 emoji",
    "", -- a Nerd Font glyph
    "very very very long line of text that will not fit anywhere at all",
}

describe("lvim-ui.util.dw")

it("measures display cells, not bytes", function()
    eq(1, util.dw("a"))
    eq(10, util.dw("ляво дясно"), "Cyrillic is one cell per character")
    eq(16, util.dw("日本語のテキスト"), "CJK is two cells per character")
    eq(0, util.dw(""))
    eq(0, util.dw(nil), "nil measures as nothing rather than erroring")
end)

describe("lvim-ui.util.clip")

it("never cuts a character in half", function()
    eq("日本", util.clip("日本語", 4), "two wide chars fit in four cells")
    eq("日本", util.clip("日本語", 5), "the third needs two cells, and only one is left")
    eq("", util.clip("日本語", 1), "no whole character fits in one cell")
end)

it("returns the string untouched when it already fits", function()
    eq("abc", util.clip("abc", 3))
    eq("abc", util.clip("abc", 99))
end)

it("gives back nothing for a non-positive width", function()
    eq("", util.clip("abc", 0))
    eq("", util.clip("abc", -3))
end)

describe("lvim-ui.util.truncate")

it("adds the ellipsis within the budget, never past it", function()
    local got = util.truncate("abcdefgh", 5)
    eq(5, util.dw(got), "the result must be exactly as wide as asked: " .. got)
    truthy(got:sub(-3) == "…", "it should end in an ellipsis: " .. got)
end)

it("degrades to the ellipsis alone, then to nothing", function()
    eq("…", util.truncate("abcdef", 1), "one cell holds the ellipsis and nothing else")
    eq("", util.truncate("abcdef", 0))
end)

it("leaves a string that fits alone", function()
    eq("abc", util.truncate("abc", 3))
    eq("日本語", util.truncate("日本語", 6))
end)

describe("lvim-ui.util: the width invariant")

it("center fills exactly the width it is given", function()
    for _, s in ipairs(AWKWARD) do
        for _, w in ipairs({ 1, 2, 3, 7, 8, 12, 20, 41 }) do
            local got = util.center(s, w)
            eq(w, util.dw(got), ("center(%q, %d) = %q"):format(s, w, got))
        end
    end
end)

it("lpad fills exactly the width it is given, at any indent", function()
    for _, s in ipairs(AWKWARD) do
        for _, w in ipairs({ 1, 2, 3, 7, 8, 12, 20, 41 }) do
            for _, indent in ipairs({ 0, 1, 2, 5 }) do
                local got = util.lpad(s, w, indent)
                eq(w, util.dw(got), ("lpad(%q, %d, %d) = %q"):format(s, w, indent, got))
            end
        end
    end
end)

describe("lvim-ui.util.title_case")

it("trims first, then uppercases, so no title keeps a double gutter", function()
    eq("TITLE", util.title_case("  title  "))
    eq("TWO WORDS", util.title_case("two words"))
    eq("", util.title_case(nil))
end)
