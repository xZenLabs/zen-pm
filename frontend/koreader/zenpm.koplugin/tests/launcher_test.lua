local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local shown = 0
package.preload["app"] = function()
    return {
        new = function()
            return {
                show = function() shown = shown + 1 end,
            }
        end,
    }
end

local Launcher = require("launcher")
assert(Launcher.open({}))
assert(shown == 1)
