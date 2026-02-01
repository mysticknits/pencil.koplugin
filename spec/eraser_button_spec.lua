--[[--
Unit tests for hardware eraser button functionality.
Tests that the hardware Eraser button provides instant erase mode
independently of the pencil enabled state and eraser tool selection.
Run with: busted spec/eraser_button_spec.lua
--]]--

-- Add the pencil.koplugin directory to the path
package.path = package.path .. ";pencil.koplugin/?.lua"

local Geometry = require("lib/geometry")

-- Helper to create a stroke
local function createStroke(page, points)
    return {
        page = page,
        points = points,
        width = 3,
        tool = "pen",
    }
end

-- Mock Pencil object with eraser button support
local function createMockPencil(strokes, options)
    options = options or {}
    local mock = {
        strokes = strokes or {},
        tool_settings = {
            eraser = { width = options.eraser_width or 20 }
        },
        input_debug_mode = false,
        page_strokes = {},
        undo_stack = {},
        current_tool = options.current_tool or "pen",
        eraser_button_active = false,
        eraser_button_deleted = nil,
        pen_x = 0,
        pen_y = 0,
        -- Mock enabled state
        _enabled = options.enabled ~= false, -- default to true
        _saved = false,
        _dirty_called = false,
    }

    function mock:isEnabled()
        return self._enabled
    end

    function mock:setEnabled(enabled)
        self._enabled = enabled
    end

    -- Mock view for paintTo
    mock.view = {
        paintTo = function() end,
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

    -- Mock getCurrentPage
    function mock:getCurrentPage()
        return options.current_page or 1
    end

    -- Mock transformCoordinates (identity transform for testing)
    function mock:transformCoordinates(x, y)
        return x, y
    end

    -- Mock saveStrokes
    function mock:saveStrokes()
        self._saved = true
    end

    -- Mock paintTo
    function mock:paintTo(bb, x, y)
        -- No-op for testing
    end

    -- Copy of eraseAtPoint from main.lua
    function mock:eraseAtPoint(x, y, page)
        if #self.strokes == 0 then
            return nil
        end

        local eraser_width = self.tool_settings.eraser.width
        local deleted = {}
        local indices_to_remove = {}
        local page_str = tostring(page)

        local function isOnCurrentPage(stroke)
            return stroke.page == page or tostring(stroke.page) == page_str
        end

        for i, stroke in ipairs(self.strokes) do
            if stroke and isOnCurrentPage(stroke) and self:isPointNearStroke(x, y, stroke, eraser_width) then
                table.insert(deleted, stroke)
                table.insert(indices_to_remove, i)
            end
        end

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

    -- onKeyPress handler (simplified from main.lua)
    function mock:onKeyPress(key)
        -- Hardware Eraser button - works regardless of pencil enabled state
        if key.key == "Eraser" then
            self.eraser_button_active = true
            self.eraser_button_deleted = {}
            return true
        end

        if not self:isEnabled() then return false end
        return false
    end

    -- onKeyRelease handler (simplified from main.lua)
    function mock:onKeyRelease(key)
        -- Hardware Eraser button released
        if key.key == "Eraser" and self.eraser_button_active then
            self.eraser_button_active = false
            if self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
                table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_button_deleted })
                self:saveStrokes()
            end
            self.eraser_button_deleted = nil
            self._dirty_called = true
            return true
        end

        if not self:isEnabled() then return false end
        return false
    end

    -- handleStylusSlot handler (simplified from main.lua)
    function mock:handleStylusSlot(input, slot)
        -- Hardware eraser button mode - works even if pencil disabled
        if self.eraser_button_active then
            if slot.id and slot.id >= 0 then
                local raw_x = slot.x or self.pen_x
                local raw_y = slot.y or self.pen_y
                local x, y = self:transformCoordinates(raw_x, raw_y)
                local page = self:getCurrentPage()
                local deleted = self:eraseAtPoint(x, y, page)
                if deleted then
                    for _, stroke in ipairs(deleted) do
                        table.insert(self.eraser_button_deleted, stroke)
                    end
                end
                self.pen_x = x
                self.pen_y = y
            end
            return true
        end

        if not self:isEnabled() then return false end
        return false
    end

    -- Initialize page index
    mock:rebuildPageIndex()

    return mock
end

describe("eraser button mode", function()

    describe("state management", function()

        it("activates eraser button mode on Eraser key press", function()
            local pencil = createMockPencil({})

            assert.is_false(pencil.eraser_button_active)

            local handled = pencil:onKeyPress({ key = "Eraser" })

            assert.is_true(handled)
            assert.is_true(pencil.eraser_button_active)
        end)

        it("deactivates eraser button mode on Eraser key release", function()
            local pencil = createMockPencil({})
            pencil:onKeyPress({ key = "Eraser" })

            assert.is_true(pencil.eraser_button_active)

            local handled = pencil:onKeyRelease({ key = "Eraser" })

            assert.is_true(handled)
            assert.is_false(pencil.eraser_button_active)
        end)

        it("initializes deleted strokes array on activation", function()
            local pencil = createMockPencil({})

            pencil:onKeyPress({ key = "Eraser" })

            assert.is_not_nil(pencil.eraser_button_deleted)
            assert.equals(0, #pencil.eraser_button_deleted)
        end)

        it("clears deleted strokes array on release", function()
            local pencil = createMockPencil({})
            pencil:onKeyPress({ key = "Eraser" })
            pencil.eraser_button_deleted = { createStroke(1, {{ x = 100, y = 100 }}) }

            pencil:onKeyRelease({ key = "Eraser" })

            assert.is_nil(pencil.eraser_button_deleted)
        end)

    end)

    describe("erasing during button hold", function()

        it("erases strokes at stylus position when eraser button active", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
                createStroke(1, {{ x = 500, y = 500 }}),
            }
            local pencil = createMockPencil(strokes, { current_page = 1 })

            pencil:onKeyPress({ key = "Eraser" })

            -- Simulate stylus movement at stroke location
            pencil:handleStylusSlot({}, { id = 1, x = 100, y = 100 })

            -- One stroke should be deleted
            assert.equals(1, #pencil.strokes)
            assert.equals(500, pencil.strokes[1].points[1].x)

            -- Deleted stroke should be tracked
            assert.equals(1, #pencil.eraser_button_deleted)
        end)

        it("does not erase when eraser button is not active", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
            }
            local pencil = createMockPencil(strokes, { current_page = 1, enabled = true })

            -- Stylus movement without eraser button
            pencil:handleStylusSlot({}, { id = 1, x = 100, y = 100 })

            -- Stroke should remain (handleStylusSlot returns false when disabled and not erasing)
            assert.equals(1, #pencil.strokes)
        end)

        it("accumulates multiple deleted strokes for single undo", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
                createStroke(1, {{ x = 200, y = 100 }}),  -- Far enough apart to be separate erasures
                createStroke(1, {{ x = 500, y = 500 }}),
            }
            local pencil = createMockPencil(strokes, { current_page = 1 })

            pencil:onKeyPress({ key = "Eraser" })

            -- First swipe erases first stroke
            pencil:handleStylusSlot({}, { id = 1, x = 100, y = 100 })
            assert.equals(1, #pencil.eraser_button_deleted)

            -- Second swipe erases second stroke
            pencil:handleStylusSlot({}, { id = 1, x = 200, y = 100 })
            assert.equals(2, #pencil.eraser_button_deleted)

            -- Both should be in the same deletion batch
            assert.equals(1, #pencil.strokes)
        end)

        it("only erases strokes on current page", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
                createStroke(2, {{ x = 100, y = 100 }}),  -- Same location, different page
            }
            local pencil = createMockPencil(strokes, { current_page = 1 })

            pencil:onKeyPress({ key = "Eraser" })
            pencil:handleStylusSlot({}, { id = 1, x = 100, y = 100 })

            -- Only page 1 stroke should be deleted
            assert.equals(1, #pencil.strokes)
            assert.equals(2, pencil.strokes[1].page)
        end)

    end)

    describe("undo on release", function()

        it("adds deleted strokes to undo stack on key release", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
            }
            local pencil = createMockPencil(strokes, { current_page = 1 })

            pencil:onKeyPress({ key = "Eraser" })
            pencil:handleStylusSlot({}, { id = 1, x = 100, y = 100 })
            pencil:onKeyRelease({ key = "Eraser" })

            assert.equals(1, #pencil.undo_stack)
            assert.equals("delete", pencil.undo_stack[1].type)
            assert.equals(1, #pencil.undo_stack[1].strokes)
        end)

        it("does not add to undo stack if nothing was deleted", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
            }
            local pencil = createMockPencil(strokes, { current_page = 1 })

            pencil:onKeyPress({ key = "Eraser" })
            -- No stylus movement - no erasure
            pencil:onKeyRelease({ key = "Eraser" })

            assert.equals(0, #pencil.undo_stack)
        end)

        it("saves strokes after erasing", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
            }
            local pencil = createMockPencil(strokes, { current_page = 1 })

            pencil:onKeyPress({ key = "Eraser" })
            pencil:handleStylusSlot({}, { id = 1, x = 100, y = 100 })

            assert.is_false(pencil._saved)

            pencil:onKeyRelease({ key = "Eraser" })

            assert.is_true(pencil._saved)
        end)

    end)

    describe("independence from pencil enabled state", function()

        it("eraser button works when pencil is disabled", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
            }
            local pencil = createMockPencil(strokes, { current_page = 1, enabled = false })

            assert.is_false(pencil:isEnabled())

            -- Eraser button should still work
            local handled = pencil:onKeyPress({ key = "Eraser" })
            assert.is_true(handled)
            assert.is_true(pencil.eraser_button_active)

            -- Should erase
            pencil:handleStylusSlot({}, { id = 1, x = 100, y = 100 })
            assert.equals(0, #pencil.strokes)

            -- Release should work
            handled = pencil:onKeyRelease({ key = "Eraser" })
            assert.is_true(handled)
            assert.equals(1, #pencil.undo_stack)
        end)

        it("eraser button works independently of current_tool setting", function()
            local strokes = {
                createStroke(1, {{ x = 100, y = 100 }}),
            }
            -- current_tool is "pen", not "eraser"
            local pencil = createMockPencil(strokes, { current_page = 1, current_tool = "pen" })

            assert.equals("pen", pencil.current_tool)

            pencil:onKeyPress({ key = "Eraser" })
            pencil:handleStylusSlot({}, { id = 1, x = 100, y = 100 })

            -- Should still erase despite current_tool being pen
            assert.equals(0, #pencil.strokes)
            assert.equals(1, #pencil.eraser_button_deleted)
        end)

        it("does not change current_tool when using eraser button", function()
            local pencil = createMockPencil({}, { current_tool = "pen" })

            pencil:onKeyPress({ key = "Eraser" })
            pencil:onKeyRelease({ key = "Eraser" })

            -- current_tool should remain unchanged
            assert.equals("pen", pencil.current_tool)
        end)

    end)

    describe("handleStylusSlot return value", function()

        it("returns true when eraser button is active to dominate input", function()
            local pencil = createMockPencil({})
            pencil:onKeyPress({ key = "Eraser" })

            local result = pencil:handleStylusSlot({}, { id = 1, x = 100, y = 100 })

            assert.is_true(result)
        end)

        it("returns false when pencil disabled and eraser button not active", function()
            local pencil = createMockPencil({}, { enabled = false })

            local result = pencil:handleStylusSlot({}, { id = 1, x = 100, y = 100 })

            assert.is_false(result)
        end)

    end)

end)
