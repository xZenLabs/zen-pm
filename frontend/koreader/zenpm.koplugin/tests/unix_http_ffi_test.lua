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
        struct sockaddr_un {
            unsigned short sun_family;
            char sun_path[108];
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
        int connect(int, const struct sockaddr *, unsigned int);
        int gettimeofday(struct timeval *, void *);
        int poll(struct pollfd *, unsigned long, int);
        int socket(int, int, int);
        char *strerror(int);
    ]]
end

assert(not pcall(function() return ffi.C.send end))
assert(not pcall(function() return ffi.C.recv end))

local UnixHTTP = dofile(root .. "/unix_http.lua")
local status, _, _, request_error = UnixHTTP.request(
    "/tmp/zenpm-missing-ffi-test.sock", "GET", "/health", nil, 1, "application/json")
assert(status == nil)
assert(request_error:find("connect:", 1, true))
assert(pcall(function() return ffi.C.send end))
assert(pcall(function() return ffi.C.recv end))

print("Unix HTTP FFI compatibility tests passed")
