local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))

local ffi = require("ffi")
package.preload["ffi/posix_h"] = function()
    ffi.cdef[[
        typedef long ssize_t;
        struct timeval {
            long tv_sec;
            int tv_usec;
        };
        struct sockaddr {
            unsigned short sa_family;
            char sa_data[14];
        };
        struct pollfd {
            int fd;
            short events;
            short revents;
        };
        static const unsigned EINTR = 4;
        static const unsigned POLLERR = 8;
        static const unsigned POLLIN = 1;
        static const unsigned POLLOUT = 4;
        int close(int);
        int gettimeofday(struct timeval *, void *);
        int poll(struct pollfd *, unsigned long, int);
        int socket(int, int, int);
        char *strerror(int);
    ]]
end

assert(not pcall(function() return ffi.C.connect end))
assert(not pcall(function() return ffi.C.send end))
assert(not pcall(function() return ffi.C.recv end))
assert(not pcall(ffi.typeof, "struct sockaddr_un"))

local UnixHTTP = dofile(root .. "/unix_http.lua")
local status, _, _, request_error = UnixHTTP.request(
    "/tmp/zenpm-missing-ffi-test.sock", "GET", "/health", nil, 1, "application/json")
assert(status == nil)
assert(request_error:find("connect:", 1, true))
assert(pcall(function() return ffi.C.connect end))
assert(pcall(function() return ffi.C.send end))
assert(pcall(function() return ffi.C.recv end))
assert(pcall(ffi.typeof, "struct sockaddr_un"))

print("Unix HTTP FFI compatibility tests passed")
