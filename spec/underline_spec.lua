--[[--
Underline-by-hold tests, run against the real main.lua.
KOReader modules are replaced with permissive stubs so the plugin can be
loaded outside the reader; scheduled callbacks are captured and fired by hand.
Run with: busted spec/underline_spec.lua
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

local scheduled = {}

local screen = {
    bb = { paintRectRGB32 = function() end },
    night_mode = false,
    getWidth = function() return 1404 end,
    getHeight = function() return 1872 end,
    refreshFast = function() end,
    refreshUI = function() end,
}

local stubs = {
    ["device"] = setmetatable({ screen = screen }, {
        __index = function() return function() return true end end,
    }),
    ["ui/uimanager"] = setmetatable({
        scheduleIn = function(_, _, fn) scheduled[fn] = true end,
        unschedule = function(_, fn) scheduled[fn] = nil end,
    }, { __index = function() return function() end end }),
    ["ui/time"] = {
        now = function() return 0 end,
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

local function fire_scheduled()
    local fns = {}
    for fn in pairs(scheduled) do table.insert(fns, fn) end
    for _, fn in ipairs(fns) do
        scheduled[fn] = nil
        fn()
    end
end

-- One text line occupies y = 100..120 between x = 50 and x = 900.
local function in_text(pos)
    return pos.x >= 50 and pos.x <= 900 and pos.y >= 100 and pos.y <= 120
end

local function new_pencil(opts)
    opts = opts or {}
    local saved = {}
    local p = setmetatable({
        tool = make_tool(PencilTool, { tool_settings = { pen = { color = { getColor8 = function() return { a = 0 } end }, color_name = "Black", width = 3, alpha = 1 } } }),
        refresh_interval_ms = 16,
        input_debug_mode = false,
        experimental_color_picker = false,
        experimental_pen_width = false,
        underline_hold = opts.underline_hold ~= false,
        side_button_down = false,
        pen_down = false,
        view = { paintTo = function() end },
        ui = {
            view = {
                screenToPageTransform = function(_, pos) return { x = pos.x, y = pos.y, page = 1 } end,
            },
            document = {
                getWordFromPosition = function(_, pos)
                    if in_text(pos) then return { word = "w", pos0 = pos, pos1 = pos } end
                end,
                getTextFromPositions = function(_, p0, p1)
                    return { text = "underlined words", pos0 = p0, pos1 = p1 }
                end,
            },
            highlight = {
                saveHighlight = function(rh)
                    table.insert(saved, rh.selected_text)
                    return #saved
                end,
                clear = function(rh) rh.selected_text = nil end,
            },
        },
    }, { __index = Pencil })
    p:initStrokeStore()
    p.isEnabled = function() return true end
    p.isOverlayActive = function() return false end
    p.transformCoordinates = function(_, x, y) return x, y end
    p.getCurrentPage = function() return 1 end
    p.paintTo = function() end
    p.assignStrokeToGroup = function() end
    p.scheduleDeferredWork = function() end
    p.scheduleDelayedRefresh = function() end
    p.cancelPendingRefresh = function() end
    p.cancelColorPickerTimer = function() end
    p.drawLineSegment = function() end
    return p, saved
end

local function slot(x, y) return { id = 1, x = x, y = y, tool = 1 } end
local function draw(p, pts)
    for _, pt in ipairs(pts) do p:handleStylusSlot(nil, slot(pt[1], pt[2])) end
end
local function lift(p) p:handleStylusSlot(nil, { id = -1, tool = 1 }) end

describe("underline by holding at line end (real main.lua)", function()
    before_each(function()
        for fn in pairs(scheduled) do scheduled[fn] = nil end
    end)

    it("turns a held horizontal line under text into a native highlight", function()
        local p, saved = new_pencil()
        draw(p, { { 100, 126 }, { 200, 127 }, { 300, 126 }, { 400, 128 } })
        fire_scheduled()
        assert.are.equal(1, #saved)
        assert.is_nil(saved[1].drawer) -- default highlight style
        assert.are.equal(100 + 2, saved[1].pos0.x)
        assert.is_true(saved[1].pos0.y >= 100 and saved[1].pos0.y <= 120)
        lift(p)
        assert.are.equal(0, #p.store.strokes)
    end)

    it("keeps the ink when the pen lifts before the hold time", function()
        local p, saved = new_pencil()
        draw(p, { { 100, 126 }, { 400, 128 } })
        lift(p)
        fire_scheduled()
        assert.are.equal(0, #saved)
        assert.are.equal(1, #p.store.strokes)
    end)

    it("ignores lines that are too short or too steep", function()
        local p, saved = new_pencil()
        draw(p, { { 100, 126 }, { 120, 127 } })
        fire_scheduled()
        lift(p)
        draw(p, { { 100, 126 }, { 200, 200 } })
        fire_scheduled()
        assert.are.equal(0, #saved)
        assert.are.equal(1, #p.store.strokes)
    end)

    it("keeps the ink when there is no text above the line", function()
        local p, saved = new_pencil()
        draw(p, { { 100, 400 }, { 400, 401 } })
        fire_scheduled()
        lift(p)
        assert.are.equal(0, #saved)
        assert.are.equal(1, #p.store.strokes)
    end)

    it("does nothing when the option is off", function()
        local p, saved = new_pencil({ underline_hold = false })
        draw(p, { { 100, 126 }, { 400, 128 } })
        fire_scheduled()
        lift(p)
        assert.are.equal(0, #saved)
        assert.are.equal(1, #p.store.strokes)
    end)

    it("restarts the hold timer while the pen keeps moving", function()
        local p = new_pencil()
        draw(p, { { 100, 126 }, { 200, 127 } })
        local first = next(scheduled)
        draw(p, { { 300, 126 } })
        local count = 0
        for _ in pairs(scheduled) do count = count + 1 end
        assert.are.equal(1, count)
        assert.are.equal(first, next(scheduled)) -- same closure, rescheduled
        draw(p, { { 304, 127 } })                -- within the still tolerance
        assert.are.equal(first, next(scheduled))
    end)
end)
