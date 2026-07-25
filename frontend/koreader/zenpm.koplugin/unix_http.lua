local UnixHTTP = {
    -- AF_UNIX is fixed by the Linux userspace ABI. Older KOReader FFI headers
    -- do not declare the constant even though they expose Unix socket calls.
    AF_UNIX = 1,
}

function UnixHTTP.parse_response(raw)
    if type(raw) ~= "string" then
        return nil, "invalid HTTP response"
    end
    local header_end = raw:find("\r\n\r\n", 1, true)
    local separator_length = 4
    if not header_end then
        header_end = raw:find("\n\n", 1, true)
        separator_length = 2
    end
    if not header_end then
        return nil, "invalid HTTP response"
    end

    local header_block = raw:sub(1, header_end - 1)
    local status_line = header_block:match("^([^\r\n]+)")
    local status = status_line and tonumber(status_line:match("^HTTP/%d+%.%d+%s+(%d%d%d)"))
    if not status then
        return nil, "invalid HTTP response"
    end

    local headers = {}
    for line in header_block:gmatch("[^\r\n]+") do
        local name, value = line:match("^([^:]+):%s*(.*)$")
        if name then
            headers[name:lower()] = value
        end
    end

    local body = raw:sub(header_end + separator_length)
    local content_length = tonumber(headers["content-length"])
    if content_length then
        if #body < content_length then
            return nil, "incomplete HTTP response"
        end
        body = body:sub(1, content_length)
    end
    return status, headers, body
end

local function request_with_ffi(socket_path, method, path, body, timeout_seconds, accept)
    local bit = require("bit")
    local ffi = require("ffi")
    require("ffi/posix_h")
    local C = ffi.C

    local function ensure_function(name, declaration)
        if not pcall(function() return C[name] end) then
            ffi.cdef(declaration)
        end
    end
    ensure_function("send", "ssize_t send(int, const void *, size_t, int);")
    ensure_function("recv", "ssize_t recv(int, void *, size_t, int);")

    local function strerror()
        return ffi.string(C.strerror(ffi.errno()))
    end

    local clock = ffi.new("struct timeval")
    local function now()
        if C.gettimeofday(clock, nil) ~= 0 then
            return os.time()
        end
        return tonumber(clock.tv_sec) + tonumber(clock.tv_usec) / 1000000
    end

    local fd = C.socket(UnixHTTP.AF_UNIX, 1, 0) -- SOCK_STREAM is 1 on PocketBook Linux.
    if fd < 0 then
        return nil, nil, nil, "socket: " .. strerror()
    end

    local function exchange()
        local address = ffi.new("struct sockaddr_un")
        local path_capacity = ffi.sizeof(address.sun_path)
        if #socket_path >= path_capacity then
            error("Unix socket path is too long")
        end
        address.sun_family = UnixHTTP.AF_UNIX
        ffi.copy(address.sun_path, socket_path)
        if C.connect(fd, ffi.cast("const struct sockaddr *", address), ffi.sizeof(address)) ~= 0 then
            error("connect: " .. strerror())
        end

        if type(path) ~= "string" or path:sub(1, 1) ~= "/"
            or path:find("\r", 1, true) or path:find("\n", 1, true) then
            error("invalid HTTP request path")
        end
        local lines = {
            method .. " " .. path .. " HTTP/1.0",
            "Host: localhost",
            "Accept: " .. (accept or "*/*"),
            "Connection: close",
        }
        if body ~= nil then
            table.insert(lines, "Content-Type: application/json")
            table.insert(lines, "Content-Length: " .. tostring(#body))
        end
        local request = table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or "")

        local deadline = now() + (tonumber(timeout_seconds) or 4)
        local pollfd = ffi.new("struct pollfd[1]")
        pollfd[0].fd = fd

        local function wait_for(event)
            pollfd[0].events = event
            pollfd[0].revents = 0
            local remaining = math.floor((deadline - now()) * 1000)
            if remaining <= 0 then
                error("timeout")
            end
            local result
            repeat
                result = C.poll(pollfd, 1, remaining)
            until result >= 0 or ffi.errno() ~= C.EINTR
            if result == 0 then
                error("timeout")
            end
            if result < 0 then
                error("poll: " .. strerror())
            end
            if bit.band(pollfd[0].revents, C.POLLERR) ~= 0 then
                error("socket error")
            end
        end

        local request_pointer = ffi.cast("const uint8_t *", request)
        local send_flags = ffi.os == "Linux" and 0x4000 or 0 -- MSG_NOSIGNAL on PocketBook Linux.
        local sent = 0
        while sent < #request do
            wait_for(C.POLLOUT)
            local count = tonumber(C.send(fd, request_pointer + sent, #request - sent, send_flags))
            if count < 0 then
                if ffi.errno() ~= C.EINTR then
                    error("send: " .. strerror())
                end
            elseif count == 0 then
                error("socket closed while sending")
            else
                sent = sent + count
            end
        end

        local chunks = {}
        local buffer = ffi.new("uint8_t[8192]")
        while true do
            wait_for(C.POLLIN)
            local count = tonumber(C.recv(fd, buffer, 8192, 0))
            if count == 0 then
                break
            elseif count < 0 then
                if ffi.errno() ~= C.EINTR then
                    error("recv: " .. strerror())
                end
            else
                table.insert(chunks, ffi.string(buffer, count))
            end
        end
        return table.concat(chunks)
    end

    local ok, raw_or_error = pcall(exchange)
    C.close(fd)
    if not ok then
        return nil, nil, nil, tostring(raw_or_error)
    end

    local status, headers_or_error, response_body = UnixHTTP.parse_response(raw_or_error)
    if not status then
        return nil, nil, nil, headers_or_error
    end
    return status, headers_or_error, response_body
end

function UnixHTTP.request(socket_path, method, path, body, timeout_seconds, accept)
    return request_with_ffi(socket_path, method, path, body, timeout_seconds, accept)
end

return UnixHTTP
