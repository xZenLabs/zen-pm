local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/ui/?.lua;" .. package.path

local shown_dialog
local checkbox
local restart_requested

package.preload["ui/widget/buttondialog"] = function() return {} end
package.preload["ui/widget/checkbutton"] = function()
    return {
        new = function(_, options)
            checkbox = options
            return options
        end,
    }
end
package.preload["ui/widget/confirmbox"] = function()
    return {
        new = function(_, options)
            function options:addWidget(widget)
                self.checkbox = widget
            end
            return options
        end,
    }
end
package.preload["ui/font"] = function() return {} end
package.preload["ui/geometry"] = function() return {} end
package.preload["ui/widget/horizontalgroup"] = function() return {} end
package.preload["ui/widget/horizontalspan"] = function() return {} end
package.preload["ui/widget/iconwidget"] = function() return {} end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["ui/widget/container/leftcontainer"] = function() return {} end
package.preload["ui/widget/textwidget"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return { show = function(_, dialog) shown_dialog = dialog end }
end
package.preload["logger"] = function() return { info = function() end } end
package.preload["device"] = function() return { screen = {} } end
package.preload["models"] = function() return {} end
package.preload["ui/inline_icon_map"] = function() return {} end
package.preload["ui/images"] = function() return {} end
package.preload["gettext"] = function() return function(value) return value end end

local Modals = require("ui/modals")
Modals.restart_koreader("Restart?", function(reopen_after_restart)
    restart_requested = reopen_after_restart
end)

assert(shown_dialog)
assert(checkbox == shown_dialog.checkbox)
assert(checkbox.text == "Open ZenPM after restart")
assert(checkbox.checked == false)
shown_dialog.ok_callback()
assert(restart_requested == false)
checkbox.checked = true
shown_dialog.ok_callback()
assert(restart_requested == true)

print("modals tests passed")
