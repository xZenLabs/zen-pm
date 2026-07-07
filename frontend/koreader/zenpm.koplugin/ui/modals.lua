local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Models = require("models")
local _ = require("gettext")

local Modals = {}
local status_modal = nil

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

function Modals.confirm(text, ok_text, ok_callback)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = ok_text or _("OK"),
        ok_callback = ok_callback,
    })
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
        buttons = buttons,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Modals.package_modify(pkg, callbacks)
    local dialog
    local buttons = {}
    if callbacks.info then
        table.insert(buttons, {
            {
                text = _("Info"),
                callback = function()
                    UIManager:close(dialog)
                    callbacks.info()
                end,
            },
        })
    end
    if callbacks.update then
        table.insert(buttons, {
            {
                text = _("Update"),
                callback = function()
                    UIManager:close(dialog)
                    callbacks.update()
                end,
            },
        })
    end
    if callbacks.reinstall_downgrade then
        table.insert(buttons, {
            {
                text = _("Reinstall / Downgrade"),
                callback = function()
                    UIManager:close(dialog)
                    callbacks.reinstall_downgrade()
                end,
            },
        })
    else
        table.insert(buttons, {
            {
                text = _("Reinstall"),
                callback = function()
                    UIManager:close(dialog)
                    callbacks.reinstall()
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Uninstall"),
            callback = function()
                UIManager:close(dialog)
                callbacks.uninstall()
            end,
        },
    })
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function() UIManager:close(dialog) end,
        },
    })
    dialog = ButtonDialog:new{
        title = Models.package_display_name(pkg, _("Package")),
        buttons = buttons,
    }
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
                    UIManager:close(dialog)
                    row.callback()
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

function Modals.restart_koreader(text, restart_callback)
    local dialog
    dialog = ButtonDialog:new{
        title = text,
        buttons = {
            {
                {
                    text = _("Restart later"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Restart now"),
                    callback = function()
                        UIManager:close(dialog)
                        restart_callback()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

return Modals
