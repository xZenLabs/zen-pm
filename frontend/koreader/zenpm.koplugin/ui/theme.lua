local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")

local Screen = Device.screen
local base_font_size = 14
local default_base_font_size = base_font_size

local Theme = {
    bg = Blitbuffer.COLOR_WHITE,
    ink = Blitbuffer.COLOR_BLACK,
    muted = Blitbuffer.COLOR_DARK_GRAY,
    border = Blitbuffer.COLOR_BLACK,
    panel = Blitbuffer.COLOR_WHITE,
    soft = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_WHITE,
}

Theme.MIN_BASE_FONT_SIZE = 8
Theme.MAX_BASE_FONT_SIZE = 32

function Theme.normalize_base_font_size(value)
    local size = tonumber(value)
    if not size then
        return base_font_size
    end
    return math.max(Theme.MIN_BASE_FONT_SIZE, math.min(Theme.MAX_BASE_FONT_SIZE, math.floor(size + 0.5)))
end

function Theme.set_base_font_size(value)
    base_font_size = Theme.normalize_base_font_size(value)
    return base_font_size
end

function Theme.get_base_font_size()
    return base_font_size
end

function Theme.scale(value)
    return Screen:scaleBySize(value)
end

function Theme.font_scale(value)
    local font_ratio = base_font_size / default_base_font_size
    local damped_ratio = 1 + (font_ratio - 1) / 2
    return math.max(1, math.floor(Theme.scale(value) * damped_ratio + 0.5))
end

function Theme.has_color()
    return Device:hasColorScreen()
end

function Theme.metrics()
    local w, h = Screen:getWidth(), Screen:getHeight()
    return {
        screen_w = w,
        screen_h = h,
        pad = Theme.scale(10),
        header_h = Theme.scale(78),
        nav_h = Theme.scale(86),
        nav_bottom_margin = Theme.has_color() and Theme.scale(5) or 0,
        card_gap = Theme.scale(8),
        card_h = Theme.scale(144),
        featured_h = Theme.scale(304),
        repo_h = Theme.scale(118),
        category_h = Theme.scale(84),
        action_w = Theme.scale(104),
        action_h = Theme.scale(42),
        search_h = Theme.scale(46),
        touch_min = Theme.scale(44),
        radius = Theme.scale(8),
        nav_radius = Theme.scale(10),
    }
end

function Theme.face(role)
    if role == "title" then
        return Font:getFace("cfont", base_font_size + 5)
    elseif role == "heading" then
        return Font:getFace("cfont", base_font_size + 2)
    elseif role == "small" then
        return Font:getFace("smallinfofont", base_font_size - 2)
    elseif role == "card_title" then
        return Font:getFace("smallinfofont", base_font_size - 3)
    elseif role == "tiny" then
        return Font:getFace("smallinfofont", base_font_size - 4)
    elseif role == "tiny_lg" then
        return Font:getFace("smallinfofont", base_font_size - 3)
    elseif role == "nav" then
        return Font:getFace("smallinfofont", base_font_size - 4)
    elseif role == "mono" then
        return Font:getFace("smallinfofont", base_font_size - 3)
    end
    return Font:getFace("cfont", base_font_size)
end

return Theme
