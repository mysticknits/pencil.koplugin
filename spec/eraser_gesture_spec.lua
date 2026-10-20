--[[--
Stylus eraser gesture tests, run against the real main.lua.
KOReader modules are replaced with permissive stubs so the plugin can be
loaded outside the reader; screen refreshes and expensive calls are counted.
Run with: busted spec/eraser_gesture_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"
-- Use the right package loader table for Lua 5.1+ compatibility
local loaders = package.loaders or package.searchers

-- A stub that accepts any field access or call and returns another stub.
local function make_stub()
    return setmetatable({}, {
        __index = function() return make_stub() end,
        __call = function() return make_stub() end,
    })
end

local refreshes = {}

local screen = {
    bb = {},
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
    ["ui/uimanager"] = setmetatable({}, { __index = function() return function() end end }),
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

-- KOReader global the plugin saves its settings through
-- (main.lua is loaded with dofile, so it sees the real globals, not busted's)
(getfenv and getfenv(0) or _G).G_reader_settings = { saveSetting = function() end, readSetting = function() end }

local Pencil = load_pencil()
local PencilStrokes = require("lib/pencilstrokes")
local PencilTool = require("lib/penciltool")
local make_tool = dofile("spec/helpers/make_tool.lua")

local TOOL_TYPE_PEN = 1
local TOOL_TYPE_ERASER = 2

local function hline(x0, x1, y)
    local pts = {}
    for x = x0, x1, 5 do table.insert(pts, { x = x, y = y }) end
    return { page = 1, tool = "pen", width = 3, points = pts }
end

-- Three horizontal strokes at y = 100, 200, 300 on page 1.
local function new_pencil(opts)
    opts = opts or {}
    local calls = { rebuild_groups = 0, box_lookups = 0, saves = 0, stale_at_save = nil }
    local annotations = {}
    for i = 1, (opts.highlights or 0) do
        annotations[i] = { drawer = "lighten", pos0 = "a" .. i, pos1 = "b" .. i }
    end
    local p = setmetatable({
        tool = make_tool(PencilTool, { tool_settings = { pen = { width = 3 }, eraser = { width = 10 } } }),
        annotation_groups = {
            { id = "g1", stroke_indices = { 1, 2 } },
            { id = "g2", stroke_indices = { 3 } },
        },
        input_debug_mode = false,
        view = { paintTo = function() end },
        ui = {
            annotation = { annotations = annotations },
            view = {},
            document = {
                getScreenBoxesFromPositions = function()
                    calls.box_lookups = calls.box_lookups + 1
                    return { { x = 900, y = 900, w = 50, h = 20 } }
                end,
            },
        },
    }, { __index = Pencil })
    p:initStrokeStore()
    for _, stroke in ipairs({ hline(0, 200, 100), hline(0, 200, 200), hline(0, 200, 300) }) do p.store:add(stroke) end
    p.isEnabled = function() return true end
    p.isOverlayActive = function() return false end
    p.transformCoordinates = function(_, x, y) return x, y end
    p.getCurrentPage = function() return 1 end
    p.paintTo = function() end
    p.rebuildAnnotationGroups = function(self)
        calls.rebuild_groups = calls.rebuild_groups + 1
    end
    p.saveStrokes = function(self)
        calls.saves = calls.saves + 1
        calls.stale_at_save = self.groups_stale
    end
    return p, calls
end

-- The eraser end erases by dragging; a touch that stays put is a click (it
-- switches pen/eraser). So the first sample of a gesture comes with a short
-- run-up that puts the contact beyond the click tolerance; later samples
-- continue the same contact.
local function eraser(p, x, y)
    if not p.tool.eraser_contact then
        p:handleStylusSlot(nil, { id = 1, x = x - 30, y = y, tool = TOOL_TYPE_ERASER })
    end
    p:handleStylusSlot(nil, { id = 1, x = x, y = y, tool = TOOL_TYPE_ERASER })
end
-- A touch that stays put
local function eraser_touch(p, x, y) p:handleStylusSlot(nil, { id = 1, x = x, y = y, tool = TOOL_TYPE_ERASER }) end
local function eraser_lift(p) p:handleStylusSlot(nil, { id = -1, tool = TOOL_TYPE_ERASER }) end
local function pen_tip(p) p:handleStylusSlot(nil, { id = -1, tool = TOOL_TYPE_PEN }) end

describe("stylus eraser gesture (real main.lua)", function()
    before_each(function()
        for i = #refreshes, 1, -1 do refreshes[i] = nil end
    end)

    it("rebuilds annotation groups once per gesture, not once per erased stroke", function()
        local p, calls = new_pencil()
        eraser(p, 50, 100)
        eraser(p, 50, 200)
        assert.are.equal(1, #p.store.strokes)
        assert.are.equal(0, calls.rebuild_groups)
        eraser_lift(p)
        assert.are.equal(1, calls.rebuild_groups)
    end)

    it("keeps group stroke indices valid while erasing", function()
        local p = new_pencil()
        eraser(p, 50, 100)  -- removes stroke 1
        assert.are.same({ 1 }, p.annotation_groups[1].stroke_indices)
        assert.are.same({ 2 }, p.annotation_groups[2].stroke_indices)
        assert.are.equal(300, p.store.strokes[p.annotation_groups[2].stroke_indices[1]].points[1].y)
    end)

    it("rebuilds groups before saving when switching back to the pen tip", function()
        local p, calls = new_pencil()
        eraser(p, 50, 100)
        pen_tip(p)
        assert.are.equal(1, calls.saves)
        assert.is_false(calls.stale_at_save)
        assert.are.equal(1, calls.rebuild_groups)
    end)

    it("does not erase again while the eraser stays still", function()
        local p = new_pencil()
        local erase_calls = 0
        local real = p.eraseAtPoint
        p.eraseAtPoint = function(...) erase_calls = erase_calls + 1; return real(...) end
        eraser(p, 500, 500)  -- the drag starts: erases where it came down and here
        local after_start = erase_calls
        assert.is_true(after_start >= 1)
        for _ = 1, 4 do eraser(p, 500, 500) end
        assert.are.equal(after_start, erase_calls)
    end)

    it("looks up highlight boxes once per gesture", function()
        local p, calls = new_pencil({ highlights = 4 })
        for x = 500, 540, 5 do eraser(p, x, 500) end
        assert.are.equal(4, calls.box_lookups)
        eraser_lift(p)
        eraser(p, 500, 600)
        assert.are.equal(8, calls.box_lookups)
    end)

    it("a click erases nothing and switches the tool; a drag does not", function()
        local p = new_pencil()
        eraser_touch(p, 50, 100)
        eraser_touch(p, 52, 101)
        eraser_lift(p)
        assert.are.equal(3, #p.store.strokes)
        assert.are.equal("eraser", p.tool.current_tool)
        eraser(p, 50, 100)
        eraser_lift(p)
        assert.are.equal(2, #p.store.strokes)
        assert.are.equal("eraser", p.tool.current_tool)  -- dragging did not switch it back
    end)

    it("rebuilds groups once, before saving, when the pen tip used as the eraser is lifted", function()
        local p, calls = new_pencil()
        p.tool.current_tool = "eraser"
        p:handleStylusSlot(nil, { id = 1, x = 50, y = 100, tool = TOOL_TYPE_PEN })
        p:handleStylusSlot(nil, { id = 1, x = 50, y = 200, tool = TOOL_TYPE_PEN })
        assert.are.equal(1, #p.store.strokes)
        assert.are.equal(0, calls.rebuild_groups)
        p:handleStylusSlot(nil, { id = -1, tool = TOOL_TYPE_PEN })
        assert.are.equal(1, calls.rebuild_groups)
        assert.are.equal(1, calls.saves)
        assert.is_false(calls.stale_at_save)
        assert.is_true(p.store:canUndo())
    end)

    it("refreshes only the area of the erased stroke", function()
        local p = new_pencil()
        eraser(p, 50, 200)
        assert.are.equal(1, #refreshes)
        local r = refreshes[1]
        assert.is_true(r.w <= 220 and r.h <= 30)
        assert.is_true(r.y <= 200 and r.y + r.h >= 200)
    end)
end)
