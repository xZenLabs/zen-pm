local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local gettext = { translation = {}, context = {}, current_lang = "pt_BR" }
local methods = {}
methods.changeLang = function(lang)
    gettext.translation = { ["Core label"] = "core:" .. lang }
    gettext.context = { core = { Label = "core context" } }
    gettext.current_lang = lang
    return true
end
methods.pgettext = function(context, value)
    return gettext.context[context] and gettext.context[context][value] or value
end
methods.ngettext = function(singular, plural, count)
    return count == 1 and singular or plural
end
setmetatable(gettext, {
    __index = methods,
    __call = function(self, value)
        return self.translation[value] or value
    end,
})
package.preload["gettext"] = function() return gettext end

local language = "pt_BR"
G_reader_settings = {
    readSetting = function(_, key)
        assert(key == "language")
        return language
    end,
}

-- CSS wraps gettext, then ZenOS adds another wrapper around it.
local sleep_screen = setmetatable({}, {
    __call = function(_, value)
        if value == "Theme" then return "External theme" end
        return gettext(value)
    end,
    __index = gettext,
})
local outer = setmetatable({}, {
    __call = function(_, value) return sleep_screen(value) end,
    __index = sleep_screen,
    __newindex = sleep_screen,
})
package.loaded["gettext"] = outer

local I18n = dofile(root .. "/i18n.lua")
I18n.install()
assert(I18n.dynamic("Games") == "Jogos")
assert(methods.changeLang("pt_BR"))
assert(I18n.dynamic("Games") == "Jogos", "core language reload erased ZenPM translations")

local translations = {
    Downloads = "Downloads",
    Fonts = "Fontes",
    Games = "Jogos",
    Media = "Mídia",
    ["Name (A-Z)"] = "Nome (A-Z)",
    ["Name (Z-A)"] = "Nome (Z-A)",
    Patches = "Correções",
    Productivity = "Produtividade",
    Screensavers = "Protetores de tela",
    Theme = "Tema",
    Utility = "Utilitário",
    Wallpapers = "Papéis de parede",
    ["ZenLabs Repo"] = "Repositório ZenLabs",
}
for msgid, expected in pairs(translations) do
    assert(I18n.dynamic(msgid) == expected, msgid)
end

local translated = require("gettext")
assert(sleep_screen("Theme") == "External theme")
assert(translated("Theme") == "Tema")

-- Core modules captured the original gettext before plugins loaded.
assert(methods.changeLang("pt_BR"))
assert(gettext("ZenPM: Open") == "ZenPM: Aberto")
assert(translated("Theme") == "Tema")
assert(translated("Core label") == "core:pt_BR")
assert(translated.pgettext("core", "Label") == "core context")
assert(translated.ngettext("item", "items", 2) == "items")

gettext.translation = {}
assert(translated("Theme") == "Tema")
I18n.install()
assert(require("gettext") == translated)
assert(gettext("Theme") == "Tema")

local saved_translation = gettext.translation
assert(translated.changeLang("pt_BR"))
translated.translation = saved_translation
assert(gettext.translation == saved_translation)

language = "fr"
assert(methods.changeLang(language))
assert(translated("Games") == "Jeux")
language = "en_US"
assert(methods.changeLang(language))
assert(translated("Games") == "Games")

I18n.uninstall()
assert(require("gettext") == outer)
assert(gettext("Games") == "Games")
language = "pt_BR"
I18n.install()
assert(I18n.dynamic("Games") == "Jogos")

local zenpm_gettext = require("gettext")
local later_gettext = setmetatable({}, {
    __call = function(_, value) return zenpm_gettext(value) end,
    __index = zenpm_gettext,
})
local zenpm_change_lang = methods.changeLang
local later_change_lang = function(lang) return zenpm_change_lang(lang) end
package.loaded["gettext"] = later_gettext
methods.changeLang = later_change_lang
I18n.uninstall()
assert(require("gettext") == later_gettext)
assert(methods.changeLang == later_change_lang)
assert(methods.changeLang(language))
assert(later_gettext("Games") == "Games")

print("i18n tests passed")
