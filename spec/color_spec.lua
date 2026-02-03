--[[--
Unit tests for color picker and pen color functionality.
Tests color selection, color picker triggering, and color persistence.
Run with: busted spec/color_spec.lua
--]]--

-- Add the pencil.koplugin directory to the path
package.path = package.path .. ";pencil.koplugin/?.lua"

-- Mock Blitbuffer for color values
local MockBlitbuffer = {
    COLOR_BLACK = { value = 0x00 },
    Color8 = function(v) return { value = v, type = "gray" } end,
    ColorRGB32 = function(r, g, b, a)
        return { r = r, g = g, b = b, a = a, type = "rgb32" }
    end,
}

-- Tool constants
local TOOL_PEN = "pen"
local TOOL_HIGHLIGHTER = "highlighter"
local TOOL_ERASER = "eraser"

-- Color picker constants (matching main.lua)
local COLOR_PICKER_HOLD_TIME_MS = 5000
local COLOR_PICKER_MOVE_THRESHOLD = 5

-- Helper to create a stroke with color
local function createStroke(page, points, options)
    options = options or {}
    return {
        page = page,
        points = points,
        width = options.width or 3,
        tool = options.tool or TOOL_PEN,
        color = options.color,
        color_name = options.color_name,
    }
end

-- Mock time module (must be defined before createMockPencil uses it)
local MockTime = {}
MockTime._current_time = 0
function MockTime.now() return MockTime._current_time end
function MockTime.to_ms(t) return t end
function MockTime.set(ms) MockTime._current_time = ms end
function MockTime.advance(ms) MockTime._current_time = MockTime._current_time + ms end

-- Mock Pencil object with color support
local function createMockPencil(options)
    options = options or {}

    local mock = {
        strokes = options.strokes or {},
        tool_settings = {
            [TOOL_PEN] = {
                width = 3,
                color = nil,
                color_name = "Black",
            },
            [TOOL_HIGHLIGHTER] = {
                width = 20,
                color = nil,
            },
            [TOOL_ERASER] = {
                width = 20,
            },
        },
        current_tool = options.current_tool or TOOL_PEN,
        input_debug_mode = false,
        page_strokes = {},
        undo_stack = {},

        -- Color picker state
        color_picker_start_x = nil,
        color_picker_start_y = nil,
        color_picker_start_time = nil,
        color_picker_check_pending = nil,
        color_picker_showing = false,
        color_picker_widget = nil,

        -- Available colors
        available_colors = {},

        -- Pen state
        pen_down = false,
        pen_x = 0,
        pen_y = 0,

        -- Mock tracking
        _saved = false,
        _notification_shown = nil,
        _scheduled_callbacks = {},
    }

    -- Initialize colors (simulating init())
    mock.tool_settings[TOOL_PEN].color = MockBlitbuffer.COLOR_BLACK
    mock.tool_settings[TOOL_HIGHLIGHTER].color = MockBlitbuffer.Color8(0xDD)

    mock.available_colors = {
        { name = "Black", color = MockBlitbuffer.COLOR_BLACK },
        { name = "Red", color = MockBlitbuffer.ColorRGB32(0xFF, 0x33, 0x00, 0xFF) },
        { name = "Orange", color = MockBlitbuffer.ColorRGB32(0xFF, 0x88, 0x00, 0xFF) },
        { name = "Yellow", color = MockBlitbuffer.ColorRGB32(0xFF, 0xFF, 0x33, 0xFF) },
        { name = "Green", color = MockBlitbuffer.ColorRGB32(0x00, 0xAA, 0x66, 0xFF) },
        { name = "Olive", color = MockBlitbuffer.ColorRGB32(0x88, 0xFF, 0x77, 0xFF) },
        { name = "Cyan", color = MockBlitbuffer.ColorRGB32(0x00, 0xFF, 0xEE, 0xFF) },
        { name = "Blue", color = MockBlitbuffer.ColorRGB32(0x00, 0x66, 0xFF, 0xFF) },
        { name = "Purple", color = MockBlitbuffer.ColorRGB32(0xEE, 0x00, 0xFF, 0xFF) },
        { name = "Gray", color = MockBlitbuffer.Color8(0x88) },
    }

    -- Set pen color
    function mock:setPenColor(color, color_name)
        self.tool_settings[TOOL_PEN].color = color
        self.tool_settings[TOOL_PEN].color_name = color_name
    end

    -- Get color by name
    function mock:getColorByName(color_name)
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == color_name then
                return color_info.color
            end
        end
        return nil
    end

    -- Reset color picker tracking
    function mock:resetColorPickerTracking()
        self.color_picker_start_x = nil
        self.color_picker_start_y = nil
        self.color_picker_start_time = nil
    end

    -- Check if color picker should be shown
    function mock:checkColorPickerTrigger()
        if not self.color_picker_start_time then return false end
        if self.color_picker_showing then return false end

        local elapsed_ms = MockTime.to_ms(MockTime.now() - self.color_picker_start_time)
        if elapsed_ms >= COLOR_PICKER_HOLD_TIME_MS then
            self:showColorPicker(self.pen_x, self.pen_y)
            self:resetColorPickerTracking()
            return true
        end
        return false
    end

    -- Schedule color picker check (mock)
    function mock:scheduleColorPickerCheck()
        self.color_picker_check_pending = true
    end

    -- Cancel color picker timer (mock)
    function mock:cancelColorPickerTimer()
        self.color_picker_check_pending = nil
        self:resetColorPickerTracking()
    end

    -- Show color picker (mock)
    function mock:showColorPicker(x, y)
        self.color_picker_showing = true
        self.color_picker_widget = {
            x = x,
            y = y,
            closed = false,
        }
    end

    -- Close color picker (mock)
    function mock:closeColorPicker()
        self.color_picker_showing = false
        self.color_picker_widget = nil
    end

    -- Handle pen touchdown - start tracking for color picker
    function mock:handlePenTouchdown(x, y)
        self.pen_down = true
        self.pen_x = x
        self.pen_y = y

        if self.color_picker_showing and self.color_picker_widget then
            -- Route to color picker
            return true
        end

        self:cancelColorPickerTimer()

        -- Record initial position and timestamp
        self.color_picker_start_x = x
        self.color_picker_start_y = y
        self.color_picker_start_time = MockTime.now()
        self:scheduleColorPickerCheck()

        return true
    end

    -- Handle pen move - check if moved too far
    function mock:handlePenMove(x, y)
        self.pen_x = x
        self.pen_y = y

        if self.color_picker_start_x and self.color_picker_start_y then
            local dx = math.abs(x - self.color_picker_start_x)
            local dy = math.abs(y - self.color_picker_start_y)
            if dx > COLOR_PICKER_MOVE_THRESHOLD or dy > COLOR_PICKER_MOVE_THRESHOLD then
                -- Pen moved too far - reset tracking
                self:resetColorPickerTracking()
                return true
            end
        end

        return true
    end

    -- Handle pen liftoff
    function mock:handlePenLiftoff()
        self.pen_down = false
        self:cancelColorPickerTimer()
    end

    -- Save strokes (mock)
    function mock:saveStrokes()
        self._saved = true
    end

    -- Load pen color by name
    function mock:loadPenColorByName(color_name)
        if color_name then
            self.tool_settings[TOOL_PEN].color_name = color_name
            local color = self:getColorByName(color_name)
            if color then
                self.tool_settings[TOOL_PEN].color = color
                return true
            end
        end
        return false
    end

    -- Create stroke with current color
    function mock:createStrokeWithCurrentColor(page, points)
        local tool_settings = self.tool_settings[self.current_tool]
        return {
            page = page,
            points = points,
            width = tool_settings.width,
            tool = self.current_tool,
            color = tool_settings.color,
            color_name = tool_settings.color_name,
        }
    end

    -- Serialize stroke for saving
    function mock:serializeStroke(stroke)
        return {
            page = stroke.page,
            points = stroke.points,
            width = stroke.width,
            tool = stroke.tool,
            color_name = stroke.color_name,  -- Save color name, not color object
        }
    end

    -- Deserialize stroke when loading
    function mock:deserializeStroke(saved)
        local tool = saved.tool or TOOL_PEN
        local tool_settings = self.tool_settings[tool]
        local color = tool_settings.color

        -- Look up color from color_name
        if saved.color_name then
            local looked_up_color = self:getColorByName(saved.color_name)
            if looked_up_color then
                color = looked_up_color
            end
        end

        return {
            page = saved.page,
            points = saved.points,
            width = saved.width,
            tool = tool,
            color = color,
            color_name = saved.color_name,
        }
    end

    return mock
end


describe("pen color functionality", function()

    describe("initialization", function()

        it("initializes with 10 available colors", function()
            local pencil = createMockPencil()
            assert.equals(10, #pencil.available_colors)
        end)

        it("includes expected color names", function()
            local pencil = createMockPencil()
            local color_names = {}
            for _, c in ipairs(pencil.available_colors) do
                color_names[c.name] = true
            end

            assert.is_true(color_names["Black"])
            assert.is_true(color_names["Red"])
            assert.is_true(color_names["Orange"])
            assert.is_true(color_names["Yellow"])
            assert.is_true(color_names["Green"])
            assert.is_true(color_names["Blue"])
            assert.is_true(color_names["Purple"])
            assert.is_true(color_names["Gray"])
        end)

        it("defaults pen color to Black", function()
            local pencil = createMockPencil()
            assert.equals("Black", pencil.tool_settings[TOOL_PEN].color_name)
            assert.is_not_nil(pencil.tool_settings[TOOL_PEN].color)
        end)

        it("sets highlighter to light gray", function()
            local pencil = createMockPencil()
            assert.is_not_nil(pencil.tool_settings[TOOL_HIGHLIGHTER].color)
            assert.equals("gray", pencil.tool_settings[TOOL_HIGHLIGHTER].color.type)
        end)

    end)

    describe("setPenColor", function()

        it("sets both color and color_name", function()
            local pencil = createMockPencil()
            local red_color = pencil.available_colors[2].color  -- Red

            pencil:setPenColor(red_color, "Red")

            assert.equals("Red", pencil.tool_settings[TOOL_PEN].color_name)
            assert.equals(red_color, pencil.tool_settings[TOOL_PEN].color)
        end)

        it("can change color multiple times", function()
            local pencil = createMockPencil()

            pencil:setPenColor(pencil.available_colors[3].color, "Orange")
            assert.equals("Orange", pencil.tool_settings[TOOL_PEN].color_name)

            pencil:setPenColor(pencil.available_colors[5].color, "Green")
            assert.equals("Green", pencil.tool_settings[TOOL_PEN].color_name)
        end)

    end)

    describe("getColorByName", function()

        it("returns correct color for valid name", function()
            local pencil = createMockPencil()

            local blue = pencil:getColorByName("Blue")

            assert.is_not_nil(blue)
            assert.equals("rgb32", blue.type)
            assert.equals(0x00, blue.r)
            assert.equals(0x66, blue.g)
            assert.equals(0xFF, blue.b)
        end)

        it("returns nil for unknown color name", function()
            local pencil = createMockPencil()

            local unknown = pencil:getColorByName("Magenta")

            assert.is_nil(unknown)
        end)

    end)

end)


describe("color picker triggering", function()

    before_each(function()
        MockTime.set(0)
    end)

    describe("tracking on touchdown", function()

        it("records position on pen touchdown", function()
            local pencil = createMockPencil()

            pencil:handlePenTouchdown(100, 200)

            assert.equals(100, pencil.color_picker_start_x)
            assert.equals(200, pencil.color_picker_start_y)
        end)

        it("records timestamp on pen touchdown", function()
            MockTime.set(1000)
            local pencil = createMockPencil()

            pencil:handlePenTouchdown(100, 200)

            assert.equals(1000, pencil.color_picker_start_time)
        end)

        it("schedules color picker check", function()
            local pencil = createMockPencil()

            pencil:handlePenTouchdown(100, 200)

            assert.is_true(pencil.color_picker_check_pending)
        end)

    end)

    describe("movement tracking", function()

        it("resets tracking when pen moves beyond threshold", function()
            local pencil = createMockPencil()
            pencil:handlePenTouchdown(100, 100)

            -- Move beyond threshold (5 pixels)
            pencil:handlePenMove(106, 100)

            assert.is_nil(pencil.color_picker_start_x)
            assert.is_nil(pencil.color_picker_start_y)
            assert.is_nil(pencil.color_picker_start_time)
        end)

        it("keeps tracking when pen moves within threshold", function()
            local pencil = createMockPencil()
            pencil:handlePenTouchdown(100, 100)

            -- Move within threshold
            pencil:handlePenMove(103, 102)

            assert.equals(100, pencil.color_picker_start_x)
            assert.equals(100, pencil.color_picker_start_y)
        end)

        it("resets tracking on Y movement beyond threshold", function()
            local pencil = createMockPencil()
            pencil:handlePenTouchdown(100, 100)

            pencil:handlePenMove(100, 110)

            assert.is_nil(pencil.color_picker_start_x)
        end)

    end)

    describe("time-based triggering", function()

        it("shows color picker after hold time elapsed", function()
            local pencil = createMockPencil()
            MockTime.set(0)
            pencil:handlePenTouchdown(100, 100)

            MockTime.advance(COLOR_PICKER_HOLD_TIME_MS)
            local triggered = pencil:checkColorPickerTrigger()

            assert.is_true(triggered)
            assert.is_true(pencil.color_picker_showing)
        end)

        it("does not show color picker before hold time", function()
            local pencil = createMockPencil()
            MockTime.set(0)
            pencil:handlePenTouchdown(100, 100)

            MockTime.advance(COLOR_PICKER_HOLD_TIME_MS - 1)
            local triggered = pencil:checkColorPickerTrigger()

            assert.is_false(triggered)
            assert.is_false(pencil.color_picker_showing)
        end)

        it("does not show color picker if tracking was reset", function()
            local pencil = createMockPencil()
            MockTime.set(0)
            pencil:handlePenTouchdown(100, 100)
            pencil:handlePenMove(200, 100)  -- Reset tracking

            MockTime.advance(COLOR_PICKER_HOLD_TIME_MS)
            local triggered = pencil:checkColorPickerTrigger()

            assert.is_false(triggered)
            assert.is_false(pencil.color_picker_showing)
        end)

        it("resets tracking after showing color picker", function()
            local pencil = createMockPencil()
            MockTime.set(0)
            pencil:handlePenTouchdown(100, 100)
            MockTime.advance(COLOR_PICKER_HOLD_TIME_MS)
            pencil:checkColorPickerTrigger()

            assert.is_nil(pencil.color_picker_start_x)
            assert.is_nil(pencil.color_picker_start_y)
            assert.is_nil(pencil.color_picker_start_time)
        end)

    end)

    describe("liftoff handling", function()

        it("cancels color picker timer on liftoff", function()
            local pencil = createMockPencil()
            pencil:handlePenTouchdown(100, 100)

            pencil:handlePenLiftoff()

            assert.is_nil(pencil.color_picker_check_pending)
        end)

        it("resets tracking on liftoff", function()
            local pencil = createMockPencil()
            pencil:handlePenTouchdown(100, 100)

            pencil:handlePenLiftoff()

            assert.is_nil(pencil.color_picker_start_x)
        end)

    end)

end)


describe("color picker widget", function()

    it("shows at pen position", function()
        local pencil = createMockPencil()

        pencil:showColorPicker(150, 250)

        assert.is_true(pencil.color_picker_showing)
        assert.equals(150, pencil.color_picker_widget.x)
        assert.equals(250, pencil.color_picker_widget.y)
    end)

    it("can be closed", function()
        local pencil = createMockPencil()
        pencil:showColorPicker(100, 100)

        pencil:closeColorPicker()

        assert.is_false(pencil.color_picker_showing)
        assert.is_nil(pencil.color_picker_widget)
    end)

end)


describe("stroke color handling", function()

    describe("creating strokes", function()

        it("stores current pen color in new stroke", function()
            local pencil = createMockPencil()
            pencil:setPenColor(pencil.available_colors[3].color, "Orange")

            local stroke = pencil:createStrokeWithCurrentColor(1, {{ x = 100, y = 100 }})

            assert.equals("Orange", stroke.color_name)
            assert.is_not_nil(stroke.color)
        end)

        it("stores Black color by default", function()
            local pencil = createMockPencil()

            local stroke = pencil:createStrokeWithCurrentColor(1, {{ x = 100, y = 100 }})

            assert.equals("Black", stroke.color_name)
        end)

    end)

    describe("serialization", function()

        it("saves color_name not color object", function()
            local pencil = createMockPencil()
            local stroke = createStroke(1, {{ x = 100, y = 100 }}, {
                color = pencil.available_colors[4].color,
                color_name = "Yellow",
            })

            local serialized = pencil:serializeStroke(stroke)

            assert.equals("Yellow", serialized.color_name)
            assert.is_nil(serialized.color)
        end)

    end)

    describe("deserialization", function()

        it("restores color from color_name", function()
            local pencil = createMockPencil()
            local saved = {
                page = 1,
                points = {{ x = 100, y = 100 }},
                width = 3,
                tool = TOOL_PEN,
                color_name = "Blue",
            }

            local stroke = pencil:deserializeStroke(saved)

            assert.equals("Blue", stroke.color_name)
            assert.is_not_nil(stroke.color)
            assert.equals("rgb32", stroke.color.type)
        end)

        it("falls back to default color if color_name missing", function()
            local pencil = createMockPencil()
            local saved = {
                page = 1,
                points = {{ x = 100, y = 100 }},
                width = 3,
                tool = TOOL_PEN,
                -- No color_name
            }

            local stroke = pencil:deserializeStroke(saved)

            assert.is_not_nil(stroke.color)
        end)

        it("falls back to default if color_name not found", function()
            local pencil = createMockPencil()
            local saved = {
                page = 1,
                points = {{ x = 100, y = 100 }},
                width = 3,
                tool = TOOL_PEN,
                color_name = "NonexistentColor",
            }

            local stroke = pencil:deserializeStroke(saved)

            -- Should still have a color (the default)
            assert.is_not_nil(stroke.color)
        end)

    end)

end)


describe("color persistence", function()

    it("loads pen color by name", function()
        local pencil = createMockPencil()

        local success = pencil:loadPenColorByName("Green")

        assert.is_true(success)
        assert.equals("Green", pencil.tool_settings[TOOL_PEN].color_name)
        assert.is_not_nil(pencil.tool_settings[TOOL_PEN].color)
    end)

    it("returns false for unknown color name", function()
        local pencil = createMockPencil()

        local success = pencil:loadPenColorByName("UnknownColor")

        assert.is_false(success)
    end)

    it("returns false for nil color name", function()
        local pencil = createMockPencil()

        local success = pencil:loadPenColorByName(nil)

        assert.is_false(success)
    end)

end)
