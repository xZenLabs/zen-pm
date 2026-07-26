local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")

local M = {}

-- Rendered via ZenPM's bundled Symbols Nerd Font subset.
local nerd_icons = {
    filter = "\u{f0236}",
    search = "\u{F0349}",
    sort = "\u{F04BA}",
    sort_asc = "\u{F15D}", -- mdi-sort-ascending
    sort_desc = "\u{F15E}", -- mdi-sort-descending
    date = "\u{F0150}",
    star = "\u{F04CE}",
    clear = "\u{F1147}",
    info = "\u{F02FD}", -- details
    details = "\u{F02FD}",
    update = "\u{F0CE2}",
    upgrade = "\u{F0CE2}",
    refresh = "\u{F0450}",
    settings_bug = "\u{F00E4}",
    settings = "\u{F0493}",
    disable = "\u{F04DB}",
    downgrade = "\u{F062C}",
    uninstall = "\u{F0156}",
    enable = "\u{F040A}",
    remove = "\u{F0374}",
    remove_queue = "\u{F0A7A}",
}

function M.icon(name)
    return nerd_icons[name]
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
    local icon = nerd_icons[name]
    return icon and (padded_icon(icon, nerd_icons) .. text) or text
end

return M
