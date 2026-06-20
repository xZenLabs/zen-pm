local Util = {}

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

function Util.trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function Util.startswith(value, prefix)
    return tostring(value or ""):sub(1, #prefix) == prefix
end

function Util.endswith(value, suffix)
    value = tostring(value or "")
    return suffix == "" or value:sub(-#suffix) == suffix
end

function Util.url_encode(value)
    value = tostring(value or "")
    return (value:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function Util.fixUtf8(value, replacement)
    value = tostring(value or "")
    replacement = replacement or ""
    local out = {}
    local i = 1
    while i <= #value do
        local c = value:byte(i)
        local len
        if c < 0x80 then
            len = 1
        elseif c >= 0xC2 and c <= 0xDF then
            len = 2
        elseif c >= 0xE0 and c <= 0xEF then
            len = 3
        elseif c >= 0xF0 and c <= 0xF4 then
            len = 4
        else
            table.insert(out, replacement)
            i = i + 1
        end
        if len then
            local ok = i + len - 1 <= #value
            for j = 1, len - 1 do
                local b = value:byte(i + j)
                if not b or b < 0x80 or b > 0xBF then
                    ok = false
                    break
                end
            end
            if ok then
                table.insert(out, value:sub(i, i + len - 1))
                i = i + len
            else
                table.insert(out, replacement)
                i = i + 1
            end
        end
    end
    return table.concat(out)
end

function Util.split_lines(value)
    local lines = {}
    value = tostring(value or "")
    if value == "" then
        return lines
    end
    value = value:gsub("\r\n", "\n")
    for line in (value .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end
    return lines
end

function Util.reverse_lines(value)
    local lines = Util.split_lines(value)
    local out = {}
    for i = #lines, 1, -1 do
        table.insert(out, lines[i])
    end
    return table.concat(out, "\n")
end

function Util.table_find(list, predicate)
    for i, item in ipairs(list or {}) do
        if predicate(item, i) then
            return item, i
        end
    end
    return nil
end

function Util.sh_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function Util.path_exists(path)
    if ok_lfs and lfs.attributes(path) then
        return true
    end
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

function Util.ensure_dir(path)
    path = tostring(path or "")
    if path == "" or Util.path_exists(path) then
        return true
    end
    local current = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        current = current == "/" and (current .. part) or (current == "" and part or current .. "/" .. part)
        if not Util.path_exists(current) then
            if ok_lfs then
                lfs.mkdir(current)
            else
                os.execute("mkdir -p " .. Util.sh_quote(current))
            end
        end
    end
    return Util.path_exists(path)
end

return Util
