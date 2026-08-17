local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.preload["gettext"] = function() return function(value) return value end end

local UnixHTTP = dofile(root .. "/unix_http.lua")
assert(UnixHTTP.AF_UNIX == 1)

local status, headers, body = UnixHTTP.parse_response(
    "HTTP/1.0 200 OK\r\n"
        .. "Content-Type: application/json\r\n"
        .. "Content-Length: 11\r\n"
        .. "\r\n"
        .. '{"ok":true}')
assert(status == 200)
assert(headers["content-type"] == "application/json")
assert(body == '{"ok":true}')

local binary = "\0\1\2payload"
status, headers, body = UnixHTTP.parse_response(
    "HTTP/1.0 200 OK\r\n"
        .. "Content-Length: " .. #binary .. "\r\n"
        .. "\r\n"
        .. binary)
assert(status == 200)
assert(body == binary)

local invalid_status, invalid_error = UnixHTTP.parse_response("not HTTP")
assert(invalid_status == nil)
assert(invalid_error:find("invalid HTTP response", 1, true))

print("unix HTTP tests passed")
