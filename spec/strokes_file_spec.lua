-- Tests for reading and writing pencil_strokes.lua across format versions,
-- and for saving before the device sleeps. Like dogear_spec, this loads the
-- real main.lua with KOReader modules stubbed out, but uses real files in a
-- temporary folder.

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

-- Minimal stand-in for KOReader's dump(): serializes plain Lua tables.
local function dump(value)
    if type(value) == "table" then
        local parts = {}
        for k, v in pairs(value) do
            local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
            table.insert(parts, key .. " = " .. dump(v))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
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
    package.loaded["dump"] = dump
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
    local f = assert(io.open(path, "r"))
    local text = f:read("*a")
    f:close()
    return text
end

local function makePencil(sidecar)
    local settings = { values = {}, doc_sidecar_dir = sidecar }
    function settings:readSetting(key) return self.values[key] end
    function settings:saveSetting(key, value) self.values[key] = value end
    return setmetatable({
        ui = { doc_settings = settings },
        available_colors = {},
        strokes = {},
        annotation_groups = {},
    }, { __index = Pencil })
end

local GROUP = '{ { id = "g1", page = 1, stroke_indices = { 1 }, bbox = { x0 = 1, y0 = 2, x1 = 3, y1 = 4 } } }'

describe("pencil_strokes.lua versions", function()
    local root, file

    before_each(function()
        root = os.tmpname()
        os.remove(root)
        assert(lfs.mkdir(root))
        file = root .. "/pencil_strokes.lua"
    end)

    after_each(function()
        os.execute("rm -rf '" .. root .. "'")
    end)

    it("loads a v3 file with a points array", function()
        write(file, 'return { version = 3, annotation_groups = ' .. GROUP .. ', strokes = { { page = 1, tool = "pen", points = { { x = 1, y = 2 }, { x = 3, y = 4 } } } } }')
        local pencil = makePencil(root)
        pencil:loadStrokes()
        assert.equals(1, #pencil.strokes)
        assert.equals(2, #pencil.strokes[1].points)
        assert.equals(3, pencil.strokes[1].points[2].x)
    end)

    it("loads a v4 file with packed points", function()
        write(file, 'return { version = 4, annotation_groups = ' .. GROUP .. ', strokes = { { page = 1, tool = "pen", p = "1 2 3 4" } } }')
        local pencil = makePencil(root)
        pencil:loadStrokes()
        assert.equals(1, #pencil.strokes)
        assert.equals(4, pencil.strokes[1].points[2].y)
    end)

    it("leaves a file from a newer Pencil alone and never saves over it", function()
        local newer = 'return { version = 99, strokes = { { page = 1, future = "ink" } } }'
        write(file, newer)
        local pencil = makePencil(root)

        pencil:loadStrokes()
        assert.is_true(pencil.strokes_file_too_new)
        assert.equals(0, #pencil.strokes)

        -- Even with new ink drawn, the file must not be overwritten.
        table.insert(pencil.strokes, { page = 1, tool = "pen", points = { { x = 5, y = 6 } } })
        pencil:saveStrokes()
        assert.equals(newer, read(file))
    end)
end)

describe("onSuspend", function()
    it("saves pending ink before the device sleeps", function()
        local calls = {}
        local pencil = setmetatable({}, { __index = Pencil })
        function pencil:flushDeferredWork() table.insert(calls, "save") end
        function pencil:flushPendingCaptures() table.insert(calls, "captures") end

        pencil:onSuspend()

        assert.same({ "save", "captures" }, calls)
    end)
end)
