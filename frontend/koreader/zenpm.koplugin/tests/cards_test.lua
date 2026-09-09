local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/ui/?.lua;" .. package.path

local painted_text = {}
local painted_text_y = {}
local painted_images = {}
local painted_boxes = {}
local painted_rects = {}
local hit_callbacks = {}

package.preload["zenpm_constants"] = function() return { PLUGIN_DIR = root } end
package.preload["i18n"] = function()
    return { dynamic_or = function(value, fallback) return value or fallback end }
end
package.preload["models"] = function()
    return {
        is_patch_package = function() return false end,
        package_action_label = function() return "Update" end,
        package_display_name = function(pkg, fallback) return pkg.name or fallback end,
        package_verified = function() return true end,
        is_image_asset_package = function(pkg)
            return pkg.category == "wallpapers" or pkg.category == "screensavers"
        end,
        repo_display_name = function(value) return value end,
    }
end
package.preload["ui/images"] = function() return { asset = function(name) return name end } end
package.preload["ui/primitives"] = function()
    return {
        box = function(_, x, y, w, h, opts)
            table.insert(painted_boxes, { x = x, y = y, w = w, h = h, opts = opts })
        end,
        rect = function(_, x, y, w, h)
            table.insert(painted_rects, { x = x, y = y, w = w, h = h })
        end,
        text = function(_, text, _, y)
            table.insert(painted_text, text)
            painted_text_y[text] = y
        end,
        text_size = function(text) return { w = #text, h = 1 } end,
        image = function(_, file, _, _, w, h, opts)
            painted_images[file] = { w = w, h = h, is_icon = opts and opts.is_icon }
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
        metrics = function() return { card_h = 80, category_h = 84, action_w = 40, action_h = 20 } end,
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
}, 0, 0, 300, { height = 60, top_divider = true })
assert(painted_boxes[1].opts.border == false and painted_boxes[1].opts.radius == false)
assert(#painted_rects == 2 and painted_rects[1].y == 0 and painted_rects[2].y == 59)
assert(painted_text_y["2 packages"] == painted_text_y.Wallpapers + 1)

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
print("cards tests passed")
