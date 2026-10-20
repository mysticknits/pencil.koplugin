--[[--
Lasso and hold-menu action tests, run against the real main.lua.
KOReader modules are replaced with permissive stubs so the plugin can be
loaded outside the reader.
Run with: busted spec/lasso_spec.lua
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

local clock = 0
local events = { refresh_fast = {}, dirty = {}, scheduled = {}, view_paints = 0 }

local function fake_bb()
    return {
        paintRectRGB32 = function() end,
        paintBorder = function() end,
        blitFrom = function() end,
        copy = function() return fake_bb() end,
        free = function() end,
    }
end

local screen = {
    bb = fake_bb(),
    night_mode = false,
    getWidth = function() return 1404 end,
    getHeight = function() return 1872 end,
    scaleBySize = function(_, v) return v end,
    refreshFast = function(_, x, y, w, h) table.insert(events.refresh_fast, { x = x, y = y, w = w, h = h }) end,
    refreshUI = function() end,
}

local stubs = {
    ["device"] = setmetatable({ screen = screen }, {
        __index = function() return function() return true end end,
    }),
    ["ui/uimanager"] = setmetatable({
        setDirty = function(_, w) table.insert(events.dirty, w) end,
        scheduleIn = function(_, _, fn) table.insert(events.scheduled, fn) end,
    }, { __index = function() return function() end end }),
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

local function hline(x0, x1, y)
    local pts = {}
    for x = x0, x1, 10 do table.insert(pts, { x = x, y = y }) end
    return { page = 1, tool = "pen", width = 3, points = pts }
end

local function new_pencil()
    local p = setmetatable({
        tool = make_tool(PencilTool),
        annotation_groups = {},
        refresh_interval_ms = 16,
        input_debug_mode = false,
        side_button_down = false,
        pen_down = false,
        view = { paintTo = function() events.view_paints = events.view_paints + 1 end },
        ui = { dialog = "ReaderUI" },
        save_delay_ms = 1500,
    }, { __index = Pencil })
    p:initStrokeStore()
    for _, stroke in ipairs({ hline(100, 300, 100), hline(100, 300, 500) }) do p.store:add(stroke) end
    p.isEnabled = function() return true end
    p.isOverlayActive = function() return false end
    p.transformCoordinates = function(_, x, y) return x, y end
    p.getCurrentPage = function() return 1 end
    p.paintTo = function() end
    p.drawLineSegment = function() end
    p.rebuilds = 0
    p.rebuildAnnotationGroups = function(self) self.rebuilds = self.rebuilds + 1 end
    p.saveStrokes = function() end
    return p
end

local function pen(p, x, y) p:handleStylusSlot(nil, { id = 1, x = x, y = y, tool = 1 }) end
local function lift(p) p:handleStylusSlot(nil, { id = -1, tool = 1 }) end

-- Circle the stroke at y = 100 (box 80..320 x 70..130).
local function circle_top(p)
    p:startLasso()
    for _, pt in ipairs({ { 80, 70 }, { 320, 70 }, { 320, 130 }, { 80, 130 }, { 80, 72 } }) do
        pen(p, pt[1], pt[2])
    end
    lift(p)
end

describe("lasso (real main.lua)", function()
    before_each(function()
        clock = 0
        events.refresh_fast, events.dirty, events.scheduled, events.view_paints = {}, {}, {}, 0
    end)

    it("selects only the strokes inside the loop", function()
        local p = new_pencil()
        circle_top(p)
        assert.are.equal("selected", p.lasso.phase)
        assert.are.equal(1, #p.lasso.strokes)
        assert.are.equal(100, p.lasso.strokes[1].points[1].y)
    end)

    it("deletes the selection from the Delete button, and undo brings it back", function()
        local p = new_pencil()
        circle_top(p)
        local _, buttons = p:lassoLayout()
        pen(p, buttons[1].x + 5, buttons[1].y + 5)
        lift(p)
        assert.is_nil(p.lasso)
        assert.are.equal(1, #p.store.strokes)
        assert.are.equal(500, p.store.strokes[1].points[1].y)
        p:undoLastStroke()
        assert.are.equal(2, #p.store.strokes)
    end)

    it("moves the selection by dragging inside the box, with undo and redo", function()
        local p = new_pencil()
        circle_top(p)
        pen(p, 200, 100)
        clock = 200
        pen(p, 250, 160)
        lift(p)
        assert.is_nil(p.lasso)
        local moved = p.store.strokes[1]
        assert.are.same({ x = 150, y = 160 }, moved.points[1])
        assert.are.same({ x = 100, y = 500 }, p.store.strokes[2].points[1])
        p:undoLastStroke()
        assert.are.same({ x = 100, y = 100 }, moved.points[1])
        p:redoLastStroke()
        assert.are.same({ x = 150, y = 160 }, moved.points[1])
    end)

    it("moves page-anchored PDF strokes in page space", function()
        local p = new_pencil()
        local s = p.store.strokes[1]
        s.page_points = {}
        for i, pt in ipairs(s.points) do s.page_points[i] = { x = pt.x / 2, y = pt.y / 2 } end
        s._vz, s._vox, s._voy = 2, 0, 0
        p.ui.paging = {}
        p.view.page_scroll = false
        p.view.state = { page = 1, zoom = 2, offset = { x = 0, y = 0 } }
        p.view.visible_area = { x = 0, y = 0 }
        circle_top(p)
        pen(p, 200, 100)
        pen(p, 240, 140)
        lift(p)
        assert.are.same({ x = 70, y = 70 }, s.page_points[1])
        assert.are.same({ x = 140, y = 140 }, s.points[1])
        p:undoLastStroke()
        assert.are.same({ x = 50, y = 50 }, s.page_points[1])
    end)

    it("ends without a selection when the loop is empty", function()
        local p = new_pencil()
        p:startLasso()
        for _, pt in ipairs({ { 600, 600 }, { 700, 600 }, { 700, 700 }, { 600, 700 } }) do pen(p, pt[1], pt[2]) end
        lift(p)
        assert.is_nil(p.lasso)
    end)

    it("leaves lasso mode when tapping outside the selection", function()
        local p = new_pencil()
        circle_top(p)
        pen(p, 900, 900)
        lift(p)
        assert.is_nil(p.lasso)
        assert.are.equal(2, #p.store.strokes)
    end)

    it("runs hold-menu actions", function()
        local p = new_pencil()
        local called = {}
        p.undoLastStroke = function() table.insert(called, "undo") end
        p.redoLastStroke = function() table.insert(called, "redo") end
        p.openNoteAt = function(_, x, y) table.insert(called, "note " .. x .. "," .. y) end
        p:runHoldMenuAction("undo", 1, 2)
        p:runHoldMenuAction("redo", 1, 2)
        p:runHoldMenuAction("note", 10, 20)
        p:runHoldMenuAction("lasso", 1, 2)
        assert.are.same({ "undo", "redo", "note 10,20" }, called)
        assert.are.equal("armed", p.lasso.phase)
    end)

    it("previews a drag without re-rendering the page", function()
        local p = new_pencil()
        circle_top(p)
        local paints = events.view_paints
        pen(p, 200, 100)
        for i = 1, 5 do
            clock = clock + 50
            pen(p, 200 + i * 10, 100 + i * 10)
        end
        assert.are.equal(paints, events.view_paints)
        assert.is_true(#events.refresh_fast >= 4)
        local r = events.refresh_fast[#events.refresh_fast]
        assert.is_true(r.w < 400 and r.h < 200) -- just around the box
    end)

    it("repaints the reader window after a move, and defers the group rebuild", function()
        local p = new_pencil()
        circle_top(p)
        pen(p, 200, 100)
        clock = 100
        pen(p, 250, 160)
        lift(p)
        assert.are.equal("ReaderUI", events.dirty[#events.dirty])
        assert.are.equal(0, p.rebuilds)
        for _, fn in ipairs(events.scheduled) do fn() end
        assert.are.equal(1, p.rebuilds)
    end)

    it("keeps group indices valid after a lasso delete", function()
        local p = new_pencil()
        p.annotation_groups = { { id = "a", stroke_indices = { 1 } }, { id = "b", stroke_indices = { 2 } } }
        circle_top(p)
        local _, buttons = p:lassoLayout()
        pen(p, buttons[1].x + 5, buttons[1].y + 5)
        lift(p)
        assert.are.same({}, p.annotation_groups[1].stroke_indices)
        assert.are.same({ 1 }, p.annotation_groups[2].stroke_indices)
        assert.are.equal(0, p.rebuilds)
    end)
end)
