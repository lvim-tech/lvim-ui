-- lvim-ui.button: render one bar element into text + highlight spans.
--
-- The ONE box model used across the whole UI: every visible element is a box —
--   { <content>, style = { padding = { front, back }, <colour> } }
-- where the colour is per-state (normal/active/hover) for interactive boxes or a single `hl` for static
-- ones. This module renders the two bar element TYPES out of that model:
--
--   "button"    — a LEAD box + a TEXT box.
--                 · lead box  = an icon glyph (`icon`) OR, with `key_badge`, the whole `key` as a badge.
--                 · text box  = the caption (`text`); when NOT a badge, `key`/`key_pos` brackets one
--                   letter of the caption (the `[X]` shortcut hint, drawn in the lead/accent colour),
--                   and an optional `count` trails inside the text box.
--                 · `style = { icon = <box>, text = <box> }`, each box per-state. Default padding {2,2}.
--   "separator" — a SINGLE box carrying an optional divider glyph/text (`text`), or nothing at all = a
--                 pure space. Static (one colour). `style = <box>` directly. Bar chevrons are rendered
--                 as separator specs, so they share this exact path.
--
-- `run`/`active`/the click target live on the spec but are consumed by `ui.bar`, not here.
--
---@module "lvim-ui.button"

local M = {}

---@alias LvimUiButtonState "normal"|"active"|"hover"|"hover_active"

---@class LvimUiBoxStyle
---@field padding? integer|integer[]  -- { front, back } (or a number = symmetric)
---@field normal? string              -- per-state colour (interactive boxes)
---@field active? string
---@field hover? string
---@field hover_active? string        -- the cursor (hover) ON the active button — distinct from plain hover so
---                                    --   landing on the active button still reads (falls back to hover)
---@field hl? string                  -- single colour (static boxes: separator / chevron / title)

---@class LvimUiButtonSpec
---@field type "button"|"separator"
---@field icon? string                -- button: lead box glyph (when not a key badge)
---@field text? string|fun(): string  -- button: caption ; separator: optional divider glyph/text
---@field key? string                 -- hotkey; with `key_badge` the lead box shows it whole, else it
---                                    --   brackets its letter in `text`
---@field key_pos? integer            -- button: explicit 1-based char index in `text` to bracket
---@field key_brackets? boolean       -- button: false = highlight the hotkey letter WITHOUT the `[ ]` brackets
---@field key_badge? boolean          -- true: lead box = the whole `key` as a badge (action style)
---@field count? number|string|fun(): (number|string|nil)  -- button: optional trailing count
---@field active? boolean             -- the semantically active button (the bar reads it)
---@field run? fun()                  -- what firing the button does (consumed by ui.bar)
---@field separator? string           -- legacy ui.bar marker — a non-interactive entry (see ui.bar)
---@field style? table                -- button: { icon = LvimUiBoxStyle, text = LvimUiBoxStyle }
---                                    --   separator: LvimUiBoxStyle directly

-- ── helpers ───────────────────────────────────────────────────────────────────

---@param n integer
---@return string
local function sp(n)
    return string.rep(" ", math.max(0, n))
end

--- Resolve a { front, back } pair from a padding value: a number (symmetric), a { front, back } table,
--- or nil (→ the given defaults).
---@param v integer|integer[]|nil
---@param df integer
---@param db integer
---@return integer front, integer back
local function pad_pair(v, df, db)
    if type(v) == "number" then
        return v, v
    elseif type(v) == "table" then
        return v[1] or df, v[2] or db
    end
    return df, db
end

--- Resolve a box's highlight group for `state`: per-state when the box defines normal/active/hover,
--- else its single static `hl`.
---@param bs LvimUiBoxStyle|nil
---@param state LvimUiButtonState|nil
---@return string|nil
local function box_hl(bs, state)
    if not bs then
        return nil
    end
    if state and (bs.normal or bs.active or bs.hover or bs.hover_active) then
        -- `hover_active` (the cursor on the active button) degrades gracefully to plain hover, then active,
        -- then normal — so a style that doesn't define it behaves exactly as before.
        if state == "hover_active" then
            return bs.hover_active or bs.hover or bs.active or bs.normal
        end
        return bs[state] or bs.normal
    end
    return bs.hl or bs.normal
end

--- The 1-based char index in `label` to bracket as the shortcut hint: an explicit `key_pos`, else the
--- KEY's first occurrence (case-insensitively), else the first char. The single home of the "[X]"
--- shortcut convention — shared by `render` and by row widgets (segmented / bracket_key option rows).
---@param label string
---@param key? string
---@param key_pos? integer
---@return integer
function M.key_pos(label, key, key_pos)
    local pos = key_pos
    if not pos and key and #key == 1 then
        -- `find` returns a BYTE index, but render / rows.segmented treat `pos` as a UTF-32 CHARACTER index
        -- (str_byteindex "utf-32"). Convert byte→char so a caption with a multibyte glyph before the hotkey
        -- brackets the RIGHT letter (latent while captions are ASCII, where byte == char).
        local b = label:lower():find(key:lower(), 1, true)
        pos = b and (vim.fn.charidx(label, b - 1) + 1) or nil
    end
    return math.max(1, math.min(pos or 1, vim.fn.strchars(label) > 0 and vim.fn.strchars(label) or 1))
end

-- ── render ────────────────────────────────────────────────────────────────────

--- Render `spec` in `state`. Returns the text and its hl spans ({ byte_c0, byte_c1, hl_group }, byte
--- columns into the returned text).
---@param spec LvimUiButtonSpec
---@param state LvimUiButtonState
---@return string text, table[] spans
function M.render(spec, state)
    local text, spans = "", {}
    local function put(s, hl)
        if s ~= "" and hl then
            spans[#spans + 1] = { #text, #text + #s, hl }
        end
        text = text .. s
    end

    -- separator: a single static box — optional glyph/text + padding, or nothing = a pure space.
    if spec.type == "separator" then
        local bs = spec.style or {}
        local f, b = pad_pair(bs.padding, 0, 0)
        put(sp(f) .. (spec.text or spec.separator or "") .. sp(b), box_hl(bs, state))
        return text, spans
    end

    -- button: a lead box (icon / key badge) + a text box (caption [+ bracketed key] [+ count]).
    local style = spec.style or {}
    local istyle, tstyle = style.icon or {}, style.text or {}
    local lf, lb = pad_pair(istyle.padding, 2, 2)
    local tf, tb = pad_pair(tstyle.padding, 2, 2)
    local ihl, thl = box_hl(istyle, state), box_hl(tstyle, state)

    local lead = spec.key_badge and spec.key or spec.icon
    if lead and lead ~= "" then
        put(sp(lf) .. lead .. sp(lb), ihl)
    end

    local txt = spec.text
    if type(txt) == "function" then
        txt = txt()
    end
    txt = txt or ""
    -- On HOVER, bracket the text box — `[caption]` — CONSUMING one padding cell each side, so the button's
    -- width (and the whole bar's layout) is unchanged: no reflow, the label just gains `[ ]`. Only when there
    -- is padding to consume on both sides (else brackets would widen the button). The brackets wear the text
    -- colour (itself the deeper hover tint).
    --
    -- ONLY for a SINGLE-PART, KEY-LESS button — a bare caption with no other cue. A button that already
    -- advertises itself some OTHER way must NOT also get `[ ]`, or it double-brackets and reads as noise:
    --   · a hotkey — the whole key as a lead badge (`s stage`) or its letter bracketed inside the caption
    --     (`[s]tage`);
    --   · a lead box — an icon/badge two-part button (`icon + label` TAB) whose glyph is its affordance.
    -- Only a truly cue-less button (the filter bands: All / Staged / Unstaged / Untracked …) has nothing to
    -- lean on, and for it these hover brackets ARE the affordance.
    local two_part = (lead and lead ~= "") or spec.key or spec.key_pos
    local hovered = not two_part and (state == "hover" or state == "hover_active") and tf >= 1 and tb >= 1
    if hovered then
        put(sp(tf - 1) .. "[", thl)
    else
        put(sp(tf), thl) -- text box left pad
    end
    if not spec.key_badge and (spec.key or spec.key_pos) and txt ~= "" then
        local pos = M.key_pos(txt, spec.key, spec.key_pos)
        local byte_pos = vim.str_byteindex(txt, "utf-32", pos - 1, false) + 1
        local next_byte = vim.str_byteindex(txt, "utf-32", pos, false) + 1
        put(txt:sub(1, byte_pos - 1), thl)
        -- The shortcut hint takes the lead/accent colour — but FALLS BACK to the text colour when the button
        -- defines no lead box (no `style.icon`), so `[X]`/brackets read as part of the caption instead of a
        -- stray default colour.
        if spec.key_brackets == false then
            put(txt:sub(byte_pos, next_byte - 1), ihl or thl) -- just the hotkey letter, no brackets
        else
            put("[" .. txt:sub(byte_pos, next_byte - 1) .. "]", ihl or thl) -- the bracketed key
        end
        put(txt:sub(next_byte), thl)
    else
        put(txt, thl)
    end
    local count = spec.count
    if type(count) == "function" then
        count = count()
    end
    if count ~= nil and count ~= "" then
        put(" " .. tostring(count), thl)
    end
    if hovered then
        put("]" .. sp(tb - 1), thl)
    else
        put(sp(tb), thl) -- text box right pad
    end
    return text, spans
end

return M
