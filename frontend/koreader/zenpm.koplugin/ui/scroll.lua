-- Scrollable list rendering and scrollbar interaction for AppView.
-- All functions take the AppView instance so they can read/write its shared
-- per-paint state: list_bounds, scroll_step, scrollbar (drag geometry) and
-- max_scroll.

local Device = require("device")

local P = require("ui/primitives")
local Theme = require("ui/theme")

local Screen = Device.screen

local Scroll = {}

-- Snap a scroll offset to whole-item steps and clamp to [0, max_scroll]. The
-- list cull in scrolled_list only draws rows fully inside the viewport, so an
-- off-grid offset clips the top/bottom row and leaves a blank band. Snapping
-- keeps every offset aligned to the item grid (matching swipe navigation).
local function snap_scroll(value, step, max_scroll)
    if step and step > 0 then
        value = math.floor(value / step + 0.5) * step
    end
    return math.max(0, math.min(value, max_scroll))
end

function Scroll.set_list_bounds(view, x, y, w, h, step)
    view.list_bounds = { x = x, y = y, w = w, h = h }
    view.scroll_step = step
end

function Scroll.draw_scrollbar(view, bb, max_scroll, scroll)
    if not view.list_bounds or not max_scroll or max_scroll <= 0 then
        return
    end
    local b = view.list_bounds
    local margin = Theme.scale(9)
    local track_w = math.max(Theme.scale(1), 1)
    local thumb_w = math.max(Theme.scale(7), track_w + 2)
    local touch_w = math.max(Theme.scale(28), 28)
    local thumb_x = b.x + b.w - margin - thumb_w
    local track_x = thumb_x + math.floor((thumb_w - track_w) / 2)
    local track_y = b.y + margin
    local track_h = b.h - margin * 2
    if track_h <= Theme.scale(24) then
        return
    end

    scroll = math.max(0, math.min(scroll or 0, max_scroll))
    local total_h = max_scroll + b.h
    local thumb_h = math.max(Theme.scale(28), math.floor(track_h * b.h / total_h))
    thumb_h = math.min(track_h, thumb_h)
    local travel = track_h - thumb_h
    local thumb_y = track_y
    if travel > 0 then
        thumb_y = track_y + math.floor(travel * scroll / max_scroll)
    end

    P.rounded_rect(bb, track_x, track_y, track_w, track_h, Theme.ink, math.floor(track_w / 2))
    P.rounded_rect(bb, thumb_x, thumb_y, thumb_w, thumb_h, Theme.ink, math.floor(thumb_w / 2))

    -- Geometry captured for fluid pan-drag (see AppView:onPanZenPM). The touch
    -- zone is wider than the visible track so the thumb is easy to grab on e-ink.
    -- Seed _thumb_y with the just-painted thumb position so the first pan move
    -- erases this static thumb instead of leaving it as a ghost.
    view.scrollbar = {
        zone = { x = thumb_x - touch_w + thumb_w, y = b.y, w = touch_w, h = b.h },
        track_x = track_x,
        track_y = track_y,
        track_w = track_w,
        track_h = track_h,
        thumb_x = thumb_x,
        thumb_w = thumb_w,
        thumb_h = thumb_h,
        travel = travel,
        max_scroll = max_scroll,
        step = view.scroll_step,
        region = { x = b.x, y = b.y, w = b.w, h = b.h },
        _thumb_y = thumb_y,
    }

    P.hit(view, thumb_x - touch_w + thumb_w, b.y, touch_w, b.h, function(_, tap_y)
        if travel <= 0 then
            return
        end
        local ratio = (tap_y - track_y - math.floor(thumb_h / 2)) / travel
        ratio = math.max(0, math.min(1, ratio))
        view.app.state.scroll[view.app:scroll_key()] =
            snap_scroll(max_scroll * ratio, view.scroll_step, max_scroll)
        view:refresh()
    end, "scrollbar")
end

-- Map an absolute screen Y to a scroll offset using the captured scrollbar
-- geometry, then store it. The offset is snapped to whole-item steps so a
-- drag scrolls in the same increments as a swipe (one list item at a time),
-- which also keeps the rendered offset aligned to the item grid. Returns true
-- if the scroll position changed.
function Scroll.apply_y(view, pos_y)
    local sb = view.scrollbar
    if not sb or sb.travel <= 0 then
        return false
    end
    local ratio = (pos_y - sb.track_y - math.floor(sb.thumb_h / 2)) / sb.travel
    ratio = math.max(0, math.min(1, ratio))
    local key = view.app:scroll_key()
    local new_scroll = snap_scroll(sb.max_scroll * ratio, sb.step, sb.max_scroll)
    if new_scroll == view.app.state.scroll[key] then
        return false
    end
    view.app.state.scroll[key] = new_scroll
    return true
end

-- Paint just the scrollbar track + thumb directly to Screen.bb for the given
-- finger Y, bypassing the widget tree (so the expensive list items are NOT
-- re-rendered). The thumb follows the finger smoothly — it is positioned from
-- the raw pointer, not the snapped item offset, so dragging feels continuous
-- even though the list itself advances one item at a time.
--
-- The whole rail+thumb is always repainted to Screen.bb (cheap), but only the
-- thumb-sized rects at the OLD and NEW positions are returned as dirty regions
-- — never the span between them. A single union rect would, on a long drag,
-- become a tall region that A2 renders as a lingering black bar; refreshing
-- just the two small thumb footprints keeps the indicator the same size as it
-- moves. Returns a list of {x,y,w,h} rects (1 or 2), or nil if the thumb
-- didn't move.
function Scroll.paint_drag_thumb(view, pos_y)
    local sb = view.scrollbar
    if not sb or sb.travel <= 0 then
        return nil
    end
    local thumb_y = math.max(sb.track_y,
        math.min(sb.track_y + sb.travel, pos_y - math.floor(sb.thumb_h / 2)))
    local prev_y = sb._thumb_y
    if prev_y == thumb_y then
        return nil
    end
    local pad = 1
    local function thumb_rect(ty)
        local top = math.max(sb.track_y, ty - pad)
        local bottom = math.min(sb.track_y + sb.track_h, ty + sb.thumb_h + pad)
        return { x = sb.thumb_x, y = top, w = sb.thumb_w, h = bottom - top }
    end

    -- Always refresh BOTH the new and old footprints. Each rect is only
    -- thumb_h tall, so even a big jump never produces a bar; and refreshing the
    -- old footprint unconditionally erases the previous thumb completely —
    -- skipping it (when the rects overlap) left an un-refreshed sliver that
    -- showed up as residual dots.
    local rects = { thumb_rect(thumb_y) }
    if prev_y then
        table.insert(rects, thumb_rect(prev_y))
    end

    -- A2 ("fast") is 1-bit, so keep every refreshed drag footprint pure B/W:
    -- clear the wider thumb studs to white, then redraw the skinny rail and
    -- current stud in black.
    for _i = 1, #rects do
        local rect = rects[_i]
        P.rect(Screen.bb, rect.x, rect.y, rect.w, rect.h, Theme.bg)
    end
    P.rounded_rect(Screen.bb, sb.track_x, sb.track_y, sb.track_w, sb.track_h, Theme.ink, math.floor(sb.track_w / 2))
    P.rounded_rect(Screen.bb, sb.thumb_x, thumb_y, sb.thumb_w, sb.thumb_h, Theme.ink, math.floor(sb.thumb_w / 2))
    sb._thumb_y = thumb_y

    return rects
end

function Scroll.scrolled_list(view, bb, items, x, y, w, h, scroll, item_h, gap, draw_item)
    Scroll.set_list_bounds(view, x, y, w, h, item_h + gap)
    P.rect(bb, x, y, w, h, Theme.bg)
    local total_h = 0
    for _ in ipairs(items or {}) do
        total_h = total_h + item_h + gap
    end
    if #(items or {}) > 0 then
        total_h = total_h - gap
    end
    local step = item_h + gap
    local max_scroll = math.max(0, total_h - h)
    if max_scroll > 0 then
        max_scroll = math.ceil(max_scroll / step) * step
    end
    scroll = snap_scroll(scroll or 0, step, max_scroll)
    if view.app and view.app.state and view.app.state.scroll and view.app.scroll_key then
        view.app.state.scroll[view.app:scroll_key()] = scroll
    end
    local scrollable = max_scroll > 0
    local cy = y - scroll
    for _, item in ipairs(items or {}) do
        if cy >= y and cy + item_h <= y + h then
            draw_item(item, cy, scrollable)
        end
        cy = cy + item_h + gap
    end
    return max_scroll
end

return Scroll
