--[[--
Geometry utilities for Pencil plugin.
Pure functions for stroke geometry calculations.

@module pencil.lib.geometry
--]]--

local Geometry = {}

--- Check if a point is near any point in a stroke.
-- Uses squared distance comparison to avoid sqrt for performance.
-- @param px X coordinate of point to check
-- @param py Y coordinate of point to check
-- @param stroke Table with points array
-- @param threshold Distance threshold (default 20)
-- @return boolean True if point is within threshold of any stroke point
function Geometry.isPointNearStroke(px, py, stroke, threshold)
    if not stroke or not stroke.points then
        return false
    end

    threshold = threshold or 20
    local threshold_sq = threshold * threshold

    for _, point in ipairs(stroke.points) do
        local dx = px - point.x
        local dy = py - point.y
        if dx * dx + dy * dy <= threshold_sq then
            return true
        end
    end
    return false
end

-- Rotation mode constants (matches KOReader's framebuffer constants)
Geometry.ROTATION_UPRIGHT = 0
Geometry.ROTATION_CLOCKWISE = 1
Geometry.ROTATION_UPSIDE_DOWN = 2
Geometry.ROTATION_COUNTER_CLOCKWISE = 3

--- Transform coordinates based on screen rotation.
-- Converts from hardware/physical coordinate space to logical/display space.
-- @param x Raw X coordinate from hardware
-- @param y Raw Y coordinate from hardware
-- @param rotation Rotation mode (0=upright, 1=CW, 2=upside-down, 3=CCW)
-- @param screen_width Current logical screen width
-- @param screen_height Current logical screen height
-- @return number, number Transformed X and Y coordinates
function Geometry.transformForRotation(x, y, rotation, screen_width, screen_height)
    if rotation == Geometry.ROTATION_UPRIGHT then
        return x, y
    elseif rotation == Geometry.ROTATION_CLOCKWISE then
        return screen_width - y, x
    elseif rotation == Geometry.ROTATION_UPSIDE_DOWN then
        return screen_width - x, screen_height - y
    elseif rotation == Geometry.ROTATION_COUNTER_CLOCKWISE then
        return y, screen_height - x
    end
    return x, y  -- fallback for unknown rotation
end

--- Number of interpolation steps to rasterize a segment of length `dist`
--- with a pen of the given width. Steps by ~half the width so consecutive
--- width×width squares overlap enough to leave no gaps, without painting
--- every pixel ~width times over (which is what stepping by 1px does).
-- @param dist segment length in pixels
-- @param width pen width in pixels
-- @return number step count (>= 1)
function Geometry.segmentStepCount(dist, width)
    local step = math.max(1, math.floor(width / 2))
    return math.max(1, math.ceil(dist / step))
end

--- Compute the bounding box of a stroke from its points array.
-- @param stroke Table with points array (each point has x, y)
-- @return table {x0, y0, x1, y1} or nil if no points
function Geometry.computeStrokeBbox(stroke)
    if not stroke or not stroke.points or #stroke.points == 0 then
        return nil
    end
    local p = stroke.points[1]
    local x0, y0, x1, y1 = p.x, p.y, p.x, p.y
    for i = 2, #stroke.points do
        p = stroke.points[i]
        if p.x < x0 then x0 = p.x end
        if p.y < y0 then y0 = p.y end
        if p.x > x1 then x1 = p.x end
        if p.y > y1 then y1 = p.y end
    end
    return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

--- Compute minimum pixel distance between two bounding boxes.
-- Returns 0 if the boxes overlap.
-- @param a table {x0, y0, x1, y1}
-- @param b table {x0, y0, x1, y1}
-- @return number minimum distance in pixels
function Geometry.bboxDistance(a, b)
    -- Compute gap on each axis (negative means overlap)
    local dx = math.max(a.x0 - b.x1, b.x0 - a.x1, 0)
    local dy = math.max(a.y0 - b.y1, b.y0 - a.y1, 0)
    if dx == 0 and dy == 0 then
        return 0  -- overlapping
    elseif dx == 0 then
        return dy
    elseif dy == 0 then
        return dx
    else
        return math.sqrt(dx * dx + dy * dy)
    end
end

--- Compute the union of two bounding boxes.
-- @param a table {x0, y0, x1, y1}
-- @param b table {x0, y0, x1, y1}
-- @return table {x0, y0, x1, y1}
function Geometry.bboxUnion(a, b)
    return {
        x0 = math.min(a.x0, b.x0),
        y0 = math.min(a.y0, b.y0),
        x1 = math.max(a.x1, b.x1),
        y1 = math.max(a.y1, b.y1),
    }
end

--- Expand a bounding box by margin pixels on each side.
-- @param bbox table {x0, y0, x1, y1}
-- @param margin number pixels to expand on each side
-- @return table {x0, y0, x1, y1}
function Geometry.bboxExpand(bbox, margin)
    return {
        x0 = bbox.x0 - margin,
        y0 = bbox.y0 - margin,
        x1 = bbox.x1 + margin,
        y1 = bbox.y1 + margin,
    }
end

--- Clamp a bounding box to fit within screen bounds.
-- @param bbox table {x0, y0, x1, y1}
-- @param sw number screen width
-- @param sh number screen height
-- @return table {x0, y0, x1, y1}
function Geometry.bboxClampToScreen(bbox, sw, sh)
    return {
        x0 = math.max(0, math.min(bbox.x0, sw)),
        y0 = math.max(0, math.min(bbox.y0, sh)),
        x1 = math.max(0, math.min(bbox.x1, sw)),
        y1 = math.max(0, math.min(bbox.y1, sh)),
    }
end

--- Compute a full-screen-width capture strip rect for an annotation bbox.
-- The strip vertically encloses the bbox plus v_margin on each side, is
-- floored at min_h px tall (extending around the bbox center), and is
-- shifted back onto the screen if a side runs off so the min-height
-- contract is preserved. Finally clamped to the screen.
-- @param bbox table {y0, y1} (x ignored; strip is always full-width)
-- @param sw number screen width
-- @param sh number screen height
-- @param v_margin number padding above/below the bbox before min_h applies
-- @param min_h number minimum strip height (legibility floor)
-- @return table {x0, y0, x1, y1} where x0=0 and x1=sw
function Geometry.captureStripRect(bbox, sw, sh, v_margin, min_h)
    local bbox_h = bbox.y1 - bbox.y0
    local strip_h = math.max(bbox_h + 2 * v_margin, min_h)
    strip_h = math.min(strip_h, sh)
    local cy = (bbox.y0 + bbox.y1) / 2
    local y0 = math.floor(cy - strip_h / 2)
    local y1 = math.floor(cy + strip_h / 2)
    -- Shift back onscreen rather than clamp-and-chop, so a near-edge bbox
    -- still produces a min_h-tall strip (when screen has room for it).
    if y0 < 0 then
        y1 = y1 - y0
        y0 = 0
    end
    if y1 > sh then
        y0 = y0 - (y1 - sh)
        y1 = sh
    end
    y0 = math.max(0, y0)
    y1 = math.min(sh, y1)
    return { x0 = 0, y0 = y0, x1 = sw, y1 = y1 }
end

return Geometry
