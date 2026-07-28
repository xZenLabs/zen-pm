local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/ui/?.lua;" .. package.path

local has_keys = false
local has_keyboard = false
local has_dpad = false
local scheduled
package.preload["device"] = function()
    return {
        hasKeys = function() return has_keys end,
        hasKeyboard = function() return has_keyboard end,
        hasDPad = function() return has_dpad end,
        screen = { getWidth = function() return 1 end, getHeight = function() return 1 end },
    }
end
package.preload["device/input"] = function() return { group = {} } end
package.preload["ui/geometry"] = function() return { new = function(_, value) return value end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, value) return value end } end
package.preload["ui/widget/container/inputcontainer"] = function()
    return {
        extend = function(_, value) return value end,
        onKeyPress = function() return false end,
        onKeyRepeat = function() return false end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, _, callback) scheduled = callback end,
        unschedule = function(_, callback)
            if scheduled == callback then scheduled = nil end
        end,
    }
end
package.preload["ui/header"] = function() return {} end
package.preload["i18n"] = function() return {} end
package.preload["ui/nav"] = function() return {} end
package.preload["ui/primitives"] = function() return {} end
package.preload["ui/pages"] = function() return {} end
package.preload["ui/scroll"] = function() return {} end
package.preload["ui/theme"] = function() return {} end
package.preload["gettext"] = function() return function(value) return value end end

local AppView = require("ui/app_view")
local closed = 0
local view = { app = { close = function() closed = closed + 1 end } }

has_keys = true
has_dpad = false
local key_view = setmetatable({}, { __index = AppView })
AppView.init(key_view)
assert(key_view.focus_enabled == true)
assert(key_view.key_events.ZenPMFocusUp)
assert(key_view.key_events.ZenPMFocusConfirm)
has_keys = false
has_dpad = false

has_keyboard = true
local keyboard_view = setmetatable({}, { __index = AppView })
AppView.init(keyboard_view)
assert(keyboard_view.focus_enabled == true)
assert(keyboard_view.key_events.ZenPMFocusDown)
has_keyboard = false

assert(AppView.onClose(view) == true)
assert(closed == 1)

local refreshes = 0
local details_view = {
    app = {
        state = {
            details_featured_expanded = false,
            scroll = { ["package:demo:readme"] = 0 },
        },
        scroll_key = function() return "package:demo:readme" end,
    },
    package_details_featured_visible = true,
    scroll_step = 10,
    scroll_page_step = 40,
    max_scroll = 100,
    refresh = function() refreshes = refreshes + 1 end,
}

assert(AppView._scroll_list(details_view, 1) == true)
assert(details_view.app.state.details_featured_expanded)
assert(details_view.app.state.scroll["package:demo:readme"] == 0)
assert(refreshes == 1)
assert(AppView._scroll_list(details_view, 1) == true)
assert(details_view.app.state.scroll["package:demo:readme"] == 40)

local focus_refreshes = 0
local focused = {}
local focus_view = {
    app = {
        state = { active_tab = "search", scroll = { packages = 0 } },
        scroll_key = function() return "packages" end,
    },
    focus_targets = {
        { id = "package:one", x = 0, y = 10, w = 80, h = 10, focus_type = "package", focus_column = "main", focus_content = true, list_group = "search", list_index = 1, list_count = 2 },
        { id = "package-action:one", x = 80, y = 10, w = 20, h = 10, focus_type = "package_action", focus_column = "action", focus_content = true, list_group = "search", list_index = 1, list_count = 2, callback = function() focused.action = true end },
        { id = "package:two", x = 0, y = 30, w = 80, h = 10, focus_type = "package", focus_column = "main", focus_content = true, list_group = "search", list_index = 2, list_count = 2 },
        { id = "package-action:two", x = 80, y = 30, w = 20, h = 10, focus_type = "package_action", focus_column = "action", focus_content = true, list_group = "search", list_index = 2, list_count = 2 },
        { id = "tab:search", x = 0, y = 50, w = 40, h = 10, focus_type = "tab", callback = function() focused.tab = true end },
        { id = "tab:installed", x = 40, y = 50, w = 40, h = 10, focus_type = "tab" },
    },
    refresh = function() focus_refreshes = focus_refreshes + 1 end,
}
setmetatable(focus_view, { __index = AppView })

assert(AppView.onZenPMFocusMove(focus_view, { 0, 1 }) == true)
assert(focus_view.focus_key == "package:one")
assert(AppView.onZenPMFocusMove(focus_view, { 1, 0 }) == true)
assert(focus_view.focus_key == "package-action:one")
assert(AppView.onZenPMFocusConfirm(focus_view) == true)
assert(focused.action == true)
assert(AppView.onZenPMFocusMove(focus_view, { 0, 1 }) == true)
assert(focus_view.focus_key == "package-action:two")
assert(AppView.onZenPMFocusMove(focus_view, { 0, 1 }) == true)
assert(focus_view.focus_key == "tab:search")
assert(AppView.onZenPMFocusMove(focus_view, { 1, 0 }) == true)
assert(focus_view.focus_key == "tab:installed")
assert(AppView.onZenPMFocusMove(focus_view, { -1, 0 }) == true)
assert(focus_view.focus_key == "tab:search")
assert(AppView.onZenPMFocusConfirm(focus_view) == true)
assert(focused.tab == true)
assert(focus_refreshes >= 6)

local scrolling_focus = {
    app = {
        state = { active_tab = "search", scroll = { packages = 0 } },
        scroll_key = function() return "packages" end,
    },
    focus_key = "package:one",
    focus_targets = {
        { id = "package:one", x = 0, y = 0, w = 1, h = 1, focus_type = "package", focus_column = "main", focus_content = true, list_group = "search", list_index = 1, list_count = 2 },
    },
    scroll_step = 10,
    max_scroll = 10,
    refresh = function() end,
}
setmetatable(scrolling_focus, { __index = AppView })
assert(AppView.onZenPMFocusMove(scrolling_focus, { 0, 1 }) == true)
assert(scrolling_focus.app.state.scroll.packages == 10)
assert(scrolling_focus.focus_pending.list_index == 2)

local detail_refreshes = 0
local details_focus = {
    app = {
        state = { active_tab = "search", details_tab = "readme", scroll = { details = 0 } },
        scroll_key = function() return "details" end,
    },
    focus_key = "package:details",
    focus_targets = {
        { id = "back", x = 0, y = 0, w = 10, h = 10, focus_type = "control" },
        { id = "package:details", x = 0, y = 10, w = 100, h = 10, focus_type = "package", focus_column = "main", focus_content = true, list_group = "package_details", list_index = 1, list_count = 1 },
        { id = "details-tab:readme", x = 0, y = 20, w = 40, h = 10, focus_type = "details_tab" },
        { id = "details-tab:release_notes", x = 50, y = 20, w = 40, h = 10, focus_type = "details_tab" },
        { id = "details-content", x = 0, y = 40, w = 100, h = 40, focus_type = "scroll_content", focus_content = true },
    },
    scroll_step = 10,
    scroll_page_step = 40,
    max_scroll = 10,
    refresh = function() detail_refreshes = detail_refreshes + 1 end,
}
setmetatable(details_focus, { __index = AppView })
details_focus.focus_targets[4].callback = function()
    details_focus.app.state.details_tab = "release_notes"
end
assert(AppView.onZenPMFocusMove(details_focus, { 0, 1 }) == true)
assert(details_focus.focus_key == "details-tab:readme")
assert(AppView.onZenPMFocusMove(details_focus, { 1, 0 }) == true)
assert(details_focus.focus_key == "details-tab:release_notes")
assert(AppView.onZenPMFocusConfirm(details_focus) == true)
assert(AppView.onZenPMFocusMove(details_focus, { 0, 1 }) == true)
assert(details_focus.focus_key == "details-content")
assert(AppView.onZenPMFocusMove(details_focus, { 0, 1 }) == true)
assert(details_focus.app.state.scroll.details == 10)
assert(AppView.onZenPMFocusMove(details_focus, { 0, -1 }) == true)
assert(details_focus.app.state.scroll.details == 0)
details_focus.max_scroll = 100
assert(AppView.onZenPMScroll(details_focus, 1) == true)
assert(details_focus.app.state.scroll.details == 40)
details_focus.app.state.scroll.details = 0
assert(AppView.onZenPMFocusMove(details_focus, { 0, -1 }) == true)
assert(details_focus.focus_key == "details-tab:release_notes")
assert(detail_refreshes >= 5)

local controls = {}
local controls_focus = {
    app = { state = { active_tab = "search", scroll = {} } },
    focus_key = "back",
    focus_targets = {
        { id = "back", x = 0, y = 0, w = 20, h = 10, focus_type = "control" },
        { id = "actions", x = 80, y = 0, w = 20, h = 10, focus_type = "control", callback = function() controls.actions = true end },
        { id = "sort:search", x = 0, y = 20, w = 30, h = 10, focus_type = "control", callback = function() controls.sort = true end },
    },
    refresh = function() end,
}
setmetatable(controls_focus, { __index = AppView })
assert(AppView.onZenPMFocusMove(controls_focus, { 1, 0 }) == true)
assert(controls_focus.focus_key == "actions")
assert(AppView.onZenPMFocusConfirm(controls_focus) == true)
assert(controls.actions == true)
assert(AppView.onZenPMFocusMove(controls_focus, { 0, 1 }) == true)
assert(controls_focus.focus_key == "sort:search")
assert(AppView.onZenPMFocusConfirm(controls_focus) == true)
assert(controls.sort == true)

local queue_controls = {}
local queue_focus = {
    app = {
        state = { active_tab = "search", scroll = { queue = 0 } },
        scroll_key = function() return "queue" end,
    },
    focus_key = "queue-entry:one",
    focus_targets = {
        { id = "back", x = 0, y = 0, w = 20, h = 10, focus_type = "control", callback = function() queue_controls.back = true end },
        { id = "clear-queue", x = 0, y = 20, w = 40, h = 10, focus_type = "control", callback = function() queue_controls.clear = true end },
        { id = "confirm-queue", x = 60, y = 20, w = 40, h = 10, focus_type = "control", callback = function() queue_controls.confirm = true end },
        { id = "queue-entry:one", x = 0, y = 40, w = 100, h = 10, focus_type = "queue_entry", focus_column = "main", focus_content = true, list_group = "queue", list_index = 1, list_count = 1 },
    },
    refresh = function() end,
}
setmetatable(queue_focus, { __index = AppView })
assert(AppView.onZenPMFocusMove(queue_focus, { 0, -1 }) == true)
assert(queue_focus.focus_key == "clear-queue")
assert(AppView.onZenPMFocusConfirm(queue_focus) == true)
assert(queue_controls.clear == true)
assert(AppView.onZenPMFocusMove(queue_focus, { 1, 0 }) == true)
assert(queue_focus.focus_key == "confirm-queue")
assert(AppView.onZenPMFocusConfirm(queue_focus) == true)
assert(queue_controls.confirm == true)
assert(AppView.onZenPMFocusMove(queue_focus, { -1, 0 }) == true)
assert(queue_focus.focus_key == "clear-queue")
assert(AppView.onZenPMFocusMove(queue_focus, { 0, -1 }) == true)
assert(queue_focus.focus_key == "back")
assert(AppView.onZenPMFocusConfirm(queue_focus) == true)
assert(queue_controls.back == true)

local queue_banner = {}
local banner_focus = {
    app = {
        state = { active_tab = "search", scroll = { packages = 0 } },
        scroll_key = function() return "packages" end,
    },
    focus_key = "package:one",
    focus_targets = {
        { id = "package:one", x = 0, y = 0, w = 100, h = 10, focus_type = "package", focus_column = "main", focus_content = true, list_group = "search", list_index = 1, list_count = 1 },
        { id = "queue-banner", x = 0, y = 20, w = 100, h = 10, focus_type = "queue_banner", callback = function() queue_banner.opened = true end },
        { id = "tab:search", x = 0, y = 40, w = 100, h = 10, focus_type = "tab" },
    },
    refresh = function() end,
}
setmetatable(banner_focus, { __index = AppView })
assert(AppView.onZenPMFocusMove(banner_focus, { 0, 1 }) == true)
assert(banner_focus.focus_key == "queue-banner")
assert(AppView.onZenPMFocusConfirm(banner_focus) == true)
assert(queue_banner.opened == true)
assert(AppView.onZenPMFocusMove(banner_focus, { 0, 1 }) == true)
assert(banner_focus.focus_key == "tab:search")

local hold_focus = {
    focus_enabled = true,
    app = { state = { active_tab = "search" } },
    focus_key = "package:one",
    focus_targets = {
        { id = "package:one", x = 0, y = 0, w = 100, h = 10, focus_type = "package", focus_content = true },
        { id = "queue-banner", x = 0, y = 20, w = 100, h = 10, focus_type = "queue_banner" },
        { id = "tab:search", x = 0, y = 40, w = 100, h = 10, focus_type = "tab" },
    },
    refresh = function() end,
}
setmetatable(hold_focus, { __index = AppView })
local function key(name)
    return {
        match = function(_, sequence)
            assert(type(sequence) == "table")
            return sequence[1] == name
        end,
    }
end
assert(AppView.onKeyPress(hold_focus, key("Down")) == false)
assert(scheduled)
assert(AppView.onKeyRepeat(hold_focus, key("Down")) == true)
AppView.onKeyRelease(hold_focus, key("Down"))
assert(scheduled == nil)
assert(AppView.onKeyPress(hold_focus, "Down") == false)
scheduled()
assert(hold_focus.focus_key == "tab:search")
assert(AppView.onZenPMFocusMove(hold_focus, { 0, -1 }) == true)
assert(hold_focus.focus_key == "queue-banner")
assert(AppView.onZenPMFocusMove(hold_focus, { 0, -1 }) == true)
assert(hold_focus.focus_key == "package:one")

print("app view tests passed")
