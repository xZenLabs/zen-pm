local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")

local Screen = Device.screen

local Theme = {
    bg = Blitbuffer.COLOR_WHITE,
    ink = Blitbuffer.COLOR_BLACK,
    muted = Blitbuffer.COLOR_DARK_GRAY,
    border = Blitbuffer.COLOR_BLACK,
    panel = Blitbuffer.COLOR_WHITE,
    soft = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_WHITE,
}

function Theme.scale(value)
    return Screen:scaleBySize(value)
end

function Theme.metrics()
    local w, h = Screen:getWidth(), Screen:getHeight()
    return {
        screen_w = w,
        screen_h = h,
        pad = Theme.scale(10),
        header_h = Theme.scale(78),
        nav_h = Theme.scale(86),
        card_gap = Theme.scale(8),
        card_h = Theme.scale(128),
        featured_h = Theme.scale(304),
        repo_h = Theme.scale(118),
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
        return Font:getFace("cfont", Theme.scale(18))
    elseif role == "heading" then
        return Font:getFace("cfont", Theme.scale(15))
    elseif role == "small" then
        return Font:getFace("smallinfofont", Theme.scale(11))
    elseif role == "mono" then
        return Font:getFace("smallinfofont", Theme.scale(10))
    end
    return Font:getFace("cfont", Theme.scale(13))
end

return Theme
