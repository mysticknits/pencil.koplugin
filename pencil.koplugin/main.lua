--[[--
Pencil plugin for KOReader.
Enables freehand drawing and annotation with stylus on supported devices.

@module koplugin.pencil
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local PencilGeometry = require("lib/geometry")
local Screen = Device.screen
local Size = require("ui/size")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local time = require("ui/time")
local ffi = require("ffi")
local C = ffi.C

-- Check if device supports touch input
if not Device:isTouchDevice() then
    return { disabled = true }
end

-- Tool types
local TOOL_PEN = "pen"
local TOOL_HIGHLIGHTER = "highlighter"
local TOOL_ERASER = "eraser"

-- Color picker trigger settings
local COLOR_PICKER_DELAY_MS = 500  -- How long pen must be held still (milliseconds)
local COLOR_PICKER_TOLERANCE_PIXELS = 15  -- How many pixels pen can move while "still"

local Pencil = InputContainer:extend{
    name = "pencil_annotation",
    is_doc_only = true,  -- Only available when a document is open
    current_stroke = nil,
    strokes = nil,       -- All strokes for current document
    current_tool = TOOL_PEN,
    touch_zones_registered = false,
    undo_stack = {},     -- For undo functionality
    eraser_tool_active = false,  -- Track if physical eraser end is in use (via BTN_TOOL_RUBBER)

    -- Stylus callback for lowest latency (via Input:registerStylusCallback)
    stylus_callback_registered = false,
    pen_down = false,
    erasing = false,  -- Track if currently in erase mode (for finger modifier)
    pen_x = 0,
    pen_y = 0,

    last_refresh_time = 0,
    refresh_interval_ms = 16,  -- Refresh at most every 16ms during drawing (~60fps)
    dirty_region = nil,  -- Accumulated dirty region for batch refresh

    -- Delayed refresh - only refresh after user stops writing
    pending_refresh = nil,
    refresh_delay_ms = 600, -- Wait 600ms after last stroke before final refresh

    -- Tool settings
    tool_settings = {
        [TOOL_PEN] = {
            width = 3,
            color = nil,  -- Blitbuffer color, set in init
            color_name = "Black",  -- For persistence and display
            alpha = 255,
        },
        [TOOL_HIGHLIGHTER] = {
            width = 20,
            color = nil,  -- Set in init (needs Blitbuffer)
            alpha = 128,
        },
        [TOOL_ERASER] = {
            width = 20,
        },
    },

    -- Side button state
    side_button_down = false,
    side_button_used_for_highlight = false,  -- Track if button was used during a stroke

    -- Color picker state (triggered by holding pen within 5 pixels for 5 seconds)
    color_picker_start_x = nil,  -- Initial X position when pen touched down
    color_picker_start_y = nil,  -- Initial Y position when pen touched down
    color_picker_start_time = nil,  -- Timestamp when pen touched down (nil if moved too far)
    color_picker_check_pending = nil,  -- Scheduled periodic check
    color_picker_showing = false,  -- Whether color picker is currently displayed

    -- Available colors for the pen (initialized in init() with actual Blitbuffer colors)
    available_colors = {},
}

function Pencil:init()
    self.ui.menu:registerToMainMenu(self)
    self.strokes = {}
    self.page_strokes = {}  -- Index: page -> array of stroke indices
    self.undo_stack = {}

    -- Initialize highlighter color (yellow)
    self.tool_settings[TOOL_HIGHLIGHTER].color = Blitbuffer.Color8(0xDD)  -- Light gray for e-ink

    -- Calculate gray value from highlight_lighten_factor setting
    local lighten_factor = G_reader_settings:readSetting("highlight_lighten_factor") or 0.2
    local gray_value = math.floor(255 * (1 - lighten_factor))

    -- Available colors for color picker (Blitbuffer color values)
    self.available_colors = {
        { name = "Black", color = Blitbuffer.COLOR_BLACK },
        { name = "Red", color = Blitbuffer.ColorRGB32(0xFF, 0x33, 0x00, 0xFF) },
        { name = "Orange", color = Blitbuffer.ColorRGB32(0xFF, 0x88, 0x00, 0xFF) },
        { name = "Yellow", color = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0x33, 0xFF) },
        { name = "Green", color = Blitbuffer.ColorRGB32(0x00, 0xAA, 0x66, 0xFF) },
        { name = "Olive", color = Blitbuffer.ColorRGB32(0x88, 0xFF, 0x77, 0xFF) },
        { name = "Cyan", color = Blitbuffer.ColorRGB32(0x00, 0xFF, 0xEE, 0xFF) },
        { name = "Blue", color = Blitbuffer.ColorRGB32(0x00, 0x66, 0xFF, 0xFF) },
        { name = "Purple", color = Blitbuffer.ColorRGB32(0xEE, 0x00, 0xFF, 0xFF) },
        { name = "Gray", color = Blitbuffer.Color8(gray_value) },
    }

    -- Load tool and stylus button settings
    self:loadSettings()

    -- Ensure pen color has a default value (black) if not set
    if not self.tool_settings[TOOL_PEN].color then
        self.tool_settings[TOOL_PEN].color = Blitbuffer.COLOR_BLACK
        self.tool_settings[TOOL_PEN].color_name = "Black"
    end

    -- Register as view module to render strokes
    self.view = self.ui.view
    self.view:registerViewModule("pencil_strokes", self)

    -- Try to load strokes now if doc_settings is ready
    -- (backup: they'll also be loaded in onReaderReady/onReadSettings)
    if self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir then
        logger.info("Pencil: doc_settings available in init, loading strokes")
        self:loadStrokes()
    else
        logger.info("Pencil: doc_settings not ready in init, will load in onReaderReady")
    end

    -- Check if plugin is enabled globally and auto-setup
    if self:isEnabled() then
        self:setupPenInput()
    end

    -- Install input event hook for debugging (if debug mode enabled)
    self:installInputDebugHook()

    -- Register custom actions for gesture mapping
    Dispatcher:registerAction("pencil_toggle_tool", {
        category = "none",
        event = "PencilToggleTool",
        title = _("Pencil: toggle pencil/eraser"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_toggle_enabled", {
        category = "none",
        event = "PencilToggleEnabled",
        title = _("Pencil: toggle on/off"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_pen", {
        category = "none",
        event = "PencilSelectPen",
        title = _("Pencil: select pencil"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_select_eraser", {
        category = "none",
        event = "PencilSelectEraser",
        title = _("Pencil: select eraser"),
        reader = true,
    })
    Dispatcher:registerAction("pencil_undo", {
        category = "none",
        event = "PencilUndo",
        title = _("Pencil: undo"),
        reader = true,
        separator = true,
    })

    logger.info("Pencil: initialized, enabled =", self:isEnabled(), "tool =", self.current_tool, "strokes =", #self.strokes)
end

-- Dispatcher event handlers (for custom gesture mapping)
function Pencil:onPencilToggleTool()
    if self.current_tool == TOOL_ERASER then
        self.current_tool = TOOL_PEN
    else
        self.current_tool = TOOL_ERASER
    end
    local display_name = self.current_tool == TOOL_PEN and _("pencil") or _("eraser")
    UIManager:show(InfoMessage:new{
        text = T(_("Tool: %1"), display_name),
        timeout = 1,
    })
    return true
end

function Pencil:onPencilToggleEnabled()
    local enabled = self:isEnabled()
    self:setEnabled(not enabled)
    if self:isEnabled() then
        self:setupPenInput()
        UIManager:show(InfoMessage:new{
            text = _("Pencil enabled"),
            timeout = 1,
        })
    else
        self:teardownPenInput()
        UIManager:show(InfoMessage:new{
            text = _("Pencil disabled"),
            timeout = 1,
        })
    end
    return true
end

function Pencil:onPencilSelectPen()
    self.current_tool = TOOL_PEN
    UIManager:show(InfoMessage:new{
        text = _("Pencil tool: pencil"),
        timeout = 1,
    })
    return true
end

function Pencil:onPencilSelectEraser()
    self.current_tool = TOOL_ERASER
    UIManager:show(InfoMessage:new{
        text = _("Eraser selected"),
        timeout = 1,
    })
    return true
end

function Pencil:onPencilUndo()
    self:undo()
    return true
end

-- Setup stylus callback for lowest latency pen capture
-- Uses the new Input:registerStylusCallback() API that intercepts stylus events
-- before they reach the gesture detector
function Pencil:setupStylusCallback()
    if self.stylus_callback_registered then return end

    local Input = Device.input
    if not Input or not Input.registerStylusCallback then
        logger.warn("Pencil: stylus callback API not available")
        return
    end

    local plugin = self

    -- Register the stylus callback
    -- Callback receives: input (Input object), slot (table with slot, id, x, y, tool, timev)
    -- Return true to "dominate" (remove from gesture detection)
    Input:registerStylusCallback(function(input, slot)
        return plugin:handleStylusSlot(input, slot)
    end)

    self.stylus_callback_registered = true
    logger.info("Pencil: stylus callback registered")
end

-- Transform stylus coordinates based on screen rotation
-- Raw stylus coordinates are in hardware space; framebuffer expects logical (rotated) space
function Pencil:transformCoordinates(x, y)
    local rotation = Screen:getRotationMode()
    return PencilGeometry.transformForRotation(x, y, rotation, Screen:getWidth(), Screen:getHeight())
end


-- Handle a stylus slot from the callback
-- slot = {slot=N, id=N, x=N, y=N, tool=N, timev=timestamp}
-- id >= 0 means contact active, id == -1 means contact lifted
function Pencil:handleStylusSlot(input, slot)
    if not self:isEnabled() then return false end

    -- Log in debug mode
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS: slot=%d id=%d x=%d y=%d tool=%d pen_down=%s tool=%s",
                slot.slot or -1, slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
                tostring(self.pen_down), self.current_tool))
    end

    -- Determine effective tool:
    -- 1. Physical eraser end (BTN_TOOL_RUBBER) takes priority
    -- 2. Otherwise use selected tool (user can toggle via gesture)
    local effective_tool
    if self.eraser_tool_active then
        effective_tool = TOOL_ERASER
    else
        effective_tool = self.current_tool
    end

    -- Handle eraser mode
    if effective_tool == TOOL_ERASER then
        if self.input_debug_mode and not self.erasing then
            self:writeDebugLog(string.format("ERASER MODE: pen_down=%s slot.id=%d",
                    tostring(self.pen_down), slot.id or -1))
        end
        if slot.id and slot.id >= 0 then
            -- Eraser is touching - erase at this position
            local first_touch = false
            if not self.pen_down then
                self.pen_down = true
                self.erasing = true
                self.eraser_deleted = {}
                first_touch = true
                if self.input_debug_mode then
                    self:writeDebugLog("=== ERASER DOWN ===")
                end
            end

            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            -- Erase on first touch OR when position changes
            if first_touch or x ~= self.pen_x or y ~= self.pen_y then
                local page = self:getCurrentPage()
                if self.input_debug_mode then
                    self:writeDebugLog(string.format("ERASE ATTEMPT at (%d, %d) page=%s erasing=%s",
                            x, y, tostring(page), tostring(self.erasing)))
                end
                local deleted = self:eraseAtPoint(x, y, page)
                if deleted then
                    for _, stroke in ipairs(deleted) do
                        table.insert(self.eraser_deleted, stroke)
                    end
                    -- Immediately repaint view and our strokes overlay, then refresh
                    self.view:paintTo(Screen.bb, 0, 0)
                    self:paintTo(Screen.bb, 0, 0)
                    Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
                    if self.input_debug_mode then
                        self:writeDebugLog(string.format("ERASED %d strokes at (%d, %d)", #deleted, x, y))
                    end
                end
                self.pen_x = x
                self.pen_y = y
            end
        else
            -- Eraser lifted
            if self.pen_down and self.erasing then
                self.pen_down = false
                self.erasing = false
                if self.eraser_deleted and #self.eraser_deleted > 0 then
                    table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_deleted })
                    self:saveStrokes()
                end
                self.eraser_deleted = nil
                UIManager:setDirty(self.view, "ui")
                if self.input_debug_mode then
                    self:writeDebugLog("=== ERASER UP ===")
                end
            end
        end
        return true  -- Dominate: remove from gesture detection
    end

    -- Handle pen/highlighter mode
    if slot.id and slot.id >= 0 then
        -- Pen down or moving
        if not self.pen_down then
            -- Check if color picker is showing - route pen tap to it
            if self.color_picker_showing and self.color_picker_widget then
                local raw_x = slot.x or 0
                local raw_y = slot.y or 0
                local x, y = self:transformCoordinates(raw_x, raw_y)
                if self.color_picker_widget:handlePenTap(x, y) then
                    -- Color picker handled the tap, don't start a stroke
                    return true
                end
            end

            -- Start new stroke
            self.pen_down = true
            self.erasing = false
            self:cancelPendingRefresh()
            self:cancelColorPickerTimer()
            self:startRawStroke()
            -- Record initial position and timestamp for color picker trigger
            local raw_x = slot.x or 0
            local raw_y = slot.y or 0
            local x, y = self:transformCoordinates(raw_x, raw_y)
            self.pen_x = x
            self.pen_y = y
            self.color_picker_start_x = x
            self.color_picker_start_y = y
            self.color_picker_start_time = time.now()
            -- Schedule periodic check for color picker trigger
            self:scheduleColorPickerCheck()
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN DOWN ===")
            end
        else
            -- Pen is moving
            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            if x ~= self.pen_x or y ~= self.pen_y then
                -- Check if pen moved more than tolerance from start position
                if self.color_picker_start_x and self.color_picker_start_y then
                    local dx = math.abs(x - self.color_picker_start_x)
                    local dy = math.abs(y - self.color_picker_start_y)
                    if dx > COLOR_PICKER_TOLERANCE_PIXELS or dy > COLOR_PICKER_TOLERANCE_PIXELS then
                        -- Pen moved too far - reset tracking (no color picker)
                        self:resetColorPickerTracking()
                    end
                end
                self:addRawPoint(x, y)
                self.pen_x = x
                self.pen_y = y
            end
        end
    else
        -- Pen lifted (id == -1)
        if self.pen_down and not self.erasing then
            self.pen_down = false
            self:cancelColorPickerTimer()
            self:endRawStroke()
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN UP ===")
            end
        end
    end

    return true  -- Dominate: remove from gesture detection
end

-- Teardown stylus callback
function Pencil:teardownStylusCallback()
    if not self.stylus_callback_registered then return end

    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end

    self.stylus_callback_registered = false
    self.pen_down = false
    logger.info("Pencil: stylus callback unregistered")
end

-- Start a new stroke from raw input
function Pencil:startRawStroke()
    local page = self:getCurrentPage()
    local tool = self.side_button_down and TOOL_HIGHLIGHTER or self.current_tool
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]

    if self.side_button_down then
        self.side_button_used_for_highlight = true
    end

    self.current_stroke = {
        page = page,
        tool = tool,
        points = {},
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }
    self.last_refresh_time = time.now()
    self.dirty_region = nil  -- Clear any pending dirty region
    logger.dbg("Pencil: raw stroke started")
end

-- Add a point from raw input and draw it
function Pencil:addRawPoint(x, y)
    if not self.current_stroke then return end

    local point = { x = x, y = y }
    table.insert(self.current_stroke.points, point)

    local n = #self.current_stroke.points

    local width = self.current_stroke.width
    local color = self.current_stroke.color
    local half_w = math.floor(width / 2) + 2  -- padding for antialiasing

    -- Draw to framebuffer and track dirty region
    local dirty_x, dirty_y, dirty_w, dirty_h
    if n == 1 then
        -- Draw first point same size as line segments for consistency
        local half_w_draw = math.floor(width / 2)
        Screen.bb:paintRectRGB32(x - half_w_draw, y - half_w_draw, width, width, color)
        -- Use slightly larger dirty region for refresh padding
        dirty_x = x - half_w
        dirty_y = y - half_w
        dirty_w = width + 4
        dirty_h = width + 4
    elseif n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]
        if self.current_stroke.tool == TOOL_HIGHLIGHTER then
            self:drawHighlighterSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        else
            self:drawLineSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
        -- Calculate bounding box of the segment
        dirty_x = math.min(p1.x, p2.x) - half_w
        dirty_y = math.min(p1.y, p2.y) - half_w
        dirty_w = math.abs(p2.x - p1.x) + width + 4
        dirty_h = math.abs(p2.y - p1.y) + width + 4
    end

    -- Accumulate dirty region for batch refresh
    if dirty_x then
        if self.dirty_region then
            -- Expand existing dirty region
            local r = self.dirty_region
            local new_x = math.min(r.x, dirty_x)
            local new_y = math.min(r.y, dirty_y)
            local new_x2 = math.max(r.x + r.w, dirty_x + dirty_w)
            local new_y2 = math.max(r.y + r.h, dirty_y + dirty_h)
            self.dirty_region = { x = new_x, y = new_y, w = new_x2 - new_x, h = new_y2 - new_y }
        else
            self.dirty_region = { x = dirty_x, y = dirty_y, w = dirty_w, h = dirty_h }
        end
    end

    -- Periodic refresh of dirty region only
    local now = time.now()
    if time.to_ms(now - self.last_refresh_time) >= self.refresh_interval_ms then
        self.last_refresh_time = now
        if self.dirty_region then
            local r = self.dirty_region
            -- Clamp to screen bounds
            local rx = math.max(0, math.floor(r.x))
            local ry = math.max(0, math.floor(r.y))
            local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
            local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
            -- Use UI refresh mode for proper color rendering on color e-ink
            Screen:refreshUI(rx, ry, rw, rh)
            self.dirty_region = nil
        end
    end
end

-- End stroke from raw input
function Pencil:endRawStroke()
    if self.input_debug_mode then
        self:writeDebugLog(string.format("endRawStroke: current_stroke=%s points=%d",
                tostring(self.current_stroke ~= nil),
                self.current_stroke and #self.current_stroke.points or 0))
    end
    if self.current_stroke and #self.current_stroke.points >= 1 then
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self:saveStrokes()
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        if self.input_debug_mode then
            self:writeDebugLog(string.format("endRawStroke: SAVED stroke #%d with %d points, total strokes=%d",
                    #self.strokes, #self.current_stroke.points, #self.strokes))
        end
        logger.dbg("Pencil: raw stroke ended with", #self.current_stroke.points, "points")
    else
        if self.input_debug_mode then
            self:writeDebugLog("endRawStroke: NOT SAVED (no current_stroke or no points)")
        end
    end
    self.current_stroke = nil
    -- Schedule delayed refresh for clean display after writing stops
    self:scheduleDelayedRefresh()
end

-- Get the path to the plugin's log file
function Pencil:getDebugLogPath()
    -- Write to KOReader's data directory (always writable)
    local log_dir = DataStorage:getDataDir()
    return log_dir .. "/pencil_input_debug.log"
end

-- Write a line to the debug log file
function Pencil:writeDebugLog(msg)
    if not self.input_debug_mode then return end

    local log_path = self:getDebugLogPath()
    local f = io.open(log_path, "a")
    if f then
        local timestamp = os.date("%H:%M:%S")
        f:write(string.format("[%s] %s\n", timestamp, msg))
        f:close()
    end
end

-- Clear the debug log file
function Pencil:clearDebugLog()
    local log_path = self:getDebugLogPath()
    local f = io.open(log_path, "w")
    if f then
        f:write("=== Pencil Annotation Input Debug Log ===\n")
        f:write("Started: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        local device_name = "unknown"
        if Device.model then
            device_name = Device.model
        elseif Device.getDeviceName then
            device_name = Device:getDeviceName() or "unknown"
        end
        f:write("Device: " .. device_name .. "\n")
        f:write("==========================================\n\n")
        f:close()
        logger.info("Pencil: cleared debug log at", log_path)
    end
end

-- Install a hook to log raw input events (for debugging eraser detection)
function Pencil:installInputDebugHook()
    if not self.input_debug_mode then return end

    -- Clear and start fresh log
    self:clearDebugLog()
    self:writeDebugLog("Input debug hook being installed...")

    local Input = Device.input
    if not Input then
        self:writeDebugLog("ERROR: Device.input not available")
        return
    end

    -- Log device info
    local pen_slot_str = tostring(Input.pen_slot or "nil")
    self:writeDebugLog("Input.pen_slot = " .. pen_slot_str)

    -- Event name lookup tables
    local btn_names = {
        [320] = "BTN_TOOL_PEN",
        [321] = "BTN_TOOL_RUBBER",
        [322] = "BTN_TOOL_BRUSH",
        [323] = "BTN_TOOL_PENCIL",
        [324] = "BTN_TOOL_AIRBRUSH",
        [325] = "BTN_TOOL_FINGER",
        [326] = "BTN_TOOL_MOUSE",
        [327] = "BTN_TOOL_LENS",
        [330] = "BTN_TOUCH",
        [331] = "BTN_STYLUS",
        [332] = "BTN_STYLUS2",
    }

    local abs_names = {
        [0] = "ABS_X",
        [1] = "ABS_Y",
        [24] = "ABS_PRESSURE",
        [25] = "ABS_DISTANCE",
        [47] = "ABS_MT_SLOT",
        [48] = "ABS_MT_TOUCH_MAJOR",
        [49] = "ABS_MT_TOUCH_MINOR",
        [53] = "ABS_MT_POSITION_X",
        [54] = "ABS_MT_POSITION_Y",
        [55] = "ABS_MT_TOOL_TYPE",
        [57] = "ABS_MT_TRACKING_ID",
        [58] = "ABS_MT_PRESSURE",
    }

    local tool_types = {
        [0] = "FINGER",
        [1] = "PEN",
        [2] = "ERASER",
    }

    -- Hook into the main event handler to see ALL events
    if not self._original_handleTouchEv and Input.handleTouchEv then
        self._original_handleTouchEv = Input.handleTouchEv
        local plugin = self
        Input.handleTouchEv = function(input_self, ev)
            local type_name = "UNK"
            local code_name = tostring(ev.code)
            local extra_info = ""

            if ev.type == 0 then
                type_name = "SYN"
            elseif ev.type == 1 then
                type_name = "KEY"
                code_name = btn_names[ev.code] or tostring(ev.code)
            elseif ev.type == 3 then
                type_name = "ABS"
                code_name = abs_names[ev.code] or tostring(ev.code)
                if ev.code == 55 then
                    extra_info = " -> " .. (tool_types[ev.value] or "?")
                end
            end

            local msg = type_name .. " " .. code_name .. "=" .. tostring(ev.value) .. extra_info
            plugin:writeDebugLog(msg)

            return plugin._original_handleTouchEv(input_self, ev)
        end
        self:writeDebugLog("Touch hook installed")
        logger.info("Pencil: Touch debug hook installed")
    end

    self:writeDebugLog("")
    self:writeDebugLog("=== Ready - use pen tip and eraser end ===")
    self:writeDebugLog("")
end

-- Load plugin settings
function Pencil:loadSettings()
    local settings = G_reader_settings:readSetting("pencil_annotation_settings") or {}
    -- Always start with pencil tool when opening a book
    self.current_tool = TOOL_PEN
    -- Input debug mode: log all input details
    self.input_debug_mode = settings.input_debug_mode or false
    -- Load pen color by name and look up the actual color value
    local color_name = settings.pen_color_name
    if color_name then
        self.tool_settings[TOOL_PEN].color_name = color_name
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == color_name then
                self.tool_settings[TOOL_PEN].color = color_info.color
                break
            end
        end
    end
end

-- Save plugin settings
function Pencil:saveSettings()
    G_reader_settings:saveSetting("pencil_annotation_settings", {
        input_debug_mode = self.input_debug_mode,
        pen_color_name = self.tool_settings[TOOL_PEN].color_name,
    })
end

-- Set current tool
function Pencil:setTool(tool)
    self.current_tool = tool
    self:saveSettings()
    -- Show visual feedback with proper display name
    local display_name = tool == TOOL_PEN and _("pencil") or _("eraser")
    UIManager:show(InfoMessage:new{
        text = T(_("Tool: %1"), display_name),
        timeout = 1,
    })
end

-- Get current tool settings
function Pencil:getCurrentToolSettings()
    return self.tool_settings[self.current_tool] or self.tool_settings[TOOL_PEN]
end

-- Check if plugin is enabled (global setting)
function Pencil:isEnabled()
    return G_reader_settings:isTrue("pencil_annotation_enabled")
end

-- Set enabled state (global setting)
function Pencil:setEnabled(enabled)
    G_reader_settings:saveSetting("pencil_annotation_enabled", enabled)
end

function Pencil:addToMainMenu(menu_items)
    menu_items.pencil_annotation = {
        text = _("Pencil"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Enable pencil"),
                checked_func = function()
                    return self:isEnabled()
                end,
                callback = function()
                    local new_state = not self:isEnabled()
                    self:setEnabled(new_state)
                    if new_state then
                        self:setupPenInput()
                    else
                        self:teardownPenInput()
                    end
                end,
                separator = true,
            },
            {
                text = _("Tool"),
                help_text = _("Select pencil or eraser."),
                sub_item_table = {
                    {
                        text = _("Pencil"),
                        checked_func = function()
                            return self.current_tool == TOOL_PEN
                        end,
                        callback = function()
                            self:setTool(TOOL_PEN)
                        end,
                    },
                    {
                        text = _("Eraser"),
                        checked_func = function()
                            return self.current_tool == TOOL_ERASER
                        end,
                        callback = function()
                            self:setTool(TOOL_ERASER)
                        end,
                    },
                },
            },
            {
                text = _("Undo last stroke"),
                callback = function()
                    self:undoLastStroke()
                end,
                enabled_func = function()
                    return #self.undo_stack > 0
                end,
                separator = true,
            },
            {
                text = _("Clear page strokes"),
                callback = function()
                    self:clearPageStrokes()
                end,
                enabled_func = function()
                    return self:hasStrokesOnCurrentPage()
                end,
            },
            {
                text = _("Clear all strokes"),
                callback = function()
                    self:clearAllStrokes()
                end,
                enabled_func = function()
                    return #self.strokes > 0
                end,
                separator = true,
            },
            {
                text = _("Input debug mode"),
                help_text = _("Enable detailed logging of input events to help diagnose stylus detection issues."),
                checked_func = function()
                    return self.input_debug_mode
                end,
                callback = function()
                    self.input_debug_mode = not self.input_debug_mode
                    self:saveSettings()
                    if self.input_debug_mode then
                        -- Install the hook now that debug mode is enabled
                        self:installInputDebugHook()
                        UIManager:show(InfoMessage:new{
                            text = T(_("Input debug mode enabled.\n\nLog file: %1\n\nUse both pen tip and eraser end, then check the log."), self:getDebugLogPath()),
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Input debug mode disabled."),
                        })
                    end
                end,
            },
            {
                text = _("View debug log path"),
                enabled_func = function()
                    return self.input_debug_mode
                end,
                callback = function()
                    local log_path = self:getDebugLogPath()
                    -- Check if log file exists
                    local f = io.open(log_path, "r")
                    local size = 0
                    local lines = 0
                    if f then
                        local content = f:read("*a")
                        size = #content
                        for _ in content:gmatch("\n") do lines = lines + 1 end
                        f:close()
                    end
                    UIManager:show(InfoMessage:new{
                        text = T(_("Debug log location:\n%1\n\nSize: %2 bytes\nLines: %3\n\nConnect your Kobo via USB to access this file."), log_path, size, lines),
                    })
                end,
            },
            {
                text = _("Clear debug log"),
                enabled_func = function()
                    return self.input_debug_mode
                end,
                callback = function()
                    self:clearDebugLog()
                    UIManager:show(InfoMessage:new{
                        text = _("Debug log cleared. Ready to capture new input events."),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Show annotation status"),
                callback = function()
                    self:showAnnotationStatus()
                end,
            },
        },
    }
end

-- Show current annotation status for debugging
function Pencil:showAnnotationStatus()
    local page = self:getCurrentPage()
    local page_strokes = self.page_strokes[page] and #self.page_strokes[page] or 0
    local filepath = self:getStrokesFilePath() or "not available"

    -- Show all pages with strokes for debugging
    local pages_info = ""
    for p, indices in pairs(self.page_strokes) do
        pages_info = pages_info .. string.format("\n  %s (%s): %d", tostring(p), type(p), #indices)
    end
    if pages_info == "" then
        pages_info = "\n  (none)"
    end

    -- Stylus callback status
    local Input = Device.input
    local pen_slot = Input and Input.pen_slot or "N/A"
    local stylus_callback_status = self.stylus_callback_registered and "registered" or "not registered"
    local pen_down_status = self.pen_down and "YES" or "no"

    local status_text = T(_([[Pencil Annotation Status

Selected tool: %1
Total strokes: %2
Strokes on this page: %3
Current page: %4 (%5)
Storage file: %6
Enabled: %7

Stylus callback: %9
Pen slot: %10
Pen down: %11

Side button: tap to toggle pen/eraser, hold+drag to highlight.

Enable "Input debug mode" to log raw events for diagnosis.

Pages with strokes:%8]]),
            self.current_tool,
            #self.strokes,
            page_strokes,
            tostring(page),
            type(page),
            filepath,
            self:isEnabled() and _("Yes") or _("No"),
            pages_info,
            stylus_callback_status,
            tostring(pen_slot),
            pen_down_status
    )

    UIManager:show(InfoMessage:new{
        text = status_text,
    })
end

-- Handle stylus button press (down event)
-- Side button behavior:
--   - Hold + drag = temporarily highlight, then return to original tool
--   - Quick press (no drawing while held) = toggle between pen and eraser
function Pencil:onStylusButtonPress()
    if not self:isEnabled() then return false end

    self.side_button_down = true
    self.side_button_used_for_highlight = false

    logger.dbg("Pencil: side button pressed")
    return true
end

-- Handle stylus button release (up event)
function Pencil:onStylusButtonRelease()
    if not self:isEnabled() then return false end

    local was_down = self.side_button_down
    self.side_button_down = false

    -- If the button was NOT used for highlighting (no drawing while held),
    -- treat it as a quick press to toggle between pen and eraser
    if was_down and not self.side_button_used_for_highlight then
        logger.dbg("Pencil: side button quick press - toggling pen/eraser")
        self:togglePenEraser()
    else
        -- Was used for highlighting - show brief feedback that we're back to normal
        logger.dbg("Pencil: highlight complete, back to", self.current_tool)
    end

    self.side_button_used_for_highlight = false
    return true
end

-- Toggle between pen and eraser
function Pencil:togglePenEraser()
    local old_tool = self.current_tool
    local new_tool
    if self.current_tool == TOOL_ERASER then
        new_tool = TOOL_PEN
    else
        new_tool = TOOL_ERASER
    end

    self.current_tool = new_tool
    self:saveSettings()
    logger.dbg("Pencil: toggled from", old_tool, "to", new_tool)

    -- Show brief visual feedback
    UIManager:show(InfoMessage:new{
        text = T(_("Tool: %1"), new_tool),
        timeout = 0.5,
    })
end

-- Handle stylus button and tool events
function Pencil:onKeyPress(key)
    local key_str = tostring(key)

    -- Always log key events when debug mode is on (even if not enabled)
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY PRESS: %s", key_str))
    end

    if not self:isEnabled() then return false end

    -- BTN_TOOL_RUBBER - physical eraser end (if device supports it)
    if key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber") then
        logger.dbg("Pencil: BTN_TOOL_RUBBER press detected")
        self.eraser_tool_active = true
        return true
    end

    -- BTN_TOOL_PEN - pen tip
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then
        logger.dbg("Pencil: BTN_TOOL_PEN press detected")
        self.eraser_tool_active = false
        return true
    end

    -- BTN_STYLUS (331) - side button on stylus (mapped to "Eraser" on Kobo)
    -- BTN_STYLUS2 (332) - second side button (mapped to "Highlighter" on Kobo)
    if key_str:match("Eraser") or key_str:match("Highlighter") or key_str:match("Stylus") then
        logger.dbg("Pencil: Stylus button press detected:", key_str)
        return self:onStylusButtonPress()
    end
    return false
end

function Pencil:onKeyRelease(key)
    local key_str = tostring(key)

    -- Always log key events when debug mode is on (even if not enabled)
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY RELEASE: %s", key_str))
    end

    if not self:isEnabled() then return false end

    -- BTN_TOOL_RUBBER released
    if key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber") then
        logger.dbg("Pencil: BTN_TOOL_RUBBER release detected")
        self.eraser_tool_active = false
        return true
    end

    -- BTN_TOOL_PEN released
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then
        logger.dbg("Pencil: BTN_TOOL_PEN release detected")
        return true
    end

    -- Side button released
    if key_str:match("Eraser") or key_str:match("Highlighter") or key_str:match("Stylus") then
        logger.dbg("Pencil: Stylus button release detected:", key_str)
        return self:onStylusButtonRelease()
    end
    return false
end

-- Undo last stroke
function Pencil:undoLastStroke()
    if #self.undo_stack == 0 then return end

    local last_action = table.remove(self.undo_stack)
    if last_action.type == "add" then
        -- Remove the stroke that was added
        local stroke_idx = last_action.stroke_idx
        if stroke_idx and self.strokes[stroke_idx] then
            table.remove(self.strokes, stroke_idx)
            self:rebuildPageIndex()
            self:saveStrokes()
            UIManager:setDirty(self.view, "ui")
        end
    elseif last_action.type == "delete" then
        -- Restore deleted strokes
        for _, stroke in ipairs(last_action.strokes) do
            table.insert(self.strokes, stroke)
        end
        self:rebuildPageIndex()
        self:saveStrokes()
        UIManager:setDirty(self.view, "ui")
    end
end

function Pencil:setupPenInput()
    if self.touch_zones_registered then return end

    logger.dbg("Pencil: setting up touch zones")

    -- Setup stylus callback for lowest latency pen capture
    self:setupStylusCallback()
    -- Register touch zones through the UI so they're in the active gesture hierarchy
    -- We need to override ALL gestures that might interfere with drawing
    self.ui:registerTouchZones({
        {
            -- Touch gesture fires IMMEDIATELY on first contact - critical for capturing stroke start
            id = "pencil_draw_touch",
            ges = "touch",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {},
            handler = function(ges)
                return self:onDrawTouch(ges)
            end,
        },
        {
            id = "pencil_draw_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "tap_forward",
                "tap_backward",
                "readerfooter_tap",
                "readerconfigmenu_tap",
                "readerhighlight_tap",
                "readermenu_tap",
                "paging_tap",
                "rolling_tap",
            },
            handler = function(ges)
                return self:onDrawTap(ges)
            end,
        },
        {
            id = "pencil_draw_hold",
            ges = "hold",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "readerhighlight_hold",
                "readerfooter_hold",
            },
            handler = function(ges)
                return self:onDrawHold(ges)
            end,
        },
        {
            id = "pencil_draw_pan",
            ges = "pan",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan",
                "rolling_pan",
                "paging_swipe",
                "rolling_swipe",
                "readerhighlight_pan",
            },
            handler = function(ges)
                return self:onDrawPan(ges)
            end,
        },
        {
            id = "pencil_draw_pan_release",
            ges = "pan_release",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan_release",
                "rolling_pan_release",
                "readerhighlight_pan_release",
            },
            handler = function(ges)
                return self:onDrawPanRelease(ges)
            end,
        },
        {
            id = "pencil_draw_swipe",
            ges = "swipe",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_swipe",
                "rolling_swipe",
                "readerhighlight_swipe",
            },
            handler = function(ges)
                return self:onDrawSwipe(ges)
            end,
        },
    })
    self.touch_zones_registered = true
end

function Pencil:teardownPenInput()
    if not self.touch_zones_registered then return end

    -- Teardown stylus callback
    self:teardownStylusCallback()

    self.ui:unRegisterTouchZones({
        { id = "pencil_draw_touch" },  -- Must unregister touch zone too
        { id = "pencil_draw_tap" },
        { id = "pencil_draw_hold" },
        { id = "pencil_draw_pan" },
        { id = "pencil_draw_pan_release" },
        { id = "pencil_draw_swipe" },
    })
    self.touch_zones_registered = false
end

-- Handle swipe gestures (block them when drawing mode is active)
function Pencil:onDrawSwipe(ges)
    if not self:isEnabled() then return false end

    -- If raw input detected pen, block swipe to prevent page turns
    if self.pen_down then return true end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then return false end

    -- Block the swipe - we don't want page turns while drawing
    return true
end

-- Handle tip long press (hold gesture)
function Pencil:onDrawHold(ges)
    if not self:isEnabled() then return false end

    -- If raw input detected pen, block hold to prevent reader highlight mode
    if self.pen_down then return true end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then return false end

    -- Block pen hold gestures while drawing mode is active
    return true
end

-- Schedule a delayed refresh after writing stops
function Pencil:scheduleDelayedRefresh()
    -- Cancel any existing pending refresh
    self:cancelPendingRefresh()

    -- Schedule new refresh
    self.pending_refresh = UIManager:scheduleIn(self.refresh_delay_ms / 1000, function()
        self.pending_refresh = nil
        -- Do a fast refresh of the whole view to show all recent strokes
        UIManager:setDirty(self.view, "fast")
        logger.dbg("Pencil: delayed refresh triggered")
    end)
end

-- Cancel pending refresh (called when new stroke starts)
function Pencil:cancelPendingRefresh()
    if self.pending_refresh then
        UIManager:unschedule(self.pending_refresh)
        self.pending_refresh = nil
    end
end

-- Reset color picker tracking (called when pen moves too far)
function Pencil:resetColorPickerTracking()
    self.color_picker_start_x = nil
    self.color_picker_start_y = nil
    self.color_picker_start_time = nil
end

-- Check if color picker should be shown (called periodically while pen is down)
function Pencil:checkColorPickerTrigger()
    if not self.color_picker_start_time then return end
    if self.color_picker_showing then return end

    local elapsed_ms = time.to_ms(time.now() - self.color_picker_start_time)
    if elapsed_ms >= COLOR_PICKER_DELAY_MS then
        -- Time elapsed without moving too far - show color picker
        self:showColorPicker(self.pen_x, self.pen_y)
        self:resetColorPickerTracking()
    end
end

-- Schedule periodic check for color picker trigger
function Pencil:scheduleColorPickerCheck()
    if self.color_picker_check_pending then
        UIManager:unschedule(self.color_picker_check_pending)
    end

    local plugin = self
    -- Check every 100ms for trigger
    self.color_picker_check_pending = UIManager:scheduleIn(0.1, function()
        plugin.color_picker_check_pending = nil
        if plugin.pen_down and plugin.color_picker_start_time and not plugin.color_picker_showing then
            plugin:checkColorPickerTrigger()
            -- Schedule next check if still waiting
            if plugin.color_picker_start_time then
                plugin:scheduleColorPickerCheck()
            end
        end
    end)
end

-- Cancel color picker check
function Pencil:cancelColorPickerTimer()
    if self.color_picker_check_pending then
        UIManager:unschedule(self.color_picker_check_pending)
        self.color_picker_check_pending = nil
    end
    self:resetColorPickerTracking()
end

-- Color picker widget for selecting pen color
local ColorPickerWidget = InputContainer:extend {
    width = nil,
    height = nil,
    colors = nil, -- Array of {color, name} objects
    current_color_name = nil, -- Currently selected color name (for comparison)
    callback = nil,
    close_callback = nil,
}

function ColorPickerWidget:init()
    local button_size = Screen:scaleBySize(36)
    local spacing = Screen:scaleBySize(8)
    local padding = Screen:scaleBySize(10)
    local selection_border = Size.border.thick * 3  -- Thicker border for selected color

    -- Calculate width dynamically based on number of colors
    local num_colors = #self.colors
    local buttons_width = num_colors * button_size + (num_colors - 1) * spacing
    -- Width is just buttons - FrameContainer adds padding on all sides
    self.width = buttons_width
    self.height = button_size  -- FrameContainer adds equal padding all sides

    -- Store button info for later position update
    self.color_buttons_info = {}

    -- Create color buttons
    local color_buttons = HorizontalGroup:new{ align = "center" }

    for i, color_info in ipairs(self.colors) do
        if i > 1 then
            table.insert(color_buttons, HorizontalSpan:new{ width = spacing })
        end

        -- Check if this color is currently selected (compare by name)
        local is_selected = (color_info.name == self.current_color_name)
        local border_size = is_selected and selection_border or Size.border.thick

        -- Use dark gray border for Black color so selection is visible, true black for others
        local border_color = Blitbuffer.COLOR_BLACK
        if color_info.name == "Black" then
            border_color = Blitbuffer.Color8(0x44)
        end

        -- Create a color swatch button
        local color_swatch = FrameContainer:new{
            width = button_size,
            height = button_size,
            padding = 0,
            margin = 0,
            bordersize = border_size,
            color = border_color,
            background = color_info.color,
            WidgetContainer:new{
                dimen = Geom:new{ w = button_size - border_size * 2, h = button_size - border_size * 2 },
            },
        }

        -- Wrap in InputContainer to handle taps
        local color_button = InputContainer:new{
            dimen = Geom:new{ w = button_size, h = button_size },
            color_swatch,
            color_value = color_info.color,  -- Store Blitbuffer color
            color_name = color_info.name,    -- Store name for display/persistence
        }

        color_button.ges_events = {
            TapSelectColor = {
                GestureRange:new{
                    ges = "tap",
                    range = function() return color_button.dimen end,
                },
            },
        }

        local widget = self
        color_button.onTapSelectColor = function(btn)
            if widget.callback then
                widget.callback(btn.color_value, btn.color_name)
            end
            if widget.close_callback then
                widget.close_callback()
            end
            return true
        end

        table.insert(color_buttons, color_button)
        table.insert(self.color_buttons_info, color_button)
    end

    -- Create the frame - FrameContainer adds equal padding on all sides
    local content = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = button_size },
        color_buttons,
    }

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = padding,
        content,
    }

    self[1] = self.frame
    self.dimen = self.frame:getSize()

    -- Register gesture to close when tapping outside
    self.ges_events = {
        TapCloseOutside = {
            GestureRange:new{
                ges = "tap",
                range = function() return Geom:new{
                    x = 0, y = 0,
                    w = Screen:getWidth(),
                    h = Screen:getHeight(),
                } end,
            },
        },
    }
end

-- Handle pen/stylus tap on color picker
-- Returns true if the tap was handled (hit a color button or was inside picker)
function ColorPickerWidget:handlePenTap(x, y)
    if not self.dimen then
        return false
    end

    -- Check if tap is inside the widget
    local inside = x >= self.dimen.x and x < self.dimen.x + self.dimen.w
            and y >= self.dimen.y and y < self.dimen.y + self.dimen.h

    if not inside then
        -- Tap outside - close the picker
        if self.close_callback then
            self.close_callback()
        end
        return true  -- Consume the event to prevent drawing
    end

    -- Calculate button positions directly from scratch
    local button_size = Screen:scaleBySize(36)
    local spacing = Screen:scaleBySize(8)
    local padding = Screen:scaleBySize(10)
    local border = Size.border.window

    local num_buttons = #self.color_buttons_info
    local total_buttons_width = num_buttons * button_size + (num_buttons - 1) * spacing

    -- The buttons are centered within the widget
    -- Frame adds border + padding on each side
    -- Then CenterContainer centers the buttons
    -- buttons_start_x = widget_x + (widget_width - total_buttons_width) / 2
    local buttons_start_x = self.dimen.x + (self.dimen.w - total_buttons_width) / 2

    -- Vertical position: border + padding (frame only, no VerticalSpans)
    local buttons_y = self.dimen.y + border + padding

    -- Check if tap is in the button row vertically
    if y >= buttons_y and y < buttons_y + button_size then
        -- Find which button was tapped based on x position
        local relative_x = x - buttons_start_x
        if relative_x >= 0 and relative_x < total_buttons_width then
            -- Calculate which button index this falls into
            local button_with_spacing = button_size + spacing
            local button_index = math.floor(relative_x / button_with_spacing) + 1
            -- Check if we're actually on the button and not in the spacing
            local pos_in_slot = relative_x - (button_index - 1) * button_with_spacing
            if pos_in_slot < button_size and button_index >= 1 and button_index <= num_buttons then
                local btn = self.color_buttons_info[button_index]
                if btn and self.callback then
                    self.callback(btn.color_value, btn.color_name)
                end
                if self.close_callback then
                    self.close_callback()
                end
                return true
            end
        end
    end

    -- Inside picker but didn't hit a button - still consume the event
    return true
end

-- Handle tap - close if outside the widget
function ColorPickerWidget:onTapCloseOutside(_, ges)
    if ges and ges.pos and self.dimen then
        -- Check if tap is inside the widget using coordinate comparison
        local x, y = ges.pos.x, ges.pos.y
        local inside = x >= self.dimen.x and x < self.dimen.x + self.dimen.w
                and y >= self.dimen.y and y < self.dimen.y + self.dimen.h
        if inside then
            -- Tap is inside, let the color buttons handle it
            return false
        end
    end
    -- Tap is outside, close the widget without changing color
    if self.close_callback then
        self.close_callback()
    end
    return true
end

function ColorPickerWidget:paintTo(bb, x, y)
    -- Use absolute position from dimen if set, otherwise use passed coordinates
    local paint_x = self.dimen and self.dimen.x or x
    local paint_y = self.dimen and self.dimen.y or y

    -- Paint the frame at the absolute position
    self.frame:paintTo(bb, paint_x, paint_y)

    -- Update button dimens for tap detection at absolute positions
    if self.color_buttons_info then
        local button_size = Screen:scaleBySize(36)
        local spacing = Screen:scaleBySize(8)
        local padding = Screen:scaleBySize(10)
        local border = Size.border.window

        -- Calculate button positions within the frame
        local total_buttons_width = #self.color_buttons_info * button_size + (#self.color_buttons_info - 1) * spacing
        local frame_inner_width = self.dimen.w - 2 * padding - 2 * border
        local buttons_start_x = paint_x + border + padding + (frame_inner_width - total_buttons_width) / 2
        local buttons_y = paint_y + border + padding  -- just FrameContainer padding

        for i, btn in ipairs(self.color_buttons_info) do
            local btn_x = buttons_start_x + (i - 1) * (button_size + spacing)
            btn.dimen.x = btn_x
            btn.dimen.y = buttons_y
        end
    end
end

function ColorPickerWidget:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.dimen)
end

-- Show color picker popup near the pen position
function Pencil:showColorPicker(x, y)
    if self.color_picker_showing then return end

    -- Discard any current stroke that was made while holding still
    -- The user was holding still to trigger color picker, not intentionally drawing
    if self.current_stroke then
        self.current_stroke = nil
        -- Repaint to remove the stroke from screen immediately
        self.view:paintTo(Screen.bb, 0, 0)
        self:paintTo(Screen.bb, 0, 0)
        Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
    end

    self.color_picker_showing = true

    local plugin = self

    -- Calculate picker size based on number of colors
    local button_size = Screen:scaleBySize(36)
    local spacing = Screen:scaleBySize(8)
    local padding = Screen:scaleBySize(10)
    local border = Size.border.window
    local num_colors = #self.available_colors
    -- Width/height = buttons + FrameContainer padding (equal on all sides) + borders
    local buttons_width = num_colors * button_size + (num_colors - 1) * spacing
    local picker_width = buttons_width + padding * 2 + border * 2
    local picker_height = button_size + padding * 2 + border * 2
    local margin_above = Screen:scaleBySize(30)  -- Gap between picker and pen
    local screen_margin = 10  -- Minimum margin from screen edges

    -- Try to position above the pen first, centered horizontally
    local picker_x = x - picker_width / 2
    local picker_y = y - picker_height - margin_above

    -- Adjust horizontal position to keep picker fully on screen
    if picker_x < screen_margin then
        picker_x = screen_margin
    end
    if picker_x + picker_width > Screen:getWidth() - screen_margin then
        picker_x = Screen:getWidth() - picker_width - screen_margin
    end

    -- If no room above, position below the pen
    if picker_y < screen_margin then
        picker_y = y + margin_above
    end

    -- Final check: ensure it fits on screen vertically
    if picker_y + picker_height > Screen:getHeight() - screen_margin then
        picker_y = Screen:getHeight() - picker_height - screen_margin
    end

    local color_picker = ColorPickerWidget:new{
        colors = self.available_colors,
        current_color_name = self.tool_settings[TOOL_PEN].color_name,
        callback = function(color_value, color_name)
            plugin:setPenColor(color_value, color_name)
            UIManager:show(InfoMessage:new{
                text = T(_("Pen color: %1"), color_name),
                timeout = 1,
            })
        end,
        close_callback = function()
            plugin.color_picker_showing = false
            UIManager:close(plugin.color_picker_widget)
            plugin.color_picker_widget = nil
            -- Refresh to clean up
            UIManager:setDirty(plugin.view, "ui")
        end,
    }

    -- Position the widget at the calculated coordinates
    -- Set dimen with absolute position before showing
    color_picker.dimen = color_picker.dimen or Geom:new{}
    color_picker.dimen.x = picker_x
    color_picker.dimen.y = picker_y

    self.color_picker_widget = color_picker

    UIManager:show(self.color_picker_widget)
    UIManager:setDirty(self.color_picker_widget, "ui")

    logger.dbg("Pencil: color picker shown at", picker_x, picker_y)
end

-- Set pen color
function Pencil:setPenColor(color, color_name)
    self.tool_settings[TOOL_PEN].color = color
    self.tool_settings[TOOL_PEN].color_name = color_name
    logger.info("Pencil: setPenColor - color_name =", color_name)
    self:saveSettings()
end

-- Handle initial touch - fires IMMEDIATELY on first contact
-- This is critical for capturing the start of strokes without delay
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and is a backup if raw input not working
function Pencil:onDrawTouch(ges)
    if not self:isEnabled() then return false end

    -- Check if this is a finger touch (not pen) - let gesture system handle it
    local is_pen, _ = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    -- Check if raw input hook detected pen - if so, block gesture but don't duplicate
    -- This is the primary pen detection method (lowest latency)
    if self.pen_down then
        -- Raw input is handling drawing - just block the gesture
        self:cancelPendingRefresh()
        return true
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end = self:isPenInput(ges)
    if not is_pen then return false end

    -- Cancel any pending refresh - user is still writing
    self:cancelPendingRefresh()

    local effective_tool = self:getEffectiveTool(is_eraser_end)

    -- For eraser, we handle in pan (need movement to erase)
    if effective_tool == TOOL_ERASER then
        return true  -- Block but don't start stroke
    end

    -- Fallback: handle via gesture system if raw input not working
    local page = self:getCurrentPage()

    -- If side button is held for highlighting
    if self.side_button_down then
        self.side_button_used_for_highlight = true
    end

    -- Start new stroke immediately with first point
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]
    self.current_stroke = {
        page = page,
        tool = effective_tool,
        points = { { x = ges.pos.x, y = ges.pos.y } },
        width = tool_settings.width,
        color = tool_settings.color,
        color_name = tool_settings.color_name,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }

    -- Draw first point to framebuffer - NO REFRESH during drawing
    -- E-ink displays show "ghost" pixels when framebuffer changes, providing visual feedback
    -- Refresh only happens after user stops writing (delayed refresh)
    local width = tool_settings.width
    local color = tool_settings.color
    local half_w = math.floor(width / 2)
    Screen.bb:paintRectRGB32(ges.pos.x - half_w, ges.pos.y - half_w, width, width, color)

    return true
end

-- Check if this is a stylus/pen event (not finger)
-- Returns: is_pen (boolean), is_eraser_end (boolean)
function Pencil:isPenInput(ges)
    -- In emulator, treat all input as pen for testing
    if Device:isEmulator() then
        return true, false
    end

    -- Check if the pen slot is currently active with tool type = pen or eraser
    -- The pen slot is separate from finger slots (usually slot 4)
    local Input = Device.input
    local is_pen = false
    local is_eraser_end = false

    -- Tool types from Linux input subsystem:
    -- TOOL_TYPE_FINGER = 0
    -- TOOL_TYPE_PEN = 1
    -- TOOL_TYPE_RUBBER/ERASER = 2
    local TOOL_TYPE_PEN = 1
    local TOOL_TYPE_ERASER = 2

    if Input and Input.pen_slot then
        local pen_slot_data = Input:getMtSlot(Input.pen_slot)
        if pen_slot_data then
            if self.input_debug_mode then
                logger.info("Pencil: isPenInput check - pen_slot=", Input.pen_slot,
                        "tool=", pen_slot_data.tool, "id=", pen_slot_data.id,
                        "x=", pen_slot_data.x, "y=", pen_slot_data.y,
                        "ges.pos=", ges.pos.x, ",", ges.pos.y)
            else
                logger.dbg("Pencil: isPenInput check - pen_slot=", Input.pen_slot,
                        "tool=", pen_slot_data.tool, "id=", pen_slot_data.id,
                        "x=", pen_slot_data.x, "y=", pen_slot_data.y)
            end

            -- Check if pen slot has tool type and is actively being tracked (id ~= -1)
            if pen_slot_data.id and pen_slot_data.id ~= -1 then
                if pen_slot_data.tool == TOOL_TYPE_PEN then
                    is_pen = true
                elseif pen_slot_data.tool == TOOL_TYPE_ERASER then
                    is_pen = true
                    is_eraser_end = true
                    logger.dbg("Pencil: eraser end detected via pen_slot tool type")
                end
            end

            -- Fallback: on some devices, the pen slot might have valid x/y even if id is reset
            if not is_pen and pen_slot_data.x and pen_slot_data.y then
                if pen_slot_data.tool == TOOL_TYPE_PEN or pen_slot_data.tool == TOOL_TYPE_ERASER then
                    local dx = math.abs((pen_slot_data.x or 0) - (ges.pos.x or 0))
                    local dy = math.abs((pen_slot_data.y or 0) - (ges.pos.y or 0))
                    if dx < 50 and dy < 50 then
                        logger.dbg("Pencil: isPenInput - pen slot matched by position")
                        is_pen = true
                        if pen_slot_data.tool == TOOL_TYPE_ERASER then
                            is_eraser_end = true
                        end
                    end
                end
            end
        end
    end

    -- Also check current slot for tool type (might be different on some devices)
    if not is_pen and Input then
        local cur_slot_data = Input:getCurrentMtSlot()
        if cur_slot_data then
            if self.input_debug_mode then
                logger.info("Pencil: current slot data - slot=", Input.cur_slot,
                        "tool=", cur_slot_data.tool, "id=", cur_slot_data.id)
            end
            if cur_slot_data.tool == TOOL_TYPE_PEN then
                logger.dbg("Pencil: isPenInput - current slot has pen tool type")
                is_pen = true
            elseif cur_slot_data.tool == TOOL_TYPE_ERASER then
                logger.dbg("Pencil: isPenInput - current slot has eraser tool type")
                is_pen = true
                is_eraser_end = true
            end
        end
    end

    -- Log all slots in debug mode to help diagnose issues
    if self.input_debug_mode and Input and Input.ev_slots then
        local slot_info = {}
        for slot, data in pairs(Input.ev_slots) do
            if data.id and data.id ~= -1 then
                table.insert(slot_info, string.format("slot%d:tool=%s,id=%s", slot, tostring(data.tool), tostring(data.id)))
            end
        end
        if #slot_info > 0 then
            logger.info("Pencil: active slots:", table.concat(slot_info, " "))
        end
    end

    return is_pen, is_eraser_end
end

-- Get the effective tool (considers physical eraser end and side button)
function Pencil:getEffectiveTool(is_eraser_end)
    -- Check both the tool type detection AND the BTN_TOOL_RUBBER state
    if is_eraser_end or self.eraser_tool_active then
        return TOOL_ERASER
    end

    -- Side button held = highlighter mode (for hold+drag highlighting)
    if self.side_button_down then
        return TOOL_HIGHLIGHTER
    end

    return self.current_tool
end

-- Called on tap - create a dot or erase at point
function Pencil:onDrawTap(ges)
    if not self:isEnabled() then return false end

    -- If raw input detected pen recently, block tap to prevent navigation
    -- Note: pen_down will be false by tap time, but we may have just drawn
    -- We should block taps if there's a current stroke or recent drawing
    if self.current_stroke then
        return true  -- Block tap while stroke in progress
    end

    -- Check if finger tap - let gesture system handle it
    local is_pen, is_eraser_end = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local page = self:getCurrentPage()
    local effective_tool = self:getEffectiveTool(is_eraser_end)
    logger.dbg("Pencil: onDrawTap - effective_tool =", effective_tool)

    -- Log to debug file for analysis
    self:writeDebugLog(string.format("=== TAP at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
            tostring(is_eraser_end), tostring(self.eraser_tool_active), effective_tool))

    if effective_tool == TOOL_ERASER then
        -- Eraser: delete strokes near tap point
        logger.info("Pencil: eraser tap at", ges.pos.x, ges.pos.y, "page =", page)
        local erased = self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        if erased then
            logger.info("Pencil: erased", #erased, "strokes")
            table.insert(self.undo_stack, { type = "delete", strokes = erased })
            self:saveStrokes()
            UIManager:setDirty(self.view, "ui")
        else
            logger.info("Pencil: eraser tap found no strokes to erase")
        end
        return true
    end

    -- Pen or Highlighter: create a dot
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]
    local stroke = {
        page = page,
        tool = effective_tool,
        points = { { x = ges.pos.x, y = ges.pos.y } },
        width = tool_settings.width,
        color = tool_settings.color,
        alpha = tool_settings.alpha,
        datetime = os.time(),
    }

    table.insert(self.strokes, stroke)
    self:indexStroke(#self.strokes, page)
    self:saveStrokes()

    -- Add to undo stack
    table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })

    -- Draw directly to screen buffer
    self:renderStroke(Screen.bb, stroke)

    -- Direct framebuffer refresh for instant feedback
    local w = stroke.width
    fastScreenRefresh(ges.pos.x - w, ges.pos.y - w, w * 2, w * 2)

    return true
end

-- Called during pan - continues stroke started by onDrawTouch
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and handles eraser mode
function Pencil:onDrawPan(ges)
    if not self:isEnabled() then return false end

    -- Check if raw input hook detected pen - if so, block gesture
    -- Raw input handles all drawing; this just needs to block swipe/pan gestures
    if self.pen_down then
        return true  -- Block pan gesture, raw input is drawing
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end = self:isPenInput(ges)
    if not is_pen then return false end

    local page = self:getCurrentPage()
    local effective_tool = self:getEffectiveTool(is_eraser_end)

    -- If side button is held and we're drawing, mark it as used for highlighting
    if self.side_button_down and effective_tool == TOOL_HIGHLIGHTER then
        self.side_button_used_for_highlight = true
    end

    -- Eraser mode: erase along path (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        if not self.eraser_path then
            self.eraser_path = {}
            self.eraser_deleted = {}
        end
        table.insert(self.eraser_path, { x = ges.pos.x, y = ges.pos.y })

        local deleted = self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        if deleted then
            for _, stroke in ipairs(deleted) do
                table.insert(self.eraser_deleted, stroke)
            end
            self.view:paintTo(Screen.bb, 0, 0)
            Screen:refreshUI()
        end
        return true
    end

    -- Fallback: handle via gesture system if raw input not working
    local tool_settings = self.tool_settings[effective_tool] or self.tool_settings[TOOL_PEN]

    -- Stroke should already exist from onDrawTouch, but handle fallback cases
    if not self.current_stroke or self.current_stroke.page ~= page or self.current_stroke.tool ~= effective_tool then
        -- Fallback: create stroke if touch event was missed or context changed
        logger.dbg("Pencil: onDrawPan creating fallback stroke")
        self.current_stroke = {
            page = page,
            tool = effective_tool,
            points = {},
            width = tool_settings.width,
            color = tool_settings.color,
            color_name = tool_settings.color_name,
            alpha = tool_settings.alpha,
            datetime = os.time(),
        }
        -- Use start_pos if available for the first point
        if ges.start_pos then
            table.insert(self.current_stroke.points, { x = ges.start_pos.x, y = ges.start_pos.y })
        end
    end

    -- Add current point to stroke
    local point = { x = ges.pos.x, y = ges.pos.y }
    table.insert(self.current_stroke.points, point)

    -- Draw the new segment to framebuffer - NO REFRESH during drawing
    -- E-ink shows ghost pixels, refresh happens on pan_release
    local n = #self.current_stroke.points
    local width = self.current_stroke.width
    local color = self.current_stroke.color

    if n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]

        if effective_tool == TOOL_HIGHLIGHTER then
            self:drawHighlighterSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        else
            self:drawLineSegment(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
    elseif n == 1 then
        local p = self.current_stroke.points[1]
        local half_w = math.floor(width / 2)
        Screen.bb:paintRectRGB32(p.x - half_w, p.y - half_w, width, width, color)
    end

    return true
end

-- Called when pan ends - finalize stroke
-- NOTE: For pen/highlighter, raw input hook may have already finalized the stroke
function Pencil:onDrawPanRelease(ges)
    if not self:isEnabled() then return false end

    -- Let finger releases be handled by gesture system
    local is_pen, is_eraser_end = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local effective_tool = self:getEffectiveTool(is_eraser_end)

    -- Log pan end to debug file
    self:writeDebugLog(string.format("=== PAN END at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
            tostring(is_eraser_end), tostring(self.eraser_tool_active), effective_tool))

    -- Handle eraser pan release (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        if self.eraser_deleted and #self.eraser_deleted > 0 then
            -- Add deleted strokes to undo stack
            table.insert(self.undo_stack, { type = "delete", strokes = self.eraser_deleted })
            self:saveStrokes()
        end
        -- Always refresh screen after erasing to clear any visual artifacts
        UIManager:setDirty(self.view, "partial")
        self.eraser_path = nil
        self.eraser_deleted = nil
        return true
    end

    -- For pen/highlighter: raw input hook already finalized the stroke
    -- Just consume the event and ensure delayed refresh is scheduled
    if not self.current_stroke then
        -- Raw input already handled it, just schedule refresh if not already pending
        self:scheduleDelayedRefresh()
        return true
    end

    -- Fallback: finalize stroke via gesture system
    if #self.current_stroke.points >= 1 then
        -- Finalize the stroke
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self:saveStrokes()

        -- Add to undo stack
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })

        logger.dbg("Pencil: stroke completed with", #self.current_stroke.points, "points")
    end

    self.current_stroke = nil

    -- Schedule delayed refresh - will fire after user stops writing
    -- If user starts another stroke, the refresh will be canceled and rescheduled
    self:scheduleDelayedRefresh()

    return true
end

-- Get current page number (stable reference for both paged and rolling modes)
function Pencil:getCurrentPage()
    if self.ui.paging then
        return self.view.state.page
    else
        -- For rolling/EPUB documents, convert XPointer to stable page number
        local xp = self.ui.document:getXPointer()
        if xp and self.ui.document.getPageFromXPointer then
            return self.ui.document:getPageFromXPointer(xp)
        end
        -- Fallback to XPointer if conversion not available
        return xp
    end
end

-- Index a stroke by page for quick lookup
function Pencil:indexStroke(stroke_idx, page)
    if not self.page_strokes[page] then
        self.page_strokes[page] = {}
    end
    table.insert(self.page_strokes[page], stroke_idx)
end

-- Rebuild page index from strokes
function Pencil:rebuildPageIndex()
    self.page_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        self:indexStroke(i, stroke.page)
    end
end

-- Get strokes for a specific page
function Pencil:getStrokesForPage(page)
    local result = {}
    local indices = self.page_strokes[page] or {}
    for _, idx in ipairs(indices) do
        if self.strokes[idx] then
            table.insert(result, self.strokes[idx])
        end
    end
    return result
end

-- Check if current page has strokes
function Pencil:hasStrokesOnCurrentPage()
    local page = self:getCurrentPage()
    return self.page_strokes[page] and #self.page_strokes[page] > 0
end

-- Clear strokes on current page
function Pencil:clearPageStrokes()
    local page = self:getCurrentPage()
    logger.info("Pencil: clearPageStrokes - current page =", page, "type =", type(page))

    -- Debug: log all pages that have strokes and total stroke count
    logger.info("Pencil: total strokes:", #self.strokes)
    logger.info("Pencil: pages with strokes:")
    for p, indices in pairs(self.page_strokes) do
        logger.info("  page =", p, "type =", type(p), "stroke count =", #indices)
    end

    -- Collect ALL stroke indices that match this page
    -- Search both by direct key lookup AND by iterating through all strokes
    local indices_to_remove = {}
    local indices_set = {}  -- To avoid duplicates

    -- Method 1: Direct key lookup
    if self.page_strokes[page] then
        for _, idx in ipairs(self.page_strokes[page]) do
            if not indices_set[idx] then
                table.insert(indices_to_remove, idx)
                indices_set[idx] = true
            end
        end
    end

    -- Method 2: Search by string comparison (handles type mismatches)
    local page_str = tostring(page)
    for p, p_indices in pairs(self.page_strokes) do
        if tostring(p) == page_str and p ~= page then
            logger.info("Pencil: found matching page via string comparison:", p, "->", page)
            for _, idx in ipairs(p_indices) do
                if not indices_set[idx] then
                    table.insert(indices_to_remove, idx)
                    indices_set[idx] = true
                end
            end
        end
    end

    -- Method 3: Direct stroke iteration (most reliable fallback)
    for i, stroke in ipairs(self.strokes) do
        if stroke.page == page or tostring(stroke.page) == page_str then
            if not indices_set[i] then
                logger.info("Pencil: found stroke via direct iteration at index", i)
                table.insert(indices_to_remove, i)
                indices_set[i] = true
            end
        end
    end

    if #indices_to_remove == 0 then
        logger.info("Pencil: clearPageStrokes - no strokes found for page", page)
        UIManager:show(InfoMessage:new{
            text = _("No annotations found on this page."),
            timeout = 1,
        })
        return
    end

    logger.info("Pencil: clearPageStrokes - removing", #indices_to_remove, "strokes from page", page)

    -- Remove strokes (in reverse order to maintain indices)
    table.sort(indices_to_remove, function(a, b) return a > b end)
    local deleted_strokes = {}
    for _, idx in ipairs(indices_to_remove) do
        if self.strokes[idx] then
            table.insert(deleted_strokes, self.strokes[idx])
            table.remove(self.strokes, idx)
        end
    end

    -- Add to undo stack
    if #deleted_strokes > 0 then
        table.insert(self.undo_stack, { type = "delete", strokes = deleted_strokes })
    end

    -- Rebuild index
    self:rebuildPageIndex()
    self:saveStrokes()

    UIManager:show(InfoMessage:new {
        text = T(_("Cleared %1 annotation(s) from page."), #deleted_strokes),
        timeout = 1,
    })
    UIManager:setDirty(self.view, "ui")
end

-- Clear all strokes
function Pencil:clearAllStrokes()
    self.strokes = {}
    self.page_strokes = {}
    self:saveStrokes()

    UIManager:setDirty(self.view, "ui")
end

-- Calculate bounding box for a stroke
function Pencil:getStrokeBounds(stroke)
    local bounds = PencilGeometry.getStrokeBounds(stroke)
    if not bounds then
        return nil
    end
    return Geom:new(bounds)
end

-- Render a line segment using rectangles (since BlitBuffer has no native line drawing)
function Pencil:drawLineSegment(bb, x1, y1, x2, y2, width, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)

    if dist < 1 then
        -- Just draw a single point
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(x1 - half_w, y1 - half_w, width, width, color)
        return
    end

    -- Step along the line drawing small rectangles
    local steps = math.ceil(dist)
    local half_w = math.floor(width / 2)

    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x1 + dx * t)
        local y = math.floor(y1 + dy * t)
        bb:paintRectRGB32(x - half_w, y - half_w, width, width, color)
    end
end

-- Render a highlighter segment (semi-transparent, wider)
function Pencil:drawHighlighterSegment(bb, x1, y1, x2, y2, width, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)

    -- Highlighter is drawn as a lighter gray to simulate transparency on e-ink
    local highlight_color = color or Blitbuffer.Color8(0xDD)

    if dist < 1 then
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(x1 - half_w, y1 - half_w, width, width, highlight_color)
        return
    end

    local steps = math.ceil(dist)
    local half_w = math.floor(width / 2)

    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x1 + dx * t)
        local y = math.floor(y1 + dy * t)
        bb:paintRectRGB32(x - half_w, y - half_w, width, width, highlight_color)
    end
end

-- Check if a point is near a stroke (for eraser)
function Pencil:isPointNearStroke(px, py, stroke, threshold)
    return PencilGeometry.isPointNearStroke(px, py, stroke, threshold)
end

-- Erase strokes at a given point
-- Returns array of deleted strokes (for undo), or nil if none
function Pencil:eraseAtPoint(x, y, page)
    -- Search ALL strokes by position, ignoring page keys
    -- This ensures eraser works regardless of how strokes were indexed
    if self.input_debug_mode then
        self:writeDebugLog(string.format("ERASE: searching %d strokes at (%d, %d)",
                #self.strokes, x, y))
    end

    if #self.strokes == 0 then
        if self.input_debug_mode then
            self:writeDebugLog("ERASE: no strokes exist")
        end
        return nil
    end

    local eraser_width = self.tool_settings[TOOL_ERASER].width
    local deleted = {}
    local indices_to_remove = {}

    -- Find strokes that intersect with eraser point (search ALL strokes)
    for i, stroke in ipairs(self.strokes) do
        -- Debug: log stroke bounds
        if self.input_debug_mode and stroke.points and #stroke.points > 0 then
            local min_x, max_x, min_y, max_y = stroke.points[1].x, stroke.points[1].x, stroke.points[1].y, stroke.points[1].y
            for _, pt in ipairs(stroke.points) do
                if pt.x < min_x then min_x = pt.x end
                if pt.x > max_x then max_x = pt.x end
                if pt.y < min_y then min_y = pt.y end
                if pt.y > max_y then max_y = pt.y end
            end
            self:writeDebugLog(string.format("ERASE: stroke %d bounds: (%d-%d, %d-%d), eraser at (%d,%d) threshold=%d",
                    i, min_x, max_x, min_y, max_y, x, y, eraser_width))
        end
        if stroke and self:isPointNearStroke(x, y, stroke, eraser_width) then
            table.insert(deleted, stroke)
            table.insert(indices_to_remove, i)
            if self.input_debug_mode then
                self:writeDebugLog(string.format("ERASE: found stroke %d to delete", i))
            end
        end
    end

    -- Remove strokes (in reverse order to maintain indices)
    if #indices_to_remove > 0 then
        table.sort(indices_to_remove, function(a, b) return a > b end)
        for _, idx in ipairs(indices_to_remove) do
            table.remove(self.strokes, idx)
        end
        self:rebuildPageIndex()
        if self.input_debug_mode then
            self:writeDebugLog(string.format("ERASE: deleted %d strokes", #deleted))
        end
        return deleted
    end

    return nil
end

-- Render a complete stroke
function Pencil:renderStroke(bb, stroke)
    if not stroke.points or #stroke.points < 1 then
        return
    end

    local tool = stroke.tool or TOOL_PEN
    local width = stroke.width or self.tool_settings[tool].width or 3

    -- Get color directly (it's already a Blitbuffer color)
    local color = stroke.color or self.tool_settings[tool].color or Blitbuffer.COLOR_BLACK

    -- Highlighter uses lighter color
    local is_highlighter = (tool == TOOL_HIGHLIGHTER)
    if is_highlighter then
        -- For highlighter, use stored color or default gray
        color = stroke.color or Blitbuffer.Color8(0xDD)
    end

    if #stroke.points == 1 then
        -- Single point (dot)
        local p = stroke.points[1]
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(p.x - half_w, p.y - half_w, width, width, color)
    else
        -- Multiple points - draw line segments
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            if is_highlighter then
                self:drawHighlighterSegment(bb, p1.x, p1.y, p2.x, p2.y, width, color)
            else
                self:drawLineSegment(bb, p1.x, p1.y, p2.x, p2.y, width, color)
            end
        end
    end
end

-- View module paintTo method - called by ReaderView during repaints
function Pencil:paintTo(bb, x, y)
    local page = self:getCurrentPage()

    -- Render saved strokes for current page
    local strokes = self:getStrokesForPage(page)
    for _, stroke in ipairs(strokes) do
        self:renderStroke(bb, stroke)
    end

    -- Render current stroke being drawn (only if on current page)
    if self.current_stroke and self.current_stroke.page == page then
        self:renderStroke(bb, self.current_stroke)
    end
end

-- Get the pencil strokes file path for this document
function Pencil:getStrokesFilePath()
    if not self.ui or not self.ui.doc_settings then
        logger.warn("Pencil: doc_settings not available")
        return nil
    end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        return sidecar_dir .. "/pencil_strokes.lua"
    end
    logger.warn("Pencil: sidecar_dir not available")
    return nil
end

-- Load strokes from our own file
function Pencil:loadStrokes()
    local filepath = self:getStrokesFilePath()
    logger.info("Pencil: loadStrokes - filepath =", filepath)

    if not filepath then
        logger.warn("Pencil: no filepath available for loading strokes")
        self.strokes = {}
        self.page_strokes = {}
        return
    end

    -- Check if file exists
    local file_exists = io.open(filepath, "r")
    if not file_exists then
        logger.info("Pencil: strokes file does not exist yet:", filepath)
        self.strokes = {}
        self.page_strokes = {}
        return
    end
    file_exists:close()

    local ok, data = pcall(dofile, filepath)
    if ok and data and data.strokes then
        -- Convert saved strokes back to usable format
        self.strokes = {}
        for i, saved in ipairs(data.strokes) do
            self.strokes[i] = self:strokeFromSaved(saved)
        end
        self:rebuildPageIndex()
        logger.info("Pencil: loaded", #self.strokes, "strokes from", filepath)
    else
        logger.warn("Pencil: failed to load strokes from", filepath, "error:", data)
        self.strokes = {}
        self.page_strokes = {}
    end
end

-- Convert stroke for saving (remove non-serializable values)
function Pencil:strokeToSaveable(stroke)
    return {
        page = stroke.page,
        tool = stroke.tool,
        width = stroke.width,
        alpha = stroke.alpha,
        datetime = stroke.datetime,
        points = stroke.points,
        color_name = stroke.color_name,  -- Save color name for persistence
    }
end

-- Convert saved stroke back to usable format
function Pencil:strokeFromSaved(saved)
    local tool = saved.tool or TOOL_PEN
    local tool_settings = self.tool_settings[tool] or self.tool_settings[TOOL_PEN]

    -- Look up color from color_name
    local color = tool_settings.color
    if saved.color_name then
        for _, color_info in ipairs(self.available_colors) do
            if color_info.name == saved.color_name then
                color = color_info.color
                break
            end
        end
    end

    return {
        page = saved.page,
        tool = saved.tool,
        width = saved.width or tool_settings.width,
        color = color,
        color_name = saved.color_name,
        alpha = saved.alpha or tool_settings.alpha,
        datetime = saved.datetime,
        points = saved.points,
    }
end

-- Save strokes to our own file
function Pencil:saveStrokes()
    local filepath = self:getStrokesFilePath()
    logger.info("Pencil: saveStrokes - filepath =", filepath, "strokes count =", #self.strokes)

    if not filepath then
        logger.warn("Pencil: no filepath available for saving strokes")
        return
    end

    -- Ensure the directory exists
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if sidecar_dir then
        local ok, err = lfs.mkdir(sidecar_dir)
        if not ok and err ~= "File exists" then
            logger.warn("Pencil: failed to create sidecar dir:", err)
        end
    end

    -- Convert strokes to saveable format (remove non-serializable values)
    local saveable_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        saveable_strokes[i] = self:strokeToSaveable(stroke)
    end

    -- Serialize and write
    local data = {
        version = 1,
        strokes = saveable_strokes,
    }

    local f, err = io.open(filepath, "w")
    if f then
        f:write("return " .. require("dump")(data))
        f:close()
        logger.info("Pencil: saved", #self.strokes, "strokes to", filepath)
    else
        logger.err("Pencil: failed to open file for writing:", filepath, "error:", err)
    end
end

-- Handle document close
function Pencil:onCloseDocument()
    logger.info("Pencil: onCloseDocument called, strokes count =", #self.strokes)

    -- Cancel any pending refresh
    self:cancelPendingRefresh()

    -- Save any in-progress stroke
    if self.current_stroke and #self.current_stroke.points >= 2 then
        logger.info("Pencil: saving in-progress stroke before close")
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        self.current_stroke = nil
    end

    self:teardownPenInput()

    -- Always save strokes on close (even if empty, to clear any previous data)
    logger.info("Pencil: saving strokes on document close")
    self:saveStrokes()

    -- Clear state
    self.eraser_path = nil
    self.eraser_deleted = nil
    self.undo_stack = {}
end

-- Handle reader ready (document fully loaded)
function Pencil:onReaderReady()
    logger.info("Pencil: onReaderReady called")
    logger.info("Pencil: doc_settings available:", self.ui.doc_settings ~= nil)
    if self.ui.doc_settings then
        logger.info("Pencil: sidecar_dir:", self.ui.doc_settings.doc_sidecar_dir)
    end

    -- Force reload strokes (in case they weren't loaded in init)
    self:loadStrokes()
    logger.info("Pencil: after loadStrokes, strokes count =", #self.strokes)

    -- Re-setup touch zones if enabled
    if self:isEnabled() and not self.touch_zones_registered then
        self:setupPenInput()
    end
end

-- Handle read settings (document opened) - backup in case onReaderReady not called
function Pencil:onReadSettings(config)
    logger.dbg("Pencil: onReadSettings called")
    -- Only load if not already loaded
    if not self.strokes or #self.strokes == 0 then
        self:loadStrokes()
    end
    -- Re-setup touch zones if enabled (in case they were torn down)
    if self:isEnabled() and not self.touch_zones_registered then
        self:setupPenInput()
    end
end

-- Handle page changes (paging mode)
function Pencil:onPageUpdate(pageno)
    -- Clear any in-progress stroke when page changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        -- Save the stroke before clearing
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:saveStrokes()
    end
    self.current_stroke = nil
    self.eraser_path = nil
    self.eraser_deleted = nil
end

-- Handle position changes (rolling/scroll mode)
function Pencil:onUpdatePos()
    -- Clear any in-progress stroke when position changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        table.insert(self.strokes, self.current_stroke)
        self:indexStroke(#self.strokes, self.current_stroke.page)
        table.insert(self.undo_stack, { type = "add", stroke_idx = #self.strokes })
        self:saveStrokes()
    end
    self.current_stroke = nil
    self.eraser_path = nil
    self.eraser_deleted = nil
end

-- Get exportable data for all pencil annotations
-- Returns array of annotation entries compatible with exporter format
function Pencil:getExportableAnnotations()
    local annotations = {}

    for i, stroke in ipairs(self.strokes) do
        local page_display = stroke.page
        if type(stroke.page) == "string" then
            -- xpointer - try to get page number
            if self.ui.document and self.ui.document.getPageFromXPointer then
                page_display = self.ui.document:getPageFromXPointer(stroke.page) or stroke.page
            end
        end

        local tool = stroke.tool or TOOL_PEN
        table.insert(annotations, {
            sort = "pencil",
            page = page_display,
            time = stroke.datetime or os.time(),
            drawer = tool,
            text = string.format(_("%s annotation (%d points)"), tool, #stroke.points),
            note = nil,
            chapter = nil,
            -- Include stroke metadata for full export
            stroke_data = {
                tool = tool,
                points = stroke.points,
                width = stroke.width,
                page_ref = stroke.page,
            },
        })
    end

    return annotations
end

-- Get summary of pencil annotations for a given page
function Pencil:getAnnotationSummary()
    local summary = {}
    for page, indices in pairs(self.page_strokes) do
        summary[page] = #indices
    end
    return summary
end

-- Get document title for export filename
function Pencil:getDocumentTitle()
    local title = self.ui.doc_props and self.ui.doc_props.title
    if not title or title == "" then
        -- Fallback to filename without extension
        local filepath = self.ui.document.file
        title = filepath:match("([^/]+)%.[^.]+$") or "unknown"
    end
    return title
end

-- Get export directory
function Pencil:getExportPath()
    local export_dir = DataStorage:getDataDir() .. "/pencil_exports"
    -- Create directory if it doesn't exist
    if lfs.attributes(export_dir, "mode") ~= "directory" then
        lfs.mkdir(export_dir)
    end
    return export_dir
end

-- Export annotations to JSON file
function Pencil:exportToJSON()
    local title = self:getDocumentTitle()
    local export_dir = self:getExportPath()
    local filename = export_dir .. "/" .. title:gsub("[^%w%-_]", "_") .. "_pencil.json"

    local export_data = {
        version = 1,
        document = {
            title = title,
            file = self.ui.document.file,
            export_time = os.date("%Y-%m-%d %H:%M:%S"),
        },
        strokes = {},
    }

    for i, stroke in ipairs(self.strokes) do
        local page_display = stroke.page
        if type(stroke.page) == "string" and self.ui.document.getPageFromXPointer then
            page_display = self.ui.document:getPageFromXPointer(stroke.page) or stroke.page
        end

        table.insert(export_data.strokes, {
            page = page_display,
            page_ref = stroke.page,
            tool = stroke.tool or TOOL_PEN,
            points = stroke.points,
            width = stroke.width,
            datetime = stroke.datetime,
        })
    end

    local file = io.open(filename, "w")
    if file then
        file:write(json.encode(export_data))
        file:close()

        UIManager:show(InfoMessage:new{
            text = T(_("Exported %1 annotations to:\n%2"), #self.strokes, filename),
            timeout = 3,
        })
        logger.dbg("Pencil: exported to", filename)
    else
        UIManager:show(InfoMessage:new{
            text = _("Failed to export annotations."),
            timeout = 3,
        })
    end
end

-- Export annotations to text file
function Pencil:exportToText()
    local title = self:getDocumentTitle()
    local export_dir = self:getExportPath()
    local filename = export_dir .. "/" .. title:gsub("[^%w%-_]", "_") .. "_pencil.txt"

    local file = io.open(filename, "w")
    if file then
        file:write("Pencil Annotations\n")
        file:write("==================\n\n")
        file:write("Document: " .. title .. "\n")
        file:write("Exported: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        file:write("Total annotations: " .. #self.strokes .. "\n\n")

        -- Group by page
        local pages = {}
        for i, stroke in ipairs(self.strokes) do
            local page_display = stroke.page
            if type(stroke.page) == "string" and self.ui.document.getPageFromXPointer then
                page_display = self.ui.document:getPageFromXPointer(stroke.page) or stroke.page
            end
            if not pages[page_display] then
                pages[page_display] = {}
            end
            table.insert(pages[page_display], stroke)
        end

        -- Sort pages and output
        local sorted_pages = {}
        for page in pairs(pages) do
            table.insert(sorted_pages, page)
        end
        table.sort(sorted_pages, function(a, b)
            if type(a) == "number" and type(b) == "number" then
                return a < b
            end
            return tostring(a) < tostring(b)
        end)

        for _, page in ipairs(sorted_pages) do
            local strokes = pages[page]
            file:write(string.format("Page %s: %d annotation(s)\n", tostring(page), #strokes))
            for j, stroke in ipairs(strokes) do
                local time_str = stroke.datetime and os.date("%Y-%m-%d %H:%M", stroke.datetime) or "unknown"
                local tool = stroke.tool or "pen"
                file:write(string.format("  - Stroke %d: %s, %d points, width %d, created %s\n",
                        j, tool, #stroke.points, stroke.width or 3, time_str))
            end
            file:write("\n")
        end

        file:close()

        UIManager:show(InfoMessage:new{
            text = T(_("Exported %1 annotations to:\n%2"), #self.strokes, filename),
            timeout = 3,
        })
        logger.dbg("Pencil: exported to", filename)
    else
        UIManager:show(InfoMessage:new{
            text = _("Failed to export annotations."),
            timeout = 3,
        })
    end
end

return Pencil
