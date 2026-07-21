local ImageViewer = require("ui/widget/imageviewer")
local Markdown = require("ui/markdown")
local P = require("ui/primitives")
local Theme = require("ui/theme")
local UIManager = require("ui/uimanager")
local ok_logger, logger = pcall(require, "logger")

local Renderer = {}

local PTF_HEADER = "\u{FFF1}"
local PTF_BOLD_START = "\u{FFF2}"
local PTF_BOLD_END = "\u{FFF3}"

local function log_image(view, url, status, detail)
    if not (ok_logger and logger and logger.info) then return end
    view._readme_image_status = view._readme_image_status or {}
    local value = status .. ":" .. tostring(detail or "")
    if view._readme_image_status[url] == value then return end
    view._readme_image_status[url] = value
    logger.info("ZenPM README image " .. status .. " " .. url .. (detail and " " .. detail or ""))
end

local function strip_html(value)
    value = tostring(value or ""):gsub("<!%-%-.-%-%->", "")
    return value:gsub("<[^>]->", "")
end

local function underscore_emphasis(value, marker, bold)
    local output = {}
    local position = 1
    while position <= #value do
        local start = value:find(marker, position, true)
        if not start then
            table.insert(output, value:sub(position))
            break
        end

        local before = start == 1 and "" or value:sub(start - 1, start - 1)
        local ending = value:find(marker, start + #marker, true)
        if before:match("[%w]") or not ending then
            table.insert(output, value:sub(position, start + #marker - 1))
            position = start + #marker
        else
            local text = value:sub(start + #marker, ending - 1)
            local after = value:sub(ending + #marker, ending + #marker)
            if text == "" or text:match("^%s") or text:match("%s$") or after:match("[%w]") then
                table.insert(output, value:sub(position, start + #marker - 1))
                position = start + #marker
            else
                table.insert(output, value:sub(position, start - 1))
                table.insert(output, bold(text))
                position = ending + #marker
            end
        end
    end
    return table.concat(output)
end

function Renderer.inline_text(value, base_url, plain)
    if plain then
        return tostring(value or "")
    end
    value = strip_html(value)
    value = value:gsub("%[([^%]]+)%]%(([^%)]+)%)", function(label, target)
        local url = Markdown.resolve_url(base_url, target:match("^%s*([^%s]+)") or target)
        return label .. " (" .. url .. ")"
    end)
    value = value:gsub("`([^`]+)`", "%1")
    local formatted = false
    local function bold(text)
        formatted = true
        return PTF_BOLD_START .. text .. PTF_BOLD_END
    end
    value = value:gsub("%*%*%*([^*]+)%*%*%*", bold)
    value = value:gsub("%*%*([^*]+)%*%*", bold)
    value = underscore_emphasis(value, "__", bold)
    value = value:gsub("%*([^*]+)%*", bold)
    value = underscore_emphasis(value, "_", bold)
    return formatted and PTF_HEADER .. value or value
end

local function add_text(layout, block, base_url, width)
    local role = "small"
    local opts = {}
    local pad = 0
    local text = Renderer.inline_text(block.text, base_url, block.plain or block.kind == "code")
    if block.kind == "heading" then
        role = block.level == 1 and "heading" or "small"
        opts.bold = true
    elseif block.kind == "quote" then
        text = "│ " .. text:gsub("\n", "\n│ ")
    elseif block.kind == "code" then
        role = "mono"
        pad = Theme.scale(8)
        opts.line_height = 0.1
    end
    local text_width = math.max(1, width - pad * 2)
    local lines, line_height = P.paragraph_metrics(text, text_width, role, opts)
    table.insert(layout, {
        kind = block.kind == "code" and "code" or "text",
        text = text,
        role = role,
        opts = opts,
        h = math.max(line_height, lines * line_height) + pad * 2,
        line_height = line_height,
        pad = pad,
    })
end

local function fallback_text_entry(text, width)
    local lines, line_height = P.paragraph_metrics(text, width, "small")
    return {
        kind = "text",
        text = text,
        role = "small",
        opts = {},
        h = math.max(line_height, lines * line_height),
        line_height = line_height,
    }
end

local function table_row(cells, base_url, column_width, bold)
    local row = { cells = {}, bold = bold }
    local row_height = 1
    for _, cell in ipairs(cells) do
        local text = Renderer.inline_text(cell, base_url)
        local lines, line_height = P.paragraph_metrics(text, column_width, "mono", { bold = bold, line_height = 0.1 })
        row_height = math.max(row_height, math.max(line_height, lines * line_height))
        table.insert(row.cells, text)
    end
    row.h = row_height
    return row
end

local function add_table(layout, block, base_url, width)
    local column_count = #block.header
    local column_gap = Theme.scale(7)
    local column_width = math.max(1, math.floor((width - column_gap * (column_count - 1)) / column_count))
    local rows = { table_row(block.header, base_url, column_width, true) }
    for _, cells in ipairs(block.rows) do
        table.insert(rows, table_row(cells, base_url, column_width, false))
    end

    local rule_h = Theme.scale(1)
    local total = Theme.scale(2)
    for index, row in ipairs(rows) do
        row.offset = total
        total = total + row.h
        if index < #rows then total = total + rule_h end
    end
    table.insert(layout, {
        kind = "table",
        rows = rows,
        column_width = column_width,
        column_gap = column_gap,
        rule_h = rule_h,
        h = total + Theme.scale(2),
    })
end

local function image_entry(view, block, image_base_url, width)
    if not view.app.state.show_readme_images then
        local alt = block.alt ~= "" and block.alt or "Image"
        return fallback_text_entry("[Image: " .. alt .. "]", width)
    end
    local url = Markdown.resolve_url(image_base_url, block.url)
    if not url:match("^https://") then
        log_image(view, block.url, "skipped", "resolved=" .. url)
        return fallback_text_entry(block.alt ~= "" and block.alt or block.url, width)
    end
    local file, failed = view.app:cached_image_file(url)
    if failed then
        log_image(view, url, "unavailable")
        return fallback_text_entry(block.alt ~= "" and block.alt or url, width)
    end
    if not file then
        return { kind = "image_pending", url = url, alt = block.alt, h = Theme.scale(150) }
    end
    local image_w, image_h = P.image_dimensions(file, width, Theme.scale(240))
    if not image_w then
        log_image(view, url, "unreadable", "file=" .. file)
        return fallback_text_entry(block.alt ~= "" and block.alt or url, width)
    end
    log_image(view, url, "ready", string.format("file=%s size=%dx%d", file, image_w, image_h))
    return { kind = "image", file = file, alt = block.alt, w = image_w, h = image_h }
end

function Renderer.render(view, bb, blocks, base_url, image_base_url, x, y, width, height, scroll)
    local gap = Theme.scale(10)
    local layout = {}
    for _, block in ipairs(blocks) do
        if block.kind == "rule" then
            table.insert(layout, { kind = "rule", h = Theme.scale(1) })
        elseif block.kind == "image" then
            table.insert(layout, image_entry(view, block, image_base_url, width))
        elseif block.kind == "table" then
            add_table(layout, block, base_url, width)
        else
            add_text(layout, block, base_url, width)
        end
    end

    local total = 0
    for index, entry in ipairs(layout) do
        entry.offset = total
        total = total + entry.h
        if index < #layout then total = total + gap end
    end

    scroll = scroll or 0
    for _, entry in ipairs(layout) do
        local entry_y = y + entry.offset - scroll
        local visible_y = math.max(y, entry_y)
        local visible_bottom = math.min(y + height, entry_y + entry.h)
        local visible_h = visible_bottom - visible_y
        if visible_h > 0 then
            if entry.kind == "rule" then
                P.rect(bb, x, visible_y, width, visible_h, Theme.soft)
            elseif entry.kind == "image_pending" then
                log_image(view, entry.url, "queued")
                view.app:queue_readme_image(entry.url)
                if entry.alt and entry.alt ~= "" then
                    P.paragraph(bb, entry.alt, x, visible_y, width, visible_h, "small", { color = Theme.muted })
                end
            elseif entry.kind == "image" then
                local source_y = visible_y - entry_y
                if P.image_cropped(bb, entry.file, x, visible_y, entry.w, visible_h, entry.h, source_y, { is_icon = false }) then
                    log_image(view, entry.file, "painted")
                    P.hit(view, x, visible_y, entry.w, visible_h, function()
                        UIManager:show(ImageViewer:new{ file = entry.file, fullscreen = true })
                    end, "readme-image:" .. entry.file)
                elseif entry.alt and entry.alt ~= "" then
                    log_image(view, entry.file, "paint-failed")
                    P.paragraph(bb, entry.alt, x, visible_y, width, visible_h, "small")
                end
            elseif entry.kind == "code" then
                P.box(bb, x, visible_y, width, visible_h, { border = false, background = Theme.soft, radius = false })
                P.rect(bb, x, visible_y, Theme.scale(3), visible_h, Theme.muted)

                local text_top = entry_y + entry.pad
                local text_bottom = entry_y + entry.h - entry.pad
                local text_y = math.max(visible_y, text_top)
                local text_h = math.min(visible_bottom, text_bottom) - text_y
                if entry_y + entry.h > y + height then
                    text_h = text_h - entry.line_height
                end
                if text_h >= entry.line_height then
                    P.scrollable_paragraph(
                        bb,
                        entry.text,
                        x + entry.pad,
                        text_y,
                        width - entry.pad * 2,
                        text_h,
                        entry.role,
                        math.max(0, text_y - text_top),
                        entry.opts
                    )
                end
            elseif entry.kind == "table" then
                for index, row in ipairs(entry.rows) do
                    local row_y = entry_y + row.offset
                    if row_y >= y and row_y + row.h <= y + height then
                        if index == 1 then
                            P.rect(bb, x, row_y, width, row.h, Theme.soft)
                        end
                        for cell_index, text in ipairs(row.cells) do
                            local cell_x = x + (cell_index - 1) * (entry.column_width + entry.column_gap)
                            P.paragraph(bb, text, cell_x, row_y, entry.column_width, row.h, "mono", {
                                bold = row.bold,
                                line_height = 0.1,
                            })
                        end
                        if index < #entry.rows then
                            P.rect(bb, x, row_y + row.h, width, entry.rule_h, Theme.soft)
                        end
                    end
                end
            else
                local text_h = visible_h
                if entry_y + entry.h > y + height then
                    text_h = text_h - entry.line_height
                end
                if text_h < entry.line_height then
                    goto next_entry
                end
                P.scrollable_paragraph(bb, entry.text, x, visible_y, width, text_h, entry.role, visible_y - entry_y, entry.opts)
            end
        end
        ::next_entry::
    end
    return math.max(0, total - height)
end

return Renderer
