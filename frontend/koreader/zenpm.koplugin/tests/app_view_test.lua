local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/ui/?.lua;" .. package.path

package.preload["device"] = function()
    return {
        hasKeys = function() return false end,
        screen = { getWidth = function() return 1 end, getHeight = function() return 1 end },
    }
end
package.preload["device/input"] = function() return { group = {} } end
package.preload["ui/geometry"] = function() return { new = function(_, value) return value end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, value) return value end } end
package.preload["ui/widget/container/inputcontainer"] = function()
    return { extend = function(_, value) return value end }
end
package.preload["ui/uimanager"] = function() return {} end
package.preload["ui/header"] = function() return {} end
package.preload["i18n"] = function() return {} end
package.preload["ui/nav"] = function() return {} end
package.preload["ui/primitives"] = function() return {} end
package.preload["ui/pages"] = function() return {} end
package.preload["ui/scroll"] = function() return {} end
package.preload["ui/theme"] = function() return {} end
package.preload["gettext"] = function() return function(value) return value end end

local AppView = require("ui/app_view")
local closed = 0
local view = { app = { close = function() closed = closed + 1 end } }

assert(AppView.onExit(view) == true)
assert(AppView.onClose(view) == true)
assert(closed == 2)

print("app view tests passed")
