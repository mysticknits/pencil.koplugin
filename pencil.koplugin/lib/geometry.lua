--[[--
Geometry utilities for Pencil plugin.
Pure functions for stroke geometry calculations.

@module pencil.lib.geometry
--]]--

local Geometry = {}

--- Calculate bounding box for a stroke.
-- @param stroke Table with points array and optional width
-- @return Table with x, y, w, h fields, or nil if stroke has no points
function Geometry.getStrokeBounds(stroke)
    if not stroke or not stroke.points or #stroke.points == 0 then
        return nil
    end

    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge

    for _, p in ipairs(stroke.points) do
        min_x = math.min(min_x, p.x)
        min_y = math.min(min_y, p.y)
        max_x = math.max(max_x, p.x)
        max_y = math.max(max_y, p.y)
    end

    local w = stroke.width or 3
    return {
        x = min_x - w,
        y = min_y - w,
        w = max_x - min_x + w * 2,
        h = max_y - min_y + w * 2,
    }
end

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

--- Calculate the distance between two points.
-- @param x1 First point X
-- @param y1 First point Y
-- @param x2 Second point X
-- @param y2 Second point Y
-- @return number Distance between points
function Geometry.distance(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end

--- Calculate squared distance between two points.
-- Useful for comparisons without the sqrt overhead.
-- @param x1 First point X
-- @param y1 First point Y
-- @param x2 Second point X
-- @param y2 Second point Y
-- @return number Squared distance between points
function Geometry.distanceSquared(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return dx * dx + dy * dy
end

return Geometry
