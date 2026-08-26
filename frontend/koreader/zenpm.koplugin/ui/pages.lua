-- Per-page content rendering for AppView. Each function draws the scrollable
-- body for one page and returns its max_scroll. Takes the AppView instance for
-- shared state and hitbox registration.

local Cards = require("ui/cards")
local Constants = require("zenpm_constants")
local I18n = dofile(Constants.PLUGIN_DIR .. "/i18n.lua")
local Images = require("ui/images")
local Markdown = require("ui/markdown")
local MarkdownRenderer = require("ui/markdown_renderer")
local Models = require("models")
local P = require("ui/primitives")
local Scroll = require("ui/scroll")
local Theme = require("ui/theme")
local Util = require("zenpm_util")
local _ = require("gettext")

local Pages = {}
local PACKAGE_ROWS_PER_SCREEN = 4
local PATCH_ROWS_PER_SCREEN = 5
local COMPACT_ROWS_PER_SCREEN = 6

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

local function compact_row_height(list_h, gap, rows_per_screen)
    local m = Theme.metrics()
    rows_per_screen = math.max(1, tonumber(rows_per_screen) or COMPACT_ROWS_PER_SCREEN)
    return math.max(m.touch_min, math.min(m.category_h,
        math.floor((list_h - gap * (rows_per_screen - 1)) / rows_per_screen)))
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

function Pages.error(view, bb, x, y, w, h, message)
    local m = Theme.metrics()
    local pad = m.pad
    local button_h = Theme.scale(46)
    local gap = Theme.scale(10)
    local button_w = math.floor((w - pad * 2 - gap) / 2)
    local button_y = y + h - button_h - Theme.scale(18)
    local platform = view.app.daemon:detect_platform()
    local abi = nil
    if platform == "kindle" or platform == "kobo" then
        abi = tostring(view.app.daemon:ereader_backend_suffix())
    end

    P.text(bb, message, x + pad, y + Theme.scale(16), w - pad * 2, "default", { color = Theme.muted })
    if abi then
        P.text(bb, _("Detected ABI: ") .. abi, x + pad, button_y - Theme.scale(34), w - pad * 2, "small", { color = Theme.muted })
    end
    P.box(bb, x + pad, button_y, button_w, button_h, { background = Theme.button_bg, border_color = Theme.button_bg, radius = math.floor(button_h / 2) })
    P.center_text_box(bb, _("Retry"), x + pad, button_y, button_w, button_h, "small", { bold = true, color = Theme.button_text })
    local retry_callback = function()
        view.app:start_backend_then_reload()
    end
    P.hit(view, x + pad, button_y, button_w, button_h, retry_callback, "retry-backend")
    P.focus_control(view, bb, "retry-backend", x + pad, button_y, button_w, button_h, retry_callback, { inverse = true })

    local quit_x = x + pad + button_w + gap
    P.box(bb, quit_x, button_y, button_w, button_h, { background = Theme.button_bg, border_color = Theme.button_bg, radius = math.floor(button_h / 2) })
    P.center_text_box(bb, _("Quit"), quit_x, button_y, button_w, button_h, "small", { bold = true, color = Theme.button_text })
    local quit_callback = function()
        view.app:quit()
    end
    P.hit(view, quit_x, button_y, button_w, button_h, quit_callback, "quit")
    P.focus_control(view, bb, "quit", quit_x, button_y, button_w, button_h, quit_callback, { inverse = true })
    Scroll.set_list_bounds(view, x, y, w, h, h)
end

function Pages.featured(view, bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local list = view.app.state.featured_packages or {}
    local list_y = y + Theme.scale(8)
    local list_h = h - Theme.scale(8)
    if #list == 0 then
        P.text(bb, _("Loading packages, please wait"), x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        Scroll.set_list_bounds(view, x, list_y, w, list_h, m.featured_h + m.card_gap)
        return 0
    end
    local bottom_inset = Theme.scale(12)
    local card_h = math.max(1, math.floor((list_h - bottom_inset - m.card_gap) / 2))
    return Scroll.scrolled_list(view, bb, list, x, list_y, w, list_h, scroll, card_h, m.card_gap, function(pkg, cy, scrollable, index, count)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.featured(view, bb, pkg, x + pad, cy, w - pad * 2 - gutter, {
            height = card_h,
            focus_group = "featured",
            focus_index = index,
            focus_count = count,
        })
    end, true)
end

function Pages.packages_page(view, bb, x, y, w, h, scroll, title, kind, visible, total, query)
    local m = Theme.metrics()
    local pad = m.pad
    local cy = y
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
    return Scroll.scrolled_list(view, bb, visible, x, list_y, w, list_h, scroll, card_h, m.card_gap, function(pkg, row_y, scrollable, index, count)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.package(view, bb, pkg, x + pad, row_y, w - pad * 2 - gutter, {
            height = card_h,
            meta_suffix = kind == "changes" and Models.friendly_published_at(pkg) or nil,
            focus_group = kind,
            focus_index = index,
            focus_count = count,
        })
    end, true)
end

local function queue_action_text(action)
    if action == "uninstall" then return _("Uninstall") end
    if action == "update" then return _("Update") end
    if action == "downgrade" then return _("Downgrade") end
    if action == "reinstall" then return _("Reinstall") end
    return _("Install")
end

local function queue_action_icon(action)
    if action == "uninstall" then return "uninstall.svg" end
    if action == "reinstall" then return "reinstall.svg" end
    if action == "install" then return "download.svg" end
    if action == "downgrade" then return "downgrade.svg" end
    return "upgrade.svg"
end

local function queue_version(value)
    value = tostring(value or "")
    if value == "" then return "v?" end
    if value:lower():gsub("^[vV]", "") == "source" then return "source" end
    return value:match("^[vV]") and value or "v" .. value
end

local function queue_version_line(entry)
    local pkg = entry.pkg or {}
    local current = pkg.installed and (pkg.installed_version or pkg.version) or nil
    if entry.is_patch then
        current = pkg.installed_version or pkg.version
    end
    local text = queue_action_text(entry.action) .. " " .. queue_version(current)
    if entry.action == "update" or entry.action == "downgrade" then
        local target = entry.release or pkg.latest_version or pkg.version
        text = text .. "  →  " .. queue_version(target)
    elseif entry.action == "install" then
        local target = entry.release or pkg.latest_version or pkg.version
        text = queue_action_text(entry.action) .. " " .. queue_version(target)
    end
    return text
end

function Pages.queue(view, bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local entries = view.app.state.queue or {}
    local list_y = y + Theme.scale(8)
    local list_h = h - (list_y - y) - Theme.scale(8)
    if #entries == 0 then
        P.text(bb, _("No queued operations."), x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        Scroll.set_list_bounds(view, x, list_y, w, list_h, m.card_h + m.card_gap)
        return 0
    end
    local row_h = compact_row_height(list_h, m.card_gap)
    return Scroll.scrolled_list(view, bb, entries, x, list_y, w, list_h, scroll, row_h, m.card_gap, function(entry, row_y, scrollable, index, count)
        local gutter = scrollable and Theme.scale(14) or 0
        local row_x = x + pad
        local row_w = w - pad * 2 - gutter
        Cards.compact(view, bb, row_x, row_y, row_w, {
            height = row_h,
            icon = view.app:package_icon_file(entry.pkg),
            icon_fallback = "?",
            title = entry.name or _("Package"),
            subtitle = queue_version_line(entry),
            subtitle_color = Theme.ink,
            right_icon = Images.asset(queue_action_icon(entry.action)),
            callback = function() view.app:show_queue_entry_modify(entry) end,
            hit_id = "queue-entry:" .. tostring(entry.key),
            focus = {
                id = "queue-entry:" .. tostring(entry.key),
                focus_type = "queue_entry",
                focus_column = "main",
                focus_content = true,
                focus_primary = true,
                list_group = "queue",
                list_index = index,
                list_count = count,
            },
        })
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
    return Scroll.scrolled_list(view, bb, repos, x, list_y, w, list_h, scroll, m.repo_h, m.card_gap, function(repo, row_y, _scrollable, index, count)
        Cards.source(view, bb, repo, x + pad, row_y, w - pad * 2, {
            focus_group = "sources",
            focus_index = index,
            focus_count = count,
        })
    end)
end

function Pages.categories(view, bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local categories = view.app.state.visible_categories or {}
    local query = view.app.state.filters.categories
    local cy = y + Theme.scale(8)
    local list_y = cy
    local list_h = h - (list_y - y) - Theme.scale(8)
    if #categories == 0 then
        local msg = query and query ~= "" and _("No categories match the filter.") or _("No categories found.")
        P.text(bb, msg, x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        Scroll.set_list_bounds(view, x, list_y, w, list_h, m.category_h + m.card_gap)
        return 0
    end
    -- The list renderer omits partially clipped rows, so fit the complete
    -- category set whenever the device has enough room above touch_min.
    local row_h = compact_row_height(
        list_h, m.card_gap, math.max(COMPACT_ROWS_PER_SCREEN, #categories))
    return Scroll.scrolled_list(view, bb, categories, x, list_y, w, list_h, scroll, row_h, m.card_gap, function(category, row_y, scrollable, index, count)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.category(view, bb, category, x + pad, row_y, w - pad * 2 - gutter, {
            height = row_h,
            focus = {
                id = "category:" .. tostring(category.id),
                focus_type = "category",
                focus_column = "main",
                focus_content = true,
                focus_primary = true,
                list_group = "categories",
                list_index = index,
                list_count = count,
            },
        })
    end)
end

function Pages.settings(view, bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local gap = m.card_gap
    local row_h = math.max(m.touch_min, Theme.scale(58))
    local rows = {
        { text = _("Scan installed plugins"), callback = function() view.app:scan_installed_plugins() end },
        {
            text = _("Only show installable packages"),
            toggle = true,
            value = function() return view.app.state.filter_installable end,
            callback = function() view.app:toggle_filter_installable() end,
        },
        {
            text = _("Advanced"),
            toggle = true,
            value = function() return view.app.state.advanced end,
            callback = function()
                view.app:toggle_advanced()
                view:refresh()
            end,
        },
        {
            text = _("Font size"),
            value = function() return tostring(view.app.state.base_font_size) end,
            callback = function() view.app:prompt_base_font_size() end,
        },
        {
            text = _("Show README images"),
            toggle = true,
            value = function() return view.app.state.show_readme_images end,
            callback = function() view.app:toggle_readme_images() end,
        },
        {
            text = _("Always manually pick version"),
            toggle = true,
            value = function() return view.app.state.manual_version_picker end,
            callback = function()
                view.app:toggle_manual_version_picker()
                view:refresh()
            end,
        },
        {
            text = _("Show all builds"),
            toggle = true,
            value = function() return view.app.state.show_all_builds end,
            callback = function()
                view.app:toggle_show_all_builds()
                view:refresh()
            end,
        },
        {
            text = _("Beta updates"),
            toggle = true,
            value = function() return view.app.state.beta_updates end,
            callback = function()
                view.app:toggle_beta_updates()
                view:refresh()
            end,
        },
    }
    if view.app:kindle_scriptlets_available() then
        table.insert(rows, 3, {
            text = _("Show Kindle Scriptlets"),
            toggle = true,
            value = function() return view.app.state.show_kindle_scriptlets end,
            callback = function() view.app:toggle_kindle_scriptlets() end,
        })
    end
    if view.app.daemon:detect_platform() == "kindle" and view.app.daemon:kindle_homepage_install_supported() then
        table.insert(rows, 2, {
            text = _("Install to Kindle homepage"),
            callback = function() view.app:install_to_kindle_homepage() end,
        })
    end
    if not view.app.daemon:is_android() and not view.app.daemon:is_pocketbook() then
        table.insert(rows, 2, {
            text = _("Install command-line interface"),
            callback = function() view.app:install_cli() end,
        })
    end
    local list_y = y + Theme.scale(8)
    local list_h = h - Theme.scale(16)
    return Scroll.scrolled_list(view, bb, rows, x, list_y, w, list_h, scroll, row_h, gap, function(row, row_y, scrollable, index, count)
        local gutter = scrollable and Theme.scale(14) or 0
        local row_x = x + pad
        local row_w = w - pad * 2 - gutter
        P.box(bb, row_x, row_y, row_w, row_h)
        local value = row.value and row.value() or nil
        local checkbox = row.toggle
        local right = checkbox and nil or (value == nil and "›" or value)
        local toggle_w = Theme.scale(56)
        local toggle_h = Theme.scale(28)
        local right_size = checkbox and { w = toggle_w } or P.text_size(right, Theme.scale(96), "small", { bold = true })
        local text_w = row_w - pad * 2 - right_size.w - Theme.scale(12)
        P.vcenter_text(bb, row.text, row_x + pad, row_y, text_w, row_h, "small", { bold = true })
        local right_x = row_x + row_w - pad - right_size.w
        if checkbox then
            P.zen_toggle(bb, right_x, row_y + math.floor((row_h - toggle_h) / 2), toggle_w, toggle_h, value == true)
        else
            P.vcenter_text(bb, right, right_x, row_y, right_size.w, row_h, "small", { bold = true, color = Theme.ink })
        end
        P.hit(view, row_x, row_y, row_w, row_h, row.callback, "setting:" .. row.text)
        P.focus_control(view, bb, "setting:" .. row.text, row_x, row_y, row_w, row_h, row.callback, {
            focus_type = "setting",
            focus_column = "main",
            focus_content = true,
            focus_primary = true,
            list_group = "settings",
            list_index = index,
            list_count = count,
        })
    end)
end

function Pages.source_details(view, bb, x, y, w, h, scroll)
    local m = Theme.metrics()
    local pad = m.pad
    local cy = y + Theme.scale(4)
    local visible = view.app.state.visible_packages or {}
    local list_y = cy
    local list_h = h - (list_y - y) - Theme.scale(8)
    local card_h = package_card_height(list_h, m.card_gap)
    if #visible == 0 then
        P.text(bb, _("No packages found for this source."), x + pad, list_y, w - pad * 2, "default", { color = Theme.muted })
        Scroll.set_list_bounds(view, x, list_y, w, list_h, card_h + m.card_gap)
        return 0
    end
    return Scroll.scrolled_list(view, bb, visible, x, list_y, w, list_h, scroll, card_h, m.card_gap, function(pkg, row_y, scrollable, index, count)
        local gutter = scrollable and Theme.scale(14) or 0
        Cards.package(view, bb, pkg, x + pad, row_y, w - pad * 2 - gutter, {
            height = card_h,
            focus_group = "source",
            focus_index = index,
            focus_count = count,
        })
    end, true)
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
    local show_featured_at_top = pkg.featured_image
        and not Models.is_font_package(pkg)
        and not view.app.state.details_featured_expanded
        and (tonumber(scroll) or 0) <= 0
    view.package_details_featured_visible = show_featured_at_top
    if show_featured_at_top then
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
    local summary_h = Theme.scale(92)
    Cards.package(view, bb, pkg, inner_x, iy, inner_w, {
        height = summary_h,
        show_title = false,
        second_line = _("By ") .. I18n.dynamic_or(pkg.author, "?"),
        text_gap = Theme.scale(6),
        border = false,
        focus_group = "package_details",
        focus_index = 1,
        focus_count = 1,
    })
    local card_bottom = iy + summary_h
    local description_y = card_bottom + Theme.scale(18)
    local divider_y = card_bottom + math.floor((description_y - card_bottom) / 2)
    P.rect(bb, panel_x + Theme.scale(2), divider_y, panel_w - Theme.scale(4), Theme.scale(1), Theme.soft)
    iy = description_y
    local description = I18n.dynamic_or(pkg.description, _("No description available."))
    local is_font = Models.is_font_package(pkg)
    local description_heading = _("Description")
    local readme_blocks = {
        { kind = "heading", level = 2, text = description_heading, plain = true },
        { kind = "paragraph", text = description, plain = true },
    }
    if not is_font then
        local readme = tostring(pkg.readme or "")
        if readme == "" then
            readme = _("No README available.")
            if pkg.readme_error_code then
                readme = readme .. " " .. _("Error code: ") .. tostring(pkg.readme_error_code)
            end
        end
        table.insert(readme_blocks, { kind = "heading", level = 2, text = _("README"), plain = true })
        for _, block in ipairs(Markdown.parse(readme)) do
            table.insert(readme_blocks, block)
        end
    end
    if is_font and pkg.featured_image and pkg.featured_image ~= "" then
        table.insert(readme_blocks, {
            kind = "image",
            alt = I18n.dynamic_or(pkg.name, _("Font preview")),
            url = pkg.featured_image,
        })
    end
    local assets = Models.package_assets(pkg)
    local show_patch_tab = Models.is_patch_package(pkg) and #assets > 0
    local show_release_notes_tab = Models.has_release_notes(pkg, view.app.state.beta_updates)
    local details_tab = view.app.state.details_tab or "readme"
    if details_tab == "release_notes" and not show_release_notes_tab then
        details_tab = "readme"
    elseif details_tab == "patches" and not show_patch_tab then
        details_tab = "readme"
    elseif details_tab ~= "release_notes" and details_tab ~= "patches" then
        details_tab = "readme"
    end
    local tabs = {
        { id = "readme", label = _("README") },
    }
    if show_release_notes_tab then
        table.insert(tabs, { id = "release_notes", label = _("Release Notes") })
    end
    if show_patch_tab then
        table.insert(tabs, { id = "patches", label = _("Patches") })
    end
    if #tabs > 1 then
        local tab_h = Theme.scale(38)
        local gap = Theme.scale(8)
        local tab_w = math.floor((inner_w - gap * (#tabs - 1)) / #tabs)
        local function draw_tab(index, id, label, tx, tw)
            local selected = details_tab == id
            P.box(bb, tx, iy, tw, tab_h, {
                background = selected and Theme.ink or Theme.panel,
                border_color = Theme.border,
                radius = math.floor(tab_h / 2),
            })
            P.center_text_box(bb, label, tx, iy, tw, tab_h, "small", {
                color = selected and Theme.button_text or Theme.ink,
            })
            local callback = function()
                view.app:set_package_details_tab(id)
            end
            local focus_id = "details-tab:" .. id
            P.hit(view, tx, iy, tw, tab_h, callback, focus_id)
            P.focus_control(view, bb, focus_id, tx, iy, tw, tab_h, callback, {
                focus_type = "details_tab",
                focus_column = index,
                inverse = selected,
            })
        end
        local tab_x = inner_x
        for index, tab in ipairs(tabs) do
            local width = index == #tabs and inner_x + inner_w - tab_x or tab_w
            draw_tab(index, tab.id, tab.label, tab_x, width)
            tab_x = tab_x + width + gap
        end
        iy = iy + tab_h + Theme.scale(14)
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
        local max_scroll = Scroll.scrolled_list(view, bb, assets, inner_x, iy, list_w, content_h, scroll, row_h, gap, function(asset, row_y, _scrollable, index, count)
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
            local callback = function()
                view.app:confirm_package_asset_action(pkg, asset, function()
                    view.app:reload_current_page()
                end)
            end
            local focus_id = "patch:" .. tostring(asset.asset or "")
            P.hit(view, inner_x, row_y, row_w, row_h, callback, focus_id)
            P.focus_control(view, bb, focus_id, inner_x, row_y, row_w, row_h, callback, {
                focus_type = "patch",
                focus_column = "main",
                focus_content = true,
                focus_primary = true,
                list_group = "patches",
                list_index = index,
                list_count = count,
            })
        end)
        return max_scroll
    end
    local viewport_inset = Theme.scale(6)
    local paragraph_w = inner_w - Theme.scale(24)
    local readme_base_url = pkg.readme_base_url or Markdown.base_url(pkg.readme_url)
    local content_blocks = readme_blocks
    local content_link_base_url = Markdown.source_base_url(pkg.source)
    if content_link_base_url == "" then
        content_link_base_url = readme_base_url
    end
    local content_image_base_url = pkg.readme_image_base_url
    local content_image_refs = pkg.readme_image_refs
    if not content_image_base_url or content_image_base_url == "" then
        content_image_base_url = Markdown.public_image_base_url(pkg.source)
    end
    if content_image_base_url == "" then
        content_image_base_url = readme_base_url
    end
    if details_tab == "release_notes" then
        content_blocks = {}
        local release_tag = tostring(pkg.release_notes_tag or "")
        if release_tag ~= "" then
            table.insert(content_blocks, { kind = "heading", level = 2, text = _("Version: ") .. release_tag, plain = true })
        end
        local release_notes = tostring(pkg.release_notes or "")
        if release_notes == "" then
            local message = _("No release notes available.")
            if pkg.release_notes_error_code then
                message = message .. " " .. _("Error code: ") .. tostring(pkg.release_notes_error_code)
            end
            table.insert(content_blocks, { kind = "paragraph", text = message, plain = true })
        else
            for _, block in ipairs(Markdown.parse(release_notes)) do
                table.insert(content_blocks, block)
            end
        end
        content_link_base_url = tostring(pkg.release_notes_base_url or "")
        if content_link_base_url == "" then
            content_link_base_url = Markdown.source_base_url(pkg.source)
        end
        content_image_base_url = tostring(pkg.release_notes_image_base_url or "")
        if content_image_base_url == "" then
            content_image_base_url = Markdown.public_image_base_url(pkg.source)
        end
        if content_image_base_url == "" then
            content_image_base_url = content_link_base_url
        end
        content_image_refs = nil
    end
    local viewport_y = iy + viewport_inset
    local viewport_h = math.max(1, content_h - viewport_inset * 2)
    local max_scroll = MarkdownRenderer.render(view, bb, content_blocks, content_link_base_url, content_image_base_url, inner_x, viewport_y, paragraph_w, viewport_h, scroll, content_image_refs)
    Scroll.set_list_bounds(view, inner_x, viewport_y, inner_w, viewport_h, Theme.scale(96))
    P.focus_control(view, bb, "details-content", inner_x, viewport_y, inner_w, viewport_h, nil, {
        focus_type = "scroll_content",
        focus_content = true,
    })
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
