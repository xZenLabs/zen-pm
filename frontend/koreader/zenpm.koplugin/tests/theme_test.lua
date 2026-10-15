local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255, COLOR_DARK_GRAY = 64, COLOR_LIGHT_GRAY = 192 }
end
package.preload["device"] = function() return { screen = {} } end
package.preload["ui/font"] = function() return {} end

local Theme = require("ui/theme")
Theme.update_accent()
assert(Theme.button_bg == 0 and Theme.button_text == 255)

local color, foreground = {}, 255
package.loaded["common/ui/accent"] = {
    color = function() return color end,
    foreground = function() return foreground end,
}
Theme.update_accent()
assert(Theme.button_bg == color and Theme.button_text == foreground)
assert(Theme.ink == 0 and Theme.border == 0, "text and outlines must remain readable")

color, foreground = {}, 0
Theme.update_accent()
assert(Theme.button_bg == color and Theme.button_text == foreground, "follow live ZenOS settings")
color, foreground = 0, 255
Theme.update_accent()
assert(Theme.button_bg == 0 and Theme.button_text == 255, "honor ZenOS's monochrome fallback")

package.loaded["common/ui/accent"] = nil
Theme.update_accent()
assert(Theme.button_bg == 0 and Theme.button_text == 255)

print("theme tests passed")
