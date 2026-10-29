-- Tests for carrying a book's ink to its new sidecar after KOReader renames
-- the book (#84). KOReader moves metadata.lua but not the plugin's own files.
-- Like dogear_spec, this loads the real main.lua with KOReader modules
-- stubbed out, but uses the real filesystem in a temporary folder.

package.path = "pencil.koplugin/?.lua;" .. package.path

local lfs = require("lfs")

-- A stand-in that tolerates any field access or call made while main.lua
-- loads (widget classes, Blitbuffer colours, Device.screen, ...).
local function permissive()
    local stub = {}
    return setmetatable(stub, {
        __index = function() return permissive() end,
        __call = function() return permissive() end,
    })
end

local function loadPencil()
    local stubbed = {
        "ffi/blitbuffer", "ui/widget/container/centercontainer", "datastorage",
        "device", "dispatcher", "ui/widget/container/framecontainer", "ui/geometry",
        "ui/gesturerange", "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
        "ui/widget/verticalgroup", "ui/widget/verticalspan", "ui/size",
        "ui/widget/infomessage", "ui/widget/container/widgetcontainer",
        "ui/time", "ffi/util", "ui/uimanager",
    }
    for _, name in ipairs(stubbed) do
        package.loaded[name] = permissive()
    end
    package.loaded["libs/libkoreader-lfs"] = lfs
    package.loaded["ui/widget/container/inputcontainer"] = {
        extend = function(_, class) return class end,
    }
    package.loaded["logger"] = {
        dbg = function() end, info = function() end,
        warn = function() end, err = function() end,
    }
    package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
    package.loaded["main"] = nil
    return dofile("pencil.koplugin/main.lua")
end

local Pencil = loadPencil()

local function write(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local function exists(path)
    return lfs.attributes(path, "mode")
end

-- A pencil whose book now lives in new_sidecar, with the old strokes path
-- remembered in its settings, as after KOReader renamed the book.
local function makePencil(new_sidecar, remembered)
    local settings = { values = { pencil_strokes_path = remembered } }
    function settings:readSetting(key) return self.values[key] end
    function settings:saveSetting(key, value) self.values[key] = value end
    settings.doc_sidecar_dir = new_sidecar
    return setmetatable({ ui = { doc_settings = settings } }, { __index = Pencil })
end

describe("moving ink after a rename", function()
    local root, old_sidecar, new_sidecar

    before_each(function()
        root = os.tmpname()
        os.remove(root)
        assert(lfs.mkdir(root))
        old_sidecar = root .. "/old.sdr"
        new_sidecar = root .. "/new.sdr"
        assert(lfs.mkdir(old_sidecar))
        assert(lfs.mkdir(new_sidecar))
        write(old_sidecar .. "/pencil_strokes.lua", "return { strokes = {} }")
        assert(lfs.mkdir(old_sidecar .. "/pencil_images"))
        write(old_sidecar .. "/pencil_images/pencil_a.jpg", "jpeg a")
    end)

    after_each(function()
        os.execute("rm -rf '" .. root .. "'")
    end)

    it("moves the strokes file and the preview pictures, then removes the old sidecar", function()
        local pencil = makePencil(new_sidecar, old_sidecar .. "/pencil_strokes.lua")

        local path = pencil:migrateStrokesFileIfNeeded()

        assert.equals(new_sidecar .. "/pencil_strokes.lua", path)
        assert.equals("return { strokes = {} }", read(path))
        assert.equals("jpeg a", read(new_sidecar .. "/pencil_images/pencil_a.jpg"))
        assert.is_nil(exists(old_sidecar))
        assert.equals(path, pencil.ui.doc_settings.values.pencil_strokes_path)
    end)

    it("never overwrites pictures already in the new sidecar", function()
        assert(lfs.mkdir(new_sidecar .. "/pencil_images"))
        write(new_sidecar .. "/pencil_images/pencil_b.jpg", "jpeg b")
        local pencil = makePencil(new_sidecar, old_sidecar .. "/pencil_strokes.lua")

        pencil:migrateStrokesFileIfNeeded()

        assert.equals("jpeg b", read(new_sidecar .. "/pencil_images/pencil_b.jpg"))
        assert.is_nil(exists(new_sidecar .. "/pencil_images/pencil_a.jpg"))
        -- The old pictures stay where they were, so nothing is lost.
        assert.equals("jpeg a", read(old_sidecar .. "/pencil_images/pencil_a.jpg"))
    end)

    it("moves the strokes file when there are no pictures", function()
        os.execute("rm -rf '" .. old_sidecar .. "/pencil_images'")
        local pencil = makePencil(new_sidecar, old_sidecar .. "/pencil_strokes.lua")

        pencil:migrateStrokesFileIfNeeded()

        assert.truthy(read(new_sidecar .. "/pencil_strokes.lua"))
        assert.is_nil(exists(new_sidecar .. "/pencil_images"))
        assert.is_nil(exists(old_sidecar))
    end)

    it("leaves things alone when the book wasn't renamed", function()
        local pencil = makePencil(old_sidecar, old_sidecar .. "/pencil_strokes.lua")

        local path = pencil:migrateStrokesFileIfNeeded()

        assert.equals(old_sidecar .. "/pencil_strokes.lua", path)
        assert.equals("jpeg a", read(old_sidecar .. "/pencil_images/pencil_a.jpg"))
    end)
end)
