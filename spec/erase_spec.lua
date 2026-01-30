--[[--
Unit tests for erase functionality.
Tests that erasing only affects strokes on the current page.
Run with: busted spec/erase_spec.lua
--]]--

-- Add the pencil.koplugin directory to the path
package.path = package.path .. ";pencil.koplugin/?.lua"

local Geometry = require("lib/geometry")

-- Mock Pencil object with minimal implementation for testing eraseAtPoint
local function createMockPencil(strokes, eraser_width)
    local mock = {
        strokes = strokes or {},
        tool_settings = {
            eraser = { width = eraser_width or 20 }
        },
        input_debug_mode = false,
        page_strokes = {},
    }

    -- Rebuild page index (simplified version)
    function mock:rebuildPageIndex()
        self.page_strokes = {}
        for i, stroke in ipairs(self.strokes) do
            local page = stroke.page
            if not self.page_strokes[page] then
                self.page_strokes[page] = {}
            end
            table.insert(self.page_strokes[page], i)
        end
    end

    -- Use real geometry function for point-near-stroke check
    function mock:isPointNearStroke(px, py, stroke, threshold)
        return Geometry.isPointNearStroke(px, py, stroke, threshold)
    end

    -- Copy of eraseAtPoint from main.lua (the fixed version)
    function mock:eraseAtPoint(x, y, page)
        -- Only erase strokes on the current page
        if #self.strokes == 0 then
            return nil
        end

        local eraser_width = self.tool_settings.eraser.width
        local deleted = {}
        local indices_to_remove = {}
        local page_str = tostring(page)

        -- Helper to check if stroke belongs to current page (handles type mismatches)
        local function isOnCurrentPage(stroke)
            return stroke.page == page or tostring(stroke.page) == page_str
        end

        -- Find strokes on the current page that intersect with eraser point
        for i, stroke in ipairs(self.strokes) do
            if stroke and isOnCurrentPage(stroke) and self:isPointNearStroke(x, y, stroke, eraser_width) then
                table.insert(deleted, stroke)
                table.insert(indices_to_remove, i)
            end
        end

        -- Remove strokes (in reverse order to maintain indices)
        if #indices_to_remove > 0 then
            table.sort(indices_to_remove, function(a, b) return a > b end)
            for _, idx in ipairs(indices_to_remove) do
                table.remove(self.strokes, idx)
            end
            self:rebuildPageIndex()
            return deleted
        end

        return nil
    end

    -- Initialize page index
    mock:rebuildPageIndex()

    return mock
end

-- Helper to create a stroke
local function createStroke(page, points)
    return {
        page = page,
        points = points,
        width = 3,
        tool = "pen",
    }
end

describe("eraseAtPoint", function()

    describe("page filtering", function()

        it("only erases strokes on the current page", function()
            -- Create strokes on different pages at the same location
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
                createStroke(2, {{ x = 100, y = 100 }}),  -- Same location, different page
                createStroke(3, {{ x = 100, y = 100 }}),  -- Same location, different page
            }

            local pencil = createMockPencil(strokes, 20)

            -- Erase at (100, 100) on page 2
            local deleted = pencil:eraseAtPoint(100, 100, 2)

            -- Should only delete the stroke on page 2
            assert.is_not_nil(deleted)
            assert.equals(1, #deleted)
            assert.equals(2, deleted[1].page)

            -- Strokes on pages 1 and 3 should remain
            assert.equals(2, #pencil.strokes)
            assert.equals(1, pencil.strokes[1].page)
            assert.equals(3, pencil.strokes[2].page)
        end)

        it("does not erase strokes on other pages even at same coordinates", function()
            local strokes = {
                createStroke(1, {{ x = 50, y = 50 }}),
                createStroke(1, {{ x = 150, y = 150 }}),
                createStroke(2, {{ x = 50, y = 50 }}),  -- Same location as page 1 stroke
            }

            local pencil = createMockPencil(strokes, 20)

            -- Erase at (50, 50) on page 1
            local deleted = pencil:eraseAtPoint(50, 50, 1)

            -- Should only delete the stroke on page 1 at (50, 50)
            assert.is_not_nil(deleted)
            assert.equals(1, #deleted)
            assert.equals(1, deleted[1].page)

            -- Page 2 stroke at same coordinates should remain
            assert.equals(2, #pencil.strokes)
            local page2_stroke_exists = false
            for _, stroke in ipairs(pencil.strokes) do
                if stroke.page == 2 and stroke.points[1].x == 50 then
                    page2_stroke_exists = true
                    break
                end
            end
            assert.is_true(page2_stroke_exists)
        end)

        it("handles string page identifiers (for EPUB XPointers)", function()
            local strokes = {
                createStroke("/body/div[1]", {{ x = 100, y = 100 }}),
                createStroke("/body/div[2]", {{ x = 100, y = 100 }}),
            }

            local pencil = createMockPencil(strokes, 20)

            -- Erase on first page (XPointer)
            local deleted = pencil:eraseAtPoint(100, 100, "/body/div[1]")

            assert.is_not_nil(deleted)
            assert.equals(1, #deleted)
            assert.equals("/body/div[1]", deleted[1].page)

            -- Second page stroke should remain
            assert.equals(1, #pencil.strokes)
            assert.equals("/body/div[2]", pencil.strokes[1].page)
        end)

        it("handles type mismatches between number and string page identifiers", function()
            -- Simulate strokes that might have been saved with numeric page
            local strokes = {
                createStroke(5, {{ x = 100, y = 100 }}),   -- Numeric page
                createStroke(10, {{ x = 100, y = 100 }}),  -- Numeric page
            }

            local pencil = createMockPencil(strokes, 20)

            -- Erase with string page (simulates potential type mismatch after serialization)
            local deleted = pencil:eraseAtPoint(100, 100, "5")

            assert.is_not_nil(deleted)
            assert.equals(1, #deleted)

            -- Only page 10 stroke should remain
            assert.equals(1, #pencil.strokes)
            assert.equals(10, pencil.strokes[1].page)
        end)

        it("handles reverse type mismatch (string stored, number queried)", function()
            local strokes = {
                createStroke("5", {{ x = 100, y = 100 }}),  -- String page
                createStroke("10", {{ x = 100, y = 100 }}), -- String page
            }

            local pencil = createMockPencil(strokes, 20)

            -- Erase with numeric page
            local deleted = pencil:eraseAtPoint(100, 100, 5)

            assert.is_not_nil(deleted)
            assert.equals(1, #deleted)

            -- Only page "10" stroke should remain
            assert.equals(1, #pencil.strokes)
            assert.equals("10", pencil.strokes[1].page)
        end)

    end)

    describe("basic functionality", function()

        it("returns nil when no strokes exist", function()
            local pencil = createMockPencil({}, 20)
            local deleted = pencil:eraseAtPoint(100, 100, 1)
            assert.is_nil(deleted)
        end)

        it("returns nil when no strokes are near the point", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
            }
            local pencil = createMockPencil(strokes, 20)

            -- Erase far from the stroke
            local deleted = pencil:eraseAtPoint(500, 500, 1)
            assert.is_nil(deleted)
            assert.equals(1, #pencil.strokes)
        end)

        it("erases strokes within eraser threshold", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
            }
            local pencil = createMockPencil(strokes, 20)

            -- Erase within threshold (15 pixels away, threshold is 20)
            local deleted = pencil:eraseAtPoint(115, 100, 1)

            assert.is_not_nil(deleted)
            assert.equals(1, #deleted)
            assert.equals(0, #pencil.strokes)
        end)

        it("does not erase strokes outside eraser threshold", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
            }
            local pencil = createMockPencil(strokes, 20)

            -- Erase outside threshold (25 pixels away, threshold is 20)
            local deleted = pencil:eraseAtPoint(125, 100, 1)

            assert.is_nil(deleted)
            assert.equals(1, #pencil.strokes)
        end)

        it("can erase multiple strokes at once", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
                createStroke(1, {{ x = 105, y = 100 }}),  -- Close to first stroke
                createStroke(1, {{ x = 500, y = 500 }}),  -- Far away
            }
            local pencil = createMockPencil(strokes, 20)

            -- Erase near first two strokes
            local deleted = pencil:eraseAtPoint(102, 100, 1)

            assert.is_not_nil(deleted)
            assert.equals(2, #deleted)
            assert.equals(1, #pencil.strokes)
            assert.equals(500, pencil.strokes[1].points[1].x)
        end)

        it("rebuilds page index after erasing", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
                createStroke(1, {{ x = 200, y = 200 }}),
                createStroke(2, {{ x = 100, y = 100 }}),
            }
            local pencil = createMockPencil(strokes, 20)

            -- Verify initial index
            assert.equals(2, #pencil.page_strokes[1])
            assert.equals(1, #pencil.page_strokes[2])

            -- Erase one stroke on page 1
            pencil:eraseAtPoint(100, 100, 1)

            -- Page index should be updated
            assert.equals(1, #pencil.page_strokes[1])
            assert.equals(1, #pencil.page_strokes[2])
        end)

    end)

    describe("multi-point strokes", function()

        it("erases stroke when near any point in the stroke", function()
            local strokes = {
                createStroke(1, {
                    { x = 0, y = 0 },
                    { x = 100, y = 100 },
                    { x = 200, y = 0 },
                }),
            }
            local pencil = createMockPencil(strokes, 20)

            -- Erase near middle point
            local deleted = pencil:eraseAtPoint(100, 100, 1)

            assert.is_not_nil(deleted)
            assert.equals(1, #deleted)
            assert.equals(0, #pencil.strokes)
        end)

        it("erases stroke when near last point", function()
            local strokes = {
                createStroke(1, {
                    { x = 0, y = 0 },
                    { x = 100, y = 100 },
                    { x = 200, y = 0 },
                }),
            }
            local pencil = createMockPencil(strokes, 20)

            -- Erase near last point
            local deleted = pencil:eraseAtPoint(200, 0, 1)

            assert.is_not_nil(deleted)
            assert.equals(1, #deleted)
        end)

    end)

end)
