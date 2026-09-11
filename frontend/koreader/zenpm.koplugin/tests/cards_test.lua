local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/ui/?.lua;" .. package.path

local painted_text = {}
local painted_text_x = {}
local painted_text_y = {}
local painted_images = {}
local painted_boxes = {}
local painted_rects = {}
local hit_callbacks = {}

package.preload["zenpm_constants"] = function()
    return { PLUGIN_DIR = root, REPO_READERBACKDROP_NAME = "ReaderBackdrop" }
end
package.preload["i18n"] = function()
    return { dynamic_or = function(value, fallback) return value or fallback end }
end
package.preload["models"] = function()
    return {
        is_patch_package = function() return false end,
        package_action_label = function() return "Update" end,
        package_display_name = function(pkg, fallback) return pkg.name or fallback end,
        package_verified = function() return true end,
        package_assets = function() return {} end,
        has_release_notes = function() return false end,
        is_font_package = function() return false end,
        is_image_asset_package = function(pkg)
            return pkg.category == "wallpapers" or pkg.category == "screensavers"
        end,
        repo_display_name = function(value) return value end,
    }
end
package.preload["ui/images"] = function()
    return {
        asset = function(name) return name end,
        package_icon = function(pkg) return pkg.icon_url end,
        is_transparent = function(value)
            if value == "/packages/readerbackdrop-moonlight/preview" then return true end
            if value == "/packages/readerbackdrop-opaque/preview" then return false end
        end,
    }
end
package.preload["ui/primitives"] = function()
    return {
        box = function(_, x, y, w, h, opts)
            table.insert(painted_boxes, { x = x, y = y, w = w, h = h, opts = opts })
        end,
        rect = function(_, x, y, w, h)
            table.insert(painted_rects, { x = x, y = y, w = w, h = h })
        end,
        text = function(_, text, x, y)
            table.insert(painted_text, text)
            painted_text_x[text] = x
            painted_text_y[text] = y
        end,
        text_size = function(text) return { w = #text, h = 1 } end,
        vcenter_text = function(_, text) return { w = #text, h = 1 } end,
        image = function(_, file, x, y, w, h, opts)
            painted_images[file] = { x = x, y = y, w = w, h = h, is_icon = opts and opts.is_icon }
            return true
        end,
        image_zoomed = function(_, file, _, _, w, h, zoom, opts)
            painted_images[file] = { w = w, h = h, zoom = zoom, is_icon = opts and opts.is_icon }
            return true
        end,
        center_text_box = function() end,
        dim = function() end,
        hit = function(_, _, _, _, _, callback, id) hit_callbacks[id] = callback end,
        focus_control = function() end,
        focus_target = function() return false end,
        focus_outline = function() end,
    }
end
package.preload["ui/theme"] = function()
    return {
        panel = 0,
        border = 0,
        button_bg = 0,
        button_text = 0,
        ink = 0,
        muted = 0,
        soft = 0,
        metrics = function()
            return { card_h = 80, category_h = 84, action_w = 40, action_h = 20, pad = 8, card_gap = 4, touch_min = 20, titlebar_h = 58, toolbar_h = 58 }
        end,
        scale = function(value) return value end,
        font_scale = function(value) return value end,
    }
end
package.preload["zenpm_util"] = function()
    return {
        trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
        fixUtf8 = function(value) return value end,
    }
end
package.preload["gettext"] = function() return function(value) return value end end

local Cards = require("ui/cards")
Cards.package({
    app = {
        state = {
            active_tab = "installed",
            queue = {
                { action = "update", self_update = true, key = "zenpm\0" },
            },
        },
        package_disabled = function() return false end,
        package_icon_file = function() return "zenpm.svg" end,
        perform_package_action = function() end,
        show_package_details = function() end,
    },
}, {}, {
    id = "zenpm-koreader",
    name = "ZenPM",
    plugin_module = "zenpm",
    installed = true,
    update_available = true,
    version = "1.0.0",
    repo = "ZenLabs",
}, 0, 0, 300, { compact = true })

assert(painted_text[#painted_text] == "Queued")

painted_text = {}
Cards.package({
    app = {
        state = { active_tab = "installed", queue = {} },
        package_disabled = function() return false end,
        package_icon_file = function() return "wallpaper.jpg", false, "wallpaper.jpg", "package" end,
        perform_package_action = function() end,
        show_package_details = function() end,
    },
}, {}, {
    id = "wallpaper",
    name = "Wallpaper",
    category = "wallpapers",
    author = "Zen Labs",
    version = "1.0.0",
    repo = "ZenLabs",
}, 0, 0, 300, { height = 92, show_title = false, second_line = "By Zen Labs" })

for _, text in ipairs(painted_text) do
    assert(text ~= "Wallpaper")
end
assert(painted_text[1] == "By Zen Labs")
assert(painted_images["wallpaper.jpg"].w == 72 and painted_images["wallpaper.jpg"].h == 72)
assert(painted_images["wallpaper.jpg"].zoom == 1.1)
assert(painted_images["wallpaper.jpg"].is_icon == false)

Cards.package({
    app = {
        state = { active_tab = "installed", queue = {} },
        package_disabled = function() return false end,
        package_icon_file = function() return "wallpaper.svg", true, "wallpaper.svg", "fallback" end,
        show_package_details = function() end,
    },
}, {}, {
    id = "wallpaper-placeholder",
    name = "Wallpaper placeholder",
    category = "wallpapers",
}, 0, 0, 300, { height = 92 })
assert(painted_images["wallpaper.svg"].w == 64 and painted_images["wallpaper.svg"].h == 64)

painted_boxes = {}
painted_rects = {}
painted_text_y = {}
Cards.category({
    app = { show_category_details = function() end },
}, {}, {
    id = "wallpapers",
    label = "Wallpapers",
    icon = "wallpaper.svg",
    count = 2,
    count_label = "2085",
}, 0, 0, 300, { height = 60, top_divider = true })
assert(painted_boxes[1].opts.border == false and painted_boxes[1].opts.radius == false)
assert(#painted_rects == 2 and painted_rects[1].y == 0 and painted_rects[2].y == 59)
assert(painted_text_y["2085 packages"] == painted_text_y.Wallpapers + 1)

painted_text = {}
Cards.category({
    app = { show_category_details = function() end },
}, {}, {
    id = "wallpapers",
    label = "Wallpapers",
    count = 0,
    count_label = "2085",
}, 0, 0, 300)
assert(painted_text[1] == "Wallpapers" and painted_text[2] == "")
assert(hit_callbacks["category:wallpapers"])

painted_text = {}
local opened_update_details
Cards.package({
    app = {
        state = { page = "installed", active_tab = "installed", queue = {} },
        package_disabled = function() return false end,
        package_icon_file = function() return "reader.svg" end,
        perform_package_action = function() end,
        show_package_details = function(_, ...)
            opened_update_details = { ... }
        end,
    },
}, {}, {
    id = "reader",
    name = "Reader",
    installed = true,
    update_available = true,
    version = "1.0.0",
    repo = "ZenLabs",
}, 0, 0, 300, { meta_suffix = "Yesterday" })

hit_callbacks["package:reader:"]()
assert(opened_update_details[1] == "reader")
assert(opened_update_details[2] == "installed")
assert(opened_update_details[3] == false)
assert(opened_update_details[4] == "release_notes")

local found_update_meta = false
for _, text in ipairs(painted_text) do
    if text == "v1.0.0 • Yesterday" then found_update_meta = true end
    assert(text ~= "v1.0.0 • ZenLabs")
end
assert(found_update_meta)

for _, page in ipairs({ "search", "installed", "category_details" }) do
    for _, status in ipairs({ "update", "ignored", "current", "uninstalled" }) do
        painted_text = {}
        Cards.package({
            app = {
                state = { page = page, active_tab = page, queue = {} },
                package_disabled = function() return false end,
                package_icon_file = function() return "reader.svg" end,
                show_package_details = function(_, ...)
                    opened_update_details = { ... }
                end,
            },
        }, {}, {
            id = "reader",
            name = "Reader",
            version = "1.0.0",
            repo = "ZenLabs",
            installed = status ~= "uninstalled",
            update_available = status == "update" or status == "ignored",
            update_ignored = status == "ignored",
        }, 0, 0, 300, { meta_suffix = "" })
        hit_callbacks["package:reader:"]()
        local expected_tab = page ~= "category_details" and status == "update" and "release_notes" or nil
        assert(opened_update_details[4] == expected_tab)
        assert(table.concat(painted_text, "\n"):find("v1.0.0 • ZenLabs", 1, true))
    end
end

painted_text = {}
painted_images = {}
local readerbackdrop_view = {
    app = {
        state = { active_tab = "search", queue = {} },
        package_disabled = function() return false end,
        perform_package_action = function() end,
        show_package_details = function() end,
    },
}
local readerbackdrop_package = {
    id = "readerbackdrop-moonlight",
    name = "Moonlight",
    version = "9.9.9",
    repo = "ReaderBackdrop",
    category = "wallpapers",
    platforms = { "koreader" },
    tags = { "illustration" },
    icon_url = "/packages/readerbackdrop-moonlight/preview",
    stars = "42",
}
Cards.package(readerbackdrop_view, {}, readerbackdrop_package, 0, 0, 300, { compact = true })
assert(table.concat(painted_text, "\n"):find("ReaderBackdrop • Transparent", 1, true))
assert(not table.concat(painted_text, "\n"):find("v9.9.9", 1, true))
assert(painted_images["downloads.svg"] and not painted_images["star.filled.svg"])
assert(not painted_images["unverified.svg"] and not painted_images["verified.svg"])
painted_text = {}
painted_images = {}
readerbackdrop_package.installed = true
readerbackdrop_view.app.state.active_tab = "installed"
Cards.package(readerbackdrop_view, {}, readerbackdrop_package, 0, 0, 300, { compact = true })
assert(painted_images["downloads.svg"] and painted_images["checkmark.svg"])
assert(painted_text_x["42"] < painted_images["downloads.svg"].x)
assert(painted_images["downloads.svg"].x < painted_images["checkmark.svg"].x)
readerbackdrop_package.installed = nil
readerbackdrop_view.app.state.active_tab = "search"
painted_text = {}
readerbackdrop_package.icon_url = "/packages/readerbackdrop-opaque/preview"
Cards.package(readerbackdrop_view, {}, readerbackdrop_package, 0, 0, 300, { compact = true })
assert(table.concat(painted_text, "\n"):find("ReaderBackdrop • Opaque", 1, true))
painted_text = {}
readerbackdrop_package.icon_url = "/packages/readerbackdrop-unknown/preview"
Cards.package(readerbackdrop_view, {}, readerbackdrop_package, 0, 0, 300, { compact = true })
assert(table.concat(painted_text, "\n"):find("ReaderBackdrop", 1, true))
assert(not table.concat(painted_text, "\n"):find("Transparent", 1, true))
assert(not table.concat(painted_text, "\n"):find("Opaque", 1, true))

painted_images = {}
Cards.source({
    app = {
        repo_icon_file = function() return "readerbackdrop.svg" end,
        show_source_details = function() end,
    },
}, {}, { name = "ReaderBackdrop", url = "https://www.readerbackdrop.com", default = true }, 0, 0, 300, { height = 100 })
assert(not painted_images["unverified.svg"] and not painted_images["verified.svg"])

package.preload["ui/font"] = function() return {} end
package.preload["ui/inline_icon_map"] = function() return { icon = function() return "" end } end
package.preload["ui/markdown"] = function()
    return {
        base_url = function() return "" end,
        source_base_url = function() return "" end,
        public_image_base_url = function() return "" end,
    }
end
local rendered_detail_blocks
package.preload["ui/markdown_renderer"] = function()
    return { render = function(_, _, blocks) rendered_detail_blocks = blocks return 0 end }
end
package.preload["ui/scroll"] = function()
    return {
        set_list_bounds = function() end,
        scrolled_list = function(_, _, entries, _, y, _, _, _, row_h, gap, draw)
            for index, entry in ipairs(entries) do
                draw(entry, y + (index - 1) * (row_h + gap), false, index, #entries)
            end
            return 0
        end,
    }
end
local Pages = require("ui/pages")
painted_text = {}
local load_more_calls = 0
local rendered_screensavers = 0
local screensavers = {}
for index = 1, 50 do
    table.insert(screensavers, {
        id = "readerbackdrop-" .. tostring(index),
        name = "Screensaver " .. tostring(index),
        repo = "ReaderBackdrop",
        category = "wallpapers",
    })
end
Pages.packages_page({
    app = {
        state = {
            page = "category_details",
            current_category = { id = "wallpapers" },
            readerbackdrop = { page = 1, total_pages = 44 },
        },
        package_disabled = function() return false end,
        package_icon_file = function()
            rendered_screensavers = rendered_screensavers + 1
            return "screensavers.svg", true
        end,
        show_package_details = function() end,
        load_more_readerbackdrop = function() load_more_calls = load_more_calls + 1 end,
    },
}, {}, 0, 0, 300, 300, 0, "Screensavers", "category", screensavers, {}, "")
assert(table.concat(painted_text, "\n"):find("Load more wallpapers", 1, true))
assert(table.concat(painted_text, "\n"):find("24 of 10 loaded", 1, true))
assert(rendered_screensavers == 24)
hit_callbacks["readerbackdrop-load-more"]()
assert(load_more_calls == 1)

painted_text = {}
Pages.packages_page({
    app = {
        state = { page = "installed", active_tab = "installed", queue = {} },
        package_disabled = function() return false end,
        package_icon_file = function() return "image.svg", true end,
        show_package_details = function() end,
    },
}, {}, 0, 0, 300, 300, 0, "Installed", "installed", {
    { id = "clouds", name = "Clouds", repo = "ReaderBackdrop", category = "wallpapers" },
    { id = "books", name = "Books", repo = "ReaderBackdrop", category = "screensavers" },
    { id = "reader", name = "Reader", repo = "ZenLabs", category = "applications" },
}, {}, "")
local installed_image_text = table.concat(painted_text, "\n")
assert(installed_image_text:find("Wallpaper", 1, true))
assert(installed_image_text:find("Screensaver", 1, true))
assert(not installed_image_text:find("ReaderBackdrop", 1, true))
assert(installed_image_text:find("ZenLabs", 1, true))

local screensaver_details_view = {
    app = {
        state = {
            current_package = {
                id = "readerbackdrop-empty",
                name = "Empty description",
                category = "screensavers",
                description = "",
                icon_url = "/packages/readerbackdrop-empty/preview",
            },
            queue = {},
            details_tab = "readme",
        },
        package_disabled = function() return false end,
        package_icon_file = function() return "screensavers.svg", true end,
        show_package_details = function() end,
    },
}
Pages.package_details(screensaver_details_view, {}, 0, 0, 300, 600, 0)
assert(#rendered_detail_blocks == 1 and rendered_detail_blocks[1].kind == "image")

screensaver_details_view.app.state.show_readme_images = false
Pages.package_details(screensaver_details_view, {}, 0, 0, 300, 600, 0)
assert(#rendered_detail_blocks == 0)
screensaver_details_view.app.state.current_package.category = "wallpapers"
Pages.package_details(screensaver_details_view, {}, 0, 0, 300, 600, 0)
assert(#rendered_detail_blocks == 0)

package.preload["ui/geometry"] = function() return { new = function(_, value) return value end } end
local Header = require("ui/header")
assert(Header.page_title({ app = { state = {
    page = "category_details",
    current_category = { id = "screensavers", label = "Screensavers" },
    readerbackdrop = { enabled = true, total = 2083 },
} } }) == "Screensavers (2083)")
assert(Header.page_title({ app = { state = {
    page = "category_details",
    current_category = { id = "wallpapers", label = "Wallpapers" },
    readerbackdrop = { enabled = true, total = 42 },
} } }) == "Wallpapers (42)")
assert(Header.page_title({ app = { state = {
    page = "category_details",
    current_category = { id = "wallpapers", label = "Wallpapers" },
    readerbackdrop = { enabled = true },
} } }) == "Wallpapers (10)")
assert(Header.page_title({ app = { state = {
    page = "source_details",
    current_repo = { name = "ReaderBackdrop" },
    readerbackdrop = {},
} } }) == "ReaderBackdrop (2085)")

local queue_closed = false
Header.draw({ app = {
    state = { page = "queue", queue_running = false },
    queue_count = function() return 0 end,
    close_queue = function() queue_closed = true end,
    show_actions = function() end,
} }, {}, 0, 0, 300)
assert(type(hit_callbacks["back-title"]) == "function")
hit_callbacks["back-title"]()
assert(queue_closed)

painted_text = {}
Pages.queue({
    app = {
        state = { queue = {
            { key = "screensaver", name = "Moonlight", action = "install", pkg = { repo = "ReaderBackdrop" } },
            { key = "old-screensaver", name = "Sunlight", action = "uninstall", pkg = { repo = "ReaderBackdrop" } },
            { key = "plugin", name = "Reader", action = "install", pkg = { version = "1.2.3" } },
        } },
        package_icon_file = function() return "package.svg" end,
        show_queue_entry_modify = function() end,
    },
}, {}, 0, 0, 300, 300, 0)
assert(painted_text[2] == "Install screensaver")
assert(painted_text[4] == "Uninstall screensaver")
assert(painted_text[6] == "Install v1.2.3")
print("cards tests passed")
