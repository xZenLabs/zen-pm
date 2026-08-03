local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local shown = 0
local reopen_after_restart = false
package.preload["app"] = function()
    return {
        new = function()
            return {}
        end,
    }
end
package.preload["zenpm_app"] = function()
    return {
        consume_reopen_after_restart = function() return reopen_after_restart end,
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
assert(not Launcher.open_after_restart({}))
reopen_after_restart = true
assert(Launcher.open_after_restart({}))
assert(shown == 2)
