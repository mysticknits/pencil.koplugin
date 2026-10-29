--[[--
Unit tests for geometry module.
Run with: busted spec/geometry_spec.lua
--]]--

-- Add the pencil.koplugin directory to the path so we can require lib/geometry
package.path = package.path .. ";pencil.koplugin/?.lua"

local Geometry = require("lib/geometry")

describe("Geometry", function()

    describe("isPointNearStroke", function()

        it("returns false for nil stroke", function()
            assert.is_false(Geometry.isPointNearPoints(0, 0, nil, 10))
        end)

        it("returns false for stroke with nil points", function()
            local stroke = { points = nil }
            assert.is_false(Geometry.isPointNearPoints(0, 0, stroke.points, 10))
        end)

        it("returns false for stroke with empty points", function()
            local stroke = { points = {} }
            assert.is_false(Geometry.isPointNearPoints(0, 0, stroke.points, 10))
        end)

        it("returns true when point is exactly on stroke point", function()
            local stroke = {
                points = { { x = 100, y = 200 } },
            }
            assert.is_true(Geometry.isPointNearPoints(100, 200, stroke.points, 10))
        end)

        it("returns true when point is within threshold", function()
            local stroke = {
                points = { { x = 100, y = 200 } },
            }
            -- Point at distance 5 from stroke point
            assert.is_true(Geometry.isPointNearPoints(105, 200, stroke.points, 10))
            assert.is_true(Geometry.isPointNearPoints(100, 205, stroke.points, 10))
        end)

        it("returns false when point is outside threshold", function()
            local stroke = {
                points = { { x = 100, y = 200 } },
            }
            -- Point at distance > 10 from stroke point
            assert.is_false(Geometry.isPointNearPoints(120, 200, stroke.points, 10))
            assert.is_false(Geometry.isPointNearPoints(100, 220, stroke.points, 10))
        end)

        it("uses default threshold of 20", function()
            local stroke = {
                points = { { x = 100, y = 100 } },
            }
            -- Within default threshold of 20
            assert.is_true(Geometry.isPointNearPoints(115, 100, stroke.points))
            -- Outside default threshold of 20
            assert.is_false(Geometry.isPointNearPoints(125, 100, stroke.points))
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
            assert.is_true(Geometry.isPointNearPoints(5, 5, stroke.points, 10))
            -- Near middle point
            assert.is_true(Geometry.isPointNearPoints(105, 105, stroke.points, 10))
            -- Near last point
            assert.is_true(Geometry.isPointNearPoints(195, 5, stroke.points, 10))
            -- Not near any point
            assert.is_false(Geometry.isPointNearPoints(100, 50, stroke.points, 10))
        end)

        it("handles boundary case (exactly at threshold)", function()
            local stroke = {
                points = { { x = 0, y = 0 } },
            }
            -- At exactly threshold distance (10 units away)
            assert.is_true(Geometry.isPointNearPoints(10, 0, stroke.points, 10))
            assert.is_true(Geometry.isPointNearPoints(0, 10, stroke.points, 10))
        end)

    end)

    describe("transformForRotation", function()
        -- Test with a typical e-reader screen: 1072x1448 (Kobo Libra)
        local WIDTH = 1072
        local HEIGHT = 1448

        describe("ROTATION_UPRIGHT (0)", function()
            it("returns coordinates unchanged", function()
                local x, y = Geometry.transformForRotation(100, 200, Geometry.ROTATION_UPRIGHT, WIDTH, HEIGHT)
                assert.equals(100, x)
                assert.equals(200, y)
            end)

            it("handles corner coordinates", function()
                local x, y = Geometry.transformForRotation(0, 0, Geometry.ROTATION_UPRIGHT, WIDTH, HEIGHT)
                assert.equals(0, x)
                assert.equals(0, y)

                x, y = Geometry.transformForRotation(WIDTH, HEIGHT, Geometry.ROTATION_UPRIGHT, WIDTH, HEIGHT)
                assert.equals(WIDTH, x)
                assert.equals(HEIGHT, y)
            end)
        end)

        describe("ROTATION_CLOCKWISE (1) - 90 degrees", function()
            it("transforms coordinates correctly", function()
                -- Formula: x' = width - y, y' = x
                local x, y = Geometry.transformForRotation(100, 200, Geometry.ROTATION_CLOCKWISE, WIDTH, HEIGHT)
                assert.equals(WIDTH - 200, x)  -- 1072 - 200 = 872
                assert.equals(100, y)
            end)

            it("transforms top-left corner to top-right", function()
                local x, y = Geometry.transformForRotation(0, 0, Geometry.ROTATION_CLOCKWISE, WIDTH, HEIGHT)
                assert.equals(WIDTH, x)  -- 1072
                assert.equals(0, y)
            end)

            it("transforms bottom-right to bottom-left", function()
                local x, y = Geometry.transformForRotation(WIDTH, HEIGHT, Geometry.ROTATION_CLOCKWISE, WIDTH, HEIGHT)
                assert.equals(WIDTH - HEIGHT, x)  -- 1072 - 1448 = -376
                assert.equals(WIDTH, y)           -- 1072
            end)
        end)

        describe("ROTATION_UPSIDE_DOWN (2) - 180 degrees", function()
            it("transforms coordinates correctly", function()
                -- Formula: x' = width - x, y' = height - y
                local x, y = Geometry.transformForRotation(100, 200, Geometry.ROTATION_UPSIDE_DOWN, WIDTH, HEIGHT)
                assert.equals(WIDTH - 100, x)   -- 1072 - 100 = 972
                assert.equals(HEIGHT - 200, y)  -- 1448 - 200 = 1248
            end)

            it("transforms origin to opposite corner", function()
                local x, y = Geometry.transformForRotation(0, 0, Geometry.ROTATION_UPSIDE_DOWN, WIDTH, HEIGHT)
                assert.equals(WIDTH, x)
                assert.equals(HEIGHT, y)
            end)

            it("transforms opposite corner to origin", function()
                local x, y = Geometry.transformForRotation(WIDTH, HEIGHT, Geometry.ROTATION_UPSIDE_DOWN, WIDTH, HEIGHT)
                assert.equals(0, x)
                assert.equals(0, y)
            end)
        end)

        describe("ROTATION_COUNTER_CLOCKWISE (3) - 270 degrees", function()
            it("transforms coordinates correctly", function()
                -- Formula: x' = y, y' = height - x
                local x, y = Geometry.transformForRotation(100, 200, Geometry.ROTATION_COUNTER_CLOCKWISE, WIDTH, HEIGHT)
                assert.equals(200, x)
                assert.equals(HEIGHT - 100, y)  -- 1448 - 100 = 1348
            end)

            it("transforms top-left to bottom-left", function()
                local x, y = Geometry.transformForRotation(0, 0, Geometry.ROTATION_COUNTER_CLOCKWISE, WIDTH, HEIGHT)
                assert.equals(0, x)
                assert.equals(HEIGHT, y)  -- 1448
            end)

            it("transforms bottom-right to top-right", function()
                local x, y = Geometry.transformForRotation(WIDTH, HEIGHT, Geometry.ROTATION_COUNTER_CLOCKWISE, WIDTH, HEIGHT)
                assert.equals(HEIGHT, x)          -- 1448
                assert.equals(HEIGHT - WIDTH, y)  -- 1448 - 1072 = 376
            end)
        end)

        describe("unknown rotation", function()
            it("returns coordinates unchanged for unknown rotation values", function()
                local x, y = Geometry.transformForRotation(100, 200, 99, WIDTH, HEIGHT)
                assert.equals(100, x)
                assert.equals(200, y)
            end)
        end)

        describe("rotation constants", function()
            it("defines correct constant values", function()
                assert.equals(0, Geometry.ROTATION_UPRIGHT)
                assert.equals(1, Geometry.ROTATION_CLOCKWISE)
                assert.equals(2, Geometry.ROTATION_UPSIDE_DOWN)
                assert.equals(3, Geometry.ROTATION_COUNTER_CLOCKWISE)
            end)
        end)

    end)

    describe("bboxExpand", function()
        it("grows the box by margin on each side", function()
            local result = Geometry.bboxExpand({ x0 = 10, y0 = 20, x1 = 30, y1 = 40 }, 5)
            assert.equals(5, result.x0)
            assert.equals(15, result.y0)
            assert.equals(35, result.x1)
            assert.equals(45, result.y1)
        end)

        it("supports zero margin", function()
            local result = Geometry.bboxExpand({ x0 = 0, y0 = 0, x1 = 10, y1 = 10 }, 0)
            assert.equals(0, result.x0)
            assert.equals(10, result.x1)
        end)
    end)

    describe("bboxClampToScreen", function()
        it("returns the box unchanged when fully inside screen", function()
            local result = Geometry.bboxClampToScreen({ x0 = 10, y0 = 20, x1 = 100, y1 = 200 }, 500, 500)
            assert.equals(10, result.x0)
            assert.equals(20, result.y0)
            assert.equals(100, result.x1)
            assert.equals(200, result.y1)
        end)

        it("clamps negative coordinates to zero", function()
            local result = Geometry.bboxClampToScreen({ x0 = -50, y0 = -30, x1 = 100, y1 = 100 }, 500, 500)
            assert.equals(0, result.x0)
            assert.equals(0, result.y0)
            assert.equals(100, result.x1)
            assert.equals(100, result.y1)
        end)

        it("clamps coordinates beyond screen to screen dimensions", function()
            local result = Geometry.bboxClampToScreen({ x0 = 100, y0 = 200, x1 = 600, y1 = 700 }, 500, 500)
            assert.equals(100, result.x0)
            assert.equals(200, result.y0)
            assert.equals(500, result.x1)
            assert.equals(500, result.y1)
        end)
    end)

    describe("captureStripRect", function()
        local sw, sh = 1264, 1680
        local v_margin = 24
        local min_h = 350

        it("returns a full-screen-width strip", function()
            local bbox = { y0 = 800, y1 = 900 }
            local rect = Geometry.captureStripRect(bbox, sw, sh, v_margin, min_h)
            assert.equals(0, rect.x0)
            assert.equals(sw, rect.x1)
        end)

        it("uses bbox + 2*v_margin when that exceeds min height", function()
            local bbox = { y0 = 800, y1 = 1200 }  -- 400 tall
            local rect = Geometry.captureStripRect(bbox, sw, sh, v_margin, min_h)
            assert.equals(400 + 2 * v_margin, rect.y1 - rect.y0)
        end)

        it("enforces min height for tiny bboxes", function()
            local bbox = { y0 = 800, y1 = 810 }  -- 10 tall, +48 margin = 58
            local rect = Geometry.captureStripRect(bbox, sw, sh, v_margin, min_h)
            assert.equals(min_h, rect.y1 - rect.y0)
        end)

        it("centers the strip on the bbox center", function()
            local bbox = { y0 = 800, y1 = 810 }
            local rect = Geometry.captureStripRect(bbox, sw, sh, v_margin, min_h)
            local center = (rect.y0 + rect.y1) / 2
            -- bbox center is 805; strip is centered there (within rounding)
            assert.is_true(math.abs(center - 805) <= 1)
        end)

        it("shifts strip down (not clipped) when bbox is near the top", function()
            local bbox = { y0 = 20, y1 = 30 }  -- center at 25, strip 350 tall
            local rect = Geometry.captureStripRect(bbox, sw, sh, v_margin, min_h)
            assert.equals(0, rect.y0)
            assert.equals(min_h, rect.y1 - rect.y0)
        end)

        it("shifts strip up (not clipped) when bbox is near the bottom", function()
            local bbox = { y0 = sh - 30, y1 = sh - 20 }
            local rect = Geometry.captureStripRect(bbox, sw, sh, v_margin, min_h)
            assert.equals(sh, rect.y1)
            assert.equals(min_h, rect.y1 - rect.y0)
        end)

        it("caps strip at screen height when min_h exceeds screen", function()
            local rect = Geometry.captureStripRect(
                { y0 = 100, y1 = 200 }, sw, 200, v_margin, min_h)
            assert.equals(0, rect.y0)
            assert.equals(200, rect.y1)
        end)

        it("returns a strip within screen bounds in all cases", function()
            local cases = {
                { y0 = 0, y1 = 0 },         -- single-point at top corner
                { y0 = sh, y1 = sh },        -- single-point at bottom corner
                { y0 = sh / 2, y1 = sh / 2 + 5 },  -- middle
                { y0 = -50, y1 = 50 },       -- bbox partially above screen
                { y0 = sh - 50, y1 = sh + 50 },  -- bbox partially below screen
            }
            for _, bbox in ipairs(cases) do
                local rect = Geometry.captureStripRect(bbox, sw, sh, v_margin, min_h)
                assert.is_true(rect.y0 >= 0)
                assert.is_true(rect.y1 <= sh)
                assert.is_true(rect.y1 > rect.y0)
            end
        end)
    end)

end)
