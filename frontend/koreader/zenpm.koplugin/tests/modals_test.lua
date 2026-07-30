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
package.preload["ui/widget/iconwidget"] = function()
    return {
        new = function(_, options)
            return options
        end,
    }
end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/inputdialog"] = function()
    return {
        new = function(_, options)
            options.input_text = options.input
            function options:onShowKeyboard() end
            function options:getInputText() return self.input_text end
            return options
        end,
        onTap = function() end,
        onCloseWidget = function(self) self.base_closed = true end,
    }
end
package.preload["ui/widget/inputtext"] = function()
    local InputText = {}
    function InputText:extend(options)
        return setmetatable(options or {}, { __index = self })
    end
    function InputText:init() end
    function InputText:paintTo() end
    function InputText:onTapTextBox()
        return "input_tap"
    end
    function InputText:setText(text)
        self.text = text
    end
    return InputText
end
package.preload["ui/widget/container/leftcontainer"] = function() return {} end
package.preload["ui/widget/textwidget"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, dialog) shown_dialog = dialog end,
        nextTick = function(_, callback) callback() end,
    }
end
package.preload["logger"] = function() return { info = function() end } end
package.preload["device"] = function()
    return {
        screen = {
            scaleBySize = function(_, size) return size end,
        },
    }
end
package.preload["models"] = function() return {} end
package.preload["ui/inline_icon_map"] = function()
    return {
        label = function(_, text) return text end,
    }
end
package.preload["ui/images"] = function()
    return {
        asset = function(name) return name end,
    }
end
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

Modals.search("Search packages", "needle", "Search...", function() end)
assert(shown_dialog.title_bar_left_icon == nil)
assert(shown_dialog.inputtext_class)

local input = setmetatable({
    text = "needle",
    _frame_textwidget = { dimen = { x = 10, y = 20, w = 100, h = 24 } },
}, { __index = shown_dialog.inputtext_class })
assert(input:onTapTextBox(nil, { pos = { x = 90 } }))
assert(input.text == "")
assert(input:onTapTextBox(nil, { pos = { x = 20 } }) == "input_tap")

local cleared_search
Modals.search("Search packages", "needle", "Search...", function(text)
    cleared_search = text
end)
shown_dialog.input_text = ""
shown_dialog:onCloseWidget()
assert(shown_dialog.base_closed)
assert(cleared_search == "")

print("modals tests passed")
