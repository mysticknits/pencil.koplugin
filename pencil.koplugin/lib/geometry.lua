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

--- Pack a points array ({x=,y=} list) into a compact "x y x y ..." string.
-- Saving points as tiny tables makes the serializer emit a key + indentation per
-- element (tens of thousands of them); packing to one string per stroke keeps
-- the serializer cost proportional to stroke count, not point count.
-- @param points array of {x=, y=} (may be nil/empty)
-- @return string space-separated coordinates ("" when empty)
function Geometry.packPoints(points)
    if not points or #points == 0 then return "" end
    local buf = {}
    local n = 0
    for i = 1, #points do
        local p = points[i]
        n = n + 1; buf[n] = p.x or 0
        n = n + 1; buf[n] = p.y or 0
    end
    return table.concat(buf, " ")
end

--- Inverse of packPoints: parse "x y x y ..." back into a {x=,y=} array.
-- Tolerates ints, floats and negatives. Returns {} for nil/empty input.
-- @param str packed string from packPoints
-- @return array of {x=, y=}
function Geometry.unpackPoints(str)
    local points = {}
    if not str or str == "" then return points end
    local nums, k = {}, 0
    for tok in str:gmatch("%S+") do
        k = k + 1
        nums[k] = tonumber(tok)
    end
    local pi = 0
    for i = 1, k - 1, 2 do
        if nums[i] and nums[i + 1] then
            pi = pi + 1
            points[pi] = { x = nums[i], y = nums[i + 1] }
        end
    end
    return points
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

--- Top-left corners of the width×width squares stamped along a segment.
-- This is the brush shape of a stroke: Pencil:drawThickLine paints exactly these
-- squares, and a highlighter stroke blends exactly their union (see Coverage).
-- @return flat array { x1, y1, x2, y2, ... } (top-left corners)
function Geometry.segmentStamps(x1, y1, x2, y2, width)
    local half_w = math.floor(width / 2)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then
        return { math.floor(x1) - half_w, math.floor(y1) - half_w }
    end
    local steps = Geometry.segmentStepCount(dist, width)
    local out = {}
    for i = 0, steps do
        local t = i / steps
        out[#out + 1] = math.floor(x1 + dx * t) - half_w
        out[#out + 1] = math.floor(y1 + dy * t) - half_w
    end
    return out
end

--[[ Coverage: the set of pixels painted so far, kept as sorted, disjoint
horizontal spans per pixel row. A highlighter is translucent, so painting
overlapping stamps would blend the same pixel several times and show dark
blobs; adding a stamp to a Coverage tells which pixels are NEW, so each pixel
is blended exactly once.

cov[y] = { {x0, x1}, ... } with x1 exclusive, sorted by x0, never touching. ]]

function Geometry.newCoverage()
    return {}
end

-- Add [a, b) to a row's span list. Returns the new list; if `new_parts` is a
-- table, the sub-spans of [a, b) that were not covered before are appended.
local function addSpan(spans, a, b, new_parts)
    local n = #spans
    local i = 1
    local out = {}
    while i <= n and spans[i][2] < a do
        out[#out + 1] = spans[i]
        i = i + 1
    end
    local merged_a, merged_b = a, b
    local pos = a  -- everything in [a, pos) is already covered
    while i <= n and spans[i][1] <= b do
        local sp = spans[i]
        if sp[1] > pos and new_parts then
            new_parts[#new_parts + 1] = { pos, sp[1] }
        end
        if sp[2] > pos then pos = sp[2] end
        if sp[1] < merged_a then merged_a = sp[1] end
        if sp[2] > merged_b then merged_b = sp[2] end
        i = i + 1
    end
    if pos < b and new_parts then
        new_parts[#new_parts + 1] = { pos, b }
    end
    out[#out + 1] = { merged_a, merged_b }
    while i <= n do
        out[#out + 1] = spans[i]
        i = i + 1
    end
    return out
end

local function sameParts(p, q)
    if #p ~= #q then return false end
    for i = 1, #p do
        if p[i][1] ~= q[i][1] or p[i][2] ~= q[i][2] then return false end
    end
    return true
end

--- Add the rectangle (x, y, w, h) to a coverage.
-- @param collect if true, return the newly covered pixels as an array of
--   rectangles { x =, y =, w =, h = } (rows with identical new spans merged
--   vertically); otherwise return nil (cheaper)
function Geometry.coverageAddRect(cov, x, y, w, h, collect)
    local rects, open, open_parts
    for row = y, y + h - 1 do
        local parts = collect and {} or nil
        cov[row] = addSpan(cov[row] or {}, x, x + w, parts)
        if collect then
            if #parts == 0 then
                open, open_parts = nil, nil
            elseif open and sameParts(parts, open_parts) then
                for _, r in ipairs(open) do r.h = r.h + 1 end
            else
                open, open_parts = {}, parts
                rects = rects or {}
                for _, pt in ipairs(parts) do
                    local r = { x = pt[1], y = row, w = pt[2] - pt[1], h = 1 }
                    open[#open + 1] = r
                    rects[#rects + 1] = r
                end
            end
        end
    end
    return rects or (collect and {} or nil)
end

--- All covered pixels as rectangles, rows with identical spans merged.
function Geometry.coverageRects(cov)
    local ys = {}
    for row in pairs(cov) do ys[#ys + 1] = row end
    table.sort(ys)
    local rects, open, open_spans, open_row = {}, nil, nil, nil
    for _, row in ipairs(ys) do
        local spans = cov[row]
        if open and open_row == row - 1 and sameParts(spans, open_spans) then
            for _, r in ipairs(open) do r.h = r.h + 1 end
        else
            open, open_spans = {}, spans
            for _, sp in ipairs(spans) do
                local r = { x = sp[1], y = row, w = sp[2] - sp[1], h = 1 }
                open[#open + 1] = r
                rects[#rects + 1] = r
            end
        end
        open_row = row
    end
    return rects
end

--- The rectangles a stroke of `points` painted with a `width` brush covers,
-- each pixel once. A one-point stroke is a single stamp.
function Geometry.strokeCoverageRects(points, width)
    local cov = Geometry.newCoverage()
    if #points == 1 then
        local st = Geometry.segmentStamps(points[1].x, points[1].y, points[1].x, points[1].y, width)
        Geometry.coverageAddRect(cov, st[1], st[2], width, width)
    else
        for i = 2, #points do
            local p1, p2 = points[i - 1], points[i]
            local st = Geometry.segmentStamps(p1.x, p1.y, p2.x, p2.y, width)
            for j = 1, #st, 2 do
                Geometry.coverageAddRect(cov, st[j], st[j + 1], width, width)
            end
        end
    end
    return Geometry.coverageRects(cov)
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

--- Check if a point lies inside a polygon (even-odd rule).
-- @param x number
-- @param y number
-- @param poly array of {x, y}; closed implicitly
-- @return boolean
function Geometry.pointInPolygon(x, y, poly)
    local inside = false
    local n = #poly
    if n < 3 then return false end
    local j = n
    for i = 1, n do
        local xi, yi = poly[i].x, poly[i].y
        local xj, yj = poly[j].x, poly[j].y
        if (yi > y) ~= (yj > y)
                and x < (xj - xi) * (y - yi) / (yj - yi) + xi then
            inside = not inside
        end
        j = i
    end
    return inside
end

--- Check if enough of a stroke's points lie inside a lasso polygon.
-- @param stroke table with points array
-- @param poly array of {x, y}
-- @param min_ratio fraction of points that must be inside (default 0.6)
-- @return boolean
function Geometry.strokeInPolygon(stroke, poly, min_ratio)
    if not stroke or not stroke.points or #stroke.points == 0 then return false end
    min_ratio = min_ratio or 0.6
    local inside = 0
    for _, p in ipairs(stroke.points) do
        if Geometry.pointInPolygon(p.x, p.y, poly) then inside = inside + 1 end
    end
    return inside / #stroke.points >= min_ratio
end

return Geometry
