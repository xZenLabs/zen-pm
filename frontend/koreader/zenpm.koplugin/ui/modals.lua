local ButtonDialog = require("ui/widget/buttondialog")
local CheckButton = require("ui/widget/checkbutton")
local ConfirmBox = require("ui/widget/confirmbox")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local InputText = require("ui/widget/inputtext")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Screen = require("device").screen
local Models = require("models")
local InlineIcons = require("ui/inline_icon_map")
local Images = require("ui/images")
local _ = require("gettext")

local Modals = {}
local status_modal = nil
local ok_android = pcall(require, "android")

local ClearableInputText = InputText:extend{}

function ClearableInputText:init()
    InputText.init(self)
    self.clear_icon = IconWidget:new{
        file = Images.asset("close.svg"),
        width = Screen:scaleBySize(24),
        height = Screen:scaleBySize(24),
    }
end

function ClearableInputText:paintTo(bb, x, y)
    InputText.paintTo(self, bb, x, y)
    local field = self._frame_textwidget.dimen
    local icon_size = self.clear_icon:getSize()
    local inset = Screen:scaleBySize(8)
    self.clear_icon:paintTo(
        bb,
        field.x + field.w - icon_size.w - inset,
        field.y + math.floor((field.h - icon_size.h) / 2)
    )
end

function ClearableInputText:onTapTextBox(arg, ges)
    local field = self._frame_textwidget.dimen
    if field and ges.pos.x >= field.x + field.w - Screen:scaleBySize(48) then
        self:setText("")
        return true
    end
    return InputText.onTapTextBox(self, arg, ges)
end

function ClearableInputText:onCloseWidget()
    self.clear_icon:free()
    InputText.onCloseWidget(self)
end

local function show_input_dialog(dialog)
    UIManager:show(dialog)
    if not ok_android then
        dialog:onShowKeyboard()
    end
end

function Modals.info(text)
    UIManager:show(InfoMessage:new{ text = text })
    Modals.close_status()
end

function Modals.info_for(text, seconds)
    local modal = InfoMessage:new{ text = text }
    UIManager:show(modal)
    Modals.close_status()
    UIManager:scheduleIn(seconds, function()
        UIManager:close(modal)
    end)
end

function Modals.notice(text)
    UIManager:show(ConfirmBox:new{
        text = text,
        icon = "notice-info",
        no_ok_button = true,
        cancel_text = _("OK"),
    })
    Modals.close_status()
end

function Modals.status(text)
    Modals.close_status()
    status_modal = InfoMessage:new{
        text = text,
        dismissable = false,
        timeout = 60,
        flush_events_on_show = true,
    }
    UIManager:show(status_modal)
    return status_modal
end

function Modals.close_status()
    if status_modal then
        UIManager:close(status_modal)
        status_modal = nil
    end
end

function Modals.confirm(text, ok_text, ok_callback, close_before_callback)
    local dialog
    dialog = ConfirmBox:new{
        text = text,
        ok_text = ok_text or _("OK"),
        keep_dialog_open = close_before_callback,
        ok_callback = function()
            if close_before_callback then
                UIManager:close(dialog)
                UIManager:nextTick(ok_callback)
            else
                ok_callback()
            end
        end,
    }
    UIManager:show(dialog)
    Modals.close_status()
end

function Modals.ignore_updates(pkg, ignore_all_callback, ignore_version_callback)
    local dialog = ConfirmBox:new{
        modal = true,
        dismissable = true,
        text = string.format(
            _("Ignore updates for %s?"),
            Models.package_display_name(pkg, _("Package"))
        ),
        ok_text = _("Always ignore"),
        cancel_text = _("Only this version"),
        ok_callback = ignore_all_callback,
        cancel_callback = ignore_version_callback,
    }
    function dialog:onClose()
        UIManager:close(self)
        return true
    end
    UIManager:show(dialog)
    Modals.close_status()
end

function Modals.input(title, input, hint, ok_text, callback, clear_callback)
    local dialog
    local buttons = {
        {
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = ok_text or _("OK"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    callback(text)
                end,
            },
        },
    }
    if clear_callback then
        table.insert(buttons, 1, {
            {
                text = _("Clear"),
                callback = function()
                    UIManager:close(dialog)
                    clear_callback()
                end,
            },
        })
    end
    dialog = InputDialog:new{
        title = title,
        input = input or "",
        input_hint = hint,
        keyboard_visible = not ok_android,
        buttons = buttons,
    }
    show_input_dialog(dialog)
end

function Modals.search(title, input, hint, callback)
    local dialog
    local initial_input = input or ""
    local search_submitted = false
    dialog = InputDialog:new{
        title = title,
        input = initial_input,
        input_hint = hint,
        keyboard_visible = not ok_android,
        inputtext_class = ClearableInputText,
        buttons = {
            {
                {
                    text = InlineIcons.label("search", _("Search")),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        search_submitted = true
                        UIManager:close(dialog)
                        callback(text)
                    end,
                },
            },
        },
    }
    function dialog:onCloseWidget()
        local should_clear = not search_submitted
            and initial_input ~= ""
            and self:getInputText() == ""
        InputDialog.onCloseWidget(self)
        if should_clear then
            UIManager:nextTick(function() callback("") end)
        end
    end
    function dialog:onCloseDialog()
        UIManager:close(self)
        return true
    end
    function dialog:onTap(arg, ges)
        if ges.pos:notIntersectWith(self.dialog_frame.dimen) then
            UIManager:close(self)
            return true
        end
        return InputDialog.onTap(self, arg, ges)
    end
    show_input_dialog(dialog)
end

function Modals.package_modify(pkg, callbacks)
    local dialog
    local buttons = {}
    local function add_button(icon, text, callback)
        table.insert(buttons, {
            {
                text = InlineIcons.label(icon, text),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    callback()
                end,
            },
        })
    end
    if callbacks.remove_queue then
        add_button("remove_queue", _("Remove from queue"), callbacks.remove_queue)
    end
    if callbacks.info then
        add_button("info", _("Details"), callbacks.info)
    end
    if callbacks.update then
        add_button("update", _("Update") .. (pkg.latest_version and pkg.latest_version ~= "" and " " .. pkg.latest_version or ""), callbacks.update)
    end
    if callbacks.toggle_updates then
        add_button(
            callbacks.updates_ignored and "allow_updates" or "ignore_updates",
            callbacks.updates_ignored and _("Allow updates") or _("Ignore updates"),
            callbacks.toggle_updates
        )
    end
    if not callbacks.manage_only and callbacks.downgrade then
        add_button("downgrade", _("Change version"), callbacks.downgrade)
    end
    if callbacks.enable_disable then
        add_button(callbacks.disabled and "enable" or "disable", callbacks.disabled and _("Enable") or _("Disable"), callbacks.enable_disable)
    end
    if callbacks.uninstall then
        add_button("uninstall", _("Uninstall"), callbacks.uninstall)
    end
    local title = Models.package_display_name(pkg, _("Package"))
    local title_icon = callbacks.title_icon
        or Images.category_icon(pkg and pkg.category)
        or Images.asset("packages.svg")
    dialog = ButtonDialog:new{
        title = nil,
        buttons = buttons,
    }
    local icon_size = Screen:scaleBySize(28)
    local gap = Screen:scaleBySize(8)
    dialog:addWidget(LeftContainer:new{
        not_focusable = true,
        dimen = Geom:new{
            w = dialog:getAddedWidgetAvailableWidth(),
            h = icon_size,
        },
        HorizontalGroup:new{
            align = "center",
            IconWidget:new{
                file = title_icon,
                width = icon_size,
                height = icon_size,
            },
            HorizontalSpan:new{ width = gap },
            TextWidget:new{
                text = title,
                face = Font:getFace("infofont"),
            },
        },
    })
    UIManager:show(dialog)
end

function Modals.actions(title, rows, options)
    options = options or {}
    local dialog
    local anchor = options.anchor
    if anchor and options.anchor_right then
        local source = anchor
        anchor = function()
            local content = dialog and dialog.movable and dialog.movable[1]
            local content_w = content and content:getSize().w or 0
            return Geom:new{
                x = source.x + source.w - content_w - Screen:scaleBySize(8),
                y = source.y,
                w = source.w,
                h = source.h,
            }
        end
    end
    local buttons = {}
    for _, row in ipairs(rows or {}) do
        table.insert(buttons, {
            {
                text = row.icon and InlineIcons.label(row.icon, row.text) or row.text,
                align = row.align or options.align,
                checked_func = row.checked_func,
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        row.callback()
                    end)
                end,
            },
        })
    end
    if options.show_cancel ~= false then
        table.insert(buttons, {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                    if options.cancel_callback then options.cancel_callback() end
                end,
            },
        })
    end
    local dialog_title = title
    if options.title_icon then
        dialog_title = nil
    end
    dialog = ButtonDialog:new{
        title = dialog_title,
        buttons = buttons,
        anchor = anchor,
        shrink_min_width = options.compact_min_width and Screen:scaleBySize(options.compact_min_width) or nil,
        shrink_unneeded_width = options.compact,
    }
    if options.title_icon then
        local icon_size = Screen:scaleBySize(28)
        local gap = Screen:scaleBySize(8)
        dialog:addWidget(LeftContainer:new{
            not_focusable = true,
            dimen = Geom:new{
                w = dialog:getAddedWidgetAvailableWidth(),
                h = icon_size,
            },
            HorizontalGroup:new{
                align = "center",
                IconWidget:new{
                    file = options.title_icon,
                    width = icon_size,
                    height = icon_size,
                },
                HorizontalSpan:new{ width = gap },
                TextWidget:new{
                    text = title,
                    face = Font:getFace("infofont"),
                },
            },
        })
    end
    UIManager:show(dialog)
end

function Modals.plugin_settings_cleanup(text, callback)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Remove settings"),
        cancel_text = _("Keep settings"),
        ok_callback = function()
            if callback then callback(true) end
        end,
        cancel_callback = function()
            if callback then callback(false) end
        end,
    })
    Modals.close_status()
end

function Modals.restart_koreader(text, restart_callback, restart_later_callback)
    local dialog
    local reopen_checkbox
    dialog = ConfirmBox:new{
        text = text,
        ok_text = _("Restart now"),
        cancel_text = _("Restart later"),
        ok_callback = function()
            logger.info("ZenPM: requesting KOReader restart")
            restart_callback(reopen_checkbox.checked)
        end,
        cancel_callback = restart_later_callback,
    }
    reopen_checkbox = CheckButton:new{
        text = _("Open ZenPM after restart"),
        checked = false,
        parent = dialog,
    }
    dialog:addWidget(reopen_checkbox)
    UIManager:show(dialog)
    Modals.close_status()
end

return Modals
