std = "luajit"
self = false
unused_args = false

globals = {
    "G_reader_settings",
}

exclude_files = {
    "dist/**",
    "frontend/koreader/zenpm.koplugin/locales/**",
    "frontend/koreader/zenpm.koplugin/tests/**",
}

-- Keep these existing style findings incremental while LuaCheck gates syntax
-- errors and undefined globals in the plugin source.
ignore = {
    "211", -- Unused local variable.
    "213", -- Unused loop variable.
    "311", -- Unused assignment.
    "421", -- Shadowing a local variable.
    "431", -- Shadowing an upvalue.
    "542", -- Empty if branch.
    "631", -- Line too long.
}
