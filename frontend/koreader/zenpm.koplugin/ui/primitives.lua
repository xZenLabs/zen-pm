local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")

local Theme = require("ui/theme")

local P = {}

local function exact_size_svg_icon(file, opts)
    return opts
        and opts.is_icon
        and tostring(file):lower():match("%.svg$") ~= nil
end

function P.rect(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then
        return
    end
    bb:paintRect(x, y, w, h, color or Theme.bg)
end

function P.rounded_rect(bb, x, y, w, h, color, radius)
    if w <= 0 or h <= 0 then
        return
    end
    radius = radius or Theme.metrics().radius
    if bb.paintRoundedRect then
        local ok = pcall(function()
            bb:paintRoundedRect(x, y, w, h, color or Theme.bg, radius)
        end)
        if ok then
            return
        end
        ok = pcall(function()
            bb:paintRoundedRect(x, y, w, h, radius, color or Theme.bg)
        end)
        if ok then
            return
        end
    end
    P.rect(bb, x, y, w, h, color or Theme.bg)
end

function P.border(bb, x, y, w, h, size, color, radius, background)
    if w <= 0 or h <= 0 then
        return
    end
    size = size or 2
    radius = radius or Theme.metrics().radius
    color = color or Theme.border
    if bb.paintRoundedRect then
        P.rounded_rect(bb, x, y, w, h, color, radius)
        if w > size * 2 and h > size * 2 then
            P.rounded_rect(bb, x + size, y + size, w - size * 2, h - size * 2, background or Theme.panel, math.max(0, radius - size))
        end
    else
        bb:paintBorder(x, y, w, h, size, color, nil, true)
    end
end

function P.stroke(bb, x, y, w, h, size, color)
    if w <= 0 or h <= 0 then
        return
    end
    bb:paintBorder(x, y, w, h, size or 2, color or Theme.border, nil, true)
end

function P.box(bb, x, y, w, h, opts)
    opts = opts or {}
    local background = opts.background or Theme.panel
    local radius = opts.radius
    if opts.border ~= false then
        P.border(bb, x, y, w, h, opts.border_size or 2, opts.border_color or Theme.border, radius, background)
    elseif radius ~= false then
        P.rounded_rect(bb, x, y, w, h, background, radius)
    else
        P.rect(bb, x, y, w, h, background)
    end
end

function P.text(bb, text, x, y, width, role, opts)
    opts = opts or {}
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        max_width = width,
    }
    widget:paintTo(bb, x, y)
    local size = widget:getSize()
    widget:free()
    return size
end

function P.paragraph(bb, text, x, y, width, height, role, opts)
    opts = opts or {}
    local widget = TextBoxWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        width = width,
        height = height,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        line_height = opts.line_height,
    }
    widget:paintTo(bb, x, y)
    local size = widget:getSize()
    widget:free()
    return size
end

function P.scrollable_paragraph(bb, text, x, y, width, height, role, scroll, opts)
    opts = opts or {}
    local face = opts.face or Theme.face(role)
    local line_height = math.floor((1 + (opts.line_height or 0.3)) * face.size + 0.5)
    local top_line = math.floor((scroll or 0) / math.max(1, line_height)) + 1
    local widget = TextBoxWidget:new{
        text = tostring(text or ""),
        face = face,
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        width = width,
        height = height,
        height_adjust = true,
        line_height = opts.line_height,
        virtual_line_num = top_line,
    }
    widget:paintTo(bb, x, y)
    local total_lines = #(widget.vertical_string_list or {})
    local visible_lines = widget.lines_per_page or total_lines
    line_height = widget.line_height_px or line_height
    widget:free()
    return math.max(0, total_lines - visible_lines) * line_height, line_height
end

function P.paragraph_line_count(text, width, role, opts)
    opts = opts or {}
    local widget = TextBoxWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        width = width,
        height = 1,
        height_adjust = true,
        line_height = opts.line_height,
    }
    local lines = #(widget.vertical_string_list or {})
    widget:free()
    return lines
end

function P.paragraph_metrics(text, width, role, opts)
    opts = opts or {}
    local widget = TextBoxWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        width = width,
        height = 1,
        height_adjust = true,
        line_height = opts.line_height,
    }
    local lines = #(widget.vertical_string_list or {})
    local line_height = widget.line_height_px or 1
    widget:free()
    return lines, line_height
end

function P.text_size(text, width, role, opts)
    opts = opts or {}
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        max_width = width,
    }
    local size = widget:getSize()
    widget:free()
    return size
end

function P.center_text(bb, text, x, y, w, role, opts)
    opts = opts or {}
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        max_width = w,
    }
    local size = widget:getSize()
    widget:paintTo(bb, x + math.max(0, math.floor((w - size.w) / 2)), y)
    widget:free()
    return size
end

function P.vcenter_text(bb, text, x, y, w, h, role, opts)
    opts = opts or {}
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        max_width = w,
    }
    local size = widget:getSize()
    widget:paintTo(bb, x, y + math.max(0, math.floor((h - size.h) / 2)))
    widget:free()
    return size
end

function P.center_text_box(bb, text, x, y, w, h, role, opts)
    opts = opts or {}
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        max_width = w,
    }
    local size = widget:getSize()
    widget:paintTo(
        bb,
        x + math.max(0, math.floor((w - size.w) / 2)),
        y + math.max(0, math.floor((h - size.h) / 2))
    )
    widget:free()
    return size
end

function P.image(bb, file, x, y, w, h, opts)
    if not file or file == "" then
        return false
    end
    opts = opts or {}
    local ok, widget = pcall(function()
        local image_opts = {
            file = file,
            width = w,
            height = h,
            alpha = opts.alpha ~= false,
            is_icon = opts.is_icon,
            file_do_cache = true,
        }
        if not exact_size_svg_icon(file, opts) then
            image_opts.scale_factor = opts.scale_factor or 0
        end
        return ImageWidget:new(image_opts)
    end)
    if not ok or not widget then
        return false
    end
    local painted = pcall(function()
        widget:paintTo(bb, x, y)
    end)
    if widget.free then
        widget:free()
    end
    return painted
end

function P.image_dimensions(file, max_width, max_height)
    if not file or file == "" or not max_width or max_width <= 0 then
        return nil
    end
    local ok, widget = pcall(function()
        return ImageWidget:new{
            file = file,
            width = max_width,
            height = max_height or max_width,
            scale_factor = 0,
            alpha = true,
            file_do_cache = true,
        }
    end)
    if not ok or not widget then
        return nil
    end
    local width, height
    local measured = pcall(function()
        local size = widget:getSize()
        local image = widget._bb
        if image then
            local image_width, image_height = image:getWidth(), image:getHeight()
            if image_width > 0 and image_height > 0 then
                width = max_width
                height = math.max(1, math.floor(image_height * width / image_width + 0.5))
                if max_height and height > max_height then
                    height = max_height
                    width = math.max(1, math.floor(image_width * height / image_height + 0.5))
                end
            end
        end
        if not width and size and size.w and size.h and size.w > 0 and size.h > 0 then
            width = math.min(max_width, size.w)
            height = math.max(1, math.floor(size.h * width / size.w + 0.5))
            if max_height and height > max_height then
                height = max_height
                width = math.max(1, math.floor(size.w * height / size.h + 0.5))
            end
        end
    end)
    widget:free()
    if not measured then
        return nil
    end
    return width, height
end

function P.image_cropped(bb, file, x, y, w, h, source_h, source_y, opts)
    if not file or file == "" or w <= 0 or h <= 0 or source_h <= 0 then
        return false
    end
    opts = opts or {}
    local base_ok, base = pcall(function()
        return ImageWidget:new{
            file = file,
            width = w,
            height = source_h,
            scale_factor = 0,
            alpha = opts.alpha ~= false,
            is_icon = opts.is_icon,
            file_do_cache = true,
        }
    end)
    if not base_ok or not base then
        return false
    end

    local painted = false
    local render_ok = pcall(function()
        base:getSize()
        local image = base._bb
        if image then
            local image_width = image:getWidth()
            if image_width > 0 then
                local center_y_ratio = math.max(0, math.min(1, (source_y + h / 2) / source_h))
                local widget = ImageWidget:new{
                    image = image,
                    image_disposable = false,
                    width = w,
                    height = h,
                    scale_factor = w / image_width,
                    alpha = opts.alpha ~= false,
                    is_icon = opts.is_icon,
                    center_x_ratio = 0.5,
                    center_y_ratio = center_y_ratio,
                }
                painted = pcall(function()
                    widget:paintTo(bb, x, y)
                end)
                if widget.free then
                    widget:free()
                end
            end
        end
    end)
    if base.free then
        base:free()
    end
    if render_ok and painted then
        return true
    end
    return P.image(bb, file, x, y, w, h, opts)
end

function P.image_zoomed(bb, file, x, y, w, h, zoom, opts)
    opts = opts or {}
    zoom = zoom or 1
    if zoom <= 1 then
        return P.image(bb, file, x, y, w, h, opts)
    end
    if not file or file == "" then
        return false
    end

    local base_ok, base = pcall(function()
        return ImageWidget:new{
            file = file,
            width = w,
            height = h,
            scale_factor = 0,
            alpha = opts.alpha ~= false,
            is_icon = opts.is_icon,
            file_do_cache = true,
        }
    end)
    if not base_ok or not base then
        return false
    end

    local painted = false
    local render_ok = pcall(function()
        base:getSize()
        local image = base._bb
        if image then
            local iw, ih = image:getWidth(), image:getHeight()
            local widget = ImageWidget:new{
                image = image,
                image_disposable = false,
                width = w,
                height = h,
                scale_factor = math.max(w / iw, h / ih) * zoom,
                alpha = opts.alpha ~= false,
                is_icon = opts.is_icon,
                center_x_ratio = 0.5,
                center_y_ratio = 0.5,
            }
            painted = pcall(function()
                widget:paintTo(bb, x, y)
            end)
            if widget.free then
                widget:free()
            end
        end
    end)
    if base.free then
        base:free()
    end
    return render_ok and painted
end

function P.image_zoomed_masked(bb, file, x, y, w, h, zoom, opts)
    return P.image_zoomed(bb, file, x, y, w, h, zoom, opts)
end

function P.dim(bb, x, y, w, h, by)
    if w <= 0 or h <= 0 or not bb.lightenRect then
        return
    end
    pcall(function()
        bb:lightenRect(x, y, w, h, by or 0.5)
    end)
end

function P.hit(app, x, y, w, h, callback, label)
    table.insert(app.hitboxes, {
        x = x, y = y, w = w, h = h,
        callback = callback,
        label = label,
    })
end

function P.contains(box, x, y)
    return x >= box.x and x <= box.x + box.w and y >= box.y and y <= box.y + box.h
end

function P.geom(x, y, w, h)
    return Geom:new{ x = x, y = y, w = w, h = h }
end

return P
