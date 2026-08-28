-- Small, dependency-free Markdown parser for package READMEs. The renderer
-- lives separately so these parsing and URL rules can be tested with LuaJIT.

local Markdown = {}

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function append_text_block(blocks, text)
    text = tostring(text or ""):gsub("<!%-%-.-%-%->", "")
    text = text:gsub("<[aA]%s+([^>]*)>(.-)</[aA]>", function(attributes, label)
        local target = attributes:match("[hH][rR][eE][fF]%s*=%s*\"([^\"]+)\"")
            or attributes:match("[hH][rR][eE][fF]%s*=%s*'([^']+)'")
        label = label:gsub("<[^>]->", "")
        return target and ("[" .. label .. "](" .. target .. ")") or label
    end)
    text = trim(text:gsub("<[^>]->", ""))
    if text ~= "" then
        table.insert(blocks, { kind = "paragraph", text = text })
    end
end

local function image_target(value)
    value = trim(value)
    local target = value:match("^<([^>]+)>") or value:match("^([^%s]+)")
    return trim(target)
end

local function is_shields_image(value)
    local target = image_target(value):lower()
    local host = target:match("^https?://([^/%?#]+)") or target:match("^//([^/%?#]+)")
    return host == "img.shields.io" or host == "shields.io"
end

local function strip_badges(value)
    local badge_references = {}
    for line in (value .. "\n"):gmatch("(.-)\n") do
        local name, target = line:match("^%s*%[([^%]]+)%]:%s*(%S+)")
        if name and (name:lower():match("^badge[-_]") or is_shields_image(target)) then
            badge_references[trim(name):lower()] = true
        end
    end
    local function strip_reference_badge(markup, reference)
        reference = trim(reference):lower()
        return (badge_references[reference] or reference:match("^badge[-_]")) and "" or markup
    end
    value = value:gsub("(%[!%[[^%]]*%]%[([^%]]+)%]%]%[[^%]]+%])", strip_reference_badge)
    value = value:gsub("(%[!%[[^%]]*%]%[([^%]]+)%]%]%([^%)]+%))", strip_reference_badge)
    value = value:gsub("(!%[[^%]]*%]%[([^%]]+)%])", strip_reference_badge)
    value = value:gsub("(%[!%[[^%]]*%]%([^%)]+%)%]%([^%)]+%))", function(markup)
        local target = markup:match("!%[[^%]]*%]%(([^%)]+)%)")
        return is_shields_image(target) and "" or markup
    end)
    value = value:gsub("(!%[[^%]]*%]%([^%)]+%))", function(markup)
        local target = markup:match("!%[[^%]]*%]%(([^%)]+)%)")
        return is_shields_image(target) and "" or markup
    end)
    value = value:gsub("(<[iI][mM][gG]%s+[^>]->)", function(tag)
        local target = tag:match("[sS][rR][cC]%s*=%s*\"([^\"]+)\"")
            or tag:match("[sS][rR][cC]%s*=%s*'([^']+)'")
        return target and is_shields_image(target) and "" or tag
    end)
    return ("\n" .. value):gsub("\n[ \t]*%[[^%]]+%]:[^\n]*", ""):sub(2)
end

local function split_images(blocks, text)
    local start = 1
    while true do
        local first, last, alt, target = text:find("!%[([^%]]*)%]%(([^%)]+)%)", start)
        local html_first, html_last = text:find("<img%s+[^>]->", start)
        if html_first and (not first or html_first < first) then
            first, last = html_first, html_last
            local tag = text:sub(html_first, html_last)
            target = tag:match("[sS][rR][cC]%s*=%s*\"([^\"]+)\"")
                or tag:match("[sS][rR][cC]%s*=%s*'([^']+)'")
            alt = tag:match("[aA][lL][tT]%s*=%s*\"([^\"]*)\"")
                or tag:match("[aA][lL][tT]%s*=%s*'([^']*)'")
            if not target then
                target = ""
            end
        end
        if not first then
            append_text_block(blocks, text:sub(start))
            return
        end
        append_text_block(blocks, text:sub(start, first - 1))
        if target ~= "" then
            table.insert(blocks, {
                kind = "image",
                alt = alt or "",
                url = image_target(target),
            })
        end
        start = last + 1
    end
end

local function table_cells(line)
    if not tostring(line):find("|", 1, true) then
        return nil
    end
    line = trim(line)
    line = line:gsub("^|", ""):gsub("|$", "")
    local cells = {}
    for cell in (line .. "|"):gmatch("(.-)|") do
        local value = trim(cell):gsub("\\|", "|")
        table.insert(cells, value)
    end
    return #cells > 1 and cells or nil
end

local function table_separator(line, column_count)
    local cells = table_cells(line)
    if not cells or #cells ~= column_count then
        return false
    end
    for _, cell in ipairs(cells) do
        if not cell:match("^:?-+:?$") then
            return false
        end
    end
    return true
end

local function normalize_path(path)
    local out = {}
    for segment in tostring(path or ""):gmatch("[^/]+") do
        if segment == ".." then
            table.remove(out)
        elseif segment ~= "." and segment ~= "" then
            table.insert(out, segment)
        end
    end
    return "/" .. table.concat(out, "/")
end

function Markdown.resolve_url(base, value)
    value = trim(value)
    if value == "" then
        return ""
    end
    if value:match("^https?://") then
        return value
    end
    if value:match("^//") then
        return "https:" .. value
    end
    local origin, base_path = tostring(base or ""):match("^(https?://[^/%?#]+)([^%?#]*)")
    if not origin then
        return value
    end
    if value:sub(1, 1) == "#" then
        return tostring(base):gsub("[#?].*$", "") .. value
    end
    local path, suffix = value:match("^([^?#]*)(.*)$")
    if path:sub(1, 1) == "/" then
        return origin .. normalize_path(path) .. suffix
    end
    return origin .. normalize_path((base_path or "/") .. "/" .. path) .. suffix
end

function Markdown.base_url(value)
    value = tostring(value or ""):gsub("[#?].*$", "")
    if value:sub(-1) == "/" then
        return value
    end
    return value:match("^(.*[/])[^/]*$") or ""
end

function Markdown.public_image_base_url(source)
    source = trim(source)
    local owner, repository = source:match("^https?://github%.com/([^/]+)/([^/]+)/?$")
    if owner and repository then
        repository = repository:gsub("%.git$", "")
        return "https://github.com/" .. owner .. "/" .. repository .. "/raw/HEAD/"
    end
    if source:match("^https?://") then
        return source:gsub("/+$", "") .. "/"
    end
    return ""
end

function Markdown.source_base_url(source)
    source = trim(source):gsub("%.git/?$", "")
    if source:match("^https?://") then
        return source:gsub("/+$", "") .. "/"
    end
    return ""
end

function Markdown.parse(value)
    local lines = {}
    value = strip_badges(tostring(value or "")):gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in (value .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end

    local blocks = {}
    local i = 1
    while i <= #lines do
        local line = lines[i]
        if line:match("^%s*$") then
            i = i + 1
        else
            local fence = line:match("^%s*```")
            local hashes, heading = line:match("^%s*(#+)%s+(.+)$")
            local unordered = line:match("^(%s*)[-+*]%s+(.+)$")
            local ordered_indent, ordered_number, ordered_text = line:match("^(%s*)(%d+)[%.)]%s+(.+)$")
            if fence then
                local code = {}
                i = i + 1
                while i <= #lines and not lines[i]:match("^%s*```") do
                    table.insert(code, lines[i])
                    i = i + 1
                end
                table.insert(blocks, { kind = "code", text = table.concat(code, "\n") })
                if i <= #lines then i = i + 1 end
            elseif hashes then
                table.insert(blocks, { kind = "heading", level = #hashes, text = heading })
                i = i + 1
            elseif line:match("^%s*[-*_]%s*[-*_]%s*[-*_][%s-*_]*$") then
                table.insert(blocks, { kind = "rule" })
                i = i + 1
            elseif line:match("^%s*>") then
                local quote = {}
                while i <= #lines and lines[i]:match("^%s*>") do
                    table.insert(quote, (lines[i]:gsub("^%s*>%s?", "")))
                    i = i + 1
                end
                table.insert(blocks, { kind = "quote", text = table.concat(quote, "\n") })
            elseif unordered or ordered_number then
                local items = {}
                local number = tonumber(ordered_number)
                while i <= #lines do
                    local indent, item = lines[i]:match("^(%s*)[-+*]%s+(.+)$")
                    local item_indent, item_number, numbered_item = lines[i]:match("^(%s*)(%d+)[%.)]%s+(.+)$")
                    if number then
                        if not numbered_item then break end
                        table.insert(items, item_indent .. tostring(item_number) .. ". " .. numbered_item)
                    else
                        if not item then break end
                        table.insert(items, indent .. "• " .. item)
                    end
                    i = i + 1
                end
                table.insert(blocks, { kind = "list", text = table.concat(items, "\n") })
            elseif table_cells(line) and table_separator(lines[i + 1], #table_cells(line)) then
                local header = table_cells(line)
                local rows = {}
                i = i + 2
                while i <= #lines do
                    local row = table_cells(lines[i])
                    if not row or #row ~= #header then
                        break
                    end
                    table.insert(rows, row)
                    i = i + 1
                end
                local image_blocks = #rows == 1 and {} or nil
                if image_blocks then
                    for column, cell in ipairs(rows[1]) do
                        local parsed = {}
                        split_images(parsed, cell)
                        if #parsed ~= 1 or parsed[1].kind ~= "image" then
                            image_blocks = nil
                            break
                        end
                        table.insert(image_blocks, { kind = "heading", level = 3, text = header[column] })
                        table.insert(image_blocks, parsed[1])
                    end
                end
                if image_blocks then
                    for _, block in ipairs(image_blocks) do table.insert(blocks, block) end
                else
                    table.insert(blocks, { kind = "table", header = header, rows = rows })
                end
            else
                local paragraph = { line }
                i = i + 1
                while i <= #lines do
                    local next_line = lines[i]
                    if next_line:match("^%s*$")
                        or next_line:match("^%s*```")
                        or next_line:match("^%s*#+%s+")
                        or next_line:match("^%s*>")
                        or next_line:match("^(%s*)[-+*]%s+(.+)$")
                        or next_line:match("^(%s*)(%d+)[%.)]%s+(.+)$")
                        or next_line:match("^%s*[-*_]%s*[-*_]%s*[-*_][%s-*_]*$") then
                        break
                    end
                    table.insert(paragraph, next_line)
                    i = i + 1
                end
                split_images(blocks, table.concat(paragraph, "\n"))
            end
        end
    end
    return blocks
end

return Markdown
