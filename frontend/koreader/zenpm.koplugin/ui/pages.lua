-- Per-page content rendering for AppView. Each function draws the scrollable
-- body for one page and returns its max_scroll. Takes the AppView instance for
-- shared state and hitbox registration.

local Cards = require("ui/cards")
local Header = require("ui/header")
local I18n = require("i18n")
local Models = require("models")
local P = require("ui/primitives")
local Scroll = require("ui/scroll")
local Theme = require("ui/theme")
local Util = require("zenpm_util")
local _ = require("gettext")

local Pages = {}
local PACKAGE_ROWS_PER_SCREEN = 4
local PATCH_ROWS_PER_SCREEN = 5

local function ellipsize(value, limit)
    local text = tostring(value or "")
    if text and #text > limit then
        text = text:sub(1, limit)
        text = Util.fixUtf8(text, "") .. "…"
    end
    return text
end

local function package_card_height(list_h, gap)
    return math.max(1, math.floor((list_h - gap * (PACKAGE_ROWS_PER_SCREEN - 1)) / PACKAGE_ROWS_PER_SCREEN))
end

local function patch_row_height(list_h, gap)
    return math.max(Theme.metrics().touch_min, math.floor((list_h - gap * (PATCH_ROWS_PER_SCREEN - 1)) / PATCH_ROWS_PER_SCREEN))
end

local function patch_asset_meta(asset)
    local parts = {}
    local arch = Util.trim(tostring(asset.arch or ""))
    if arch ~= "" and arch:lower() ~= "any" then
        table.insert(parts, arch)
    end
    local size = tonumber(asset.size)
    if size and size > 0 then
        table.insert(parts, tostring(math.floor((size + 1023) / 1024)) .. " KB")
    end
    return table.concat(parts, " • ")
end

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
    local card_h = package_card_height(list_h, m.card_gap)
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
        Scroll.set_list_bounds(view, x, list_y, w, list_h, card_h + m.card_gap)
        return 0
    end
    return Scroll.scrolled_list(view, bb, visible, x, list_y, w, list_h, scroll, card_h, m.card_gap, function(pkg, row_y, scrollable)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.package(view, bb, pkg, x + pad, row_y, w - pad * 2 - gutter, { height = card_h })
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
    local card_h = package_card_height(list_h, m.card_gap)
    if #visible == 0 then
        P.text(bb, _("No packages found for this source."), x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        Scroll.set_list_bounds(view, x, list_y, w, list_h, card_h + m.card_gap)
        return 0
    end
    return Scroll.scrolled_list(view, bb, visible, x, list_y, w, list_h, scroll, card_h, m.card_gap, function(pkg, row_y, scrollable)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.package(view, bb, pkg, x + pad, row_y, w - pad * 2 - gutter, { height = card_h })
    end)
end

function Pages.package_details(view, bb, x, y, w, h, scroll)
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
        if not P.image_zoomed_masked(bb, view.app:package_featured_file(pkg), panel_x + border, cy + border, panel_w - border * 2, art_h - border, 1.1, {
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
    local readme = Models.readme_text(pkg.github_readme)
    local content = readme
    local heading = _("GitHub README")
    if content == "" then
        content = I18n.dynamic_or(pkg.description, _("No description available."))
        heading = _("Description")
    end
    local assets = Models.package_assets(pkg)
    local show_patch_tabs = Models.is_patch_package(pkg) and #assets > 0
    local details_tab = show_patch_tabs and (view.app.state.details_tab or "readme") or "readme"
    if details_tab ~= "patches" then
        details_tab = "readme"
    end
    if show_patch_tabs then
        local tab_h = Theme.scale(38)
        local gap = Theme.scale(8)
        local tab_w = math.floor((inner_w - gap) / 2)
        local function draw_tab(id, label, tx, tw)
            local selected = details_tab == id
            P.box(bb, tx, iy, tw, tab_h, {
                background = selected and Theme.panel or Theme.bg,
                border_color = selected and Theme.border or Theme.soft,
                radius = math.floor(tab_h / 2),
            })
            P.center_text_box(bb, label, tx, iy, tw, tab_h, "small", { bold = selected })
            P.hit(view, tx, iy, tw, tab_h, function()
                view.app:set_package_details_tab(id)
            end, "details-tab:" .. id)
        end
        draw_tab("readme", _("GitHub README"), inner_x, tab_w)
        draw_tab("patches", _("Patches"), inner_x + tab_w + gap, inner_w - tab_w - gap)
        iy = iy + tab_h + Theme.scale(14)
    else
        P.text(bb, heading, inner_x, iy, inner_w, "small", { bold = true })
        iy = iy + Theme.scale(34)
    end
    local content_h = cy + panel_h - Theme.scale(14) - iy
    if content_h <= 0 then
        Scroll.set_list_bounds(view, panel_x, cy, panel_w, panel_h, panel_h)
        return 0
    end
    if details_tab == "patches" then
        local gap = Theme.scale(8)
        local row_h = patch_row_height(content_h, gap)
        local list_w = inner_w
        local max_scroll = Scroll.scrolled_list(view, bb, assets, inner_x, iy, list_w, content_h, scroll, row_h, gap, function(asset, row_y)
            local gutter = Theme.scale(30)
            local row_w = list_w - gutter
            P.box(bb, inner_x, row_y, row_w, row_h)
            local text_x = inner_x + Theme.scale(10)
            local text_w = row_w - Theme.scale(20)
            local installed = Models.patch_file_installed(pkg, tostring(asset.asset or ""))
            local label = ellipsize(asset.asset, 70)
            if installed then
                label = label .. "  " .. _("(installed)")
            end
            P.text(bb, label, text_x, row_y + Theme.scale(8), text_w, "small", { bold = true })
            local meta = patch_asset_meta(asset)
            if meta ~= "" then
                P.text(bb, meta, text_x, row_y + Theme.scale(32), text_w, "tiny", { color = Theme.muted })
            end
            P.hit(view, inner_x, row_y, row_w, row_h, function()
                view.app:confirm_package_asset_action(pkg, asset, function()
                    view.app:reload_current_page()
                end)
            end, "patch:" .. tostring(asset.asset or ""))
        end)
        return max_scroll
    end
    local max_scroll, line_h = P.scrollable_paragraph(bb, content, inner_x, iy, inner_w - Theme.scale(12), content_h, "small", scroll)
    Scroll.set_list_bounds(view, inner_x, iy, inner_w, content_h, line_h)
    return max_scroll
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
