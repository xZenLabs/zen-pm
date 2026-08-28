local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/ui/?.lua;" .. package.path

local image_options
local painted = false
local underline

package.preload["ui/geometry"] = function() return {} end
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
        ink = 1,
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

print("primitives tests passed")
