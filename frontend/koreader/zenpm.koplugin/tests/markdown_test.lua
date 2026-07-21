local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local Markdown = require("ui/markdown")

package.preload["ui/widget/imageviewer"] = function() return {} end
package.preload["ui/primitives"] = function() return {} end
package.preload["ui/theme"] = function() return {} end
package.preload["ui/uimanager"] = function() return {} end
local Renderer = require("ui/markdown_renderer")

local function kinds(blocks)
    local out = {}
    for _, block in ipairs(blocks) do
        table.insert(out, block.kind)
    end
    return table.concat(out, ",")
end

local tests = {
    {
        name = "README blocks",
        input = "# Title\n\nParagraph with *emphasis* and [link](docs/guide.md).\n\n- One\n- Two\n\n1. First\n2. Second\n\n> Quoted\n> text\n\n```lua\nprint('hello')\n```\n\n---",
        want = "heading,paragraph,list,list,quote,code,rule",
    },
    {
        name = "inline image",
        input = "Before ![Diagram](images/diagram.png) after",
        want = "paragraph,image,paragraph",
    },
    {
        name = "HTML image",
        input = "<p><img src=\"images/diagram.png\" alt=\"Diagram\"></p>",
        want = "image",
    },
    {
        name = "pipe table",
        input = "| Name | Value |\n| --- | --- |\n| One | Two |",
        want = "table",
    },
}

for _, test in ipairs(tests) do
    local got = kinds(Markdown.parse(test.input))
    assert(got == test.want, test.name .. ": got " .. got .. ", want " .. test.want)
end

local code_blocks = Markdown.parse("```lua\n  print('hello')\n```")
assert(code_blocks[1].kind == "code" and code_blocks[1].text == "  print('hello')")

local table_blocks = Markdown.parse("Name | Value\n:--- | ---:\nOne | Two")
assert(table_blocks[1].kind == "table")
assert(table_blocks[1].header[1] == "Name" and table_blocks[1].rows[1][2] == "Two")

assert(Markdown.resolve_url("https://repo.zen-labs.org/packages/demo/", "images/shot.png") == "https://repo.zen-labs.org/packages/demo/images/shot.png")
assert(Markdown.resolve_url("https://repo.zen-labs.org/packages/demo/", "../shared/logo.png") == "https://repo.zen-labs.org/packages/shared/logo.png")
assert(Markdown.resolve_url("https://repo.zen-labs.org/packages/demo/", "/assets/logo.png") == "https://repo.zen-labs.org/assets/logo.png")
assert(Markdown.resolve_url("https://repo.zen-labs.org/packages/demo/", "https://cdn.example/logo.png") == "https://cdn.example/logo.png")
assert(Markdown.base_url("https://repo.zen-labs.org/packages/demo/README.md?version=1") == "https://repo.zen-labs.org/packages/demo/")
assert(Markdown.public_image_base_url("https://github.com/xZenLabs/ZenUI") == "https://github.com/xZenLabs/ZenUI/raw/HEAD/")
assert(Markdown.source_base_url("https://github.com/xZenLabs/ZenUI.git") == "https://github.com/xZenLabs/ZenUI/")
assert(Markdown.resolve_url(Markdown.source_base_url("https://github.com/xZenLabs/ZenUI"), "docs/guide.md") == "https://github.com/xZenLabs/ZenUI/docs/guide.md")

local formatted = Renderer.inline_text("zen_ui.koplugin and _bold_", "")
assert(formatted:find("zen_ui.koplugin", 1, true))
assert(formatted ~= "zen_ui.koplugin and _bold_")

print("markdown tests passed")
