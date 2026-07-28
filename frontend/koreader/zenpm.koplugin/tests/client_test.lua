local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

package.preload["json"] = function()
    return {
        encode = function() return '{"scan":true}' end,
        decode = function(value)
            assert(value == '{"ok":true}')
            return { ok = true }
        end,
    }
end
package.preload["socket.http"] = function() return {} end
package.preload["ltn12"] = function() return {} end
package.preload["socket"] = function()
    return {
        gettime = function() return 1 end,
    }
end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["constants"] = function()
    return {
        API_BASE = "http://127.0.0.1:18765",
        PLUGIN_DIR = root,
        UNIX_SOCKET = "/tmp/zenpm.sock",
    }
end
local Client = require("client")
local unix_request
local client = Client:new({
    unix_http = {
        request = function(socket_path, method, path, body, timeout, accept)
            unix_request = {
                socket_path = socket_path,
                method = method,
                path = path,
                body = body,
                timeout = timeout,
                accept = accept,
            }
            return 200, { ["content-type"] = "application/json" }, '{"ok":true}'
        end,
    },
})

local ok, response = client:request("POST", "/koreader/plugins/scan", { scan = true })
assert(ok and response.ok)
assert(unix_request.socket_path == "/tmp/zenpm.sock")
assert(unix_request.method == "POST")
assert(unix_request.path == "/koreader/plugins/scan")
assert(unix_request.body == '{"scan":true}')
assert(unix_request.timeout == 4)
assert(unix_request.accept == "application/json, text/plain, */*")

ok, response = client:scan_installed_plugins()
assert(ok and response.ok)
assert(unix_request.method == "POST")
assert(unix_request.path == "/koreader/plugins/scan")
assert(unix_request.body == nil)
assert(unix_request.timeout == 60)

ok, response = client:get_log(5000)
assert(ok and response.ok)
assert(unix_request.method == "GET")
assert(unix_request.path == "/log?tail=5000")
assert(unix_request.timeout == 30)

client.request = function(_, method, path, body)
    assert(method == "GET")
    assert(path == "/packages/example%20package/release-notes?prerelease=1")
    assert(body == nil)
    return true, {}
end
assert(client:get_package_release_notes("example package", true))

client.request = function(_, method, path, body)
    assert(method == "GET")
    assert(path == "/packages?platform=koreader&beta=1")
    assert(body == nil)
    return true, {}
end
assert(client:list_packages("koreader", false, true))

local requested_timeout

client.request = function(_, method, path, body, timeout)
    assert(method == "GET")
    assert(path == "/packages/example%20package/readme")
    assert(body == nil)
    requested_timeout = timeout
    return true, {}
end

assert(client:get_package_readme("example package"))
assert(requested_timeout.block == 10)
assert(requested_timeout.total == 20)

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
