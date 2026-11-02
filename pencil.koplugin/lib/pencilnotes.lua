-- Notes subsystem for the Pencil plugin.
-- Owns note state, marker rendering, persistence, and the private canvas.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local PencilGeometry = require("lib/geometry")
local PencilStrokes = require("lib/pencilstrokes")
local PencilTool = require("lib/penciltool")
local _ = require("gettext")
local T = require("ffi/util").template
local time = require("ui/time")

local TOOL_PEN = PencilTool.TOOLS.PEN
local TOOL_ERASER = PencilTool.TOOLS.ERASER
local NoteCanvas

local PencilNotes = {}
PencilNotes.__index = PencilNotes

function PencilNotes:new(o)
    o = o or {}
    o.items = o.items or {}
    return setmetatable(o, self)
end

function PencilNotes:isOpen()
    return self.canvas ~= nil
end

function PencilNotes:handleStylus(slot)
    if not self.canvas then return false end
    return self.canvas:handleStylus(slot)
end

-- Notes: a full-screen canvas for longer handwriting, anchored to a spot in
-- the book and shown there as a small marker. Created from the hold-pen
-- menu; reopened by tapping the marker with the pen.
--
-- note = {
--     id, datetime, page, x, y,       -- anchor; x/y are screen coords at creation
--     xpointer,                        -- EPUB: follows reflow
--     page_x, page_y,                  -- PDF: page coordinates
--     pages = { { strokes = { { points, width, color_name } } } },
-- }

local NOTE_MARKER_SIZE = 28
local NOTE_MARKER_HIT_PAD = 12

-- Screen position of a note's marker on the current view, or nil when the
-- note isn't on a visible page.
function PencilNotes:getMarkerPos(note)
    if self.plugin.ui.paging then
        local zoom, ox, oy = self.plugin:pageAffine(note.page)
        if not zoom or not note.page_x then return nil end
        return note.page_x * zoom + ox, note.page_y * zoom + oy
    end
    if self.plugin:getGroupCurrentPage(note) ~= self.plugin:getCurrentPage() then return nil end
    local y = note.y
    if note.xpointer and self.plugin.ui.document and self.plugin.ui.document.getScreenPositionFromXPointer then
        local ok, sy = pcall(self.plugin.ui.document.getScreenPositionFromXPointer, self.plugin.ui.document, note.xpointer)
        if ok and sy then y = sy end
    end
    return note.x, y
end

function PencilNotes:getMarkerRect(note)
    local x, y = self:getMarkerPos(note)
    if not x then return nil end
    local size = NOTE_MARKER_SIZE
    local rx = math.max(0, math.min(math.floor(x - size / 2), Screen:getWidth() - size))
    local ry = math.max(0, math.min(math.floor(y - size / 2), Screen:getHeight() - size))
    return { x = rx, y = ry, w = size, h = size }
end

function PencilNotes:findMarkerAt(x, y)
    for _, note in ipairs(self.items or {}) do
        local r = self:getMarkerRect(note)
        if r and x >= r.x - NOTE_MARKER_HIT_PAD and x <= r.x + r.w + NOTE_MARKER_HIT_PAD
                and y >= r.y - NOTE_MARKER_HIT_PAD and y <= r.y + r.h + NOTE_MARKER_HIT_PAD then
            return note
        end
    end
end

-- A small "page with lines" icon.
function PencilNotes:paintTo(bb)
    for _, note in ipairs(self.items or {}) do
        local r = self:getMarkerRect(note)
        if r then
            bb:paintRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE)
            bb:paintBorder(r.x, r.y, r.w, r.h, 2, Blitbuffer.COLOR_BLACK)
            local inset = math.floor(r.w / 5)
            for i = 1, 3 do
                bb:paintRect(r.x + inset, r.y + i * math.floor(r.h / 4), r.w - 2 * inset, 2, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

-- Create a note anchored at screen position (x, y) and open it.
function PencilNotes:openAt(x, y)
    local note = {
        id = "note_" .. os.date("%Y%m%d%H%M%S") .. "_" .. tostring(#(self.items or {}) + 1),
        datetime = os.time(),
        page = self.plugin:getCurrentPage(),
        x = x,
        y = y,
        pages = { { strokes = {} } },
    }
    if self.plugin.ui.paging then
        local pos = self.plugin.view:screenToPageTransform({ x = x, y = y })
        if pos and pos.page then
            note.page = pos.page
            local zoom, ox, oy = self.plugin:pageAffine(pos.page)
            if zoom then
                note.page_x, note.page_y = (x - ox) / zoom, (y - oy) / zoom
            end
        end
    elseif self.plugin.ui.rolling then
        note.xpointer = self.plugin:getXPointerAtBboxCenter({ x0 = x, y0 = y, x1 = x, y1 = y })
    end
    self.items = self.items or {}
    table.insert(self.items, note)
    self:open(note)
end

-- @param wait_lift ignore the pen contact that opened the note
function PencilNotes:open(note, wait_lift)
    if self.canvas then return end
    -- The canvas takes over pen input, including the rest of this contact.
    self.plugin.pen_down = false
    self.plugin.current_stroke = nil
    self.canvas = NoteCanvas:new{
        owner = self,
        plugin = self.plugin,
        note = note,
        wait_lift = wait_lift,
    }
    UIManager:show(self.canvas)
    UIManager:setDirty(self.canvas, "ui")
end

local function noteHasInk(note)
    for _, page in ipairs(note.pages or {}) do
        if #page.strokes > 0 then return true end
    end
    return false
end

function PencilNotes:remove(note)
    for i, n in ipairs(self.items or {}) do
        if n == note then
            table.remove(self.items, i)
            return
        end
    end
end

-- Close the canvas; notes left empty are dropped.
function PencilNotes:close(delete)
    local canvas = self.canvas
    if not canvas then return end
    self.canvas = nil
    UIManager:close(canvas)
    if delete or not noteHasInk(canvas.note) then
        self:remove(canvas.note)
    end
    self.plugin:saveStrokes()
    self.plugin:repaintReader()
end

function PencilNotes:serialize()
    local out = {}
    for _, note in ipairs(self.items or {}) do
        local pages = {}
        for i, page in ipairs(note.pages) do
            local strokes = {}
            for j, s in ipairs(page.strokes) do
                strokes[j] = { p = PencilGeometry.packPoints(s.points), width = s.width, color_name = s.color_name }
            end
            pages[i] = { strokes = strokes }
        end
        table.insert(out, {
            id = note.id, datetime = note.datetime, page = note.page,
            x = note.x, y = note.y, xpointer = note.xpointer,
            page_x = note.page_x, page_y = note.page_y,
            pages = pages,
        })
    end
    return out
end

function PencilNotes:deserialize(saved)
    local notes = {}
    for _, n in ipairs(saved or {}) do
        local pages = {}
        for i, page in ipairs(n.pages or {}) do
            local strokes = {}
            for j, s in ipairs(page.strokes or {}) do
                strokes[j] = { points = PencilGeometry.unpackPoints(s.p), width = s.width, color_name = s.color_name }
            end
            pages[i] = { strokes = strokes }
        end
        if #pages == 0 then pages[1] = { strokes = {} } end
        table.insert(notes, {
            id = n.id, datetime = n.datetime, page = n.page,
            x = n.x, y = n.y, xpointer = n.xpointer,
            page_x = n.page_x, page_y = n.page_y,
            pages = pages,
        })
    end
    self.items = notes
    return self.items
end

-- Full-screen writing canvas for one note. Pen input is routed here by
-- Pencil:handleStylusSlot while it's open; the top bar works with both pen
-- and finger.
NoteCanvas = InputContainer:extend{
    owner = nil,
    plugin = nil,
    note = nil,
    wait_lift = false,
    page_index = 1,
}

function NoteCanvas:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.bar_h = Screen:scaleBySize(48)
    self.page_index = 1
    self.ges_events = {
        TapBar = {
            GestureRange:new{
                ges = "tap",
                range = function() return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = self.bar_h } end,
            },
        },
    }
end

function NoteCanvas:currentPage()
    return self.note.pages[self.page_index]
end

function NoteCanvas:barButtons()
    local labels = {
        { name = "done", label = _("Done") },
        { name = "undo", label = _("Undo") },
        { name = "prev", label = _("Prev") },
        { name = "page", label = T("%1/%2", self.page_index, #self.note.pages) },
        { name = "next", label = _("Next") },
        { name = "add", label = _("+ Page") },
        { name = "delete", label = _("Delete") },
    }
    local w = math.floor(Screen:getWidth() / #labels)
    for i, b in ipairs(labels) do
        b.x, b.y, b.w, b.h = (i - 1) * w, 0, w, self.bar_h
    end
    return labels
end

function NoteCanvas:hitBar(x, y)
    if y < 0 or y >= self.bar_h then return nil end
    for _, b in ipairs(self:barButtons()) do
        if x >= b.x and x < b.x + b.w then return b.name end
    end
end

function NoteCanvas:runBarAction(name)
    local plugin = self.plugin
    if name == "done" then
        self.owner:close(false)
        return
    elseif name == "delete" then
        self.owner:close(true)
        return
    elseif name == "undo" then
        table.remove(self:currentPage().strokes)
    elseif name == "prev" then
        self.page_index = math.max(1, self.page_index - 1)
    elseif name == "next" then
        self.page_index = math.min(#self.note.pages, self.page_index + 1)
    elseif name == "add" then
        table.insert(self.note.pages, self.page_index + 1, { strokes = {} })
        self.page_index = self.page_index + 1
    else
        return
    end
    self:repaint()
end

function NoteCanvas:onTapBar(_, ges)
    local name = ges and ges.pos and self:hitBar(ges.pos.x, ges.pos.y)
    if name then self:runBarAction(name) end
    return true
end

function NoteCanvas:strokeColor(stroke)
    for _, c in ipairs(self.plugin.available_colors or {}) do
        if c.name == stroke.color_name then return c.color end
    end
    return Blitbuffer.COLOR_BLACK
end

function NoteCanvas:renderStroke(bb, stroke)
    local pts = stroke.points
    local color = self:strokeColor(stroke)
    if #pts == 1 then
        local half = math.floor(stroke.width / 2)
        bb:paintRectRGB32(pts[1].x - half, pts[1].y - half, stroke.width, stroke.width, color)
        return
    end
    for i = 2, #pts do
        PencilStrokes.drawThickLine(bb, pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y, stroke.width, color)
    end
end

function NoteCanvas:paintTo(bb)
    local w, h = Screen:getWidth(), Screen:getHeight()
    bb:paintRect(0, 0, w, h, Blitbuffer.COLOR_WHITE)
    local face = Font:getFace("cfont", 18)
    for _, b in ipairs(self:barButtons()) do
        bb:paintBorder(b.x, b.y, b.w, b.h, 1, Blitbuffer.COLOR_DARK_GRAY)
        local label = TextWidget:new{ text = b.label, face = face, max_width = b.w - 4 }
        local size = label:getSize()
        label:paintTo(bb, b.x + math.floor((b.w - size.w) / 2), b.y + math.floor((b.h - size.h) / 2))
        label:free()
    end
    bb:paintRect(0, self.bar_h, w, 2, Blitbuffer.COLOR_BLACK)
    for _, stroke in ipairs(self:currentPage().strokes) do
        self:renderStroke(bb, stroke)
    end
end

function NoteCanvas:repaint()
    self:paintTo(Screen.bb)
    Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
end

function NoteCanvas:isEraser(slot)
    local plugin = self.plugin
    return plugin.tool:getEffectiveToolForSlot(slot, plugin.side_button_down) == TOOL_ERASER
end

function NoteCanvas:eraseAt(x, y)
    local strokes = self:currentPage().strokes
    local settings = self.plugin.tool:getToolSettings(TOOL_ERASER)
    local radius = (settings and settings.width) or 20
    local erased = false
    for i = #strokes, 1, -1 do
        if PencilGeometry.isPointNearStroke(x, y, strokes[i], radius) then
            table.remove(strokes, i)
            erased = true
        end
    end
    if erased then self:repaint() end
end

-- Pen input while the canvas is open. Always consumes the event.
function NoteCanvas:handleStylus(slot)
    local plugin = self.plugin
    local down = slot.id ~= nil and slot.id >= 0
    if self.wait_lift then
        if not down then self.wait_lift = false end
        return true
    end
    local x, y = plugin:transformCoordinates(slot.x or self.last_x or 0, slot.y or self.last_y or 0)

    if not down then
        if self.stroke then
            -- Show what was drawn since the last batched refresh.
            plugin:refreshDirtyRegion()
            self.stroke = nil
        elseif self.contact and self.contact.bar then
            local name = self:hitBar(self.contact.x, self.contact.y)
            self.contact = nil
            if name then self:runBarAction(name) end
            return true
        end
        self.contact = nil
        return true
    end

    if self:isEraser(slot) then
        self.contact = self.contact or {}
        self:eraseAt(x, y)
        self.last_x, self.last_y = x, y
        return true
    end

    if not self.contact then
        -- New contact: the bar takes taps, the page takes ink.
        self.contact = { x = x, y = y, bar = y < self.bar_h }
        if self.contact.bar then return true end
        local settings = plugin.tool:getToolSettings(TOOL_PEN)
        self.stroke = { points = { { x = x, y = y } }, width = settings.width, color_name = settings.color_name }
        table.insert(self:currentPage().strokes, self.stroke)
        plugin.stroke_fast_refresh = true
        plugin.dirty_region = nil
        plugin.last_refresh_time = time.now()
        self:drawLive(x, y, x, y)
    elseif self.stroke and (x ~= self.last_x or y ~= self.last_y) then
        table.insert(self.stroke.points, { x = x, y = y })
        self:drawLive(self.last_x, self.last_y, x, y)
    end
    self.last_x, self.last_y = x, y
    return true
end

-- Draw a segment straight to the framebuffer and refresh in batches,
-- reusing the reader's low-latency path.
function NoteCanvas:drawLive(x1, y1, x2, y2)
    local plugin = self.plugin
    local width = self.stroke.width
    PencilStrokes.drawThickLine(Screen.bb, x1, y1, x2, y2, width, self:strokeColor(self.stroke))
    local pad = math.floor(width / 2) + 2
    local x0, y0 = math.min(x1, x2) - pad, math.min(y1, y2) - pad
    local w, h = math.abs(x2 - x1) + 2 * pad, math.abs(y2 - y1) + 2 * pad
    local r = plugin.dirty_region
    if r then
        local rx2, ry2 = math.max(r.x + r.w, x0 + w), math.max(r.y + r.h, y0 + h)
        r.x, r.y = math.min(r.x, x0), math.min(r.y, y0)
        r.w, r.h = rx2 - r.x, ry2 - r.y
    else
        plugin.dirty_region = { x = x0, y = y0, w = w, h = h }
    end
    local now = time.now()
    if time.to_ms(now - plugin.last_refresh_time) >= plugin.refresh_interval_ms then
        plugin.last_refresh_time = now
        plugin:refreshDirtyRegion()
    end
end


return PencilNotes
