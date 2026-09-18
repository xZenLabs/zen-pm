local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
local elapsed, errno, closed = 0, 0, 0
local nonblocking, stalled, interrupted, backlog_full
local sent, received = 0, 0
local response = "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok"
local C = {
    EINTR = 4, EAGAIN = 11, F_SETFL = 4, O_NONBLOCK = 2048,
    POLLIN = 1, POLLOUT = 4, POLLERR = 8,
    socket = function() return 7 end,
    close = function() closed = closed + 1 end,
    strerror = function() return "would block" end,
    gettimeofday = function(clock)
        clock.tv_sec, clock.tv_usec = 0, elapsed * 1000000
        return 0
    end,
    fcntl = function(_, command, flags)
        assert(command == 4 and flags == 2048)
        nonblocking = true
        return 0
    end,
    connect = function()
        assert(nonblocking, "connect must not block before the request deadline")
        if backlog_full then errno = 11; return -1 end
        return 0
    end,
    poll = function(_, _, timeout)
        assert(timeout <= math.floor((1 - elapsed) * 1000), "EINTR must not restart the timeout")
        if interrupted then
            elapsed, errno = elapsed + 0.4, 4
            return -1
        end
        if stalled then elapsed = elapsed + timeout / 1000; return 0 end
        return 1
    end,
    send = function(_, _, size)
        sent = sent + 1
        if sent == 1 then errno = 11; return -1 end
        return size
    end,
    recv = function(_, buffer)
        received = received + 1
        if received == 1 then errno = 11; return -1 end
        if received == 2 then buffer.data = response; return #response end
        return 0
    end,
}
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/posix_h"] = function() return {} end
package.preload["ffi"] = function()
    return {
        C = C, os = "Linux",
        typeof = function() return true end,
        errno = function() return errno end,
        sizeof = function() return 108 end,
        copy = function() end,
        cast = function(kind, value) return kind == "int" and value or 0 end,
        string = function(value) return type(value) == "table" and value.data or value end,
        new = function(kind)
            if kind == "struct sockaddr_un" then return { sun_path = {} } end
            if kind == "struct pollfd[1]" then return { [0] = {} } end
            return {}
        end,
    }
end
local UnixHTTP = dofile(arg[1] or root .. "/unix_http.lua")
local function request()
    elapsed, sent, received, nonblocking = 0, 0, 0, false
    return UnixHTTP.request("/tmp/zenpm.sock", "GET", "/log?tail=200", nil, 1)
end

local status, _, body = request()
assert(status == 200 and body == "ok" and sent == 2 and received == 3)
assert(closed == 1)

stalled = true
local _, _, _, request_error = request()
assert(request_error:find("timeout", 1, true) and elapsed <= 1)
assert(closed == 2)

stalled, interrupted = false, true
_, _, _, request_error = request()
assert(request_error:find("timeout", 1, true) and elapsed < 1.5)
assert(closed == 3)

interrupted, backlog_full = false, true
_, _, _, request_error = request()
assert(request_error:find("connect:", 1, true) and elapsed == 0)
assert(closed == 4)
print("Unix HTTP deadline tests passed")
