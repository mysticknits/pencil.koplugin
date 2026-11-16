-- Object-based lasso selection for Pencil.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local PencilGeometry = require("lib/geometry")
local PencilStrokes = require("lib/pencilstrokes")
local _ = require("gettext")
local time = require("ui/time")

local PencilLasso = {}
PencilLasso.__index = PencilLasso

function PencilLasso:new(o)
    o = o or {}
    assert(o.plugin, "PencilLasso requires a plugin")
    return setmetatable(o, self)
end

-- Lasso: select strokes by circling them, then delete or drag them.
-- Phases: "armed" (waiting for the pen), "drawing" (path being drawn),
-- "selected" (buttons + selection box shown), "moving" (dragging).
-- The selection box and buttons are painted on the page by paintTo and
-- hit-tested here, so pen input keeps coming to the plugin (an overlay
-- widget would route the pen to KOReader's gestures instead).

local LASSO_MIN_RATIO = 0.6       -- Share of a stroke's points that must be inside
local LASSO_BOX_MARGIN = 8        -- Padding around the selection box
local LASSO_PREVIEW_MS = 40       -- Min interval between drag previews

function PencilLasso:start()
    self.state = { phase = "armed" }
end

-- Drop lasso state (and the drag snapshot) without repainting.
function PencilLasso:clear()
    local lasso = self.state
    if not lasso then return end
    if lasso.snapshot then
        lasso.snapshot:free()
        lasso.snapshot = nil
    end
    self.state = nil
end

function PencilLasso:cancel()
    if not self.state then return end
    self:clear()
    self.plugin:repaintReader()
end

-- Returns true while the lasso owns pen input.
function PencilLasso:isActive()
    return self.state ~= nil
end

function PencilLasso:handleStylus(slot)
    local lasso = self.state
    local raw_x = slot.x or self.plugin.pen_x or 0
    local raw_y = slot.y or self.plugin.pen_y or 0
    local x, y = self.plugin:transformCoordinates(raw_x, raw_y)
    local down = slot.id ~= nil and slot.id >= 0

    if lasso.phase == "armed" then
        if down then
            lasso.phase = "drawing"
            lasso.path = { { x = x, y = y } }
            self.plugin.pen_down = true
            self.plugin.dirty_region = nil
            self.plugin.stroke_fast_refresh = true
            self.plugin.last_refresh_time = time.now()
        end
    elseif lasso.phase == "drawing" then
        if down then
            local last = lasso.path[#lasso.path]
            if math.abs(x - last.x) + math.abs(y - last.y) >= 3 then
                table.insert(lasso.path, { x = x, y = y })
                self:drawSegment(last.x, last.y, x, y)
            end
        else
            self.plugin.pen_down = false
            self:finishPath()
        end
    elseif lasso.phase == "selected" then
        if down and not self.plugin.pen_down then
            self.plugin.pen_down = true
            local hit = self:hitTest(x, y)
            if hit == "delete" then
                self:deleteSelection()
            elseif hit == "done" then
                self:cancel()
            elseif hit == "inside" then
                lasso.phase = "moving"
                lasso.from = { x = x, y = y }
                lasso.dx, lasso.dy = 0, 0
                lasso.preview_time = time.now()
                -- The page as shown now; the drag preview only moves an
                -- outline over it, restoring pixels from this copy.
                lasso.snapshot = Screen.bb:copy()
            else
                self:cancel()
            end
        elseif not down then
            self.plugin.pen_down = false
        end
    elseif lasso.phase == "moving" then
        if down then
            lasso.dx, lasso.dy = x - lasso.from.x, y - lasso.from.y
            local now = time.now()
            if time.to_ms(now - lasso.preview_time) >= LASSO_PREVIEW_MS then
                lasso.preview_time = now
                self:previewDrag()
            end
        else
            self.plugin.pen_down = false
            self:applyMove()
        end
    end
    return true
end

-- Draw a piece of the lasso path as a thin gray line, refreshed in batches.
function PencilLasso:drawSegment(x1, y1, x2, y2)
    PencilStrokes.drawThickLine(Screen.bb, x1, y1, x2, y2, 2, Blitbuffer.COLOR_DARK_GRAY)
    local x0, y0 = math.min(x1, x2) - 3, math.min(y1, y2) - 3
    local w, h = math.abs(x2 - x1) + 6, math.abs(y2 - y1) + 6
    local r = self.plugin.dirty_region
    if r then
        local rx2, ry2 = math.max(r.x + r.w, x0 + w), math.max(r.y + r.h, y0 + h)
        r.x, r.y = math.min(r.x, x0), math.min(r.y, y0)
        r.w, r.h = rx2 - r.x, ry2 - r.y
    else
        self.plugin.dirty_region = { x = x0, y = y0, w = w, h = h }
    end
    local now = time.now()
    if time.to_ms(now - self.plugin.last_refresh_time) >= self.plugin.refresh_interval_ms then
        self.plugin.last_refresh_time = now
        self.plugin:refreshDirtyRegion()
    end
end

-- Strokes that can be selected: the ones drawn on screen right now.
function PencilLasso:visibleStrokes()
    local out = {}
    local pages, page = self.plugin:getVisiblePages()
    for _, p in ipairs(pages) do
        for _, idx in ipairs(self.plugin.store.page_strokes[p] or {}) do
            local stroke = self.plugin.store.strokes[idx]
            if stroke then
                if stroke.page_points then
                    if self.plugin:syncStrokeToView(stroke) then table.insert(out, stroke) end
                elseif p == page then
                    table.insert(out, stroke)
                end
            end
        end
    end
    return out
end

function PencilLasso:finishPath()
    local lasso = self.state
    self.plugin.dirty_region = nil
    local path = lasso.path
    if not path or #path < 3 then
        self:cancel()
        return
    end
    local selected, bbox = {}, nil
    for _, stroke in ipairs(self:visibleStrokes()) do
        if PencilGeometry.strokeInPolygon(stroke, path, LASSO_MIN_RATIO) then
            local b = PencilGeometry.computeStrokeBbox(stroke)

            if b and b.x0 and b.y0 and b.x1 and b.y1 then
                table.insert(selected, stroke)
                bbox = bbox and PencilGeometry.bboxUnion(bbox, b) or b
            end
        end
    end
    lasso.path = nil
    if #selected == 0 then
        self:cancel()
        return
    end
    lasso.strokes = selected
    lasso.bbox = PencilGeometry.bboxExpand(bbox, LASSO_BOX_MARGIN)
    lasso.phase = "selected"
    self:repaint(false)
end

-- Selection box (offset by the current drag) and button rects.
function PencilLasso:layout()
    local lasso = self.state
    local b = lasso.bbox
    local dx, dy = lasso.dx or 0, lasso.dy or 0
    local box = { x = b.x0 + dx, y = b.y0 + dy, w = b.x1 - b.x0, h = b.y1 - b.y0 }
    local bw, bh = Screen:scaleBySize(90), Screen:scaleBySize(40)
    local gap = Screen:scaleBySize(8)
    local by = box.y - bh - gap
    if by < 0 then by = box.y + box.h + gap end
    by = math.min(by, Screen:getHeight() - bh)
    local bx = math.max(0, math.min(box.x, Screen:getWidth() - 2 * bw - gap))
    return box, {
        { name = "delete", label = _("Delete"), x = bx, y = by, w = bw, h = bh },
        { name = "done", label = _("Done"), x = bx + bw + gap, y = by, w = bw, h = bh },
    }
end

function PencilLasso:hitTest(x, y)
    local box, buttons = self:layout()
    for _, b in ipairs(buttons) do
        if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
            return b.name
        end
    end
    if x >= box.x and x < box.x + box.w and y >= box.y and y < box.y + box.h then
        return "inside"
    end
end

-- Painted by paintTo while a selection exists.
function PencilLasso:paintTo(bb)
    if not (self.state and self.state.strokes) then return end
    local box, buttons = self:layout()
    bb:paintBorder(box.x, box.y, box.w, box.h, 2, Blitbuffer.COLOR_DARK_GRAY)
    if self.state.phase == "moving" then return end
    local face = Font:getFace("cfont", 18)
    for _, b in ipairs(buttons) do
        bb:paintRect(b.x, b.y, b.w, b.h, Blitbuffer.COLOR_WHITE)
        bb:paintBorder(b.x, b.y, b.w, b.h, 2, Blitbuffer.COLOR_BLACK)
        local label = TextWidget:new{ text = b.label, face = face, max_width = b.w - 4 }
        local size = label:getSize()
        label:paintTo(bb, b.x + math.floor((b.w - size.w) / 2), b.y + math.floor((b.h - size.h) / 2))
        label:free()
    end
end

function PencilLasso:repaint(fast)
    local target = self.plugin.ui and (self.plugin.ui.dialog or self.plugin.ui) or self.plugin.view
    UIManager:setDirty(target, fast and "partial" or "ui")
end

-- Move the selection outline to the current drag offset: restore the old
-- outline's pixels from the snapshot, draw the new one, refresh just that.
function PencilLasso:previewDrag()
    local lasso = self.state
    local snap = lasso.snapshot
    if not snap then return end
    local box = self:layout()
    local bb = Screen.bb
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local function clamp(r)
        local x0, y0 = math.max(0, r.x), math.max(0, r.y)
        local x1, y1 = math.min(sw, r.x + r.w), math.min(sh, r.y + r.h)
        if x1 <= x0 or y1 <= y0 then return nil end
        return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    end
    local function restore(r)
        local c = clamp(r)
        if c then bb:blitFrom(snap, c.x, c.y, c.x, c.y, c.w, c.h) end
    end
    local prev = lasso.prev_box
    if prev then
        local t = 2
        restore({ x = prev.x, y = prev.y, w = prev.w, h = t })
        restore({ x = prev.x, y = prev.y + prev.h - t, w = prev.w, h = t })
        restore({ x = prev.x, y = prev.y, w = t, h = prev.h })
        restore({ x = prev.x + prev.w - t, y = prev.y, w = t, h = prev.h })
    end
    local c = clamp(box)
    if c then bb:paintBorder(c.x, c.y, c.w, c.h, 2, Blitbuffer.COLOR_DARK_GRAY) end
    local area = prev and {
        x = math.min(prev.x, box.x), y = math.min(prev.y, box.y),
        w = math.max(prev.x + prev.w, box.x + box.w) - math.min(prev.x, box.x),
        h = math.max(prev.y + prev.h, box.y + box.h) - math.min(prev.y, box.y),
    } or box
    area = clamp(area)
    if area then Screen:refreshFast(area.x, area.y, area.w, area.h) end
    lasso.prev_box = box
end

function PencilLasso:deleteSelection()
    local selected = self.state.strokes
    self:clear()
    -- Their baked PDF ink goes too (undo restores them as overlay ink).
    self.plugin:deleteEmbeddedAnnotationsFor(selected)
    if self.plugin.store:removeStrokes(selected) then
        self.plugin.store:pushUndo({ type = "delete", strokes = selected })
    end
    self.plugin:afterHistoryChange()
end

function PencilLasso:applyMove()
    local lasso = self.state
    local dx, dy = lasso.dx or 0, lasso.dy or 0
    if lasso.snapshot then
        lasso.snapshot:free()
        lasso.snapshot = nil
    end
    lasso.prev_box = nil
    if math.abs(dx) + math.abs(dy) < 3 then
        -- A tap inside the box: keep the selection.
        lasso.phase = "selected"
        lasso.dx, lasso.dy = 0, 0
        self:repaint(false)
        return
    end
    self:clear()
    local pdeltas = self.plugin:translateStrokes(lasso.strokes, dx, dy)
    self.plugin.store:pushUndo({ type = "move", strokes = lasso.strokes, dx = dx, dy = dy, pdeltas = pdeltas })
    self.plugin:afterHistoryChange()
end

return PencilLasso
