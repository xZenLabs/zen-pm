local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Modals = {}

function Modals.info(text)
    UIManager:show(InfoMessage:new{ text = text })
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
    dialog = ButtonDialog:new{
        title = pkg.name or pkg.id or _("Package"),
        buttons = {
            {
                {
                    text = _("Info"),
                    callback = function()
                        UIManager:close(dialog)
                        if callbacks.info then callbacks.info() end
                    end,
                },
            },
            {
                {
                    text = _("Reinstall"),
                    callback = function()
                        UIManager:close(dialog)
                        callbacks.reinstall()
                    end,
                },
            },
            {
                {
                    text = _("Uninstall"),
                    callback = function()
                        UIManager:close(dialog)
                        callbacks.uninstall()
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Modals.actions(title, rows)
    local dialog
    local buttons = {}
    for _, row in ipairs(rows or {}) do
        table.insert(buttons, {
            {
                text = row.text,
                callback = function()
                    UIManager:close(dialog)
                    row.callback()
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function() UIManager:close(dialog) end,
        },
    })
    dialog = ButtonDialog:new{
        title = title,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return Modals
