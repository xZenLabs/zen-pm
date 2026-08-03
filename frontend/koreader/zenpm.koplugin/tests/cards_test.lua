local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/ui/?.lua;" .. package.path

local painted_text = {}

package.preload["constants"] = function() return { PLUGIN_DIR = root } end
package.preload["i18n"] = function()
    return { dynamic_or = function(value, fallback) return value or fallback end }
end
package.preload["models"] = function()
    return {
        is_patch_package = function() return false end,
        package_action_label = function() return "Update" end,
        package_display_name = function(pkg, fallback) return pkg.name or fallback end,
        package_verified = function() return true end,
        repo_display_name = function(value) return value end,
    }
end
package.preload["ui/images"] = function() return { asset = function(name) return name end } end
package.preload["ui/primitives"] = function()
    return {
        box = function() end,
        text = function(_, text) table.insert(painted_text, text) end,
        text_size = function(text) return { w = #text, h = 1 } end,
        image = function() return true end,
        image_zoomed = function() return true end,
        center_text_box = function() end,
        dim = function() end,
        hit = function() end,
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
        metrics = function() return { card_h = 80, action_w = 40, action_h = 20 } end,
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
        package_icon_file = function() return "zenpm.svg" end,
        perform_package_action = function() end,
        show_package_details = function() end,
    },
}, {}, {
    id = "zenpm-koreader",
    name = "ZenPM",
    author = "Zen Labs",
    version = "1.0.0",
    repo = "ZenLabs",
}, 0, 0, 300, { height = 92, show_title = false, second_line = "By Zen Labs" })

for _, text in ipairs(painted_text) do
    assert(text ~= "ZenPM")
end
assert(painted_text[1] == "By Zen Labs")

painted_text = {}
Cards.package({
    app = {
        state = { active_tab = "changes", queue = {} },
        package_disabled = function() return false end,
        package_icon_file = function() return "reader.svg" end,
        perform_package_action = function() end,
        show_package_details = function() end,
    },
}, {}, {
    id = "reader",
    name = "Reader",
    version = "1.0.0",
    repo = "ZenLabs",
}, 0, 0, 300, { meta_suffix = "Yesterday" })

local found_changes_meta = false
for _, text in ipairs(painted_text) do
    if text == "v1.0.0 • Yesterday" then found_changes_meta = true end
    assert(text ~= "v1.0.0 • ZenLabs")
end
assert(found_changes_meta)
print("cards tests passed")
