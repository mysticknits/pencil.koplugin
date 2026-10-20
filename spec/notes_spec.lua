--[[--
Note canvas tests, run against the real main.lua.
KOReader modules are replaced with permissive stubs so the plugin can be
loaded outside the reader; widgets get a minimal new() that runs init().
Run with: busted spec/notes_spec.lua
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

local shown, closed = {}, {}

local screen = {
    bb = make_stub(),
    night_mode = false,
    getWidth = function() return 1400 end,
    getHeight = function() return 1800 end,
    scaleBySize = function(_, v) return v end,
    refreshFast = function() end,
    refreshUI = function() end,
}

local function widget_class(o)
    o = o or {}
    o.new = function(cls, t)
        t = setmetatable(t or {}, { __index = cls })
        if t.init then t:init() end
        return t
    end
    o.extend = function(cls, sub) return widget_class(setmetatable(sub or {}, { __index = cls })) end
    return o
end

local stubs = {
    ["device"] = setmetatable({ screen = screen }, {
        __index = function() return function() return true end end,
    }),
    ["ui/uimanager"] = setmetatable({
        show = function(_, w) table.insert(shown, w) end,
        close = function(_, w) table.insert(closed, w) end,
    }, { __index = function() return function() end end }),
    ["ui/time"] = {
        now = function() return 0 end,
        to_ms = function(t) return t end,
    },
    ["ui/geometry"] = { new = function(_, t) return t end },
    ["ui/widget/textwidget"] = {
        new = function(_, t)
            return {
                getSize = function() return { w = 40, h = 20 } end,
                paintTo = function() end,
                free = function() end,
            }
        end,
    },
    ["ui/widget/container/inputcontainer"] = widget_class(),
    ["ffi/util"] = {
        template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
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

local function new_pencil(opts)
    opts = opts or {}
    local p = setmetatable({
        tool = make_tool(PencilTool, { tool_settings = {
            pen = { color_name = "Black", width = 3, alpha = 1 },
            eraser = { width = 10 },
        } }),
        available_colors = {},
        annotation_groups = {},
        notes = {},
        refresh_interval_ms = 16,
        input_debug_mode = false,
        experimental_color_picker = false,
        experimental_pen_width = false,
        hold_menu = false,
        underline_hold = false,
        side_button_down = false,
        pen_down = false,
        view = opts.view or { paintTo = function() end },
        ui = opts.ui or { rolling = {}, document = {} },
    }, { __index = Pencil })
    p:initStrokeStore()
    p.isEnabled = function() return true end
    p.isOverlayActive = function() return false end
    p.transformCoordinates = function(_, x, y) return x, y end
    p.getCurrentPage = function() return 5 end
    p.getXPointerAtBboxCenter = function() return "/body/p[3].12" end
    p.drawLineSegment = function() end
    p.saved = 0
    p.saveStrokes = function(self) self.saved = self.saved + 1 end
    return p
end

local function pen(p, x, y, tool) p:handleStylusSlot(nil, { id = 1, x = x, y = y, tool = tool or 1 }) end
local function lift(p) p:handleStylusSlot(nil, { id = -1, tool = 1 }) end
local function tap_bar(p, name)
    for _, b in ipairs(p.note_canvas:barButtons()) do
        if b.name == name then
            pen(p, b.x + 5, b.y + 5)
            lift(p)
            return
        end
    end
    error("no bar button " .. name)
end

describe("note canvas (real main.lua)", function()
    it("creates a note at the hold position and records ink on the canvas", function()
        local p = new_pencil()
        p:openNoteAt(300, 400)
        assert.is_truthy(p.note_canvas)
        pen(p, 100, 500)
        pen(p, 200, 520)
        lift(p)
        local note = p.notes[1]
        assert.are.equal(5, note.page)
        assert.are.equal("/body/p[3].12", note.xpointer)
        assert.are.equal(1, #note.pages[1].strokes)
        assert.are.equal(2, #note.pages[1].strokes[1].points)
        assert.are.equal(0, #p.store.strokes) -- canvas ink never reaches the page
        tap_bar(p, "done")
        assert.is_nil(p.note_canvas)
        assert.are.equal(1, #p.notes)
        assert.is_true(p.saved > 0)
    end)

    it("drops a note that was closed without ink", function()
        local p = new_pencil()
        p:openNoteAt(300, 400)
        tap_bar(p, "done")
        assert.are.equal(0, #p.notes)
    end)

    it("reopens a note by tapping its marker, ignoring the rest of that contact", function()
        local p = new_pencil()
        p:openNoteAt(300, 400)
        pen(p, 100, 500)
        lift(p)
        tap_bar(p, "done")
        pen(p, 302, 398) -- on the marker
        assert.is_truthy(p.note_canvas)
        pen(p, 320, 420) -- same contact keeps moving: no ink
        lift(p)
        assert.are.equal(1, #p.notes[1].pages[1].strokes)
        assert.is_false(p.pen_down)
    end)

    it("erases, undoes, and pages through the canvas", function()
        local p = new_pencil()
        p:openNoteAt(300, 400)
        pen(p, 100, 500) pen(p, 200, 500) lift(p)
        pen(p, 100, 900) pen(p, 200, 900) lift(p)
        pen(p, 100, 500, 2) lift(p) -- eraser end over the first stroke
        assert.are.equal(1, #p.notes[1].pages[1].strokes)
        tap_bar(p, "undo")
        assert.are.equal(0, #p.notes[1].pages[1].strokes)
        pen(p, 100, 600) lift(p)
        tap_bar(p, "add")
        assert.are.equal(2, #p.notes[1].pages)
        assert.are.equal(2, p.note_canvas.page_index)
        pen(p, 100, 700) lift(p)
        tap_bar(p, "prev")
        assert.are.equal(1, p.note_canvas.page_index)
        assert.are.equal(1, #p.notes[1].pages[2].strokes)
    end)

    it("deletes a note from the canvas", function()
        local p = new_pencil()
        p:openNoteAt(300, 400)
        pen(p, 100, 500) lift(p)
        tap_bar(p, "delete")
        assert.are.equal(0, #p.notes)
    end)

    it("saves and loads notes", function()
        local p = new_pencil()
        p:openNoteAt(300, 400)
        pen(p, 100, 500) pen(p, 200, 520) lift(p)
        tap_bar(p, "done")
        local loaded = p:notesFromSaved(p:notesToSaveable())
        assert.are.equal(1, #loaded)
        assert.are.equal("/body/p[3].12", loaded[1].xpointer)
        assert.are.same({ { x = 100, y = 500 }, { x = 200, y = 520 } }, loaded[1].pages[1].strokes[1].points)
    end)

    it("anchors PDF notes in page coordinates", function()
        local view = {
            state = { page = 2, zoom = 2, offset = { x = 0, y = 0 } },
            visible_area = { x = 0, y = 0 },
            paintTo = function() end,
            screenToPageTransform = function(_, pos) return { x = pos.x / 2, y = pos.y / 2, page = 2 } end,
        }
        local p = new_pencil({ view = view, ui = { paging = {} } })
        p:openNoteAt(300, 400)
        pen(p, 100, 500) lift(p)
        tap_bar(p, "done")
        local note = p.notes[1]
        assert.are.equal(150, note.page_x)
        view.state.zoom = 1
        local x, y = p:getNoteMarkerPos(note)
        assert.are.equal(150, x)
        assert.are.equal(200, y)
    end)
end)
