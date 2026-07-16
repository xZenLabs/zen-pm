local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")

local M = {}

-- These are the matching Zen UI inline icon map values. Zen UI registers its
-- Symbols Nerd Font as a Font fallback when it is active.
local nerd_icons = {
    search = "\u{F0349}",
    info = "\u{F02FD}", -- details
    update = "\u{F0CE2}",
    disable = "\u{F04DB}",
    downgrade = "\u{F0CDC}",
    uninstall = "\u{F0156}",
    enable = "\u{F040A}",
    remove = "\u{F0374}",
}

local fa_icons = {
    search = "\u{F002}",
    info = "\u{F129}",
    update = "\u{F01B}",
    disable = "\u{F04D}",
    downgrade = "\u{F01A}",
    uninstall = "\u{F1F8}",
    enable = "\u{F04B}",
    remove = "\u{F068}",
}

local function can_render_nerd_icons()
    for _i, font in ipairs(Font.fallbacks or {}) do
        -- Zen UI registers this bundled font. KOReader's own Symbols font is
        -- present even without Zen UI, so it must use the Font Awesome map.
        if font == "SymbolsNerdFont-Regular.ttf" then
            return true
        end
    end
    return false
end

function M.icon(name)
    local icons = can_render_nerd_icons() and nerd_icons or fa_icons
    return icons[name]
end

local spacers = { "\u{2003}", "\u{2002}", " ", "\u{2009}", "\u{200A}" }

local function text_width(text, face)
    local widget = TextWidget:new{
        text = text,
        face = face,
        bold = true,
    }
    local width = widget:getSize().w
    widget:free()
    return width
end

local function padded_icon(icon, icons)
    local face = Font:getFace("cfont", 20)
    local max_width = 0
    for _name, glyph in pairs(icons) do
        max_width = math.max(max_width, text_width(glyph, face))
    end

    local target_width = max_width + text_width("  ", face)
    local prefix = icon
    local width = text_width(prefix, face)
    while width < target_width do
        local next_prefix
        local next_width = width
        for _, spacer in ipairs(spacers) do
            local candidate = prefix .. spacer
            local candidate_width = text_width(candidate, face)
            if candidate_width <= target_width and candidate_width > next_width then
                next_prefix = candidate
                next_width = candidate_width
            end
        end
        if not next_prefix then break end
        prefix = next_prefix
        width = next_width
    end
    return prefix
end

function M.label(name, text)
    local icons = can_render_nerd_icons() and nerd_icons or fa_icons
    local icon = icons[name]
    return icon and (padded_icon(icon, icons) .. text) or text
end

return M
