local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local IconButton = require("ui/widget/iconbutton")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Screen = require("device").screen
local Models = require("models")
local InlineIcons = require("ui/inline_icon_map")
local Images = require("ui/images")
local Theme = require("ui/theme")
local _ = require("gettext")

local Modals = {}
local status_modal = nil
local ok_android = pcall(require, "android")

local InputClearOverlay = OverlapGroup:extend{}

local function show_input_dialog(dialog)
    UIManager:show(dialog)
    if not ok_android then
        dialog:onShowKeyboard()
    end
end

function InputClearOverlay:propagateEvent(event)
    for i = #self, 1, -1 do
        if self[i]:handleEvent(event) then
            return true
        end
    end
    return false
end

function Modals.info(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function Modals.info_for(text, seconds)
    local modal = InfoMessage:new{ text = text }
    UIManager:show(modal)
    UIManager:scheduleIn(seconds, function()
        UIManager:close(modal)
    end)
end

function Modals.status(text)
    Modals.close_status()
    status_modal = InfoMessage:new{
        text = text,
        dismissable = false,
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
    dialog = InputDialog:new{
        title = title,
        input = input or "",
        input_hint = hint,
        keyboard_visible = not ok_android,
        title_bar_left_icon = "close",
        title_bar_left_icon_tap_callback = function()
            UIManager:close(dialog)
        end,
        buttons = {
            {
                {
                    text = InlineIcons.label("search", _("Search")),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        callback(text)
                    end,
                },
            },
        },
    }

    local input_container = dialog.vgroup[3]
    local clear_button = IconButton:new{
        icon = "close",
        width = Theme.scale(20),
        height = Theme.scale(20),
        padding = Theme.scale(10),
        allow_flash = false,
        show_parent = dialog,
        callback = function()
            dialog:setInputText("", false, false)
            if not ok_android then
                dialog:onShowKeyboard()
            end
        end,
    }
    local input_size = dialog._input_widget:getSize()
    input_container[1] = InputClearOverlay:new{
        dimen = input_size,
        dialog._input_widget,
        clear_button,
    }
    clear_button.overlap_offset = {
        input_size.w - clear_button.dimen.w,
        math.floor((input_size.h - clear_button.dimen.h) / 2),
    }

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
        add_button("remove", _("Remove from queue"), callbacks.remove_queue)
    end
    if callbacks.info then
        add_button("info", _("Details"), callbacks.info)
    end
    if callbacks.update then
        add_button("update", _("Update") .. (pkg.latest_version and pkg.latest_version ~= "" and " " .. pkg.latest_version or ""), callbacks.update)
    end
    if not callbacks.manage_only and callbacks.downgrade then
        add_button("downgrade", _("Downgrade"), callbacks.downgrade)
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
                text = row.text,
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
                callback = function() UIManager:close(dialog) end,
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
    local dialog
    dialog = ButtonDialog:new{
        title = text,
        buttons = {
            {
                {
                    text = _("Keep settings"),
                    callback = function()
                        UIManager:close(dialog)
                        if callback then callback(false) end
                    end,
                },
                {
                    text = _("Remove settings"),
                    callback = function()
                        UIManager:close(dialog)
                        if callback then callback(true) end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Modals.restart_koreader(text, restart_callback, restart_later_callback)
    local dialog
    dialog = ButtonDialog:new{
        title = text,
        buttons = {
            {
                {
                    text = _("Restart later"),
                    callback = function()
                        UIManager:close(dialog)
                        if restart_later_callback then restart_later_callback() end
                    end,
                },
                {
                    text = _("Restart now"),
                    callback = function()
                        UIManager:close(dialog)
                        logger.info("ZenPM: requesting KOReader restart")
                        restart_callback()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

return Modals
