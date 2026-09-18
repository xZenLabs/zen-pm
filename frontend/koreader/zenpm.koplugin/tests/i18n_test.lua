local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local gettext = { translation = {}, context = {} }
setmetatable(gettext, {
    __call = function(self, value)
        return self.translation[value] or value
    end,
})
package.preload["gettext"] = function() return gettext end

G_reader_settings = {
    readSetting = function(_, key)
        assert(key == "language")
        return "pt_BR"
    end,
}

local I18n = dofile(root .. "/i18n.lua")
I18n.install()

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

print("i18n tests passed")
