--[[--
Unit tests for geometry module.
Run with: busted spec/geometry_spec.lua
--]]--

-- Add the pencil.koplugin directory to the path so we can require lib/geometry
package.path = package.path .. ";pencil.koplugin/?.lua"

local Geometry = require("lib/geometry")

describe("Geometry", function()

    describe("getStrokeBounds", function()

        it("returns nil for nil stroke", function()
            assert.is_nil(Geometry.getStrokeBounds(nil))
        end)

        it("returns nil for stroke with nil points", function()
            local stroke = { points = nil }
            assert.is_nil(Geometry.getStrokeBounds(stroke))
        end)

        it("returns nil for stroke with empty points", function()
            local stroke = { points = {} }
            assert.is_nil(Geometry.getStrokeBounds(stroke))
        end)

        it("calculates bounds for single point stroke", function()
            local stroke = {
                points = { { x = 100, y = 200 } },
                width = 10,
            }
            local bounds = Geometry.getStrokeBounds(stroke)

            assert.is_not_nil(bounds)
            assert.equals(90, bounds.x)   -- 100 - 10
            assert.equals(190, bounds.y)  -- 200 - 10
            assert.equals(20, bounds.w)   -- 0 + 10*2
            assert.equals(20, bounds.h)   -- 0 + 10*2
        end)

        it("calculates bounds for multi-point stroke", function()
            local stroke = {
                points = {
                    { x = 10, y = 20 },
                    { x = 50, y = 80 },
                    { x = 30, y = 40 },
                },
                width = 5,
            }
            local bounds = Geometry.getStrokeBounds(stroke)

            assert.is_not_nil(bounds)
            assert.equals(5, bounds.x)    -- min_x(10) - width(5)
            assert.equals(15, bounds.y)   -- min_y(20) - width(5)
            assert.equals(50, bounds.w)   -- (max_x(50) - min_x(10)) + width*2
            assert.equals(70, bounds.h)   -- (max_y(80) - min_y(20)) + width*2
        end)

        it("uses default width of 3 when not specified", function()
            local stroke = {
                points = { { x = 100, y = 100 } },
            }
            local bounds = Geometry.getStrokeBounds(stroke)

            assert.is_not_nil(bounds)
            assert.equals(97, bounds.x)   -- 100 - 3
            assert.equals(97, bounds.y)   -- 100 - 3
            assert.equals(6, bounds.w)    -- 0 + 3*2
            assert.equals(6, bounds.h)    -- 0 + 3*2
        end)

        it("handles negative coordinates", function()
            local stroke = {
                points = {
                    { x = -50, y = -30 },
                    { x = 20, y = 10 },
                },
                width = 2,
            }
            local bounds = Geometry.getStrokeBounds(stroke)

            assert.is_not_nil(bounds)
            assert.equals(-52, bounds.x)  -- -50 - 2
            assert.equals(-32, bounds.y)  -- -30 - 2
            assert.equals(74, bounds.w)   -- (20 - (-50)) + 2*2
            assert.equals(44, bounds.h)   -- (10 - (-30)) + 2*2
        end)

    end)

    describe("isPointNearStroke", function()

        it("returns false for nil stroke", function()
            assert.is_false(Geometry.isPointNearStroke(0, 0, nil, 10))
        end)

        it("returns false for stroke with nil points", function()
            local stroke = { points = nil }
            assert.is_false(Geometry.isPointNearStroke(0, 0, stroke, 10))
        end)

        it("returns false for stroke with empty points", function()
            local stroke = { points = {} }
            assert.is_false(Geometry.isPointNearStroke(0, 0, stroke, 10))
        end)

        it("returns true when point is exactly on stroke point", function()
            local stroke = {
                points = { { x = 100, y = 200 } },
            }
            assert.is_true(Geometry.isPointNearStroke(100, 200, stroke, 10))
        end)

        it("returns true when point is within threshold", function()
            local stroke = {
                points = { { x = 100, y = 200 } },
            }
            -- Point at distance 5 from stroke point
            assert.is_true(Geometry.isPointNearStroke(105, 200, stroke, 10))
            assert.is_true(Geometry.isPointNearStroke(100, 205, stroke, 10))
        end)

        it("returns false when point is outside threshold", function()
            local stroke = {
                points = { { x = 100, y = 200 } },
            }
            -- Point at distance > 10 from stroke point
            assert.is_false(Geometry.isPointNearStroke(120, 200, stroke, 10))
            assert.is_false(Geometry.isPointNearStroke(100, 220, stroke, 10))
        end)

        it("uses default threshold of 20", function()
            local stroke = {
                points = { { x = 100, y = 100 } },
            }
            -- Within default threshold of 20
            assert.is_true(Geometry.isPointNearStroke(115, 100, stroke))
            -- Outside default threshold of 20
            assert.is_false(Geometry.isPointNearStroke(125, 100, stroke))
        end)

        it("checks all points in stroke", function()
            local stroke = {
                points = {
                    { x = 0, y = 0 },
                    { x = 100, y = 100 },
                    { x = 200, y = 0 },
                },
            }
            -- Near first point
            assert.is_true(Geometry.isPointNearStroke(5, 5, stroke, 10))
            -- Near middle point
            assert.is_true(Geometry.isPointNearStroke(105, 105, stroke, 10))
            -- Near last point
            assert.is_true(Geometry.isPointNearStroke(195, 5, stroke, 10))
            -- Not near any point
            assert.is_false(Geometry.isPointNearStroke(100, 50, stroke, 10))
        end)

        it("handles boundary case (exactly at threshold)", function()
            local stroke = {
                points = { { x = 0, y = 0 } },
            }
            -- At exactly threshold distance (10 units away)
            assert.is_true(Geometry.isPointNearStroke(10, 0, stroke, 10))
            assert.is_true(Geometry.isPointNearStroke(0, 10, stroke, 10))
        end)

    end)

    describe("distance", function()

        it("returns 0 for same point", function()
            assert.equals(0, Geometry.distance(5, 5, 5, 5))
        end)

        it("calculates horizontal distance", function()
            assert.equals(10, Geometry.distance(0, 0, 10, 0))
        end)

        it("calculates vertical distance", function()
            assert.equals(10, Geometry.distance(0, 0, 0, 10))
        end)

        it("calculates diagonal distance (3-4-5 triangle)", function()
            assert.equals(5, Geometry.distance(0, 0, 3, 4))
        end)

        it("handles negative coordinates", function()
            assert.equals(5, Geometry.distance(-3, -4, 0, 0))
        end)

    end)

    describe("distanceSquared", function()

        it("returns 0 for same point", function()
            assert.equals(0, Geometry.distanceSquared(5, 5, 5, 5))
        end)

        it("returns squared distance (avoids sqrt)", function()
            -- 3-4-5 triangle: distance = 5, squared = 25
            assert.equals(25, Geometry.distanceSquared(0, 0, 3, 4))
        end)

        it("handles larger distances", function()
            -- 10 horizontal, squared = 100
            assert.equals(100, Geometry.distanceSquared(0, 0, 10, 0))
        end)

    end)

end)
