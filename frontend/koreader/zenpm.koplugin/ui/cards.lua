local Models = require("models")
local Images = require("ui/images")
local P = require("ui/primitives")
local Theme = require("ui/theme")
local Util = require("zenpm_util")

local Cards = {}

local function ellipsize(value, limit)
    local title = tostring(value or "")
    if title and #title > limit then
        title = title:sub(1, limit)
        title = Util.fixUtf8(title, "") .. "…"
    end
    return title
end

local function verification_icon(verified)
    return Images.asset(verified and "verified.svg" or "unverified.svg")
end

local function draw_verification_icon(bb, verified, x, y, size)
    return P.image(bb, verification_icon(verified), x, y, size, size, { is_icon = true })
end

local function package_meta_text(pkg)
    local parts = {}
    if pkg and pkg.version and pkg.version ~= "" and pkg.version ~= "0.0.0" then
        table.insert(parts, "v" .. pkg.version)
    end
    table.insert(parts, pkg and pkg.repo or "?")
    return table.concat(parts, " · ")
end

local function action_pill(view, bb, text, x, y, w, h, callback)
    P.box(bb, x, y, w, h, { background = Theme.bg, border_size = 2, radius = math.floor(h / 2) })
    P.center_text_box(bb, text, x, y, w, h, "small", { bold = true })
    P.hit(view, x, y, w, h, callback, text)
end

function Cards.package(view, bb, pkg, x, y, w, opts)
    opts = opts or {}
    local m = Theme.metrics()
    local h = opts.height or m.card_h
    P.box(bb, x, y, w, h, { border = opts.border })
    local pad = opts.pad or Theme.scale(10)
    local icon_w = opts.compact and 0 or Theme.scale(58)
    local text_x = x + pad + icon_w + (icon_w > 0 and Theme.scale(10) or 0)
    local action_w = opts.action_w or m.action_w
    local action_h = opts.action_h or m.action_h
    local action_x = x + w - action_w - pad
    local action_y = y + math.floor((h - action_h) / 2)
    local text_w = action_x - text_x - Theme.scale(8)

    if icon_w > 0 then
        local ix = x + pad
        local iy = y + math.floor((h - icon_w) / 2)
        if not P.image(bb, view.app:package_icon_file(pkg), ix, iy, icon_w, icon_w, { is_icon = true }) then
            P.center_text(bb, pkg.repo == "KindleForge" and "KF" or "Z", ix, iy + Theme.scale(20), icon_w, "small", { bold = true })
        end
    end

    local title = ellipsize(pkg.name or pkg.id or "Unknown package", 60)
    local second_line = ellipsize(opts.second_line or pkg.description or "No description", 54)
    local meta_text = ellipsize(package_meta_text(pkg), 48)
    local text_gap = opts.text_gap or Theme.scale(4)
    local title_size = P.text_size(title, text_w, "small", { bold = true })
    local line2_size = P.text_size(second_line, text_w, "small")
    local meta_size = P.text_size(meta_text, text_w - Theme.scale(24), "small")
    local stack_h = title_size.h + line2_size.h + meta_size.h + text_gap * 2
    local title_y = y + pad
    local max_bottom = y + h - pad
    if title_y + stack_h > max_bottom then
        title_y = math.max(y + Theme.scale(4), max_bottom - stack_h)
    end
    local line2_y = title_y + title_size.h + text_gap
    local meta_y = line2_y + line2_size.h + text_gap
    P.text(bb, title, text_x, title_y, text_w, "small", { bold = true })
    P.text(bb, second_line, text_x, line2_y, text_w, "small")
    P.text(bb, meta_text, text_x, meta_y, text_w - Theme.scale(24), "small")
    local verify_size = Theme.scale(16)
    draw_verification_icon(bb, Models.package_verified(pkg), text_x + math.min(meta_size.w + Theme.scale(5), text_w - verify_size), meta_y + math.floor((meta_size.h - verify_size) / 2), verify_size)

    if pkg.installed then
        local check = Theme.scale(28)
        local cx = x + w - Theme.scale(34)
        local cy = y + Theme.scale(5)
        if not P.image(bb, Images.asset("checkmark.svg"), cx, cy, check, check, { is_icon = true }) then
            P.center_text(bb, "v", cx, cy + Theme.scale(2), check, "small", { bold = true })
        end
    end

    action_pill(view, bb, Models.package_action_label(pkg), action_x, action_y, action_w, action_h, function()
        view.app:perform_package_action(pkg, function()
            view.app:reload_current_page()
        end)
    end)
    P.hit(view, x, y, action_x - x, h, function()
        view.app:show_package_details(pkg.id or pkg.name, view.app.state.active_tab)
    end, "package:" .. tostring(pkg.id or pkg.name))
    return h
end

function Cards.featured(view, bb, pkg, x, y, w)
    local m = Theme.metrics()
    local h = m.featured_h
    P.box(bb, x, y, w, h)
    local art_h = h - Theme.scale(118)
    local inset = Theme.scale(3)
    if not P.image_zoomed_masked(bb, view.app:package_featured_file(pkg), x + inset, y + inset, w - inset * 2, art_h - inset * 2, 1.25, {
        is_icon = false,
        outer_bounds = { x = x, y = y, w = w, h = h },
        mask_bounds = { x = x + Theme.scale(2), y = y + Theme.scale(2), w = w - Theme.scale(4), h = h - Theme.scale(4) },
    }) then
        P.center_text(bb, "Featured", x, y + math.floor(art_h / 2) - Theme.scale(14), w, "heading", { bold = true, color = Theme.muted })
    end
    P.rect(bb, x, y + art_h - Theme.scale(1), w, Theme.scale(1), Theme.border)
    P.hit(view, x, y, w, h, function()
        view.app:show_package_details(pkg.id or pkg.name, view.app.state.active_tab)
    end, "featured:" .. tostring(pkg.id or pkg.name))
    Cards.package(view, bb, pkg, x + Theme.scale(2), y + art_h, w - Theme.scale(4), {
        compact = true,
        height = h - art_h - Theme.scale(3),
        pad = Theme.scale(6),
        text_gap = Theme.scale(2),
        action_w = Theme.scale(104),
        action_h = Theme.scale(42),
        border = false,
    })
    return h
end

function Cards.source(view, bb, repo, x, y, w)
    local m = Theme.metrics()
    local h = m.repo_h
    P.box(bb, x, y, w, h)
    local pad = Theme.scale(10)
    local icon = Theme.scale(62)
    local ix = x + pad
    local iy = y + math.floor((h - icon) / 2)
    if not P.image(bb, view.app:repo_icon_file(repo), ix, iy, icon, icon, { is_icon = true }) then
        P.center_text(bb, repo.name == "KindleForge" and "KF" or "SRC", ix, iy + Theme.scale(18), icon, "small", { bold = true })
    end

    local action_w = repo.default and 0 or Theme.scale(96)
    local text_x = x + pad + icon + Theme.scale(10)
    local text_w = w - (text_x - x) - pad - action_w - (action_w > 0 and Theme.scale(12) or 0)
    local title_y = y + Theme.scale(24)
    local url_y = y + Theme.scale(66)
    local title_size = P.text(bb, ellipsize(repo.name or "Source", 60), text_x, title_y, text_w - Theme.scale(22), "heading", { bold = true })
    local verify_size = Theme.scale(18)
    draw_verification_icon(bb, Models.repo_verified(repo), text_x + math.min(title_size.w + Theme.scale(5), text_w - verify_size), title_y + math.floor((title_size.h - verify_size) / 2), verify_size)
    P.text(bb, ellipsize(repo.url or "", 54), text_x, url_y, text_w, "small")

    if action_w > 0 then
        action_pill(view, bb, "Remove", x + w - action_w - pad, y + math.floor((h - m.action_h) / 2), action_w, m.action_h, function()
            view.app:confirm_remove_source(repo.name)
        end)
    end
    P.hit(view, x, y, w - action_w - pad, h, function()
        view.app:show_source_details(repo.name)
    end, "source:" .. tostring(repo.name))
    return h
end

return Cards
