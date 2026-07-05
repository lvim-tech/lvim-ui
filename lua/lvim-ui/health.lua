-- lvim-ui.health: `:checkhealth lvim-ui` — reports that the floating UI toolkit is loadable, its required
-- base (lvim-utils) is present, and which OPTIONAL integrations are available (lvim-hud for the statusline
-- title overlay). Pure diagnostics; it changes nothing.
--
---@module "lvim-ui.health"

local M = {}

local health = vim.health
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local err = health.error or health.report_error
local info = health.info or health.report_info

--- Whether a Lua module can be required without error.
---@param mod string
---@return boolean
local function has(mod)
    return (pcall(require, mod))
end

function M.check()
    start("lvim-ui")

    if vim.fn.has("nvim-0.12") == 1 then
        ok("Neovim >= 0.12")
    else
        err("Neovim >= 0.12 required")
    end

    -- Required base.
    if has("lvim-utils.utils") then
        ok("lvim-utils (base: utils / highlight / colors / cursor) is available")
    else
        err("lvim-utils not found — lvim-ui requires it (utils.merge, palette, highlight, cursor)")
    end

    -- The toolkit itself.
    if has("lvim-ui.surface") and has("lvim-ui.config") then
        ok("lvim-ui toolkit loaded (surface / frame / button / bar / rows)")
    else
        err("lvim-ui modules failed to load")
    end

    -- Optional integrations.
    if has("lvim-hud.overlay") then
        ok("lvim-hud present — a surface title can publish to the statusline overlay")
    else
        info("lvim-hud not installed — statusline title overlay is disabled (optional)")
    end

    local config = require("lvim-ui.config")
    info("popup filetype: " .. tostring(config.filetype))
    info("title placement: " .. tostring(config.title_line) .. " · counter: " .. tostring(config.counter))
    if config.backdrop and config.backdrop.float then
        local bf = config.backdrop.float
        if bf.enabled == false then
            warn("float backdrop is disabled")
        else
            info("float backdrop: " .. tostring(bf.mode) .. " · amount " .. tostring(bf.amount))
        end
    end
end

return M
