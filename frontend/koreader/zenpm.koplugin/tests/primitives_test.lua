local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/ui/?.lua;" .. package.path

local image_options
local painted = false
local underline

package.preload["ffi/blitbuffer"] = function()
    return { isColor8 = function(color) return type(color) == "number" end }
end
package.preload["ui/geometry"] = function() return { new = function(_, value) return value end } end
local pixels = {}
local color_screen = false
local feedback_box
local feedback_events = {}
local screen = {
    isColorScreen = function() return color_screen end,
    bb = { invertRect = function(_, x, y, w, h)
        for row = y, y + h - 1 do
            for col = x, x + w - 1 do
                local index = row * 40 + col
                pixels[index] = 255 - pixels[index]
            end
        end
    end },
}
package.preload["device"] = function() return { screen = screen } end
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function(_, widget, mode, region)
            assert(widget == nil and mode == (color_screen and "ui" or "fast"))
            assert(region.x == feedback_box.x and region.y == feedback_box.y)
            assert(region.w == feedback_box.w and region.h == feedback_box.h)
            feedback_events[#feedback_events + 1] = "dirty"
        end,
        forceRePaint = function() feedback_events[#feedback_events + 1] = "repaint" end,
        yieldToEPDC = function()
            assert(pixels[feedback_box.y * 40 + feedback_box.x] == 32, "corners must stay rounded")
            local center = (feedback_box.y + math.floor(feedback_box.h / 2)) * 40
                + feedback_box.x + math.floor(feedback_box.w / 2)
            assert(pixels[center] == 223, "the highlight must be visible before restoring")
            assert(pixels[0] == 32, "feedback must stay inside the control")
            feedback_events[#feedback_events + 1] = "yield"
        end,
    }
end
package.preload["ui/widget/imagewidget"] = function()
    return {
        new = function(_, options)
            image_options = options
            return {
                paintTo = function()
                    painted = true
                end,
                free = function() end,
            }
        end,
    }
end
package.preload["ui/widget/textwidget"] = function() return {} end
package.preload["ui/widget/textboxwidget"] = function()
    return {
        new = function()
            return {
                use_xtext = true,
                virtual_line_num = 1,
                lines_per_page = 1,
                line_height_px = 20,
                vertical_string_list = { {} },
                paintTo = function() end,
                getSize = function() return { w = 100, h = 20 } end,
                getXtextHighlightRects = function()
                    return { { x = 10, y = 0, w = 30, h = 20 } }
                end,
                free = function() end,
            }
        end,
    }
end
package.preload["ui/theme"] = function()
    return {
        face = function() return { size = 10 } end,
        scale = function(value) return value end,
        metrics = function() return { radius = 8 } end,
        ink = 1,
        bg = 0,
        panel = 0,
        border = 1,
        button_bg = 2,
        button_text = 3,
    }
end

local P = require("ui/primitives")
assert(P.image({}, "upgrade.svg", 0, 0, 24, 24, { is_icon = true, invert = true }))
assert(painted)
assert(image_options.invert == true)
assert(image_options.alpha == false)

assert(P.image({}, "packages.svg", 0, 0, 24, 24, { is_icon = true }))
assert(image_options.invert == nil)
assert(image_options.alpha == true)

local styled_icons = 0
package.loaded["common/ui/accent"] = { styleIcon = function(_, active)
    assert(active)
    styled_icons = styled_icons + 1
end }
assert(P.image({}, "upgrade.svg", 0, 0, 24, 24, { is_icon = true, invert = true }))
assert(image_options.alpha == true and not image_options.invert and styled_icons == 1)
package.loaded["common/ui/accent"] = nil

local drawn = {}
local drawing_buffer = {}
for _i, name in ipairs({ "paintRect", "paintRectRGB32", "paintRoundedRect", "paintRoundedRectRGB32",
    "paintBorder", "paintBorderRGB32" }) do
    drawing_buffer[name] = function(_bb, _x, _y, _w, _h, color_or_size, color)
        drawn[#drawn + 1] = { name = name,
            color = name:find("paintBorder", 1, true) and color or color_or_size }
    end
end
local rgb = {}
P.rect(drawing_buffer, 0, 0, 24, 16, rgb)
assert(drawn[#drawn].name == "paintRectRGB32" and drawn[#drawn].color == rgb)
P.rounded_rect(drawing_buffer, 0, 0, 24, 16, rgb, 8)
assert(drawn[#drawn].name == "paintRoundedRectRGB32" and drawn[#drawn].color == rgb)
P.stroke(drawing_buffer, 0, 0, 24, 16, 2, rgb)
assert(drawn[#drawn].name == "paintBorderRGB32" and drawn[#drawn].color == rgb)
P.rect(drawing_buffer, 0, 0, 24, 16, 1)
assert(drawn[#drawn].name == "paintRect")

local Theme = require("ui/theme")
Theme.button_bg = rgb
P.focus_outline(drawing_buffer, 0, 0, 24, 16)
assert(drawn[#drawn].color == rgb)
Theme.button_text = Theme.ink
P.focus_outline(drawing_buffer, 0, 0, 24, 16, true)
assert(drawn[#drawn].color == Theme.ink, "light accents must keep visible focus outlines")
Theme.button_text = 3
drawn = {}
P.zen_toggle(drawing_buffer, 0, 0, 56, 28, true)
local has_fill, has_knob = false, false
for _i, drawing in ipairs(drawn) do
    has_fill = has_fill or drawing.name == "paintRectRGB32" and drawing.color == rgb
    has_knob = has_knob or drawing.color == Theme.button_text
end
assert(has_fill and has_knob, "enabled toggles need the accent and its contrasting knob")
drawn = {}
P.zen_toggle(drawing_buffer, 0, 0, 56, 28, false)
for _i, drawing in ipairs(drawn) do
    assert(drawing.name == "paintRect" and drawing.color ~= rgb, "off toggles must remain monochrome")
end
local Scroll = require("ui/scroll")
local scroll_view = { hitboxes = {}, list_bounds = { x = 0, y = 0, w = 100, h = 200 } }
drawn = {}
Scroll.draw_scrollbar(scroll_view, drawing_buffer, 200, 0)
assert(#drawn == 2 and drawn[1].color == rgb and drawn[2].color == rgb)
local saved_buffer = screen.bb
screen.bb = drawing_buffer
drawn = {}
assert(Scroll.paint_drag_thumb(scroll_view, 150))
assert(drawn[#drawn - 1].color == rgb and drawn[#drawn].color == rgb)
screen.bb = saved_buffer
Theme.button_bg = 2

local view = { hitboxes = {} }
local opened
P.scrollable_paragraph({
    paintRect = function(_, x, y, w, h)
        underline = { x = x, y = y, w = w, h = h }
    end,
}, "link", 0, 0, 100, 20, "small", 0, {
    links = { { start_idx = 1, end_idx = 4, url = "https://example.com" } },
    link_view = view,
    link_callback = function(url) opened = url end,
})
assert(underline.x == 10 and underline.y == 19 and underline.w == 30 and underline.h == 1)
assert(#view.hitboxes == 1 and view.hitboxes[1].label == "readme-link:https://example.com")
view.hitboxes[1].callback()
assert(opened == "https://example.com")

local flash_disabled = false
G_reader_settings = { isFalse = function(_, key)
    assert(key == "flash_ui")
    return flash_disabled
end }
for index = 0, 40 * 40 - 1 do pixels[index] = 32 end
for _, color in ipairs({ false, true }) do
    color_screen = color
    for _, size in ipairs({ { 24, 16 }, { 30, 20 }, { 4, 4 } }) do
        feedback_box = { x = 8, y = 8, w = size[1], h = size[2] }
        feedback_events = {}
        P.flash(feedback_box)
        assert(table.concat(feedback_events, ",") == "dirty,repaint,yield,dirty")
        for _, pixel in pairs(pixels) do
            assert(pixel == 32, "feedback must restore every pixel before the callback")
        end
    end
end
feedback_events = {}
flash_disabled = true
P.flash(feedback_box)
assert(#feedback_events == 0)
flash_disabled = false
feedback_box.allow_flash = false
P.flash(feedback_box)
assert(#feedback_events == 0)
feedback_box.allow_flash = nil

local zen_flashes = 0
package.loaded["common/ui/button_feedback"] = { flash = function(region)
    assert(region.x == feedback_box.x and region.y == feedback_box.y)
    assert(region.w == feedback_box.w and region.h == feedback_box.h)
    zen_flashes = zen_flashes + 1
end }
P.flash(feedback_box)
assert(zen_flashes == 1 and #feedback_events == 0, "reuse ZenOS's feedback when loaded")
package.loaded["common/ui/button_feedback"] = nil

local borders = 0
local border_buffer = { paintBorder = function(_, _, _, _, _, _, _, radius)
    assert(radius == 8, "focus highlights must have rounded corners")
    borders = borders + 1
end }
P.focus_outline(border_buffer, 8, 8, 24, 16)
P.focus_outline(border_buffer, 8, 8, 24, 16, true)
assert(borders == 2)
P.hit(view, 8, 8, 24, 16, function() end, "scrollbar", false)
assert(view.hitboxes[#view.hitboxes].allow_flash == false)

print("primitives tests passed")
