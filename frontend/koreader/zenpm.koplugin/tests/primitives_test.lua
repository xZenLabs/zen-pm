local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/ui/?.lua;" .. package.path

local image_options
local painted = false

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
package.preload["ui/widget/textboxwidget"] = function() return {} end
package.preload["ui/theme"] = function() return {} end

local P = require("ui/primitives")
assert(P.image({}, "upgrade.svg", 0, 0, 24, 24, { is_icon = true, invert = true }))
assert(painted)
assert(image_options.invert == true)
assert(image_options.alpha == false)

assert(P.image({}, "packages.svg", 0, 0, 24, 24, { is_icon = true }))
assert(image_options.invert == nil)
assert(image_options.alpha == true)

print("primitives tests passed")
