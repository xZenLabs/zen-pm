local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local connected = false
local resume_open
package.preload["daemon"] = function()
    return {
        new = function()
            return {
                loopback_ready = function() return connected end,
            }
        end,
    }
end
package.preload["device"] = function()
    return {
        isPocketBook = function() return true end,
    }
end
package.preload["ui/network/manager"] = function()
    return {
        isConnected = function() return connected end,
        runWhenConnected = function(_, callback) resume_open = callback end,
    }
end

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
assert(shown == 0)
assert(type(resume_open) == "function")

connected = true
resume_open()
assert(shown == 1)
