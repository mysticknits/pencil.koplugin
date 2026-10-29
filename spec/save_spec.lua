-- Tests for where and when saveStrokes writes pencil_strokes.lua. Like
-- dogear_spec, this loads the real main.lua with KOReader modules stubbed
-- out, but uses real files in a temporary folder.

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
    -- Just enough of KOReader's util and dump for saveStrokes.
    package.loaded["util"] = {
        makePath = function(path)
            os.execute("mkdir -p '" .. path .. "'")
            return lfs.attributes(path, "mode") == "directory"
        end,
    }
    package.loaded["dump"] = function() return "{}" end
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

local function makePencil(sidecar, strokes)
    local settings = { values = {}, doc_sidecar_dir = sidecar }
    function settings:saveSetting(key, value) self.values[key] = value end
    return setmetatable({
        ui = { doc_settings = settings },
        strokes = strokes,
        annotation_groups = {},
        strokes_loaded = true,
    }, { __index = Pencil })
end

local INK = { { page = 1, tool = "pen", points = { { x = 1, y = 2 } } } }

describe("saveStrokes", function()
    local root

    before_each(function()
        root = os.tmpname()
        os.remove(root)
        assert(lfs.mkdir(root))
    end)

    after_each(function()
        os.execute("rm -rf '" .. root .. "'")
    end)

    it("creates a missing sidecar folder so new ink is saved right away", function()
        local sidecar = root .. "/hash/ab/book.sdr"
        makePencil(sidecar, INK):saveStrokes()
        assert.equals("file", lfs.attributes(sidecar .. "/pencil_strokes.lua", "mode"))
    end)

    it("writes nothing for a book with no ink and no strokes file", function()
        local sidecar = root .. "/book.sdr"
        makePencil(sidecar, {}):saveStrokes()
        assert.is_nil(lfs.attributes(sidecar, "mode"))
    end)

    it("still saves an empty file when all ink was erased", function()
        local sidecar = root .. "/book.sdr"
        assert(lfs.mkdir(sidecar))
        local f = assert(io.open(sidecar .. "/pencil_strokes.lua", "w"))
        f:write("return { strokes = { {} } }")
        f:close()

        makePencil(sidecar, {}):saveStrokes()

        local after = io.open(sidecar .. "/pencil_strokes.lua"):read("*a")
        assert.equals("return {}", after)
    end)
end)
