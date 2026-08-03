-- Shared title bar and per-page toolbar rendering for AppView.

local Images = require("ui/images")
local InlineIcons = require("ui/inline_icon_map")
local Models = require("models")

local Geom = require("ui/geometry")
local Constants = require("constants")
local I18n = dofile(Constants.PLUGIN_DIR .. "/i18n.lua")
local P = require("ui/primitives")
local Theme = require("ui/theme")
local _ = require("gettext")

local Header = {}

local function focus_control(view, bb, id, x, y, w, h, callback, inverse)
    P.focus_control(view, bb, id, x, y, w, h, callback, { inverse = inverse })
end

local function ellipsize(value, limit)
    local title = tostring(value or "")
    if #title > limit then
        title = title:sub(1, limit)
        title = require("zenpm_util").fixUtf8(title, "") .. "…"
    end
    return title
end

local function filtered_count(visible, total, query)
    local count = tostring(#(visible or {}))
    if query and query ~= "" then
        count = count .. "/" .. tostring(#(total or {}))
    end
    return count
end

function Header.page_title(view)
    local state = view.app.state
    local page = state.page
    if page == "home" then
        return _("Featured") .. " (" .. tostring(#(state.featured_packages or {})) .. ")"
    elseif page == "changes" then
        return _("Changes") .. " (" .. tostring(#(state.changes_packages or {})) .. ")"
    elseif page == "search" then
        return _("Discover") .. " (" .. filtered_count(state.visible_packages, state.packages, state.filters.search) .. ")"
    elseif page == "categories" then
        return _("Categories") .. " (" .. filtered_count(state.visible_categories, state.categories, state.filters.categories) .. ")"
    elseif page == "category_details" then
        local category = state.current_category or {}
        return I18n.dynamic_or(category.label, _("Category")) .. " ("
            .. filtered_count(state.visible_packages, state.category_packages, state.filters.category) .. ")"
    elseif page == "installed" then
        return _("Installed") .. " ("
            .. filtered_count(state.visible_packages, state.installed_packages, state.filters.installed) .. ")"
    elseif page == "sources" then
        return _("Sources") .. " (" .. tostring(#(state.repos or {})) .. ")"
    elseif page == "source_details" then
        local repo = state.current_repo or {}
        return Models.repo_display_name(I18n.dynamic_or(repo.name, _("Source"))) .. " ("
            .. tostring(#(state.visible_packages or {})) .. ")"
    elseif page == "package_details" then
        return Models.package_display_name(state.current_package or {}, _("Package Details"))
    elseif page == "queue" then
        return _("Queue") .. " (" .. tostring(view.app:queue_count()) .. ")"
    elseif page == "settings" then
        return _("Settings")
    elseif page == "debug" then
        return _("Debug")
    end
    return _("ZenPM")
end

function Header.draw_actions(view, bb, x, y)
    local s = Theme.scale(42)
    P.box(bb, x, y, s, s, { border = false })
    local dot = Theme.scale(6)
    local cx = x + math.floor((s - dot) / 2)
    local first_y = y + math.floor((s - Theme.scale(24)) / 2)
    for i = 0, 2 do
        P.box(bb, cx, first_y + i * Theme.scale(9), dot, dot, {
            border = false,
            background = Theme.ink,
            radius = math.floor(dot / 2),
        })
    end
    local callback = function()
        view.app:show_actions(Geom:new{ x = x, y = y, w = s, h = s })
    end
    P.hit(view, x, y, s, s, callback, "actions")
    focus_control(view, bb, "actions", x, y, s, s, callback)
    return s
end

local function icon_button_width(label, icon)
    local label_size = P.text_size(label, Theme.scale(128), "small", { bold = true })
    return Theme.scale(10) + icon + Theme.scale(6) + label_size.w + Theme.scale(14), label_size
end

function Header.draw_sort_button(view, bb, x, y, kind)
    local s = Theme.scale(42)
    local icon = Theme.scale(24)
    local label = _("Sort")
    local w, label_size = icon_button_width(label, icon)
    P.box(bb, x, y, w, s, { border = false, background = Theme.ink, radius = math.floor(s / 2) })
    P.center_text_box(bb, InlineIcons.icon("sort"), x + Theme.scale(10), y, icon, s, "small", { bold = true, color = Theme.bg })
    P.vcenter_text(bb, label, x + Theme.scale(10) + icon + Theme.scale(6), y, label_size.w, s, "small", { bold = true, color = Theme.bg })
    local callback = function() view.app:prompt_sort(kind) end
    local id = "sort:" .. tostring(kind)
    P.hit(view, x, y, w, s, callback, id)
    focus_control(view, bb, id, x, y, w, s, callback, true)
    return w
end

function Header.draw_installed_category_button(view, bb, x, y)
    local h = Theme.scale(42)
    local icon = Theme.scale(24)
    local category = Models.category_for_id(view.app.state.filters.installed)
    local label = category and Models.category_label(category) or _("Filter")
    local label_size = P.text_size(label, Theme.scale(128), "small", { bold = true })
    local w = Theme.scale(10) + icon + Theme.scale(6) + label_size.w + Theme.scale(14)
    P.box(bb, x, y, w, h, { border = false, background = Theme.ink, radius = math.floor(h / 2) })
    P.center_text_box(bb, InlineIcons.icon("filter"), x + Theme.scale(10), y, icon, h, "small", { bold = true, color = Theme.bg })
    P.vcenter_text(bb, label, x + Theme.scale(10) + icon + Theme.scale(6), y, label_size.w, h, "small", { bold = true, color = Theme.bg })
    local callback = function()
        view.app:prompt_installed_category_filter()
    end
    P.hit(view, x, y, w, h, callback, "filter-category:installed")
    focus_control(view, bb, "filter-category:installed", x, y, w, h, callback, true)
    return w
end

function Header.draw_back(view, bb, x, y, callback)
    local s = Theme.scale(46)
    P.box(bb, x, y, s, s, { border = false })
    if not P.image(bb, Images.asset("chevron.left.svg"), x + Theme.scale(8), y + Theme.scale(8), s - Theme.scale(16), s - Theme.scale(16), { is_icon = true }) then
        P.center_text(bb, "<", x, y + Theme.scale(13), s, "title", { bold = true })
    end
    P.hit(view, x, y, s, s, callback, "back")
    focus_control(view, bb, "back", x, y, s, s, callback)
    return s
end

function Header.draw_close(view, bb, x, y)
    local s = Theme.scale(46)
    P.box(bb, x, y, s, s, { border = false })
    if not P.image(bb, Images.asset("close.svg"), x + Theme.scale(11), y + Theme.scale(11), s - Theme.scale(22), s - Theme.scale(22), { is_icon = true }) then
        P.center_text(bb, "×", x, y + Theme.scale(10), s, "title", { bold = true })
    end
    local callback = function() view.app:close_settings() end
    P.hit(view, x, y, s, s, callback, "close-settings")
    focus_control(view, bb, "close-settings", x, y, s, s, callback)
    return s
end

function Header.draw_search_button(view, bb, x, y, kind)
    local s = Theme.scale(42)
    local icon = Theme.scale(24)
    local label = _("Search")
    local w, label_size = icon_button_width(label, icon)
    P.box(bb, x, y, w, s, { border = false, background = Theme.ink, radius = math.floor(s / 2) })
    P.center_text_box(bb, InlineIcons.icon("search"), x + Theme.scale(10), y, icon, s, "small", { bold = true, color = Theme.bg })
    P.vcenter_text(bb, label, x + Theme.scale(10) + icon + Theme.scale(6), y, label_size.w, s, "small", { bold = true, color = Theme.bg })
    local callback = function() view.app:prompt_filter(kind) end
    local id = "search:" .. kind
    P.hit(view, x, y, w, s, callback, id)
    focus_control(view, bb, id, x, y, w, s, callback, true)
    return w
end

local function toolbar_y(y, h, control_h)
    return y + math.floor((h - control_h) / 2)
end

local function title_button_width(label)
    return P.text_size(label, Theme.scale(256), "small", { bold = true }).w + Theme.scale(28)
end

local function draw_title_button(view, bb, x, y, label, callback, hit_id, enabled)
    local h = Theme.scale(42)
    local w = title_button_width(label)
    P.box(bb, x, y, w, h, {
        border_color = enabled and Theme.button_bg or Theme.soft,
        background = enabled and Theme.button_bg or Theme.bg,
        radius = math.floor(h / 2),
    })
    P.center_text_box(bb, label, x, y, w, h, "small", { bold = true, color = enabled and Theme.button_text or Theme.muted })
    if enabled then
        P.hit(view, x, y, w, h, callback, hit_id)
        focus_control(view, bb, hit_id, x, y, w, h, callback, true)
    end
    return w
end

local function page_back_callback(view, page)
    if page == "category_details" then
        return function() view.app:show_categories() end
    elseif page == "source_details" then
        return function() view.app:show_sources() end
    elseif page == "package_details" then
        return function() view.app:go_back_from_details() end
    elseif page == "queue" then
        return function() view.app:close_queue() end
    end
end

local function draw_queue_clear_button(view, bb, x, y)
    local h = Theme.scale(42)
    local icon = h - Theme.scale(14)
    local label = _("Clear")
    local label_size = P.text_size(label, Theme.scale(128), "small", { bold = true })
    local w = Theme.scale(14) + icon + Theme.scale(6) + label_size.w + Theme.scale(14)
    local enabled = view.app:queue_count() > 0 and not view.app.state.queue_running
    P.box(bb, x, y, w, h, {
        border = false,
        background = enabled and Theme.button_bg or Theme.bg,
        radius = math.floor(h / 2),
    })
    P.center_text_box(bb, InlineIcons.icon("clear"), x + Theme.scale(7), y, icon, h, "small", { bold = true, color = enabled and Theme.button_text or Theme.muted })
    P.vcenter_text(bb, label, x + Theme.scale(7) + icon + Theme.scale(6), y, label_size.w, h, "small", { bold = true, color = enabled and Theme.button_text or Theme.muted })
    if enabled then
        local callback = function() view.app:confirm_clear_queue() end
        P.hit(view, x, y, w, h, callback, "clear-queue")
        focus_control(view, bb, "clear-queue", x, y, w, h, callback, true)
    end
end

local function draw_title_bar(view, bb, x, y, w)
    local m = Theme.metrics()
    local h = m.titlebar_h
    local page = view.app.state.page
    local pad = m.pad
    local title_x = x + pad
    local title_right = x + w - pad
    local top_right_control_x
    P.box(bb, x, y, w, h, { border = false, background = Theme.panel })
    local back_callback = page_back_callback(view, page)
    if back_callback then
        title_x = title_x + Header.draw_back(view, bb, title_x, toolbar_y(y, h, Theme.scale(46)), back_callback) + Theme.scale(6)
    end
    if page == "settings" then
        local close_s = Theme.scale(46)
        local close_x = title_right - close_s
        Header.draw_close(view, bb, close_x, toolbar_y(y, h, close_s))
        top_right_control_x = close_x
        title_right = close_x - Theme.scale(8)
    else
        local action_s = Theme.scale(42)
        local action_x = title_right - action_s
        Header.draw_actions(view, bb, action_x, toolbar_y(y, h, action_s))
        top_right_control_x = action_x
        title_right = action_x - Theme.scale(8)
    end
    if page == "home" then
        local logo = Theme.scale(42)
        if not P.image(bb, Images.asset("zenpm.svg"), title_x, toolbar_y(y, h, logo), logo, logo, { is_icon = true }) then
            P.center_text_box(bb, "Z", title_x, toolbar_y(y, h, logo), logo, logo, "title", { bold = true })
        end
        title_x = title_x + logo + Theme.scale(14)
        P.vcenter_text(bb, _("Welcome") .. " " .. _("to") .. " " .. _("ZenPM"), title_x, y, math.max(0, title_right - title_x), h, "title", { bold = true })
    else
        P.vcenter_text(bb, ellipsize(Header.page_title(view), 60), title_x, y, math.max(0, title_right - title_x), h, "heading", { bold = true })
    end
    view.koreader_menu_zone = { x = x, y = y, w = w, h = h }
    -- Taps near ZenPM's top-right control should not leak through to
    -- KOReader's title-bar menu gesture. Keep a generous guard on its left
    -- and extend it to the screen edge on its right.
    local guard_x = math.max(x, top_right_control_x - Theme.scale(18))
    view.koreader_menu_tap_guard = { x = guard_x, y = y, w = x + w - guard_x, h = h }
    return y + h
end

function Header.draw(view, bb, x, y, w)
    local page = view.app.state.page
    local m = Theme.metrics()
    local pad = m.pad
    y = draw_title_bar(view, bb, x, y, w)
    local toolbar_h = m.toolbar_h

    local button_y = toolbar_y(y, toolbar_h, Theme.scale(42))
    local control_x = x + pad
    local gap = Theme.scale(6)
    local filter_kind = ({
        search = "search",
        category_details = "category",
        source_details = "source",
    })[page]
    local sort_kind = ({
        search = "search",
        changes = "changes",
        category_details = "category",
        installed = "installed",
        sources = "sources",
        source_details = "source",
    })[page]
    if sort_kind then
        control_x = control_x + Header.draw_sort_button(view, bb, control_x, button_y, sort_kind) + gap
    end
    if page == "installed" then
        control_x = control_x + Header.draw_installed_category_button(view, bb, control_x, button_y) + gap
    end
    local right_x = x + w - pad
    if page == "sources" then
        local label = "+ " .. _("Add Source")
        right_x = right_x - title_button_width(label)
        draw_title_button(view, bb, right_x, button_y, label, function()
            view.app:prompt_add_source()
        end, "add-source", true)
    elseif page == "installed" or page == "changes" then
        local updates = view.app:installed_update_count()
        local label = _("Update All") .. " (" .. tostring(updates) .. ")"
        local enabled = updates > 0 and not view.app.state.queue_running
        right_x = right_x - title_button_width(label)
        draw_title_button(view, bb, right_x, button_y, label, function()
            view.app:queue_all_updates()
        end, "upgrade-all", enabled)
    end
    if filter_kind then
        local search_w = icon_button_width(_("Search"), Theme.scale(24))
        right_x = right_x - search_w
        Header.draw_search_button(view, bb, right_x, button_y, filter_kind)
    end
    if page == "queue" then
        local button_h = Theme.scale(42)
        local confirm_w = Theme.scale(120)
        local confirm_x = x + w - pad - confirm_w
        local enabled = view.app:queue_count() > 0 and not view.app.state.queue_running
        local row_y = button_y
        draw_queue_clear_button(view, bb, control_x, row_y)
        P.box(bb, confirm_x, row_y, confirm_w, button_h, {
            background = enabled and Theme.button_bg or Theme.bg,
            border_color = enabled and Theme.button_bg or Theme.soft,
            radius = math.floor(button_h / 2),
        })
        P.center_text_box(bb, _("Confirm"), confirm_x, row_y, confirm_w, button_h, "small", { bold = true, color = enabled and Theme.button_text or Theme.muted })
        if enabled then
            local callback = function() view.app:prompt_queue_confirmation() end
            P.hit(view, confirm_x, row_y, confirm_w, button_h, callback, "confirm-queue")
            focus_control(view, bb, "confirm-queue", confirm_x, row_y, confirm_w, button_h, callback, true)
        end
        return y + toolbar_h
    end
    if filter_kind or sort_kind then
        return y + toolbar_h
    end
    return y
end

return Header
