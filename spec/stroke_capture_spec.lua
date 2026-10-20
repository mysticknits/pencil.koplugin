--[[--
Stroke capture tests for pen down / move / lift, run against the real main.lua.
KOReader modules are replaced with permissive stubs so the plugin can be
loaded outside the reader; screen refreshes are recorded.
Run with: busted spec/stroke_capture_spec.lua
--]]--

-- Use the right package loader table for Lua 5.1+ compatibility
local loaders = package.loaders or package.searchers
package.path = package.path .. ";pencil.koplugin/?.lua"


-- A stub that accepts any field access or call and returns another stub.
local function make_stub()
    return setmetatable({}, {
        __index = function() return make_stub() end,
        __call = function() return make_stub() end,
    })
end

local refreshes = {}
local clock = 0

local screen = {
    bb = { paintRectRGB32 = function() end },
    night_mode = false,
    getWidth = function() return 1264 end,
    getHeight = function() return 1680 end,
    refreshFast = function(_, x, y, w, h) table.insert(refreshes, { x = x, y = y, w = w, h = h }) end,
    refreshUI = function(_, x, y, w, h) table.insert(refreshes, { x = x, y = y, w = w, h = h }) end,
}

local stubs = {
    ["device"] = setmetatable({ screen = screen }, {
        __index = function() return function() return true end end,
    }),
    ["ui/time"] = {
        now = function() return clock end,
        to_ms = function(t) return t end,
    },
    ["ui/widget/container/inputcontainer"] = {
        -- No stub fallback: unset fields must read as nil, as in KOReader.
        extend = function(_, o) return o or {} end,
    },
    ["gettext"] = function(s) return s end,
    ["logger"] = setmetatable({}, { __index = function() return function() end end }),
}

local function load_pencil()
    table.insert(loaders, 2, function(name)
                     if name == "lib/geometry" or name == "lib/penciltool" or name == "lib/pencilstrokes" then return nil end
                     return function() return stubs[name] or make_stub() end
    end)
    local Pencil = dofile("pencil.koplugin/main.lua")
    table.remove(loaders, 2)
    return Pencil
end

local Pencil = load_pencil()
local PencilStrokes = require("lib/pencilstrokes")
local PencilTool = require("lib/penciltool")
local make_tool = dofile("spec/helpers/make_tool.lua")

local function new_pencil()
    local p = setmetatable({
        tool = make_tool(PencilTool, { tool_settings = { pen = { color = { getColor8 = function() return { a = 0 } end }, color_name = "Black", width = 3, alpha = 1 } } }),
        refresh_interval_ms = 16,
        input_debug_mode = false,
        experimental_color_picker = false,
        experimental_pen_width = false,
        side_button_down = false,
        pen_down = false,
    }, { __index = Pencil })
    p:initStrokeStore()
    p.isEnabled = function() return true end
    p.isOverlayActive = function() return false end
    p.transformCoordinates = function(_, x, y) return x, y end
    p.getCurrentPage = function() return 1 end
    p.assignStrokeToGroup = function() end
    p.scheduleDeferredWork = function() end
    p.scheduleDelayedRefresh = function() end
    p.cancelPendingRefresh = function() end
    p.cancelColorPickerTimer = function() end
    p.drawLineSegment = function() end
    return p
end

local function down(p, x, y) p:handleStylusSlot(nil, { id = 1, x = x, y = y, tool = 1 }) end
local function move(p, x, y) p:handleStylusSlot(nil, { id = 1, x = x, y = y, tool = 1 }) end
local function lift(p) p:handleStylusSlot(nil, { id = -1, tool = 1 }) end

describe("stroke capture (real main.lua)", function()
    before_each(function()
        for i = #refreshes, 1, -1 do refreshes[i] = nil end
        clock = 0
    end)

    it("saves a tap with no movement as a one-point dot", function()
        local p = new_pencil()
        down(p, 100, 200)
        lift(p)
        assert.are.equal(1, #p.store.strokes)
        assert.are.same({ { x = 100, y = 200 } }, p.store.strokes[1].points)
    end)

    it("keeps every dot of an ellipsis written quickly", function()
        local p = new_pencil()
        for i = 0, 2 do
            down(p, 100 + i * 20, 300)
            lift(p)
        end
        assert.are.equal(3, #p.store.strokes)
    end)

    it("starts a stroke at the touch-down point", function()
        local p = new_pencil()
        down(p, 10, 10)
        move(p, 20, 10)
        move(p, 30, 10)
        lift(p)
        assert.are.same({ x = 10, y = 10 }, p.store.strokes[1].points[1])
        assert.are.equal(3, #p.store.strokes[1].points)
    end)

    it("does not add a point when the touch-down frame has no position", function()
        local p = new_pencil()
        p:handleStylusSlot(nil, { id = 1, tool = 1 })
        move(p, 50, 60)
        lift(p)
        assert.are.same({ { x = 50, y = 60 } }, p.store.strokes[1].points)
    end)

    it("refreshes the stroke tail on lift instead of waiting for the delayed refresh", function()
        local p = new_pencil()
        down(p, 10, 10)
        clock = 20
        move(p, 20, 10)  -- periodic refresh fires here
        local before_tail = #refreshes
        clock = 25
        move(p, 400, 10) -- within 16ms: drawn but not yet refreshed
        lift(p)
        assert.are.equal(before_tail + 1, #refreshes)
        local r = refreshes[#refreshes]
        assert.is_true(r.x + r.w >= 400)
        assert.is_nil(p.dirty_region)
    end)
end)
