local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local PROXY_URL = "https://zen-pm-reporter.misty-mud-afb2.workers.dev/"
local UPLOAD_URL = PROXY_URL .. "upload"
local MAX_INLINE_LOG = 60000
local MAX_TITLE = 500
local MAX_BODY = 65536

local Reporter = {}

local function truncate_utf8_bytes(text, max_bytes, suffix)
    suffix = suffix or ""
    if #text <= max_bytes then return text end
    local keep = max_bytes - #suffix
    while keep > 0 and text:byte(keep + 1) >= 0x80 and text:byte(keep + 1) <= 0xBF do
        keep = keep - 1
    end
    return text:sub(1, keep) .. suffix
end

local function log_url(response)
    if type(response) == "table" then
        return response.url
    end
    return tostring(response or ""):match('"url"%s*:%s*"([^"]+)"')
end

local function koreader_version()
    local ok, version = pcall(require, "version")
    if ok and type(version) == "string" and version ~= "" then
        return version
    end
    if ok and type(version) == "table" then
        return version.version or version.short or version.git or "unknown"
    end
    return rawget(_G, "KOREADER_VERSION") or "unknown"
end

local function device_name()
    return Device.model or Device.model_name or Device.device_model or Device.name or "unknown"
end

local function koreader_crash_log(app)
    local root = app.daemon:koreader_root()
    if type(root) ~= "string" or root == "" then return "" end
    local file = io.open(root .. "/crash.log", "rb")
    if not file then return "" end
    local contents = file:read("*a") or ""
    file:close()
    return contents
end

local function issue_body(description, app, username, uploaded_log_url, inline_log, has_crash_log)
    local parts = {
        "**Describe the bug**",
        description ~= "" and description or "_No description provided._",
        "",
        "**Environment**",
        "- ZenPM: " .. tostring(app.version or app.daemon:plugin_version() or "unknown"),
        "- KOReader: " .. tostring(koreader_version()),
        "- Device: " .. tostring(device_name()),
        "- Platform: " .. tostring(app:platform()),
        "",
    }
    local log_name = has_crash_log and "ZenPM.log and KOReader crash.log" or "ZenPM.log"
    if uploaded_log_url then
        table.insert(parts, "**Logs:** [" .. log_name .. "](" .. uploaded_log_url .. ")")
    else
        table.insert(parts, "<details>")
        table.insert(parts, "<summary>" .. log_name .. "</summary>")
        table.insert(parts, "")
        table.insert(parts, "```")
        table.insert(parts, inline_log)
        table.insert(parts, "```")
        table.insert(parts, "</details>")
    end
    if username ~= "" then
        table.insert(parts, "")
        table.insert(parts, "**Reported by:** @" .. username)
    end
    table.insert(parts, "")
    table.insert(parts, "_Submitted via the ZenPM in-app bug reporter._")
    return table.concat(parts, "\n")
end

local function check_network()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return not (ok and NetworkMgr and type(NetworkMgr.isOnline) == "function" and not NetworkMgr:isOnline())
end

function Reporter:show(app)
    if not check_network() then
        return require("ui/modals").info(_("No network connection. Please connect to Wi-Fi and try again."))
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("ZenPM.log and KOReader's crash.log (if present) will be attached to a public GitHub issue. They may contain package names, repository URLs, and file paths.") .. "\n\n" .. _("Continue?"),
        ok_text = _("Continue"),
        ok_callback = function()
            self:ask_title(app)
        end,
    })
end

function Reporter:ask_title(app)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Bug report title"),
        description = _("A short summary of what went wrong"),
        input_hint = _("Brief description of the bug"),
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            {
                text = _("Next"),
                is_enter_default = true,
                callback = function()
                    local title = (dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                    if title == "" then return end
                    UIManager:close(dialog)
                    self:ask_description(app, title)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Reporter:ask_description(app, title)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Bug description (optional)"),
        description = _("Steps to reproduce, expected vs. actual behavior"),
        input_type = "text",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            {
                text = _("Next"),
                is_enter_default = true,
                callback = function()
                    local description = (dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                    UIManager:close(dialog)
                    self:ask_username(app, title, description)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Reporter:ask_username(app, title, description)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("GitHub username (optional)"),
        description = _("Enter your GitHub username to be tagged in the issue"),
        input_hint = _("username"),
        buttons = {{
            {
                text = _("Skip"),
                callback = function()
                    UIManager:close(dialog)
                    self:submit(app, title, description, "")
                end,
            },
            {
                text = _("Submit"),
                is_enter_default = true,
                callback = function()
                    local username = (dialog:getInputText() or ""):match("^%s*@?(.-)%s*$")
                    UIManager:close(dialog)
                    self:submit(app, title, description, username)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Reporter:submit(app, title, description, username)
    local Modals = require("ui/modals")
    Modals.status(_("Submitting report…"))
    UIManager:nextTick(function()
        local ok_log, log = app.client:get_log(5000)
        if not ok_log or type(log) ~= "string" or log == "" then
            Modals.close_status()
            return Modals.info(_("Could not retrieve the ZenPM log: ") .. tostring(log or "unknown error"))
        end

        local crash_log = koreader_crash_log(app)
        if crash_log ~= "" then
            log = log .. "\n\n===== KOReader crash.log =====\n" .. crash_log
        end
        local uploaded_log_url
        local uploaded, upload_response = app.client:request("POST", UPLOAD_URL, { log = log })
        if uploaded then
            uploaded_log_url = log_url(upload_response)
        end
        local inline_log = truncate_utf8_bytes(log, MAX_INLINE_LOG, "\n...[truncated]")
        local body = issue_body(description, app, username, uploaded_log_url, inline_log, crash_log ~= "")
        body = truncate_utf8_bytes(body, MAX_BODY, "\n...[truncated]")
        local report_title = truncate_utf8_bytes("[BUG] " .. title, MAX_TITLE + 6)
        local submitted, response, code = app.client:request("POST", PROXY_URL, {
            title = report_title,
            body = body,
            labels = { "bug" },
        })
        Modals.close_status()
        if submitted then
            local url = log_url(response) or "https://github.com/AnthonyGress/ZenPackageManager/issues"
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = _("Bug report submitted!") .. "\n\n" .. url,
                no_ok_button = true,
                cancel_text = _("OK"),
            })
        else
            Modals.info(_("Failed to submit report: ") .. tostring(response or code or "unknown error"))
        end
    end)
end

return Reporter
