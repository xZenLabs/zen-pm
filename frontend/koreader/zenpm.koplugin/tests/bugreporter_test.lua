local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local uploaded_logs = {}
package.preload["device"] = function() return { model = "Test device" } end
package.preload["datastorage"] = function()
    return {
        getDataDir = function() return "/tmp/zenpm-bugreporter-test" end,
    }
end
package.preload["ui/modals"] = function()
    return {
        close_status = function() end,
        notice = function() end,
        status = function() end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, callback) callback() end,
    }
end
package.preload["gettext"] = function() return function(value) return value end end

local Reporter = require("bugreporter")
local original_open = io.open
io.open = function(path, mode)
    if path == "/tmp/zenpm-bugreporter-test/crash.log" then
        return {
            read = function(_, read_mode)
                assert(read_mode == "*a")
                return "crash first\ndhcpd lease renewal\ncrash last\nDHCpd startup"
            end,
            close = function() end,
        }
    end
    return original_open(path, mode)
end
local app = {
    client = {
        get_log = function()
            return true, "ZenPM log"
        end,
        request = function(_, method, url, body)
            assert(method == "POST")
            if url:find("/upload", 1, true) then
                table.insert(uploaded_logs, body.log)
            end
            return true, { url = "https://example.test/report" }
        end,
    },
    daemon = {
        is_android = function() return false end,
        koreader_root = function() return nil end,
        plugin_version = function() return "test" end,
    },
    platform = function() return "test" end,
    version = "test",
}

Reporter:submit(app, "report", "", "")
io.open = original_open

assert(uploaded_logs[1] == "ZenPM log")
assert(uploaded_logs[2] == "crash first\ncrash last\n")
print("bug reporter tests passed")
