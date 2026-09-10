local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local Markdown = require("ui/markdown")

local measured_image
local measured_image_max_height
local image_tap_callback
local shown_image_viewer
local scheduled_callbacks = {}
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ui/widget/imageviewer"] = function()
    return {
        new = function(_, options)
            options.onClose = function(self) self.closed = true end
            return options
        end,
    }
end
package.preload["ui/primitives"] = function()
    return {
        image_dimensions = function(file, _, max_height)
            measured_image = file
            measured_image_max_height = max_height
            return 80, 40
        end,
        image_cropped = function() return true end,
        hit = function(_, _, _, _, _, callback) image_tap_callback = callback end,
        paragraph = function() end,
    }
end
package.preload["ui/theme"] = function()
    return {
        scale = function(value) return value end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, _, callback) table.insert(scheduled_callbacks, callback) end,
        show = function(_, widget) shown_image_viewer = widget end,
    }
end
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
    {
        name = "image-only table",
        input = "| First | Second |\n| :---: | :---: |\n| ![First](https://example.com/first.png) | ![Second](https://example.com/second.png) |",
        want = "heading,image,heading,image",
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

local badge_blocks = Markdown.parse([=[
[![Build](https://img.shields.io/badge/build-passing.svg)](https://example.com/build)
<img src="https://img.shields.io/badge/version-1.0.svg">
[![Discord][badge-discord]][link-discord]
[![AGPL Licence][badge-license]](LICENSE)
[![Custom][shield-image]][custom-link]

[badge-discord]: https://example.com/discord.svg
[badge-license]: https://example.com/license.svg
[shield-image]: https://img.shields.io/badge/custom-badge.svg
[link-discord]: https://example.com/discord
[custom-link]: https://example.com/custom

Kept
]=])
assert(#badge_blocks == 1 and badge_blocks[1].text == "Kept")

local zenos_blocks = Markdown.parse([[
<p>
  <a href="https://zen-labs.org/zen-os">Website</a> ·
  <a href="docs/installation.md">Installation guide</a>
</p>
]])
assert(#zenos_blocks == 1)
local zenos_text, zenos_links = Renderer.inline_text(zenos_blocks[1].text, "https://github.com/xZenLabs/zen-os/")
assert(zenos_text == "Website ·\n  Installation guide")
assert(#zenos_links == 2)
assert(zenos_links[1].url == "https://zen-labs.org/zen-os")
assert(zenos_links[2].url == "https://github.com/xZenLabs/zen-os/docs/installation.md")

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

local linked, links = Renderer.inline_text(
    "Read [the docs](guide.md) or https://example.com/path.",
    "https://repo.example/demo/"
)
assert(linked == "Read the docs or https://example.com/path.")
assert(#links == 2)
assert(linked:sub(links[1].start_idx, links[1].end_idx) == "the docs")
assert(links[1].url == "https://repo.example/demo/guide.md")
assert(linked:sub(links[2].start_idx, links[2].end_idx) == "https://example.com/path")
assert(links[2].url == "https://example.com/path")

local html_linked, html_links = Renderer.inline_text(
    '<a href="https://example.com/html">HTML link</a> and <https://example.com/auto>',
    ""
)
assert(html_linked == "HTML link and https://example.com/auto")
assert(#html_links == 2)

local quoted, quoted_links = Renderer.inline_text("│ [quote](https://example.com/quote)", "")
assert(quoted == "│ quote")
assert(quoted_links[1].start_idx == 3 and quoted_links[1].end_idx == 7)

local queued_images = {}
local image_view = {
    app = {
        state = { show_readme_images = true },
        cached_image_file = function() return nil, false end,
        queue_readme_image = function(_, url) table.insert(queued_images, url) end,
    },
}
Renderer.render(image_view, {}, {
    { kind = "image", alt = "First", url = "first.png" },
    { kind = "image", alt = "Second", url = "second.png" },
}, "", "https://repo.example/packages/demo/", 0, 0, 100, 100, 0)
assert(#queued_images == 1)
assert(queued_images[1] == "https://repo.example/packages/demo/first.png")

Renderer.render(image_view, {}, {
    { kind = "image", alt = "Preview", url = "/packages/readerbackdrop-test/preview" },
}, "", "https://www.readerbackdrop.com/", 0, 0, 100, 100, 0)
assert(queued_images[2] == "/packages/readerbackdrop-test/preview")

Renderer.render({
    app = {
        state = { show_readme_images = true },
        cached_image_file = function() return "wallpaper.jpg", false end,
    },
}, {}, {
    { kind = "image", alt = "Wallpaper", url = "wallpaper.jpg", max_height = 480 },
}, "", "https://repo.example/packages/demo/", 0, 0, 100, 0, 0)
assert(measured_image == "wallpaper.jpg" and measured_image_max_height == 480)
measured_image = nil

Renderer.render({
    app = {
        state = { show_readme_images = true },
        cached_image_file = function() return "wallpaper.jpg", false end,
    },
}, {}, {
    { kind = "image", alt = "Wallpaper", url = "wallpaper.jpg" },
}, "", "https://repo.example/packages/demo/", 0, 0, 100, 100, 0)
assert(image_tap_callback)
image_tap_callback()
assert(shown_image_viewer.file == "wallpaper.jpg")
assert(shown_image_viewer.fullscreen == true and shown_image_viewer.with_title_bar == false)
assert(shown_image_viewer:onTap() == true and shown_image_viewer.closed == true)
measured_image = nil

local prepared_file = os.tmpname()
local prepared_handle = assert(io.open(prepared_file, "w"))
prepared_handle:write("prepared image")
prepared_handle:close()
local prepared_ref = os.tmpname()
local ref_handle = assert(io.open(prepared_ref, "w"))
ref_handle:write(prepared_file .. "\t1200\t600\n")
ref_handle:close()

local managed_url = "https://repo.example/packages/demo/managed.png"
local managed_view = {
    app = {
        state = { page = "package_details", show_readme_images = true },
        cached_image_file = function() error("backend-managed images must not use the frontend cache") end,
        queue_readme_image = function() error("backend-managed images must not use the frontend queue") end,
        refresh = function() end,
    },
}
Renderer.render(managed_view, {}, {
    { kind = "image", alt = "Managed", url = "managed.png" },
}, "", "https://repo.example/packages/demo/", 0, 0, 100, 0, 0, {
    [managed_url] = prepared_ref,
})
assert(measured_image == nil)
assert(#scheduled_callbacks == 0)

local pending_ref = os.tmpname()
assert(os.remove(pending_ref))
Renderer.render(managed_view, {}, {
    { kind = "image", alt = "Pending", url = "pending.png" },
}, "", "https://repo.example/packages/demo/", 0, 0, 100, 0, 0, {
    ["https://repo.example/packages/demo/pending.png"] = pending_ref,
})
assert(#scheduled_callbacks == 1)

local pending_ref_2 = os.tmpname()
assert(os.remove(pending_ref_2))
local prepared_refreshes = 0
managed_view.app.refresh = function() prepared_refreshes = prepared_refreshes + 1 end
Renderer.render(managed_view, {}, {
    { kind = "image", alt = "Pending", url = "pending.png" },
    { kind = "image", alt = "Pending 2", url = "pending-2.png" },
}, "", "https://repo.example/packages/demo/", 0, 0, 100, 0, 0, {
    ["https://repo.example/packages/demo/pending.png"] = pending_ref,
    ["https://repo.example/packages/demo/pending-2.png"] = pending_ref_2,
})
assert(#scheduled_callbacks == 1)
local first_ref = assert(io.open(pending_ref, "w"))
first_ref:write(prepared_file .. "\t1200\t600\n")
first_ref:close()
table.remove(scheduled_callbacks, 1)()
assert(prepared_refreshes == 0)
assert(#scheduled_callbacks == 1)
local second_ref = assert(io.open(pending_ref_2, "w"))
second_ref:write(prepared_file .. "\t1200\t600\n")
second_ref:close()
table.remove(scheduled_callbacks, 1)()
assert(prepared_refreshes == 1)
assert(#scheduled_callbacks == 0)

assert(os.remove(prepared_ref))
assert(os.remove(prepared_file))
assert(os.remove(pending_ref))
assert(os.remove(pending_ref_2))

print("markdown tests passed")
