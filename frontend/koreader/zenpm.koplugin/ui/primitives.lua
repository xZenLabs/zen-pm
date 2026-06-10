local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local ok_logger, logger = pcall(require, "logger")

local Theme = require("ui/theme")

local P = {}

local function exact_size_svg_icon(file, opts)
    return opts
        and opts.is_icon
        and tostring(file):match("/zen[^/]*%.svg$") ~= nil
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
        if tostring(file):match("/zen[^/]*%.svg$") then
            local size = widget:getSize()
            local image = widget._bb
            local image_w = image and image:getWidth() or "?"
            local image_h = image and image:getHeight() or "?"
            if ok_logger and logger and logger.dbg then
                logger.dbg("[zenpm] image", file, "slot", w, h, "size", size.w, size.h, "bb", image_w, image_h, "is_icon", tostring(opts.is_icon), "exact", tostring(exact_size_svg_icon(file, opts)))
            end
        end
        widget:paintTo(bb, x, y)
    end)
    if widget.free then
        widget:free()
    end
    return painted
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
            local widget = ImageWidget:new{
                image = image,
                image_disposable = false,
                width = w,
                height = h,
                scale_factor = zoom,
                alpha = opts.alpha ~= false,
                is_icon = opts.is_icon,
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
