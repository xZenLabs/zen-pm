local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

package.preload["ui/font"] = function()
    return { getFace = function() return {} end }
end
package.preload["ui/widget/textwidget"] = function()
    return { new = function(_, options)
        return { getSize = function() return { w = #options.text, h = 24 } end, free = function() end }
    end }
end
package.preload["device"] = function()
    return { screen = { scaleBySize = function(_, value) return value end } }
end
local files = {}
package.preload["ui/images"] = function()
    return { custom_icon = function(name) return files[name] end }
end
local image, glyph
local image_ok = true
package.preload["ui/primitives"] = function()
    return {
        image = function(_, file, x, y, w, h, opts)
            image = { file = file, x = x, y = y, w = w, h = h, opts = opts }
            return image_ok
        end,
        center_text_box = function(_, text) glyph = text end,
    }
end

local Icons = require("ui/inline_icon_map")
local default_label = Icons.label("search", "Search")
assert(default_label:find(Icons.icon("search"), 1, true))
Icons.paint({}, "search", 10, 20, 24, 42, "small")
assert(glyph == Icons.icon("search") and image == nil)

files.search = "/custom/search.png"
glyph = nil
Icons.paint({}, "search", 10, 20, 24, 42, "small", { invert = true })
assert(image.file == files.search and image.x == 10 and image.y == 29)
assert(image.w == 24 and image.h == 24 and image.opts.is_icon and image.opts.invert)
assert(glyph == nil)
local label = Icons.label("search", "Search")
assert(label:sub(-6) == "Search" and not label:find(Icons.icon("search"), 1, true))
assert(Icons.label("sort", "Sort"):find(Icons.icon("sort"), 1, true))
image_ok = false
Icons.paint({}, "search", 10, 20, 24, 42, "small")
assert(glyph == Icons.icon("search"), "failed custom images must keep a visible fallback")
image_ok = true

local paints = 0
local paint_label = function() paints = paints + 1 end
local widget = { paintTo = paint_label, getSize = function() return { w = 100, h = 32 } end }
local fallback_widget = { paintTo = paint_label }
local dialog = {
    buttons = { { { zenpm_icon = "search" }, { zenpm_icon = "sort" } } },
    buttontable = { buttons_layout = { { { label_widget = widget }, { label_widget = fallback_widget } } } },
}
Icons.apply_dialog(dialog)
widget:paintTo({}, 5, 10)
assert(paints == 1 and image.file == files.search and image.x == 5 and image.y == 15)
assert(fallback_widget.paintTo == paint_label, "missing icons must keep native labels")
files = {}
glyph = nil
widget:paintTo({}, 5, 10)
assert(paints == 2 and glyph == Icons.icon("search"), "a disabled pack must fall back safely")
files.search = "/custom/search.png"
local input_label = { paintTo = paint_label, getSize = widget.getSize }
Icons.apply_dialog({
    buttons = { { { zenpm_icon = "search" } } },
    button_table = { buttons_layout = { { { label_widget = input_label } } } },
})
input_label:paintTo({}, 5, 10)
assert(paints == 3 and image.file == files.search)

print("inline icon tests passed")
