-- lvim-ui.preview: a `frame` center-panel provider that shows a file LOCATION by displaying the
-- file's REAL buffer in the panel window. Because it IS the buffer (not a copy), the preview is fully
-- EDITABLE and stays in two-way sync with the file for free: an edit made here lands in the file, and an
-- edit made in another window shows here. It swaps the buffer in, positions the cursor, and gives the
-- pane a file winbar. The diagnostic SIGNS are hidden here (`signcolumn = "no"`) — they belong to the
-- list panel; the preview stays a clean editable view.
--
-- Navigation out of the preview: the frame's panel/sector keys (`<C-h>`/`<C-l>` move panels, `<C-j>`/
-- `<C-k>` move header·center·footer) are bound on the file buffer ONLY while the preview window is
-- focused (added on WinEnter, removed on WinLeave) — a real buffer is shared, so a persistent map would
-- leak into every other window showing the file. They are normal-mode only, so text editing (and
-- insert-mode `<C-h>` = backspace) is untouched.
--
---@module "lvim-ui.preview"

local api = vim.api

local M = {}

-- A single shared BLANK scratch buffer shown when there is no location to preview (an empty filtered list)
-- — so the preview clears instead of keeping the previous file. Shared across previews (no per-open leak).
local shared_empty
local function empty_buffer()
    if not (shared_empty and api.nvim_buf_is_valid(shared_empty)) then
        shared_empty = api.nvim_create_buf(false, true)
        vim.bo[shared_empty].bufhidden = "hide"
    end
    return shared_empty
end

local NS = api.nvim_create_namespace("lvim-utils-preview-empty")

--- Paint `buf` as the "nothing to preview" placeholder: ONE full-width row styled like the file title bar
--- (the `LvimUiPeekEmpty` tint), so the empty state reads as a title bar with NO blank body beneath it. The
--- picker reuses this for its lines preview and the fzf backend, so the empty preview is IDENTICAL everywhere.
--- `ns` is the caller's extmark namespace (the caller wipes it when its own results render, so the title-bar
--- tint never bleeds onto a real preview line).
---@param buf integer
---@param ns integer
---@param message? string  the text (config.picker.empty_preview / opts.empty_preview; default "Nothing to preview")
function M.render_empty(buf, ns, message)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    vim.bo[buf].modifiable = true
    pcall(api.nvim_buf_set_lines, buf, 0, -1, false, { " " .. (message or "Nothing to preview") })
    vim.bo[buf].modifiable = false
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    pcall(api.nvim_buf_set_extmark, buf, ns, 0, 0, { end_row = 1, hl_group = "LvimUiPeekEmpty", hl_eol = true })
end

--- Highlight a SCRATCH preview buffer WITHOUT ever setting its `filetype`. Setting the filetype would fire the
--- FileType autocmds → lvim-ls / lvim-ts attach + the unified install prompt on every previewed file (and a
--- real LSP attach: spurious diagnostics, the autocmd cascade that pops the quickfix). So instead — exactly
--- like fzf-lua's previewer:
---   1. start the treesitter highlighter BY LANGUAGE (`vim.treesitter.start(buf, lang)`, never the filetype)
---      when the parser is installed → full treesitter colours, no FileType event, no offers, no LSP attach;
---   2. fall back to vim's regex `:syntax` (coarser) ONLY when no parser is installed.
--- The buffer is REUSED for each file scrolled past, so the previous file's highlighter is stopped first. (The
--- old reused-buffer treesitter heap-corruption — global `tostring` overwritten by the node one — is gone on
--- current Neovim; verified by stress test.) NOT for the editable real-file preview below — that IS the real
--- buffer and keeps its filetype + LSP + treesitter on purpose.
---@param buf integer
---@param ft string?  the source filetype; nil/"" clears highlighting
function M.set_syntax(buf, ft)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    pcall(vim.treesitter.stop, buf) -- drop the previous file's highlighter (the buffer is reused per file)
    ft = (ft and ft ~= "") and ft or ""
    -- Rich path: treesitter keyed by LANGUAGE, so no `filetype` is set → no FileType autocmd → no install
    -- offers and no LSP. Only fires when the parser is actually installed (pcall fails cleanly otherwise).
    local lang = ft ~= "" and vim.treesitter.language.get_lang(ft) or nil
    if lang then
        vim.bo[buf].syntax = "" -- no regex syntax double-painting under the treesitter highlighter
        if pcall(vim.treesitter.start, buf, lang) then
            return
        end
    end
    -- Fallback: vim's regex `:syntax` (coarser) when no parser exists for the language — still no filetype.
    if vim.bo[buf].syntax ~= ft then
        pcall(api.nvim_set_option_value, "syntax", ft, { buf = buf })
    end
end

--- Render a previewed file into a panel using a FRESH scratch buffer each call, then swap it into the panel
--- window and wipe the previous one. Treesitter caches ONE parser per buffer (the first language), so a reused
--- buffer cannot switch languages as you scroll between file types — `start()` then fails ("No parser for …")
--- and the highlight silently degrades to regex `:syntax`. A new buffer per file sidesteps that entirely — the
--- same reason fzf-lua swaps its preview buffer. The preview panel is display-only (its navigation keymaps live
--- on the LIST buffer), so swapping its buffer is safe; window-local options are reapplied by the caller.
---@param pan table     the preview panel (`pan.win`, `pan.buf`); `pan.buf` is updated to the new buffer
---@param lines string[]
---@param ft string?
function M.render_file(pan, lines, ft)
    if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
        return
    end
    local new = api.nvim_create_buf(false, true)
    vim.bo[new].bufhidden = "wipe"
    pcall(api.nvim_buf_set_lines, new, 0, -1, false, lines)
    vim.bo[new].modifiable = false
    M.set_syntax(new, ft)
    local old = pan.buf
    pcall(api.nvim_win_set_buf, pan.win, new)
    pan.buf = new
    if old and old ~= new and api.nvim_buf_is_valid(old) then
        pcall(api.nvim_buf_delete, old, { force = true })
    end
end

-- The frame nav keys bound on the focused preview buffer → the method/dir they drive on the frame.
local NAV = {
    { "<C-h>", "panel", -1 },
    { "<C-l>", "panel", 1 },
    { "<C-j>", "sector", 1 },
    { "<C-k>", "sector", -1 },
}

--- A filetype icon for `filename` from nvim-web-devicons when installed (colour discarded — the winbar
--- paints it), else a generic document glyph.
---@param filename string
---@return string
local function file_icon(filename)
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if ok then
        local icon = devicons.get_icon(
            vim.fn.fnamemodify(filename, ":t"),
            vim.fn.fnamemodify(filename, ":e"),
            { default = true }
        )
        if icon and icon ~= "" then
            return icon
        end
    end
    return ""
end

---@class LvimUiPreviewOpts
---@field item fun(): table|nil   returns the current location { filename, lnum, col, end_lnum?, end_col? }
---@field number? string          preview gutter: "none" | "normal" | "relative"
---@field empty? string           the "nothing to preview" placeholder text (default "Nothing to preview")

--- Create a preview provider.
---@param opts LvimUiPreviewOpts
---@return table provider
function M.new(opts)
    opts = opts or {}
    local cur_file -- the file currently shown (set the winbar only when it changes)
    local frame -- the owning frame state (captured from pan.frame), so the nav keys can reach it
    local nav_buf -- the buffer the nav keys are currently bound on (nil = none)
    local augroup -- the WinEnter/WinLeave group that adds/removes the nav keys
    local augroup_win -- the preview window the current augroup watches
    ---@type table<integer, true>
    local owned_buffers = {}

    local function remove_nav()
        if nav_buf and api.nvim_buf_is_valid(nav_buf) then
            for _, m in ipairs(NAV) do
                pcall(vim.keymap.del, "n", m[1], { buffer = nav_buf })
            end
        end
        nav_buf = nil
    end

    local function add_nav(buf)
        if nav_buf == buf then
            return
        end
        remove_nav()
        for _, m in ipairs(NAV) do
            local method, dir = m[2], m[3]
            vim.keymap.set("n", m[1], function()
                if frame then
                    frame[method](dir)
                end
            end, { buffer = buf, nowait = true, silent = true })
        end
        nav_buf = buf
    end

    --- One-time: while the preview window is focused, bind the frame nav keys on its (real) buffer; drop
    --- them again the moment focus leaves, so the shared file buffer is never left mapped elsewhere.
    ---@param pan table
    local function ensure_autocmds(pan)
        if augroup and augroup_win == pan.win then
            return
        end
        remove_nav()
        if augroup then
            pcall(api.nvim_del_augroup_by_id, augroup)
        end
        augroup_win = pan.win
        augroup = api.nvim_create_augroup("LvimUiPreviewNav_" .. tostring(pan.win), { clear = true })
        api.nvim_create_autocmd("WinEnter", {
            group = augroup,
            callback = function()
                if api.nvim_win_is_valid(pan.win) and api.nvim_get_current_win() == pan.win then
                    add_nav(api.nvim_win_get_buf(pan.win))
                end
            end,
        })
        api.nvim_create_autocmd("WinLeave", {
            group = augroup,
            callback = function()
                if api.nvim_get_current_win() == pan.win then
                    remove_nav()
                end
            end,
        })
    end

    return {
        item = opts.item, -- exposed so the dynamic peek float can read the focused location (lnum/col) directly
        -- Forget the shown file so the NEXT `update` re-asserts the winbar — used when the provider is
        -- re-rendered into a FRESH window (the dynamic peek float, recreated on each show), which has no winbar.
        reset = function()
            cur_file = nil
            remove_nav()
            if augroup then
                pcall(api.nvim_del_augroup_by_id, augroup)
                augroup = nil
                augroup_win = nil
            end
        end,
        on_close = function()
            remove_nav()
            if augroup then
                pcall(api.nvim_del_augroup_by_id, augroup)
                augroup = nil
                augroup_win = nil
            end
            for buf in pairs(owned_buffers) do
                if api.nvim_buf_is_valid(buf) and vim.bo[buf].modified == false then
                    pcall(api.nvim_buf_delete, buf, { force = true })
                end
            end
            owned_buffers = {}
        end,
        update = function(pan, _geom)
            local it = opts.item and opts.item()
            if not (pan.win and api.nvim_win_is_valid(pan.win)) then
                return
            end
            -- No focused location (e.g. the filtered list is empty) → show the BLANK placeholder so the
            -- preview doesn't keep showing the previous file. Leave it alone if the user is editing it.
            if not (it and it.filename) then
                if api.nvim_get_current_win() ~= pan.win then
                    local eb = empty_buffer()
                    if api.nvim_win_get_buf(pan.win) ~= eb then
                        api.nvim_win_set_buf(pan.win, eb)
                    end
                    cur_file = nil
                    vim.wo[pan.win].winbar = "" -- a plain styled row (no winbar → no empty body row)
                    M.render_empty(eb, NS, opts.empty)
                end
                return
            end
            frame = pan.frame
            ensure_autocmds(pan)
            -- If the user is IN the preview (editing it), don't swap its buffer or move its cursor out from
            -- under them on a list-navigation / live-reload refresh — leave the edit alone.
            if api.nvim_get_current_win() == pan.win then
                return
            end
            -- Show the REAL file buffer — editable, and bidirectionally in sync with the file (it is the
            -- buffer). Only swap when it actually changes (navigating rows of the same file just moves the
            -- cursor). `nvim_win_set_buf` (not `:edit`) avoids E37 on a modified buffer.
            local pbuf = vim.fn.bufadd(it.filename)
            local was_loaded = vim.api.nvim_buf_is_loaded(pbuf)
            vim.fn.bufload(pbuf)
            if not was_loaded then
                owned_buffers[pbuf] = true
            end
            if api.nvim_win_get_buf(pan.win) ~= pbuf then
                api.nvim_win_set_buf(pan.win, pbuf)
            end

            if cur_file ~= it.filename then
                cur_file = it.filename
                -- Full-width file winbar: filetype icon · name · directory.
                local rel = vim.fn.fnamemodify(it.filename, ":~:.")
                local tail = vim.fn.fnamemodify(it.filename, ":t")
                local dir = vim.fn.fnamemodify(rel, ":h")
                local wb = "%#LvimUiPeekFileIcon# " .. file_icon(it.filename) .. " %#LvimUiPeekFile#" .. tail .. " "
                if dir ~= "." and dir ~= "" then
                    wb = wb .. "%#LvimUiPeekFileBar# " .. dir
                end
                vim.wo[pan.win].winbar = wb .. "%#LvimUiPeekFileBar#%="
            end

            local pn = opts.number or "normal"
            vim.wo[pan.win].number = pn == "normal" or pn == "relative"
            vim.wo[pan.win].relativenumber = pn == "relative"
            vim.wo[pan.win].signcolumn = "no" -- diagnostic signs live in the list panel, not here
            vim.wo[pan.win].foldcolumn = "0"
            -- mark it a preview window so sticky-context plugins (treesitter-context) skip it — else the
            -- context header floats up out of this small pane over the statusline / the buffer above.
            vim.wo[pan.win].previewwindow = true
            vim.wo[pan.win].cursorline = true
            -- The preview is the RIGHT panel of the multi-panel peek → NEUTRAL cursorline (a bg line over
            -- the real source), matching the list panel; never the popup-list yellow.
            -- Keep FloatBorder mapped to the tinted peek-border group (set by open_panel_win): swapping the
            -- file buffer in here re-sets winhighlight, so without this the content-border ring loses its tint
            -- and reads as borderless next to the list panel.
            vim.wo[pan.win].winhighlight =
                "Normal:LvimUiPeekNormal,CursorLine:LvimUiCursorLine,FloatBorder:LvimUiPeekBorder"

            -- Place the cursor on the location (no extmark — a highlight on the real buffer would bleed
            -- into every other window showing this file).
            local lnum = math.min(it.lnum or 1, math.max(1, api.nvim_buf_line_count(pbuf)))
            pcall(api.nvim_win_set_cursor, pan.win, { lnum, math.max(0, (it.col or 1) - 1) })
            api.nvim_win_call(pan.win, function()
                vim.cmd("normal! zz")
            end)
        end,
    }
end

return M
