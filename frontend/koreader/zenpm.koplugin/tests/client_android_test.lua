local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local requests = {}
local log_messages = {}
package.preload["json"] = function()
    return {
        decode = function(value)
            assert(value == '{"ok":true}')
            return { ok = true }
        end,
    }
end
package.preload["socket.http"] = function()
    return {
        request = function(request)
            table.insert(requests, request)
            request.sink('{"ok":true}')
            return true, 200, { ["content-type"] = "application/json" }, "HTTP/1.1 200 OK"
        end,
    }
end
package.preload["ltn12"] = function()
    return {
        sink = {
            table = function(parts)
                return function(part)
                    if part then table.insert(parts, part) end
                    return 1
                end
            end,
        },
    }
end
package.preload["socket"] = function()
    return {
        gettime = function() return 1 end,
        skip = function(count, ...) return select(count + 1, ...) end,
    }
end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function()
    return {
        info = function(message) table.insert(log_messages, message) end,
    }
end
package.preload["zenpm_constants"] = function()
    return {
        API_BASE = "http://127.0.0.1:18765",
        PLUGIN_DIR = root,
        UNIX_SOCKET = "/tmp/zenpm.sock",
    }
end
package.preload["android"] = function() return {} end

local Client = require("client")
local client = Client:new()
assert(client.unix_socket == nil)

local ok, response = client:request("GET", "/health")
assert(ok and response.ok)
assert(#requests == 1)
assert(requests[1].url == "http://127.0.0.1:18765/health")
assert(log_messages[1] == "ZenPM HTTP GET http://127.0.0.1:18765/health started")
assert(log_messages[2] == "ZenPM HTTP GET http://127.0.0.1:18765/health HTTP 200 after 0ms")

print("Android client tests passed")
