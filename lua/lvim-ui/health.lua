-- lvim-ui.health: `:checkhealth lvim-ui` — reports that the floating UI toolkit is loadable, its required
-- base (lvim-utils) is present, and which OPTIONAL integrations are available (lvim-hud for the statusline
-- title overlay). Pure diagnostics; it changes nothing.
--
---@module "lvim-ui.health"

local M = {}

local health = vim.health

--- Whether a Lua module can be required without error.
---@param mod string
---@return boolean
local function has(mod)
    return (pcall(require, mod))
end

function M.check()
    health.start("lvim-ui")

    if vim.fn.has("nvim-0.12") == 1 then
        health.ok("Neovim >= 0.12")
    else
        health.error("Neovim >= 0.12 required")
    end

    -- Required base.
    if has("lvim-utils.utils") then
        health.ok("lvim-utils (base: utils / highlight / colors / cursor) is available")
    else
        health.error("lvim-utils not found — lvim-ui requires it (utils.merge, palette, highlight, cursor)")
    end

    -- The toolkit itself.
    if has("lvim-ui.surface") and has("lvim-ui.config") then
        health.ok("lvim-ui toolkit loaded (surface / frame / button / bar / rows)")
    else
        health.error("lvim-ui modules failed to load")
    end

    -- Optional integrations.
    if has("lvim-hud.overlay") then
        health.ok("lvim-hud present — a surface title can publish to the statusline overlay")
    else
        health.info("lvim-hud not installed — statusline title overlay is disabled (optional)")
    end

    local config = require("lvim-ui.config")
    health.info("popup filetype: " .. tostring(config.filetype))
    health.info("title placement: " .. tostring(config.title_line) .. " · counter: " .. tostring(config.counter))
    if config.backdrop and config.backdrop.float then
        local bf = config.backdrop.float
        if bf.enabled == false then
            health.warn("float backdrop is disabled")
        else
            local amt = bf[bf.mode] and bf[bf.mode].amount
            health.info("float backdrop: " .. tostring(bf.mode) .. " · amount " .. tostring(amt))
        end
    end
end

return M
