local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path

local lfs = require("lfs")
local cache_root = os.tmpname()
os.remove(cache_root)
assert(lfs.mkdir(cache_root))

package.preload["zenpm_constants"] = function()
    return {
        ASSET_DIR = root .. "/assets",
        CATEGORIES = {},
    }
end
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function()
            return cache_root
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return lfs
end

local hashes = {}
local hash_count = 0
package.preload["ffi/sha2"] = function()
    return {
        sha256 = function(value)
            if not hashes[value] then
                hash_count = hash_count + 1
                hashes[value] = string.format("%064x", hash_count)
            end
            return hashes[value]
        end,
    }
end

local function load_images()
    package.loaded["ui/images"] = nil
    return require("ui/images")
end

local function path_exists(path)
    return lfs.attributes(path, "mode") == "file"
end

local function remove_tree(path)
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local child = path .. "/" .. name
            if lfs.attributes(child, "mode") == "directory" then
                remove_tree(child)
            else
                assert(os.remove(child))
            end
        end
    end
    assert(lfs.rmdir(path))
end

local downloads = 0
local payload = "first image"
local client = {
    download = function()
        downloads = downloads + 1
        return true, payload, 200, { ["content-type"] = "image/png" }
    end,
}
local url = "https://example.invalid/icon.png"

local Images = load_images()
local first = assert(Images.file_for(client, "android", url))
assert(downloads == 1)
assert(path_exists(first))

Images = load_images()
assert(Images.file_for(client, "android", url) == first)
assert(downloads == 1)

Images.invalidate_cache()
assert(Images.cached_file("android", url) == nil)
payload = "updated image"
local updated = assert(Images.file_for(client, "android", url))
assert(downloads == 2)
assert(updated ~= first)
assert(path_exists(updated))
assert(not path_exists(first))

Images.invalidate_cache()
local unchanged = assert(Images.file_for(client, "android", url))
assert(downloads == 3)
assert(unchanged == updated)

Images = load_images()
assert(Images.cached_file("android", url) == updated)
assert(os.remove(updated))
Images = load_images()
assert(Images.cached_file("android", url) == nil)
assert(Images.file_for(client, "android", url) == updated)
assert(downloads == 4)

for i = 1, 256 do
    payload = "image " .. i
    local extra_url = "https://example.invalid/image-" .. i .. ".png"
    assert(Images.file_for(client, "android", extra_url))
end

local image_count = 0
local cache_dir = cache_root .. "/ZenPM/cache/koreader-images"
for name in lfs.dir(cache_dir) do
    if name:match("^image%-") then
        image_count = image_count + 1
    end
end
assert(image_count <= 256)

assert(Images.file_for(client, "android", root .. "/assets/packages.svg")
    == root .. "/assets/packages.svg")

remove_tree(cache_root)
print("images tests passed")
