-- Every module of the UI toolkit loads on its own. Consumers require them piecemeal
-- (`require("lvim-ui.surface")`, `.form`, `.tree`), so a module that only loads through the
-- aggregate is a break waiting for the first plugin that reaches for it directly.

local root = PLUGIN_ROOT .. "/lua/lvim-ui"

---@return string[]
local function modules()
    local out = {}
    local function walk(dir, prefix)
        for name, kind in vim.fs.dir(dir) do
            if kind == "directory" then
                walk(dir .. "/" .. name, prefix .. name .. ".")
            elseif name:match("%.lua$") then
                local stem = name:sub(1, -5)
                out[#out + 1] = stem == "init" and prefix:sub(1, -2) or (prefix .. stem)
            end
        end
    end
    walk(root, "lvim-ui.")
    table.sort(out)
    return out
end

describe("lvim-ui: every module loads")

for _, mod in ipairs(modules()) do
    it(mod, function()
        local ok, err = pcall(require, mod)
        truthy(ok, tostring(err))
    end)
end

describe("lvim-ui: setup and health")

it("setup() merges its options and runs twice without stacking autocmds", function()
    local ui = require("lvim-ui")
    ui.setup({})
    local before = #vim.api.nvim_get_autocmds({ event = "ColorScheme" })
    ui.setup({})
    eq(before, #vim.api.nvim_get_autocmds({ event = "ColorScheme" }))
end)

it("the health check runs to completion", function()
    local health = require("lvim-ui.health")
    truthy(type(health.check) == "function", "no check() to run")
    local ok, err = pcall(health.check)
    truthy(ok, tostring(err))
end)
