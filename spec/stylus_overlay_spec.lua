-- Tests for how the stylus callback treats overlays (menus, dialogs, the
-- color picker) on top of the reader. Like dogear_spec, this loads the real
-- main.lua with KOReader modules stubbed out.

package.path = "pencil.koplugin/?.lua;" .. package.path

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
        "libs/libkoreader-lfs", "ui/time", "ffi/util", "ui/uimanager",
    }
    for _, name in ipairs(stubbed) do
        package.loaded[name] = permissive()
    end
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

local TOOL_TYPE_PEN = 1

-- A pencil whose drawing calls are recorded, with an overlay we can open and
-- close by hand.
local function makePencil()
    local pencil = setmetatable({
        current_tool = "pen",
        overlay = false,
        started = 0,
        points = 0,
        ended = 0,
    }, { __index = Pencil })
    function pencil:isEnabled() return true end
    function pencil:isOverlayActive() return self.overlay end
    function pencil:transformCoordinates(x, y) return x, y end
    function pencil:startRawStroke() self.started = self.started + 1 end
    function pencil:addRawPoint() self.points = self.points + 1 end
    function pencil:endRawStroke() self.ended = self.ended + 1 end
    function pencil:cancelPendingRefresh() end
    function pencil:cancelColorPickerTimer() end
    return pencil
end

local function down(pencil, x, y)
    return pencil:handleStylusSlot(nil, { id = 1, x = x, y = y, tool = TOOL_TYPE_PEN })
end

local function lift(pencil, x, y)
    return pencil:handleStylusSlot(nil, { id = -1, x = x, y = y, tool = TOOL_TYPE_PEN })
end

describe("stylus callback and overlays", function()
    it("leaves pen input to an overlay that was already open", function()
        local pencil = makePencil()
        pencil.overlay = true

        assert.is_false(down(pencil, 100, 100))
        assert.is_false(lift(pencil, 100, 100))

        assert.equals(0, pencil.started)
        assert.is_falsy(pencil.pen_down)
    end)

    it("keeps a contact that started on the page when an overlay opens mid-contact", function()
        local pencil = makePencil()
        assert.is_true(down(pencil, 100, 100))
        assert.is_true(pencil.pen_down)

        -- The color picker opens while the pen is held still.
        pencil.overlay = true

        assert.is_true(down(pencil, 104, 100))
        assert.is_true(lift(pencil, 104, 100))

        assert.equals(1, pencil.started)
        assert.equals(1, pencil.ended)
        assert.is_false(pencil.pen_down)
    end)

    it("hands the next contact to the overlay once the held one lifts", function()
        local pencil = makePencil()
        down(pencil, 100, 100)
        pencil.overlay = true
        lift(pencil, 100, 100)

        -- A pen tap on the open picker goes to the picker.
        assert.is_false(down(pencil, 300, 50))
        assert.is_false(lift(pencil, 300, 50))
        assert.equals(1, pencil.started)
    end)

    it("starts a fresh stroke after the overlay closes", function()
        local pencil = makePencil()
        down(pencil, 100, 100)
        pencil.overlay = true
        lift(pencil, 100, 100)
        pencil.overlay = false

        assert.is_true(down(pencil, 200, 200))
        assert.is_true(lift(pencil, 260, 200))

        assert.equals(2, pencil.started)
        assert.equals(2, pencil.ended)
    end)
end)
