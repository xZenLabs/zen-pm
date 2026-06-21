-- Per-page content rendering for AppView. Each function draws the scrollable
-- body for one page and returns its max_scroll. Takes the AppView instance for
-- shared state and hitbox registration.

local Cards = require("ui/cards")
local Header = require("ui/header")
local I18n = require("i18n")
local P = require("ui/primitives")
local Scroll = require("ui/scroll")
local Theme = require("ui/theme")
local _ = require("gettext")

local Pages = {}

function Pages.featured(view, bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local list = view.app.state.featured_packages or {}
    local list_y = y + Theme.scale(8)
    local list_h = h - Theme.scale(8)
    if #list == 0 then
        P.text(bb, _("Featured packages coming soon."), x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        Scroll.set_list_bounds(view, x, list_y, w, list_h, m.featured_h + m.card_gap)
        return 0
    end
    return Scroll.scrolled_list(view, bb, list, x, list_y, w, list_h, scroll, m.featured_h, m.card_gap, function(pkg, cy, scrollable)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.featured(view, bb, pkg, x + pad, cy, w - pad * 2 - gutter)
    end)
end

function Pages.packages_page(view, bb, x, y, w, h, scroll, title, kind, visible, total, query)
    local m = Theme.metrics()
    local pad = m.pad
    local count = tostring(#(visible or {}))
    if query and query ~= "" then
        count = count .. "/" .. tostring(#(total or {}))
    end
    local cy = y
    local sort_s = Theme.scale(42)
    local sort_x = x + w - pad - sort_s
    P.text(bb, title .. " (" .. count .. ")", x + pad, cy + Theme.scale(6), sort_x - x - pad - Theme.scale(8), "heading", { bold = true })
    Header.draw_sort_button(view, bb, sort_x, cy + Theme.scale(6), kind)
    cy = cy + Theme.scale(54)
    local list_y = cy
    local list_h = h - (list_y - y) - Theme.scale(8)
    if #(visible or {}) == 0 then
        local msg = _("No packages found. Try Refresh.")
        if kind == "installed" then
            msg = query and query ~= "" and _("No installed packages match the filter.") or _("No packages installed. Browse Search to find packages.")
        elseif kind == "category" then
            msg = query and query ~= "" and _("No packages match the filter.") or _("No packages found for this category.")
        elseif query and query ~= "" then
            msg = _("No packages match the filter.")
        end
        P.text(bb, msg, x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        Scroll.set_list_bounds(view, x, list_y, w, list_h, m.card_h + m.card_gap)
        return 0
    end
    return Scroll.scrolled_list(view, bb, visible, x, list_y, w, list_h, scroll, m.card_h, m.card_gap, function(pkg, row_y, scrollable)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.package(view, bb, pkg, x + pad, row_y, w - pad * 2 - gutter)
    end)
end

function Pages.sources(view, bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local list_y = y + Theme.scale(8)
    local list_h = h - Theme.scale(12)
    local repos = view.app.state.repos or {}
    if #repos == 0 then
        P.text(bb, _("No repositories configured."), x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        Scroll.set_list_bounds(view, x, list_y, w, list_h, m.repo_h + m.card_gap)
        return 0
    end
    return Scroll.scrolled_list(view, bb, repos, x, list_y, w, list_h, scroll, m.repo_h, m.card_gap, function(repo, row_y)
        Cards.source(view, bb, repo, x + pad, row_y, w - pad * 2)
    end)
end

function Pages.categories(view, bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local categories = view.app.state.visible_categories or {}
    local total = view.app.state.categories or {}
    local query = view.app.state.filters.categories
    local count = tostring(#categories)
    if query and query ~= "" then
        count = count .. "/" .. tostring(#total)
    end
    local cy = y
    P.text(bb, _("Categories") .. " (" .. count .. ")", x + pad, cy + Theme.scale(6), w - pad * 2, "heading", { bold = true })
    cy = cy + Theme.scale(54)
    local list_y = cy
    local list_h = h - (list_y - y) - Theme.scale(8)
    if #categories == 0 then
        local msg = query and query ~= "" and _("No categories match the filter.") or _("No categories found.")
        P.text(bb, msg, x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        Scroll.set_list_bounds(view, x, list_y, w, list_h, m.category_h + m.card_gap)
        return 0
    end
    return Scroll.scrolled_list(view, bb, categories, x, list_y, w, list_h, scroll, m.category_h, m.card_gap, function(category, row_y, scrollable)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.category(view, bb, category, x + pad, row_y, w - pad * 2 - gutter)
    end)
end

function Pages.source_details(view, bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local cy = y + Theme.scale(8)
    local visible = view.app.state.visible_packages or {}
    local sort_s = Theme.scale(42)
    local sort_x = x + w - pad - sort_s
    P.text(bb, _("Packages") .. " (" .. tostring(#visible) .. ")", x + pad, cy, sort_x - x - pad - Theme.scale(8), "heading", { bold = true })
    Header.draw_sort_button(view, bb, sort_x, cy, "source")
    cy = cy + Theme.scale(54)
    local list_y = cy
    local list_h = h - (list_y - y) - Theme.scale(8)
    if #visible == 0 then
        P.text(bb, _("No packages found for this source."), x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        Scroll.set_list_bounds(view, x, list_y, w, list_h, m.card_h + m.card_gap)
        return 0
    end
    return Scroll.scrolled_list(view, bb, visible, x, list_y, w, list_h, scroll, m.card_h, m.card_gap, function(pkg, row_y, scrollable)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.package(view, bb, pkg, x + pad, row_y, w - pad * 2 - gutter)
    end)
end

function Pages.package_details(view, bb, x, y, w, h)
    local m = Theme.metrics()
    local pad = m.pad
    local pkg = view.app.state.current_package or {}
    local cy = y + Theme.scale(8)
    local panel_h = h - Theme.scale(30)
    local panel_x = x + pad
    local panel_w = w - pad * 2
    P.box(bb, panel_x, cy, panel_w, panel_h)
    local inner_x = x + pad + Theme.scale(12)
    local inner_w = w - pad * 2 - Theme.scale(24)
    local iy = cy + Theme.scale(12)
    if pkg.featured_image then
        local art_h = m.featured_h - Theme.scale(118)
        local border = Theme.scale(2)
        if not P.image_zoomed_masked(bb, view.app:package_featured_file(pkg), panel_x + border, cy + border, panel_w - border * 2, art_h - border, 1.25, {
            is_icon = false,
            outer_bounds = { x = panel_x, y = cy, w = panel_w, h = panel_h },
            mask_bounds = { x = panel_x + border, y = cy + border, w = panel_w - border * 2, h = panel_h - border * 2 },
        }) then
            P.center_text(bb, _("Featured"), panel_x, cy + Theme.scale(60), panel_w, "heading", { bold = true, color = Theme.muted })
        end
        iy = cy + art_h
        P.rect(bb, panel_x + Theme.scale(2), iy, panel_w - Theme.scale(4), Theme.scale(1), Theme.border)
        iy = iy + Theme.scale(10)
    end
    local summary_h = m.card_h
    Cards.package(view, bb, pkg, inner_x, iy, inner_w, {
        height = summary_h,
        second_line = _("By ") .. I18n.dynamic_or(pkg.author, "?"),
        text_gap = Theme.scale(6),
        border = false,
    })
    local card_bottom = iy + summary_h
    local description_y = card_bottom + Theme.scale(18)
    local divider_y = card_bottom + math.floor((description_y - card_bottom) / 2)
    P.rect(bb, panel_x + Theme.scale(2), divider_y, panel_w - Theme.scale(4), Theme.scale(1), Theme.soft)
    iy = description_y
    P.text(bb, _("Description"), inner_x, iy, inner_w, "small", { bold = true })
    iy = iy + Theme.scale(34)
    local desc_bottom = cy + panel_h - Theme.scale(14)
    local desc_h = desc_bottom - iy
    if desc_h > 0 then
        P.paragraph(bb, I18n.dynamic_or(pkg.description, _("No description available.")), inner_x, iy, inner_w, desc_h, "small")
    end
    return cy + panel_h - Theme.scale(12)
end

function Pages.debug(view, bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local cy = y + Theme.scale(8)
    local panel_h = h - Theme.scale(16)
    P.box(bb, x + pad, cy, w - pad * 2, panel_h)
    local lines = view.app.state.log_lines or {}
    local inner_x = x + pad + Theme.scale(12)
    local inner_y = cy + Theme.scale(12)
    local inner_w = w - pad * 2 - Theme.scale(24)
    local inner_h = panel_h - Theme.scale(24)
    local line_h = Theme.scale(22)
    Scroll.set_list_bounds(view, inner_x, inner_y, inner_w, inner_h, line_h)
    P.rect(bb, inner_x, inner_y, inner_w, inner_h, Theme.bg)

    local ty = inner_y - scroll
    for _, line in ipairs(lines) do
        if ty >= inner_y and ty + line_h <= inner_y + inner_h then
            P.text(bb, line, inner_x, ty, inner_w, "mono")
        end
        ty = ty + line_h
    end
    return math.max(0, #lines * line_h - inner_h)
end

return Pages
