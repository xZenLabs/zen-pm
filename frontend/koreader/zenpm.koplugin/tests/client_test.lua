local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

package.preload["json"] = function() return {} end
package.preload["socket.http"] = function() return {} end
package.preload["ltn12"] = function() return {} end
package.preload["socket"] = function() return {} end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["constants"] = function() return { API_BASE = "http://127.0.0.1:8080" } end

local Client = require("client")
local client = Client:new()
local requested_timeout

client.request = function(_, method, path, body, timeout)
    assert(method == "GET")
    assert(path == "/packages/example/releases")
    assert(body == nil)
    requested_timeout = timeout
    return true, {}
end

assert(client:get_package_releases("example"))
assert(requested_timeout.block == 10)
assert(requested_timeout.total == 15)

print("client tests passed")
