local I18n = {}

local ok_logger, logger = pcall(require, "logger")
local plugin_dir = (debug.getinfo(1, "S").source:match("^@(.+)/i18n%.lua$") or ".")
local installed = false
local gettext_ref = nil
local original_change_lang = nil

local function log_warn(...)
    if ok_logger and logger and logger.warn then
        logger.warn(...)
    end
end

local function log_info(...)
    if ok_logger and logger and logger.info then
        logger.info(...)
    end
end

local function unescape(value)
    return tostring(value or "")
        :gsub("\\n", "\n")
        :gsub("\\t", "\t")
        :gsub('\\"', '"')
        :gsub("\\\\", "\\")
end

local function parse_po(path)
    local f = io.open(path, "r")
    if not f then
        return nil, nil, 0
    end

    local translations = {}
    local contexts = {}
    local ctx, id, str
    local in_ctx, in_id, in_str = false, false, false

    local function flush()
        if id and id ~= "" and str and str ~= "" then
            if ctx and ctx ~= "" then
                if not contexts[ctx] then
                    contexts[ctx] = {}
                end
                contexts[ctx][id] = str
            else
                translations[id] = str
            end
        end
        ctx, id, str = nil, nil, nil
        in_ctx, in_id, in_str = false, false, false
    end

    for raw_line in f:lines() do
        local line = raw_line:match("^%s*(.-)%s*$")
        if line == "" or line:match("^#") then
            if line == "" then
                flush()
            end
        elseif line:match("^msgctxt%s+\"") then
            flush()
            ctx = unescape(line:match('^msgctxt%s+"(.*)"') or "")
            in_ctx, in_id, in_str = true, false, false
        elseif line:match("^msgid%s+\"") then
            if not in_ctx then
                flush()
            end
            id = unescape(line:match('^msgid%s+"(.*)"') or "")
            in_ctx, in_id, in_str = false, true, false
        elseif line:match("^msgstr%s+\"") then
            str = unescape(line:match('^msgstr%s+"(.*)"') or "")
            in_ctx, in_id, in_str = false, false, true
        elseif line:match('^"') then
            local cont = unescape(line:match('^"(.*)"') or "")
            if in_ctx and ctx then
                ctx = ctx .. cont
            elseif in_id and id then
                id = id .. cont
            elseif in_str and str then
                str = str .. cont
            end
        end
    end

    flush()
    f:close()

    local count = 0
    for _ in pairs(translations) do
        count = count + 1
    end
    for _, msgs in pairs(contexts) do
        for _ in pairs(msgs) do
            count = count + 1
        end
    end
    return translations, contexts, count
end

local function detect_lang()
    local lang = G_reader_settings and G_reader_settings.readSetting and G_reader_settings:readSetting("language")
    if type(lang) == "string" and lang ~= "" then
        return lang
    end
    local env = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or ""
    return env:match("^([a-zA-Z_]+)") or "en"
end

local function load_for_lang(lang)
    if not lang or lang == "en" or lang:match("^en_") then
        return nil, nil
    end
    local function try(name)
        local path = plugin_dir .. "/locales/" .. name .. ".po"
        local translations, contexts, count = parse_po(path)
        if translations and count and count > 0 then
            log_info("zenpm i18n: loaded " .. path .. " - " .. tostring(count) .. " entries")
            return translations, contexts
        end
        return nil, nil
    end

    local translations, contexts = try(lang)
    if translations then
        return translations, contexts
    end

    local prefix = lang:match("^([a-zA-Z]+)")
    if prefix and prefix ~= lang then
        return try(prefix)
    end
    return nil, nil
end

local function apply_translations(gettext, lang)
    local translations, contexts = load_for_lang(lang)
    if not translations then
        log_warn("zenpm i18n: no custom translations for lang=" .. tostring(lang))
        return
    end
    if type(gettext.translation) ~= "table" then
        gettext.translation = {}
    end
    if type(gettext.context) ~= "table" then
        gettext.context = {}
    end
    for msgid, msgstr in pairs(translations) do
        gettext.translation[msgid] = msgstr
    end
    for msgctxt, msgs in pairs(contexts or {}) do
        if not gettext.context[msgctxt] then
            gettext.context[msgctxt] = {}
        end
        for msgid, msgstr in pairs(msgs) do
            gettext.context[msgctxt][msgid] = msgstr
        end
    end
end

function I18n.install()
    if installed then
        return
    end
    local ok, gettext = pcall(require, "gettext")
    if not ok or not gettext then
        log_warn("zenpm i18n: gettext unavailable")
        return
    end
    gettext_ref = gettext
    apply_translations(gettext, detect_lang())

    local mt = getmetatable(gettext)
    if mt and type(mt.__index) == "table" and type(mt.__index.changeLang) == "function" then
        original_change_lang = mt.__index.changeLang
        mt.__index.changeLang = function(new_lang)
            local result = original_change_lang(new_lang)
            apply_translations(gettext, new_lang)
            return result
        end
    end
    installed = true
end

function I18n.uninstall()
    if not installed then
        return
    end
    if gettext_ref and original_change_lang then
        local mt = getmetatable(gettext_ref)
        if mt and type(mt.__index) == "table" then
            mt.__index.changeLang = original_change_lang
            original_change_lang(gettext_ref.current_lang)
        end
    end
    gettext_ref = nil
    original_change_lang = nil
    installed = false
end

function I18n.get_lang()
    return detect_lang()
end

function I18n.dynamic(value)
    if value == nil then
        return nil
    end
    value = tostring(value)
    if value == "" then
        return nil
    end
    local _ = require("gettext")
    return _(value)
end

function I18n.dynamic_or(value, fallback)
    return I18n.dynamic(value) or fallback
end

return I18n
