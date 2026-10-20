--[[--
Pencil plugin for KOReader.
Enables freehand drawing and annotation with stylus on supported devices.

@module koplugin.pencil
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local PencilGeometry = require("lib/geometry")
local PencilTool = require("lib/penciltool")
local PencilStrokes = require("lib/pencilstrokes")
local Screen = Device.screen
local Size = require("ui/size")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local TextWidget = require("ui/widget/textwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextViewer = require("ui/widget/textviewer")
local NetworkMgr = require("ui/network/manager")
local MyScript = require("lib/myscript")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local time = require("ui/time")
local function trimString(v) return tostring(v or ""):match("^%s*(.-)%s*$") end

-- Check if device supports touch input
if not Device:isTouchDevice() then
    return { disabled = true }
end

-- Tool types (managed by lib/penciltool.lua)
local TOOL_PEN = PencilTool.TOOLS.PEN
local TOOL_HIGHLIGHTER = PencilTool.TOOLS.HIGHLIGHTER
local TOOL_ERASER = PencilTool.TOOLS.ERASER
local LINUX_TOOLTYPE = PencilTool.LINUX_TOOLTYPE

-- Native PDF ink-annotation support (issue #63).
--
-- We call koreader-base's MuPDF wrapper directly, so this feature patches NO
-- core KOReader files. Everything we need comes from require("ffi/mupdf"):
-- koreader-base exports the ink setters as of koreader/koreader-base#2444,
-- shipped in KOReader 2026.07. The local cdefs below are a fallback for builds
-- whose stock ffi/mupdf_h.lua predates that -- on 2026.07+ ffi/mupdf declares
-- these symbols first and LuaJIT rejects our (pcall'd) redefinition, which is
-- fine: the stock declarations are the ones we then call.
--
-- InkAnnot is nil when the symbols are absent, so on older KOReader builds the
-- feature degrades gracefully instead of erroring.
local InkAnnot = (function()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    -- Pulls in fz_point / pdf_annot / pdf_page / PDF_ANNOT_INK and loads the lib.
    if not pcall(require, "ffi/mupdf") then return nil end
    pcall(ffi.cdef, [[
        void *mupdf_pdf_set_annot_ink_list(fz_context *, pdf_annot *, int, const int *, const fz_point *);
        void *mupdf_pdf_set_annot_border_width(fz_context *, pdf_annot *, float);
        void *mupdf_pdf_update_annot(fz_context *, pdf_annot *);
    ]])
    local W_ok, W = pcall(ffi.loadlib, "wrap-mupdf")
    if not W_ok or not W then return nil end
    -- Probe: the symbol resolves lazily and errors if the lib lacks it.
    if not pcall(function() return W.mupdf_pdf_set_annot_ink_list end) then return nil end
    local ink_ok, ink_type = pcall(function() return ffi.C.PDF_ANNOT_INK end)
    return { ffi = ffi, W = W, PDF_ANNOT_INK = ink_ok and ink_type or 15 }
end)()

-- Color picker trigger settings
local COLOR_PICKER_DELAY_MS = 500  -- How long pen must be held still (milliseconds)
local COLOR_PICKER_TOLERANCE_PIXELS = 15  -- How many pixels pen can move while "still"

-- Underline by holding the pen at the end of a horizontal stroke
local UNDERLINE_HOLD_MS = 600          -- How long the pen must rest at the end
local UNDERLINE_STILL_PIXELS = 10      -- Movement allowed while resting
local UNDERLINE_MIN_LENGTH = 40        -- Shorter strokes are never underlines
local UNDERLINE_MAX_SLOPE = 0.25       -- Max stroke height / width
local UNDERLINE_SEARCH_PIXELS = 48     -- How far above the stroke to look for text

-- Palm rejection: touches that start while the pen is near the screen, or
-- within this long after the pen was last seen, are dropped.
local PALM_GRACE_MS = 800

-- Annotation grouping constants
local GROUP_TIME_THRESHOLD_S = 10   -- seconds between strokes to be grouped
local GROUP_SPATIAL_THRESHOLD = 200 -- pixels between bboxes to be grouped

-- Annotation image constants
local IMAGE_CAPTURE_V_MARGIN_PX = 24     -- vertical padding around bbox before clamping
local IMAGE_MIN_HEIGHT_PX = 350          -- floor for captured strip height (legibility)
local IMAGE_MAX_DIM = 1280               -- only downscale captures whose longer side exceeds this
local IMAGE_JPEG_QUALITY = 85
local IMAGE_CAPTURE_DEBOUNCE_S = 4       -- seconds after last stroke before capturing
local IMAGE_BADGE_SIZE = 48              -- on-page badge edge (px) when annotation is stale
local IMAGE_BADGE_HIT_PAD = 32           -- extra pixels around badge for tap hit-test
local IMAGE_BADGE_MARGIN_GAP = 5         -- gap from text/screen edge for margin badge
local ANNOTATION_HOLD_HIT_PAD = 18  -- extra pixels around annotation bbox

-- Module-level reference to the most recently initialized Pencil instance.
-- Used by the bookmark-list hook (a class-level monkey-patch installed once)
-- to find the live plugin without coupling to KOReader internals.
local _active_pencil = nil
local _bookmark_hook_installed = false
local _palm_filter_installed = false

local NoteCanvas  -- defined with the notes code below

local Pencil = InputContainer:extend{
    name = "pencil_annotation",
    is_doc_only = true,  -- Only available when a document is open
    current_stroke = nil,
    store = nil,         -- PencilStrokes instance (strokes of the document, page index, history), set in init()
    tool = nil,          -- PencilTool instance (tool selection/settings/eraser/highlight state), set in init()
    touch_zones_registered = false,
    eraser_button_deleted = {},    -- Track deletions for undo

    -- Stylus callback for lowest latency (via Input:registerStylusCallback)
    stylus_callback_registered = false,
    pen_down = false,
    pen_x = 0,
    pen_y = 0,

    last_refresh_time = 0,
    refresh_interval_ms = 16,  -- Refresh at most every 16ms during drawing (~60fps)
    dirty_region = nil,  -- Accumulated dirty region for batch refresh

    -- Delayed refresh - only refresh after user stops writing
    pending_refresh = nil,

    -- Références vers les traits affichés temporairement en noir.
    -- Ils seront redessinés directement en couleur après le délai.
    pending_color_strokes = nil,
    pending_color_repaint = false,
    refresh_delay_ms = 600, -- Wait 600ms after last stroke before final refresh
    -- Screen-space bbox of strokes drawn since the last delayed refresh fired.
    -- The post-lift "clean" refresh is scoped to this region instead of the
    -- whole screen, so a dense page doesn't trigger a full-panel e-ink update.
    pending_refresh_bbox = nil,

    -- Debounced save - coalesces full O(N) serialization across consecutive strokes.
    -- Force-flushed on page change, close, and the deferred-work scheduler.
    pending_save = nil,
    save_delay_ms = 1500,
    dirty_groups = nil, -- Set of groups awaiting syncGroupBookmark (id -> group)
    pending_group_strokes = nil, -- Stroke indices awaiting grouping outside PEN UP

    -- Side button state
    side_button_down = false,

    -- Color picker state (triggered by holding pen within 5 pixels for 5 seconds)
    color_picker_start_x = nil,  -- Initial X position when pen touched down
    color_picker_start_y = nil,  -- Initial Y position when pen touched down
    color_picker_start_time = nil,  -- Timestamp when pen touched down (nil if moved too far)
    color_picker_check_pending = nil,  -- Scheduled periodic check
    color_picker_showing = false,  -- Whether color picker is currently displayed
    color_picker_tool = nil,  -- Tool (pen or highlighter) the hold-still picker is timing for
    color_picker_contact_active = false, -- Consume the triggering hold until pen lift

    -- Available colors for the pen (initialized in init() with actual Blitbuffer colors)
    available_colors = {},
}

-- The document's strokes, their page index and undo/redo history, and what
-- PencilStrokes needs to know about this plugin and the current view.
function Pencil:initStrokeStore()
    self.store = PencilStrokes:new{
        log = function(message)
            if self.input_debug_mode then self:writeDebugLog(message) end
        end,
        -- Annotation groups keep indices into the stroke list: renumber them
        on_removed = function(indices) self:shiftGroupStrokeIndices(indices) end,
    }
    self.stroke_render_ctx = {
        tool_settings = function(tool) return self.tool:getToolSettings(tool) end,
        night_mode = false,
    }
    self.stroke_view = {
        zoom = function(page) return (self:pageAffine(page)) end,
        sync = function(stroke) return self:syncStrokeToView(stroke) end,
    }
    self.stroke_translate = function(strokes, dx, dy, pdeltas, sign)
        return self:translateStrokes(strokes, dx, dy, pdeltas, sign)
    end
end

function Pencil:init()
    -- CRITICAL: Add plugin to ReaderUI widget tree so it receives ALL key events
    -- This ensures we catch Eraser button press/release events
    -- Technique borrowed from eraser.koplugin by SimonLiu <simonliu423@gmail.com>
    table.insert(self.ui, self)                -- Add to widget children for event propagation
    table.insert(self.ui.active_widgets, self) -- Always receive events even when hidden

    self.ui.menu:registerToMainMenu(self)
    self:initStrokeStore()
    self.annotation_groups = {}  -- Annotation groups for bookmark integration
    self.pending_group_strokes = {}
    self.pending_color_strokes = {}

    -- Tool selection, per-tool settings, eraser and highlight mode state
    self.tool = PencilTool:new()

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

    -- Available pen widths for the optional experimental width picker.
    -- Gated by self.experimental_pen_width; see loadSettings().
    self.available_widths = {
        { name = "w3", width = 3 },
        { name = "w5", width = 5 },
        { name = "w7", width = 7 },
        { name = "w9", width = 9 },
    }

    -- Load tool and stylus button settings
    self:loadSettings()

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

    -- Initialize debug logging (if debug mode enabled)
    self:initDebugLog()

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
    })
    Dispatcher:registerAction("pencil_redo", {
        category = "none",
        event = "PencilRedo",
        title = _("Pencil: redo"),
        reader = true,
        separator = true,
    })

    -- Per-instance state for the annotation-image feature
    self.pending_image_captures = {}
    self.image_data_dirty = false
    _active_pencil = self

    -- Install the (class-level, one-time) bookmark list hook so taps on
    -- pencil bookmarks open the saved image.
    self:installBookmarkHook()

    logger.info("Pencil: initialized, enabled =", self:isEnabled(), "tool =", self.tool:getTool(), "strokes =", self.store:count())
end

-- Dispatcher event handlers (for custom gesture mapping)
function Pencil:onPencilToggleTool()
    self.tool:togglePenEraser()
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
    self.tool:setTool(TOOL_PEN)
    return true
end

function Pencil:onPencilSelectEraser()
    self.tool:setTool(TOOL_ERASER)
    return true
end

function Pencil:onPencilUndo()
    self:undoLastStroke()
    return true
end

function Pencil:onPencilRedo()
    self:redoLastStroke()
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
    self._stylus_cb = function(input, slot)
        return plugin:handleStylusSlot(input, slot)
    end
    Input:registerStylusCallback(self._stylus_cb)

    self.stylus_callback_registered = true
    logger.info("Pencil: stylus callback registered")
    self:installPalmFilter(Input)
end

-- Wrap Input:routeStylusEvents (runs on every touch frame, before gesture
-- detection) so finger slots can be dropped while the pen is in use.
-- Installed once per Input object; it defers to the active plugin instance.
function Pencil:installPalmFilter(input)
    if _palm_filter_installed or not input.routeStylusEvents then return end
    local route = input.routeStylusEvents
    input.routeStylusEvents = function(inp, ...)
        if _active_pencil then
            _active_pencil:ensureStylusCallback(inp)
        end
        route(inp, ...)
        if _active_pencil then
            _active_pencil:filterPalmSlots(inp)
        end
    end
    _palm_filter_installed = true
end

-- Other plugins (Ink Away, for one) register their own stylus callback while
-- open and unregister it on close without restoring ours, which would leave
-- the reader deaf to the pen. Put ours back once the reader is on top again.
function Pencil:ensureStylusCallback(input)
    if not (self.stylus_callback_registered and self._stylus_cb) then return end
    if input.stylus_callback ~= nil or not input.registerStylusCallback then return end
    if self:isOverlayActive() then return end
    input:registerStylusCallback(self._stylus_cb)
    logger.info("Pencil: stylus callback restored")
end

-- Is a slot routed to us as a stylus actually a palm? The pen tip always
-- reports tool 1, so its slot is learned from that. Tool 2/3 is trusted only
-- on the pen's slot, or while the Kobo eraser / side button latch is held
-- (input.lua then rewrites the pen's tool 1 to 2/3). Approach adapted from
-- Ink Away's Stylus.classify (EmirErtorer/ink-away.koplugin, MIT).
function Pencil:isPalmSlot(input, slot)
    local tool = slot.tool
    if tool == 1 then
        self.learned_pen_slot = slot.slot
        return false
    end
    if tool ~= 2 and tool ~= 3 then return false end
    if slot.slot == nil then return false end  -- can't tell without a slot number
    if input then
        if input.pen_slot ~= nil and slot.slot == input.pen_slot then return false end
        -- Latch names: KOReader 2026.07+ (stylus_*) and the older patched
        -- input.lua shipped with this plugin (kobo_*).
        if tool == 2 and (input.stylus_eraser_active or input.kobo_eraser_active) then return false end
        if tool == 3 and (input.stylus_highlighter_active or input.kobo_highlighter_active) then return false end
    end
    if self.learned_pen_slot ~= nil and slot.slot == self.learned_pen_slot then return false end
    return true
end

-- Drop finger contacts that start while the pen is near or was just used.
-- A dropped contact stays dropped until its lift (which is dropped too), and
-- contacts that started before stay untouched, so the gesture detector never
-- sees half a contact.
function Pencil:filterPalmSlots(input)
    local slots = input.MTSlots
    if not slots or #slots == 0 then return end
    self.palm_slots = self.palm_slots or {}
    self.finger_slots = self.finger_slots or {}
    local enabled = self.palm_rejection and self:isEnabled()

    local suppress = false
    if enabled then
        local pen = input.ev_slots and input.pen_slot and input.ev_slots[input.pen_slot]
        local pen_tool = pen and pen.tool
        if pen_tool == 1 or pen_tool == 2 then
            suppress = true  -- pen (tip or eraser) is in proximity
        elseif self.last_stylus_time
                and time.to_ms(time.now() - self.last_stylus_time) <= PALM_GRACE_MS then
            suppress = true
        end
    end

    for i = #slots, 1, -1 do
        local s = slots[i]
        local is_pen = s.slot == input.pen_slot or s.tool == 1 or s.tool == 2 or s.tool == 3
        if not is_pen and s.slot ~= nil then
            local key = s.slot
            local lifting = not s.id or s.id < 0
            if self.palm_slots[key] then
                table.remove(slots, i)
                if lifting then self.palm_slots[key] = nil end
            elseif self.finger_slots[key] then
                if lifting then self.finger_slots[key] = nil end
            elseif not lifting then
                if suppress then
                    self.palm_slots[key] = true
                    table.remove(slots, i)
                else
                    self.finger_slots[key] = true
                end
                if self.input_debug_mode then
                    local pen = input.ev_slots and input.pen_slot and input.ev_slots[input.pen_slot]
                    self:writeDebugLog(string.format(
                        "PALM: touch start slot=%s id=%s x=%s y=%s -> %s (enabled=%s pen_slot_tool=%s stylus_age_ms=%s)",
                        tostring(key), tostring(s.id), tostring(s.x), tostring(s.y),
                        suppress and "DROPPED" or "passed", tostring(enabled),
                        tostring(pen and pen.tool),
                        self.last_stylus_time and tostring(time.to_ms(time.now() - self.last_stylus_time)) or "never"))
                end
            end
        end
    end
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
    -- A resting palm can reach us looking like the eraser: Linux reports a
    -- rejected touch as MT_TOOL_PALM (2), the eraser's tool number, and
    -- input.lua routes any tool 2/3 slot here. Swallow it so it neither
    -- erases nor becomes a gesture.
    if self:isPalmSlot(input, slot) then
        if self.input_debug_mode then
            self:writeDebugLog(string.format("PALM: stylus-looking slot=%s tool=%s id=%s x=%s y=%s swallowed",
                tostring(slot.slot), tostring(slot.tool), tostring(slot.id), tostring(slot.x), tostring(slot.y)))
        end
        return true
    end
    -- Remembered for palm rejection (see filterPalmSlots)
    self.last_stylus_time = time.now()
    if self.note_canvas then
        return self.note_canvas:handleStylus(slot)
    end
    -- Tool types from Linux input subsystem
    local TOOL_TYPE_PEN = 1
    local TOOL_TYPE_ERASER = 2
    local TOOL_TYPE_HIGHLIGHTER = 3

    -- Debug logging at the very start to see slot.tool
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS SLOT: id=%d x=%d y=%d tool=%d eraser_active=%s",
            slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.tool.eraser_button_active)))
    end

    -- Don't capture pen input when a menu or overlay is on top of the reader
    if self:isOverlayActive() then return false end

    -- Detect eraser end via slot.tool BEFORE key events arrive
    -- This handles the timing issue where stylus callback fires before key events
    local eraser_change, eraser_clicked = self.tool:detectEraserAndUpdate(slot)
    if eraser_change == true then
        self.eraser_button_deleted = {}
    elseif eraser_change == false then
        -- Switched from eraser end to pen tip
        self:endEraserMode()
        if eraser_clicked then self:onEraserClick() end
    end

    -- Eraser role (eraser end, or hardware button) - works even if pencil disabled.
    --   click (touch that stays put) = toggle pen/eraser, nothing is erased
    --   drag = erase what the pen passes over, tool is NOT toggled
    if self.tool.eraser_button_active then
        local touching = slot.id and slot.id >= 0
        local x, y
        if touching then
            x, y = self:transformCoordinates(slot.x or self.pen_x, slot.y or self.pen_y)
        end
        local phase = self.tool:trackEraserContact(touching, x, y)
        if phase == "drag_start" then
            -- Also erase where the pen first touched down
            local contact = self.tool.eraser_contact
            self:eraseWithEraserRole(contact.x0, contact.y0)
            self:eraseWithEraserRole(x, y)
        elseif phase == "drag" then
            -- The digitizer reports at a high rate; only erase when the
            -- eraser actually moved.
            if x ~= self.pen_x or y ~= self.pen_y then
                self:eraseWithEraserRole(x, y)
            end
        elseif phase == "drag_end" then
            -- Eraser lifted off the screen (button/end still active)
            self:finishEraseGesture()
            UIManager:setDirty(self.view, "ui")
        elseif phase == "click" then
            self:onEraserClick()
        end
        return true
    end

    -- Highlighter role: highlight the text below the pen, or draw a highlighter
    -- stroke when there is no text below it (decided when the contact starts).
    -- Text highlights go through KOReader's ReaderHighlight. Sticky: once a text
    -- highlight starts, we stay in it until pen lift even if the side button is
    -- released mid-drag.
    -- A pen touching down while a picker is up taps the picker, even with the
    -- highlighter button held (otherwise it would start a highlight under it)
    if self.color_picker_showing and self.color_picker_widget and not self.pen_down
            and slot.id and slot.id >= 0 then
        local px, py = self:transformCoordinates(slot.x or 0, slot.y or 0)
        if self.color_picker_widget:handlePenTap(px, py) then
            return true
        end
    end

    -- The hold that opened the picker must not transition back into a text or
    -- freehand highlight behind the popup. Consume it until the pen is lifted;
    -- the following contact can then select a picker item normally.
    if self.color_picker_contact_active then
        if not slot.id or slot.id < 0 then
            self.color_picker_contact_active = false
            self.pen_down = false
            self.current_stroke = nil
            self.live_highlighter = nil
            self.tool.highlighting = false
            self.tool.highlight_freehand = false
            self:cancelColorPickerTimer()
        end
        return true
    end

    local highlight_step = self.tool:detectHighlighting(slot, self.side_button_down)
    if highlight_step == "extend" then
        self:extendTextHighlight(slot.x or 0, slot.y or 0)
        -- Holding the highlighter still over text opens the picker too
        local hx, hy = self:transformCoordinates(slot.x or 0, slot.y or 0)
        self.pen_x, self.pen_y = hx, hy
        self:movePickerTracking(hx, hy)
        return true
    elseif highlight_step == "finish" then
        self:cancelColorPickerTimer()
        self:finishTextHighlight()
        return true
    elseif highlight_step == "ignore" then
        return true
    elseif highlight_step == "start" then
        if self:startTextHighlight(slot.x or 0, slot.y or 0) then
            local hx, hy = self:transformCoordinates(slot.x or 0, slot.y or 0)
            self.pen_x, self.pen_y = hx, hy
            self:beginPickerTracking(hx, hy, TOOL_HIGHLIGHTER)
            return true
        end
        -- No text below the pen: this contact draws a freehand highlighter
        -- stroke (handled below, effective tool is the highlighter)
        self.tool.highlight_freehand = true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Log in debug mode
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS: slot=%d id=%d x=%d y=%d tool=%d pen_down=%s tool=%s",
            slot.slot or -1, slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.pen_down), self.tool:getTool()))
    end

    -- Determine effective tool: eraser role, then highlighter role (slot.tool
    -- or side button held), then the selected tool. Same rule as the gesture path.
    local effective_tool = self.tool:getEffectiveToolForSlot(slot, self.side_button_down)
    if self.input_debug_mode and effective_tool == TOOL_ERASER and slot.tool == LINUX_TOOLTYPE.ERASER then
        self:writeDebugLog(string.format("ERASER END detected via slot.tool=%d", slot.tool))
    end

    -- Handle eraser mode
    if effective_tool == TOOL_ERASER then
        if self.input_debug_mode and not self.tool.erasing then
            self:writeDebugLog(string.format("ERASER MODE: pen_down=%s slot.id=%d",
                tostring(self.pen_down), slot.id or -1))
        end
        if slot.id and slot.id >= 0 then
            -- Eraser is touching - erase at this position
            local first_touch = false
            if not self.pen_down then
                self.pen_down = true
                self.tool.erasing = true
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
                        x, y, tostring(page), tostring(self.tool.erasing)))
                end
                local deleted = self:eraseAtPoint(x, y, page, true)
                if deleted then
                    for _, stroke in ipairs(deleted) do
                        table.insert(self.eraser_deleted, stroke)
                    end
                    self:refreshAfterErase(deleted, false)
                    if self.input_debug_mode then
                        self:writeDebugLog(string.format("ERASED %d strokes at (%d, %d)", #deleted, x, y))
                    end
                end
                self.pen_x = x
                self.pen_y = y
            end
        else
            -- Eraser lifted
            if self.pen_down and self.tool.erasing then
                self.pen_down = false
                self.tool.erasing = false
                self:finishEraseGesture()
                if self.eraser_deleted and #self.eraser_deleted > 0 then
                    self.store:pushUndo({ type = "delete", strokes = self.eraser_deleted })
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

    if self.lasso then
        return self:handleLassoSlot(slot)
    end

    -- Handle pen/highlighter mode
    if slot.id and slot.id >= 0 then
        -- Pen down or moving
        if not self.pen_down then
            -- Pen down on a note marker opens the note.
            if self.notes and #self.notes > 0 then
                local mx, my = self:transformCoordinates(slot.x or 0, slot.y or 0)
                local note = self:findNoteMarkerAt(mx, my)
                if note then
                    self:openNote(note, true)
                    return true
                end
            end
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
            self.tool.erasing = false
            self:cancelPendingRefresh()
            self:cancelColorPickerTimer()
            self:startRawStroke(effective_tool)
            -- Record initial position and timestamp for color picker trigger
            local raw_x = slot.x or 0
            local raw_y = slot.y or 0
            local x, y = self:transformCoordinates(raw_x, raw_y)
            -- Record the touch-down point itself, so a tap with no movement
            -- (a dot) still produces a stroke and strokes start where the pen
            -- landed instead of at the first move.
            if slot.x and slot.y then
                self:addRawPoint(x, y)
            end
            self.pen_x = x
            self.pen_y = y
            -- Hold still to open the pen's or the highlighter's picker
            self:beginPickerTracking(x, y, effective_tool)
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN DOWN ===")
            end
        else
            -- Pen is moving
            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            if x ~= self.pen_x or y ~= self.pen_y then
                -- Pen moved too far from where it came down: no picker
                self:movePickerTracking(x, y)
                self:addRawPoint(x, y)
                self:trackUnderlineHold(x, y)
                self.pen_x = x
                self.pen_y = y
            end
        end
    else
        -- Pen lifted (id == -1)
        if self.pen_down and not self.tool.erasing then
            self.pen_down = false
            self:cancelColorPickerTimer()
            self:cancelUnderlineHold()
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

-- Luminance (0..255) of a Blitbuffer color, or nil when it can't be derived.
local function colorLuminance(color)
    if not color or not color.getColor8 then return nil end
    local ok, c8 = pcall(color.getColor8, color)
    if not ok or not c8 then return nil end
    return c8.a
end

-- Start a new stroke from raw input
function Pencil:startRawStroke(tool)
    local page = self:getCurrentPage()
    tool = tool or (self.side_button_down and TOOL_HIGHLIGHTER or self.tool:getTool())
    local tool_settings = self.tool:getToolSettings(tool)

    self.current_stroke = PencilStrokes.newStroke(page, tool, tool_settings)

    -- Resolve the effective draw color once per stroke. The night-mode
    -- invert allocates a new FFI color object, so doing it per point puts
    -- avoidable pressure on the GC during long strokes.
    local draw_color = tool_settings.color
    if Screen.night_mode and tool_settings.color_name ~= "Black" and tool_settings.color_name ~= "Gray"
            and draw_color and draw_color.invert then
        draw_color = draw_color:invert()
    end
    self.stroke_draw_color = draw_color

    -- Decide the in-stroke refresh waveform once per stroke. Dark ink can
    -- use the fast monochrome waveform (DU/A2 — what Kobo's own notebook
    -- uses for live ink), which has far lower e-ink latency than the UI
    -- waveform. Light shades (highlighter, gray) would get thresholded to
    -- white and turn invisible mid-stroke, and color screens still need the
    -- UI waveform to show non-black shades while drawing, so those keep
    -- refreshUI. The final delayed refresh repaints everything at full
    -- quality either way.
    local lum = colorLuminance(draw_color)
    local color_screen = Screen.isColorEnabled and Screen:isColorEnabled()
    self.stroke_fast_refresh = Screen.refreshFast ~= nil
        and lum ~= nil and lum < 0x80
        and not (color_screen and tool_settings.color_name ~= "Black")

    self.last_refresh_time = time.now()
    self.dirty_region = nil  -- Clear any pending dirty region
    logger.dbg("Pencil: raw stroke started")
end

-- Add a point from raw input and draw it
function Pencil:addRawPoint(x, y)
    if not self.current_stroke then return end

    local point = { x = x, y = y }
    table.insert(self.current_stroke.points, point)

    local bbox = self.current_stroke.bbox
    if bbox then
        if x < bbox.x0 then bbox.x0 = x end
        if y < bbox.y0 then bbox.y0 = y end
        if x > bbox.x1 then bbox.x1 = x end
        if y > bbox.y1 then bbox.y1 = y end
    else
        self.current_stroke.bbox = { x0 = x, y0 = y, x1 = x, y1 = y }
    end

    local n = #self.current_stroke.points

    local width = self.current_stroke.width
    local color = PencilStrokes.liveColor(self.current_stroke, self.live_black_preview)
    local half_w = math.floor(width / 2) + 2

    -- Reinvert color in night mode (if it's not black or gray)
    local using_black_preview =
        self.live_black_preview
        and self.current_stroke.tool == TOOL_PEN
        and self.current_stroke.color_name
        and self.current_stroke.color_name ~= "Black"

    if using_black_preview then
        color = Screen.night_mode
            and Blitbuffer.COLOR_WHITE
            or Blitbuffer.COLOR_BLACK
    elseif Screen.night_mode
        and self.current_stroke.color_name ~= "Black"
        and self.current_stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    -- Draw to framebuffer and track dirty region
    local dirty_x, dirty_y, dirty_w, dirty_h
    if n == 1 then
        if self.ui and self.ui.paging then
            self:captureStrokeAnchor(self.current_stroke, x, y)
        end
        -- Draw first point same size as line segments for consistency
        if self.current_stroke.tool == TOOL_HIGHLIGHTER then
            self.live_highlighter = PencilStrokes.drawLiveHighlighter(self.live_highlighter, Screen.bb, self.current_stroke, x, y, x, y)
        else
            local half_w_draw = math.floor(width / 2)
            Screen.bb:paintRectRGB32(x - half_w_draw, y - half_w_draw, width, width, color)
        end
        -- Use slightly larger dirty region for refresh padding
        dirty_x = x - half_w
        dirty_y = y - half_w
        dirty_w = width + 4
        dirty_h = width + 4
    elseif n >= 2 then
        local p1 = self.current_stroke.points[n - 1]
        local p2 = self.current_stroke.points[n]
        if self.current_stroke.tool == TOOL_HIGHLIGHTER then
            self.live_highlighter = PencilStrokes.drawLiveHighlighter(self.live_highlighter, Screen.bb, self.current_stroke, p1.x, p1.y, p2.x, p2.y)
        else
            PencilStrokes.drawThickLine(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
        -- Calculate bounding box of the segment
        dirty_x = math.min(p1.x, p2.x) - half_w
        dirty_y = math.min(p1.y, p2.y) - half_w
        dirty_w = math.abs(p2.x - p1.x) + width + 4
        dirty_h = math.abs(p2.y - p1.y) + width + 4
    end

    -- Accumulate dirty region for batch refresh
    if dirty_x then
        local r = self.dirty_region
        if r then
            -- Expand existing dirty region in place (no per-point alloc)
            local x2 = math.max(r.x + r.w, dirty_x + dirty_w)
            local y2 = math.max(r.y + r.h, dirty_y + dirty_h)
            if dirty_x < r.x then r.x = dirty_x end
            if dirty_y < r.y then r.y = dirty_y end
            r.w = x2 - r.x
            r.h = y2 - r.y
        else
            self.dirty_region = { x = dirty_x, y = dirty_y, w = dirty_w, h = dirty_h }
        end
    end

    -- Periodic refresh of dirty region only
    local now = time.now()
    if time.to_ms(now - self.last_refresh_time) >= self.refresh_interval_ms then
        self.last_refresh_time = now
        self:refreshDirtyRegion()
    end
end

-- Refresh the screen area drawn since the last refresh, if any.
function Pencil:refreshDirtyRegion()
    local r = self.dirty_region
    if not r then return end
    -- Clamp to screen bounds
    local rx = math.max(0, math.floor(r.x))
    local ry = math.max(0, math.floor(r.y))
    local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
    local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
    if self.stroke_fast_refresh then
        -- Fast monochrome waveform: lowest e-ink latency for dark ink
        Screen:refreshFast(rx, ry, rw, rh)
    else
        -- UI waveform: needed for proper shading of light/colored ink
        Screen:refreshUI(rx, ry, rw, rh)
    end
    self.dirty_region = nil
end

-- Restart the underline hold timer whenever the pen moves beyond the
-- "still" tolerance; leave it running while the pen rests.
function Pencil:trackUnderlineHold(x, y)
    if not self.underline_hold or self.side_button_down then return end
    if self.underline_still_x
            and math.abs(x - self.underline_still_x) <= UNDERLINE_STILL_PIXELS
            and math.abs(y - self.underline_still_y) <= UNDERLINE_STILL_PIXELS then
        return
    end
    self.underline_still_x = x
    self.underline_still_y = y
    if not self._underline_check then
        -- One closure per plugin instance, reused for every reschedule.
        self._underline_check = function() self:checkUnderlineHold() end
    end
    UIManager:unschedule(self._underline_check)
    UIManager:scheduleIn(UNDERLINE_HOLD_MS / 1000, self._underline_check)
end

function Pencil:cancelUnderlineHold()
    self.underline_still_x = nil
    self.underline_still_y = nil
    if self._underline_check then
        UIManager:unschedule(self._underline_check)
    end
end

-- Fired after the pen rested UNDERLINE_HOLD_MS: if the stroke so far is a
-- roughly horizontal line under text, turn it into a native highlight.
function Pencil:checkUnderlineHold()
    local stroke = self.current_stroke
    if not (self.pen_down and stroke and not self.tool.highlighting) then return end
    if stroke.tool ~= TOOL_PEN or #stroke.points < 2 then return end
    local bbox = PencilGeometry.computeStrokeBbox(stroke)
    local w, h = bbox.x1 - bbox.x0, bbox.y1 - bbox.y0
    if w < UNDERLINE_MIN_LENGTH or h > w * UNDERLINE_MAX_SLOPE then return end
    if not self:underlineTextAbove(bbox) then return end

    -- The ink was only a gesture: drop it and repaint where it was.
    self.current_stroke = nil
    self.dirty_region = nil
    self.view:paintTo(Screen.bb, 0, 0)
    self:paintTo(Screen.bb, 0, 0)
    local pad = (stroke.width or 3) + 4
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local rx, ry = math.max(0, bbox.x0 - pad), math.max(0, bbox.y0 - pad)
    Screen:refreshUI(rx, ry, math.min(sw - rx, w + 2 * pad), math.min(sh - ry, h + 2 * pad))
end

-- Find the page position of the text just above a screen point, looking
-- up to UNDERLINE_SEARCH_PIXELS. Returns the page position and the offset.
function Pencil:findTextAbove(x, y)
    for dy = 2, UNDERLINE_SEARCH_PIXELS, 4 do
        local page_pos = self.ui.view:screenToPageTransform({ x = x, y = y - dy })
        if page_pos then
            local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, page_pos)
            if ok and word and word.pos0 then
                return page_pos, dy
            end
        end
    end
end

-- Save a native KOReader highlight over the text above a stroke bbox.
-- @return true if a highlight was saved
function Pencil:underlineTextAbove(bbox)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return false
    end
    local start_pos, dy = self:findTextAbove(bbox.x0 + 2, bbox.y0)
    if not start_pos then return false end
    -- Use the same text line for the end point.
    local end_pos = self.ui.view:screenToPageTransform({ x = bbox.x1 - 2, y = bbox.y0 - dy })
    if not end_pos then return false end

    local ok, selected = pcall(self.ui.document.getTextFromPositions,
                               self.ui.document, start_pos, end_pos)
    if not (ok and selected and selected.pos0 and selected.pos1) then return false end
    -- No drawer set: saveHighlight uses the reader's default highlight style.

    local rh = self.ui.highlight
    rh.selected_text = selected
    local saved, err = pcall(rh.saveHighlight, rh, false)
    if not saved then
        logger.warn("Pencil: saving underline failed:", tostring(err))
    end
    if rh.clear then pcall(rh.clear, rh) end
    return saved
end

-- End stroke from raw input
function Pencil:endRawStroke()
    if self.input_debug_mode then
        self:writeDebugLog(string.format("endRawStroke: current_stroke=%s points=%d",
            tostring(self.current_stroke ~= nil),
            self.current_stroke and #self.current_stroke.points or 0))
    end
    if self.current_stroke and #self.current_stroke.points >= 1 then
        self:anchorStrokeToPage(self.current_stroke)
        local stroke_idx = self.store:add(self.current_stroke)
        self.store:pushUndo({ type = "add", stroke_idx = stroke_idx })
        self:assignStrokeToGroup(stroke_idx)
        self:scheduleDeferredWork()
        if self.input_debug_mode then
            self:writeDebugLog(string.format("endRawStroke: SAVED stroke #%d with %d points, total strokes=%d",
                self.store:count(), #self.current_stroke.points, self.store:count()))
        end
        logger.dbg("Pencil: raw stroke ended with", #self.current_stroke.points, "points")
        -- Track the region this stroke touched so the delayed refresh below
        -- can be scoped to it instead of the whole screen.
        self:accumulateRefreshBbox(self.current_stroke)

        -- Le trait a été affiché directement en noir dans Screen.bb.
        -- Conserver sa référence pour pouvoir le redessiner directement
        -- avec sa vraie couleur après le délai.
        if self.live_black_preview
            and self.current_stroke.tool == TOOL_PEN
            and self.current_stroke.color_name
            and self.current_stroke.color_name ~= "Black" then
            self.pending_color_strokes = self.pending_color_strokes or {}
            self.pending_color_strokes[#self.pending_color_strokes + 1] =
                self.current_stroke
        end
    else
        if self.input_debug_mode then
            self:writeDebugLog("endRawStroke: NOT SAVED (no current_stroke or no points)")
        end
    end
    -- Show the tail drawn since the last periodic refresh now, rather than
    -- letting it appear only with the delayed full refresh.
    self:refreshDirtyRegion()
    self.current_stroke = nil
    self.live_highlighter = nil
    -- Schedule delayed refresh for clean display after writing stops
    self:scheduleDelayedRefresh()
end

-- Paint the in-progress text selection as "invert" rectangles while a
-- highlight drag is active. Mirrors what KOReader does during a normal
-- finger long-press+drag: the reader's paintTo iterates
-- self.view.highlight.temp[page] and inversion-paints each sbox. All we
-- have to do is populate that table with our current sboxes, then
-- setDirty so a repaint runs.
function Pencil:_paintTempSelection()
    if not (self.ui and self.ui.view and self.ui.view.highlight and self.ui.highlight) then
        return
    end
    local rh = self.ui.highlight
    local temp = self.ui.view.highlight.temp
    -- Reset any previous frame's temp entries so stale sboxes from earlier
    -- in the drag don't linger after the selection shrinks.
    for k in pairs(temp) do temp[k] = nil end
    if rh.selected_text and rh.selected_text.sboxes and #rh.selected_text.sboxes > 0 then
        local page_key = rh.hold_pos and rh.hold_pos.page or 1
        temp[page_key] = rh.selected_text.sboxes
    end
    UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
end

-- Clear the in-progress selection preview. Called on pen lift before we
-- persist the selection as a saved highlight (which then paints itself
-- via drawSavedHighlight instead of via temp).
function Pencil:_clearTempSelection()
    if not (self.ui and self.ui.view and self.ui.view.highlight) then return end
    local temp = self.ui.view.highlight.temp
    for k in pairs(temp) do temp[k] = nil end
    UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
end

-- Start a native KOReader text-highlight selection at a raw stylus position.
-- Called from handleStylusSlot when slot.tool has been promoted to HIGHLIGHTER
-- by input.lua (i.e., the side button is held during a pen contact).
--
-- Manipulates self.ui.highlight (ReaderHighlight) directly because there is
-- no public "start programmatic selection" API — the standard entry points
-- (onHold / onHoldPan) do extra work (panel-zoom probing, gesture wiring)
-- that we don't need and that would interact badly with our stylus-sourced
-- events. The methods we do call (getWordFromPosition / getTextFromPositions
-- / saveHighlight) are the same ones KOReader itself invokes internally.
function Pencil:startTextHighlight(raw_x, raw_y)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return false
    end
    local screen_x, screen_y = self:transformCoordinates(raw_x, raw_y)
    local page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
    if not page_pos then return false end  -- Outside any page area

    -- Only a text highlight if there is a word right below the pen; otherwise
    -- the caller draws a freehand highlighter stroke instead.
    local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, page_pos)
    if not (ok and word and word.pos0 and word.pos1) then
        return false
    end

    local rh = self.ui.highlight
    rh.hold_pos = page_pos
    rh.selected_text = {
        text = word.word or "",
        pos0 = word.pos0,
        pos1 = word.pos1,
        sboxes = word.sbox and { word.sbox } or {},
        pboxes = word.pbox and { word.pbox } or {},
    }

    self.tool.highlighting = true
    -- Prevent the drawing-path pen-down branch from also firing on subsequent
    -- events for this contact.
    self.pen_down = true

    -- Show the first-word preview immediately.
    self:_paintTempSelection()
    return true
end

-- Extend the active text-highlight selection to a new raw stylus position.
-- Called on each stylus slot update while self.tool.highlighting is true.
function Pencil:extendTextHighlight(raw_x, raw_y)
    if not (self.ui and self.ui.highlight and self.ui.view and self.ui.document) then
        return
    end
    local rh = self.ui.highlight
    if not rh.hold_pos then return end

    local screen_x, screen_y = self:transformCoordinates(raw_x, raw_y)
    local page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
    if not page_pos then return end
    rh.holdpan_pos = page_pos

    -- getTextFromPositions handles EPUB (xpointer) and PDF (x/y/page) shapes
    -- and returns a selection dict with pos0/pos1/text/sboxes/pboxes.
    local ok, selected = pcall(self.ui.document.getTextFromPositions,
                               self.ui.document, rh.hold_pos, rh.holdpan_pos)
    if ok and selected and selected.pos0 and selected.pos1 then
        rh.selected_text = selected
        -- Repaint preview with the new sboxes.
        self:_paintTempSelection()
    end
end

-- Drop the text highlight in progress without saving it (the highlighter was
-- held still to open its picker). The pen stays "down" until it is lifted, so
-- the rest of this contact is ignored.
function Pencil:cancelTextHighlight()
    local rh = self.ui and self.ui.highlight
    self:_clearTempSelection()
    if rh and rh.clear then
        pcall(rh.clear, rh)
    end
    self.tool.highlighting = false
    -- Rest of this contact: not a new highlight, not a stroke
    self.tool.highlight_freehand = true
end

-- Persist the current selection as a KOReader highlight annotation and reset.
-- Called on slot.id transitioning to -1 (pen lift) while self.tool.highlighting.
function Pencil:finishTextHighlight()
    local rh = self.ui and self.ui.highlight
    local has_selection = rh and rh.selected_text
        and rh.selected_text.pos0 and rh.selected_text.pos1

    -- Clear the in-progress preview first; the saved highlight's own paint
    -- path (drawSavedHighlight) will take over on the next frame.
    self:_clearTempSelection()

    if has_selection then
        -- saveHighlight(false) builds the annotation item from self.selected_text
        -- and calls self.ui.annotation:addItem(item) internally, handling the
        -- PDF/EPUB item-shape difference. It emits AnnotationsModified itself,
        -- so we do NOT emit a second one here — a userpatch may further wrap
        -- this call to prompt for color, but that's not the plugin's concern.
        local ok, err = pcall(rh.saveHighlight, rh, false)
        if not ok then
            logger.warn("Pencil: saveHighlight failed:", tostring(err))
        end
    end

    if rh and rh.clear then
        pcall(rh.clear, rh)
    end

    self.tool.highlighting = false
    self.pen_down = false
end

-- Find the index in self.ui.annotation.annotations of a saved text highlight
-- whose rendered boxes cover screen position (screen_x, screen_y).
-- Returns nil if no highlight is at that position.
-- Used by the eraser path so flipping to the eraser end and swiping across a
-- highlight removes it, the same way it removes freehand strokes.
function Pencil:findHighlightAtScreenPos(screen_x, screen_y)
    if not (self.ui and self.ui.annotation and self.ui.annotation.annotations
            and self.ui.view and self.ui.document) then
        return nil
    end

    local is_paging = self.ui.paging ~= nil
    local page_pos
    if is_paging then
        page_pos = self.ui.view:screenToPageTransform({ x = screen_x, y = screen_y })
        if not page_pos then return nil end
    end

    -- Box lookups go through the document engine for every highlight in the
    -- book, which is far too slow per eraser sample. Compute them once per
    -- page and reuse until a highlight is removed or the gesture ends.
    local cache_page = is_paging and page_pos.page or self:getCurrentPage()
    local cache = self.highlight_box_cache
    if not cache or cache.page ~= cache_page then
        cache = { page = cache_page, entries = {} }
        for index, item in ipairs(self.ui.annotation.annotations) do
            -- drawer is nil for page-bookmarks; only text highlights have it set.
            if item.drawer and item.pos0 and item.pos1 then
                local boxes
                if is_paging then
                    if item.page == page_pos.page then
                        local ok, got = pcall(self.ui.document.getPageBoxesFromPositions,
                                              self.ui.document, page_pos.page, item.pos0, item.pos1)
                        if ok then boxes = got end
                    end
                else
                    -- Rolling mode (EPUB): work in screen coordinates directly.
                    local ok, got = pcall(self.ui.document.getScreenBoxesFromPositions,
                                          self.ui.document, item.pos0, item.pos1, true)
                    if ok then boxes = got end
                end
                if boxes and #boxes > 0 then
                    table.insert(cache.entries, { index = index, boxes = boxes })
                end
            end
        end
        self.highlight_box_cache = cache
    end

    local px = is_paging and page_pos.x or screen_x
    local py = is_paging and page_pos.y or screen_y
    for _, entry in ipairs(cache.entries) do
        for _, box in ipairs(entry.boxes) do
            if px >= box.x and px < box.x + box.w
                    and py >= box.y and py < box.y + box.h then
                return entry.index
            end
        end
    end
    return nil
end

-- Delete any KOReader text highlight at the given screen position.
-- Used by the eraser pass inside handleStylusSlot. removeItemByIndex emits
-- AnnotationsModified and does the logical cleanup, but on e-ink its
-- setDirty is not strong enough to clear the highlight's painted pixels
-- from the framebuffer — users saw the removed highlight linger until the
-- next page turn forced a full refresh. Force a UI-mode setDirty here so
-- the overlay actually disappears.
function Pencil:eraseHighlightAtScreenPos(screen_x, screen_y)
    local index = self:findHighlightAtScreenPos(screen_x, screen_y)
    if not index then return false end
    -- Use ReaderHighlight:deleteHighlight, not bookmark:removeItemByIndex.
    -- The latter only drops the highlight from KOReader's list; the former also
    -- removes it from the PDF (via writePdfAnnotation "delete") when write-into-
    -- PDF is on -- otherwise MuPDF keeps rendering the baked annotation and the
    -- highlight never disappears. The PDF mutation is in-memory; our close
    -- flush writes it out (mark dirty so it does).
    if not (self.ui and self.ui.highlight and self.ui.highlight.deleteHighlight) then
        return false
    end
    local ok = pcall(self.ui.highlight.deleteHighlight, self.ui.highlight, index)
    -- Annotation indices and rendered boxes shift after a removal.
    self.highlight_box_cache = nil
    if ok then
        self._pdf_dirty = true
        UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
    end
    return ok
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

-- Initialize debug logging (clear log and write header)
function Pencil:initDebugLog()
    if not self.input_debug_mode then return end
    self:clearDebugLog()
    self:writeDebugLog("Debug logging enabled")
    local Input = Device.input
    if Input then
        self:writeDebugLog("Input.pen_slot = " .. tostring(Input.pen_slot or "nil"))
    end
end

-- Load plugin settings
function Pencil:loadSettings()
    local settings = G_reader_settings:readSetting("pencil_annotation_settings") or {}
    self.input_debug_mode = settings.input_debug_mode or false
    self.experimental_bookmark_sync = settings.experimental_bookmark_sync or false
    self.experimental_pen_width = settings.experimental_pen_width or false
    self.experimental_color_picker = settings.experimental_color_picker or false
    self.auto_save_pdf = settings.auto_save_pdf or false
    self.myscript_language = settings.myscript_language or "en_US"
    self.myscript_application_key = settings.myscript_application_key or ""
    self.myscript_hmac_key = settings.myscript_hmac_key or ""
    self.underline_hold = settings.underline_hold ~= false
    self.palm_rejection = settings.palm_rejection ~= false
    self.hold_menu = settings.hold_menu ~= false
    self.live_black_preview = settings.live_black_preview or false
    self.tool:loadSettings(settings, self.available_colors, self.available_widths)
end

function Pencil:saveSettings()
    local settings = {
        input_debug_mode = self.input_debug_mode,
        experimental_bookmark_sync = self.experimental_bookmark_sync,
        experimental_pen_width = self.experimental_pen_width,
        experimental_color_picker = self.experimental_color_picker,
        auto_save_pdf = self.auto_save_pdf,
        myscript_language = self.myscript_language,
        myscript_application_key = self.myscript_application_key,
        myscript_hmac_key = self.myscript_hmac_key,
        underline_hold = self.underline_hold,
        palm_rejection = self.palm_rejection,
        hold_menu = self.hold_menu,
        live_black_preview = self.live_black_preview,
    }
    for key, value in pairs(self.tool:exportSettings()) do
        settings[key] = value
    end
    G_reader_settings:saveSetting("pencil_annotation_settings", settings)
end

function Pencil:setTool(tool)
    self.tool:setTool(tool)
    self:saveSettings()
end

function Pencil:isEnabled()
    return G_reader_settings:readSetting("pencil_annotation_enabled") == true
end

-- Check if a menu or overlay is shown on top of the reader view.
-- When true, pen input should pass through so the overlay can handle it.
function Pencil:isOverlayActive()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    -- ReaderUI is the document view itself — anything else is an overlay.
    -- getTopmostVisibleWidget skips widgets marked invisible — transient
    -- decorations that paint but don't capture input, e.g. TrapWidget.
    return (top.name or top.id) ~= "ReaderUI"
end

-- Set enabled state (global setting)
function Pencil:setEnabled(enabled)
    G_reader_settings:saveSetting("pencil_annotation_enabled", enabled)
end

-- Highlighter submenu: color and opacity of the highlighter strokes drawn
-- where there is no text to highlight.
function Pencil:buildHighlighterMenu()
    local function hlSettings()
        return self.tool:getToolSettings(TOOL_HIGHLIGHTER)
    end

    local color_items = {}
    for _, color_info in ipairs(self:getHighlighterColors()) do
        table.insert(color_items, {
            text = color_info.name,
            radio = true,
            checked_func = function()
                return hlSettings().color_name == color_info.name
            end,
            callback = function()
                self:setHighlighterColor(color_info.color, color_info.name)
            end,
            keep_menu_open = true,
        })
    end

    local opacity_items = {}
    for _, percent in ipairs(PencilTool.HIGHLIGHTER_OPACITIES) do
        table.insert(opacity_items, {
            text = string.format("%d%%", percent),
            radio = true,
            checked_func = function()
                return self.tool:getHighlighterOpacity() == percent
            end,
            callback = function()
                self:setHighlighterOpacity(percent)
            end,
            keep_menu_open = true,
        })
    end

    return {
        text_func = function()
            return T(_("Highlighter: %1, %2"), hlSettings().color_name or "?",
                string.format("%d%%", self.tool:getHighlighterOpacity()))
        end,
        help_text = _("Color and opacity of the highlighter strokes drawn where there is no text under the pen. A lower opacity lets more of the page show through. Strokes already drawn keep their own color and opacity."),
        sub_item_table = {
            {
                text_func = function()
                    return T(_("Color: %1"), hlSettings().color_name or "?")
                end,
                sub_item_table = color_items,
            },
            {
                text_func = function()
                    return T(_("Opacity: %1"), string.format("%d%%", self.tool:getHighlighterOpacity()))
                end,
                sub_item_table = opacity_items,
            },
        },
    }
end

function Pencil:addToMainMenu(menu_items)
    menu_items.pencil_annotation = {
        text = _("Pencil"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Enabled"),
                checked_func = function()
                    return self:isEnabled()
                end,
                callback = function()
                    self:onPencilToggleEnabled()
                end,
                separator = true,
            },
            {
                text = _("Swap Eraser and Highlighter"),
                checked_func = function()
                    return self.tool:isSwaped()
                end,
                callback = function()
                    self.tool:swapEraserHighlighter()
                    self:saveSettings()
                end,
                separator = true,
            },
            self:buildHighlighterMenu(),
            {
                text = _("Tool"),
                help_text = _("Select pencil or eraser."),
                sub_item_table = {
                    {
                        text = _("Pencil"),
                        checked_func = function()
                            return self.tool:getTool() == TOOL_PEN
                        end,
                        callback = function()
                            self:setTool(TOOL_PEN)
                        end,
                    },
                    {
                        text = _("Eraser"),
                        checked_func = function()
                            return self.tool:getTool() == TOOL_ERASER
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
                    return self.store:canUndo()
                end,
            },
            {
                text = _("Redo"),
                callback = function()
                    self:redoLastStroke()
                end,
                enabled_func = function()
                    return self.store:canRedo()
                end,
                separator = true,
            },
            {
                text = _("Clear page strokes"),
                callback = function()
                    self:clearPageStrokes()
                end,
                enabled_func = function()
                    return self.store:hasOnPage(self:getCurrentPage())
                end,
            },
            {
                text = _("Clear all strokes"),
                callback = function()
                    self:clearAllStrokes()
                end,
                enabled_func = function()
                    return self.store:count() > 0
                end,
            },
            {
                text_func = function()
                    local bytes = self:getImagesSizeBytes()
                    if bytes <= 0 then
                        return _("Annotation images: none")
                    elseif bytes < 1024 * 1024 then
                        return T(_("Annotation images: %1 KB"), math.floor(bytes / 1024))
                    else
                        return T(_("Annotation images: %1 MB"),
                            string.format("%.1f", bytes / (1024 * 1024)))
                    end
                end,
                help_text = _("Saved preview images of your annotations are used to show what you wrote even after the device is rotated, and to preview annotations from the bookmark list. Tap to clear them for this book."),
                keep_menu_open = true,
                enabled_func = function()
                    return self:getImagesSizeBytes() > 0
                end,
                callback = function(touchmenu_instance)
                    self:purgeAllImages()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    UIManager:show(InfoMessage:new{
                        text = _("Cleared all annotation preview images for this book."),
                        timeout = 2,
                    })
                end,
                separator = true,
            },
            {
                text = _("Experimental"),
                sub_item_table = {
                    {
                        text = _("Bookmark sync"),
                        help_text = _("Automatically create KOReader bookmarks for pencil annotations so you can navigate to annotated pages from the Bookmarks menu."),
                        checked_func = function()
                            return self.experimental_bookmark_sync
                        end,
                        callback = function()
                            self.experimental_bookmark_sync = not self.experimental_bookmark_sync
                            self:saveSettings()
                            if self.experimental_bookmark_sync then
                                self:syncAllBookmarks()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync enabled. Pencil annotations will appear in the Bookmarks menu."),
                                    timeout = 3,
                                })
                            else
                                self:removeAllPencilBookmarks()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync disabled. Pencil bookmarks removed."),
                                    timeout = 3,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Color picker"),
                        help_text = _("Allow the hold-pen-still gesture to open a picker for changing pen color (and, if the pen width picker is also enabled, stroke width). Holding the highlighter still opens a picker for its color and opacity. When disabled, the pen and the highlighter stay on their last-saved settings."),
                        checked_func = function()
                            return self.experimental_color_picker
                        end,
                        callback = function()
                            self.experimental_color_picker = not self.experimental_color_picker
                            self:saveSettings()
                            if self.experimental_color_picker then
                                UIManager:show(InfoMessage:new{
                                    text = _("Color picker enabled. Hold the pen still to open it."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Color picker disabled. Pen will keep its current color."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Pen width picker"),
                        help_text = _("Add pen width options (3, 5, 7, 9) to the color picker. The width buttons appear as black bars whose height previews the stroke thickness. Requires the color picker to also be enabled."),
                        checked_func = function()
                            return self.experimental_pen_width
                        end,
                        callback = function()
                            self.experimental_pen_width = not self.experimental_pen_width
                            self:saveSettings()
                            if self.experimental_pen_width then
                                UIManager:show(InfoMessage:new{
                                    text = _("Pen width picker enabled. Hold the pen still to open the picker and choose a stroke width."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Pen width picker disabled."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Tool menu when holding the pen still"),
                        help_text = _("Hold the pen still on the page for a moment to open a menu with Undo, Redo, Lasso and Note (plus colors and widths when those options are on)."),
                        checked_func = function()
                            return self.hold_menu
                        end,
                        callback = function()
                            self.hold_menu = not self.hold_menu
                            self:saveSettings()
                        end,
                    },
                    {
                        text = _("Highlight by holding at line end"),
                        help_text = _("Draw a line under text and rest the pen at the end for a moment: the ink is replaced by a native KOReader highlight (in your default highlight style) on the words above it."),
                        checked_func = function()
                            return self.underline_hold
                        end,
                        callback = function()
                            self.underline_hold = not self.underline_hold
                            self:saveSettings()
                        end,
                    },
                    {
                        text = _("Ignore touch while writing"),
                        help_text = _("Ignore finger and palm touches that start while the pen is near the screen or was just used, so a resting hand doesn't turn pages or open menus. Move the pen away to use touch again."),
                        checked_func = function()
                            return self.palm_rejection
                        end,
                        callback = function()
                            self.palm_rejection = not self.palm_rejection
                            self:saveSettings()
                        end,
                    },
                    {
                        text = _("Text highlight (side button)"),
                        help_text = _("When enabled, holding the stylus side button during a pen drag creates a native KOReader text highlight on the words under the pen, like a long-press \xe2\x86\x92 Highlight. Where there is no text under the pen, a highlighter stroke is drawn instead. When disabled, the side button always draws a highlighter stroke. Off by default because this is a new integration and has edge cases. Requires a stylus that sends BTN_STYLUS2."),
                        checked_func = function()
                            return self.tool:isExperimentalTextHighlight()
                        end,
                        callback = function()
                            self.tool:experimentalTextHighlight()
                            self:saveSettings()
                            if self.tool:isExperimentalTextHighlight() then
                                UIManager:show(InfoMessage:new{
                                    text = _("Text highlight enabled. Hold the side button while dragging the pen across words; away from text it draws a highlighter stroke."),
                                    timeout = 3,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Text highlight disabled."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Save annotations to PDF (this page)"),
                        help_text = _("Write this page's pencil strokes (as ink annotations) and text highlights (as native highlight annotations) into the PDF file, so they travel with the file and are visible in any PDF reader. PDF documents only. Requires a KOReader build with MuPDF ink support (see the Pencil README)."),
                        keep_menu_open = true,
                        -- Always selectable for PDFs (it reports if there's
                        -- nothing on the page), so it's never hidden/greyed.
                        enabled_func = function()
                            return self.ui.paging ~= nil
                        end,
                        callback = function()
                            self:saveCurrentPageToPdf()
                        end,
                    },
                    {
                        text = _("Auto-save pencil ink to PDF on close"),
                        help_text = _("When enabled, every pencil stroke you've drawn is written into the PDF file as a native ink annotation when you close the document, so your annotations travel with the file. Runs once per session (only new strokes are added). PDF documents only; requires a KOReader build with MuPDF ink support. Text highlights are not auto-saved — use the per-page action above for those."),
                        enabled_func = function()
                            return self.ui.paging ~= nil and InkAnnot ~= nil
                        end,
                        checked_func = function()
                            return self.auto_save_pdf == true
                        end,
                        callback = function()
                            self.auto_save_pdf = not self.auto_save_pdf
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = self.auto_save_pdf
                                    and _("Pencil ink will be saved into the PDF when you close the document.")
                                    or _("Auto-save to PDF disabled."),
                                timeout = 2,
                            })
                        end,
                    },
                    {
                        text = _("Live black preview"),
                        help_text = _("Draw colored pen strokes in black while writing for faster visual feedback on color e-ink devices. The final delayed refresh redraws them using the selected color."),
                        checked_func = function()
                            return self.live_black_preview
                        end,
                        callback = function()
                            self.live_black_preview = not self.live_black_preview
                            self:saveSettings()

                            UIManager:show(InfoMessage:new{
                                               text = self.live_black_preview
                                                   and _("Live black preview enabled.")
                                                   or _("Live black preview disabled."),
                                               timeout = 2,
                            })
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Handwriting recognition"),
                sub_item_table = {
                    { text = _("Configure MyScript"), callback = function() self:showMyScriptSettingsDialog() end },
                    { text = _("Recognize latest annotation group"),
                      enabled_func = function() return self:getLatestAnnotationGroupOnCurrentPage() ~= nil end,
                      callback = function() local g = self:getLatestAnnotationGroupOnCurrentPage(); if g then self:recognizeAnnotationGroup(g) end end },
                    {
                        text = _("Recognize all annotation groups"),
                        enabled_func = function()
                            return self.annotation_groups and #self.annotation_groups > 0
                        end,
                        callback = function()
                            self:recognizeAllAnnotationGroups()
                        end,
                    },
                    {
                        text = _("Show all recognized text"),
                        enabled_func = function()
                            return self:hasRecognizedAnnotations()
                        end,
                        callback = function()
                            self:showAllRecognizedText()
                        end,
                    },
                    {
                        text = _("Edit all recognized text"),
                        enabled_func = function()
                            return self:hasRecognizedAnnotations()
                        end,
                        callback = function()
                            self:editAllRecognizedText()
                        end,
                    },
                },
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
                        -- Initialize debug logging
                        self:initDebugLog()
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
    local page_strokes = self.store.page_strokes[page] and #self.store.page_strokes[page] or 0
    local filepath = self:getStrokesFilePath() or "not available"

    -- Show all pages with strokes for debugging
    local pages_info = ""
    for p, indices in pairs(self.store.page_strokes) do
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

Eraser end: click to switch pen/eraser, drag to erase. Side button: hold+drag to highlight.

Enable "Input debug mode" to log raw events for diagnosis.

Pages with strokes:%8]]),
        self.tool:getTool(),
        self.store:count(),
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
-- Highlighter-role button (the side button, or the eraser end when swapped):
-- while it is down the pen highlights (text below the pen, or a freehand
-- highlighter stroke). Switching pen/eraser is the eraser role's click, see
-- onEraserClick().
function Pencil:onStylusButtonPress()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    self.side_button_down = true
    logger.dbg("Pencil: highlighter button pressed")
    return true
end

-- Handle stylus button release (up event)
function Pencil:onStylusButtonRelease()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    self.side_button_down = false
    logger.dbg("Pencil: highlighter button released, back to", self.tool:getTool())
    return true
end

-- Toggle between pen and eraser
function Pencil:togglePenEraser()
    self.tool:togglePenEraser()
    self:saveSettings()
end

-- Erase strokes (and native highlights) under a screen position on behalf of
-- the eraser end/button, remembering what was deleted for undo.
function Pencil:eraseWithEraserRole(x, y)
    self.eraser_button_deleted = self.eraser_button_deleted or {}
    -- Group rebuilding is deferred to the end of the gesture (finishEraseGesture)
    local deleted = self:eraseAtPoint(x, y, self:getCurrentPage(), true)
    if deleted then
        for _, stroke in ipairs(deleted) do
            table.insert(self.eraser_button_deleted, stroke)
        end
        self:refreshAfterErase(deleted, true)
    end
    -- Also remove any native KOReader text highlight at this position.
    -- removeItemByIndex emits AnnotationsModified and triggers its own
    -- repaint, so we don't need to mirror the refreshFast call above.
    self:eraseHighlightAtScreenPos(x, y)
    self.pen_x = x
    self.pen_y = y
end

-- A click with the eraser role (eraser end touching without dragging, or the
-- eraser button pressed and released) switches between pen and eraser.
function Pencil:onEraserClick()
    if not self:isEnabled() then return end
    logger.dbg("Pencil: eraser click - toggling pen/eraser")
    self:togglePenEraser()
end

-- Eraser mode ended (eraser end lifted or eraser button released): push what
-- it deleted onto the undo stack and repaint.
function Pencil:endEraserMode()
    self:finishEraseGesture()
    if self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
        self.store:pushUndo({ type = "delete", strokes = self.eraser_button_deleted })
        self:saveStrokes()
    end
    self.eraser_button_deleted = nil
    UIManager:setDirty(self.view, "ui")
end

-- Handle stylus button and tool events.
-- What a physical input does (erase / highlight) is decided by PencilTool, so
-- the swap eraser/highlighter option applies the same way to key press, key
-- release and raw stylus slots.
function Pencil:onKeyPress(key)
    -- Some Kobo key/Event objects have a __tostring that errors on nil fields;
    -- guard so a stray key event can't abort this handler mid-eraser-gesture.
    local ok_str, key_str = pcall(tostring, key)
    if not ok_str then key_str = "" end

    -- Always log key events when debug mode is on (even if not enabled)
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY PRESS: %s key.key=%s", key_str, tostring(key.key)))
    end

    local role, input = self.tool:roleForKey(key.key, key_str)

    -- Eraser role (eraser end/button, or the side button when swapped) -
    -- works regardless of pencil enabled state
    if role == TOOL_ERASER then
        logger.info("Pencil: eraser input PRESSED:", input)
        -- BTN_TOOL_RUBBER is the eraser end itself and stays flagged until it leaves
        if self.tool:activateEraser(input == PencilTool.INPUT.RUBBER) then
            self.eraser_button_deleted = {}
        end
        return true
    end

    -- BTN_TOOL_PEN - pen tip - deactivate eraser mode
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then
        logger.info("Pencil: BTN_TOOL_PEN press - deactivating eraser mode")
        self:finishEraseGesture()
        if self.tool.eraser_button_active and self.eraser_button_deleted and #self.eraser_button_deleted > 0 then
            -- Save any pending eraser deletions before switching to pen
            self.store:pushUndo({ type = "delete", strokes = self.eraser_button_deleted })
            self:saveStrokes()
        end
        self.tool:deactivateEraser(false)
        self.eraser_button_deleted = nil
        self.tool.eraser_tool_active = false
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Highlighter role (side button, or the eraser end/button when swapped):
    -- hold+drag highlights
    if role == TOOL_HIGHLIGHTER then
        logger.dbg("Pencil: highlighter input press detected:", key_str)
        return self:onStylusButtonPress()
    end
    return false
end

function Pencil:onKeyRelease(key)
    local ok_str, key_str = pcall(tostring, key)
    if not ok_str then key_str = "" end

    -- Always log key events when debug mode is on (even if not enabled)
    if self.input_debug_mode then
        self:writeDebugLog(string.format("KEY RELEASE: %s key.key=%s", key_str, tostring(key.key)))
    end

    local role, input = self.tool:roleForKey(key.key, key_str)

    -- Eraser role released - works regardless of pencil enabled state
    if role == TOOL_ERASER then
        if input == PencilTool.INPUT.RUBBER then
            -- BTN_TOOL_RUBBER released (eraser end moved away)
            logger.info("Pencil: BTN_TOOL_RUBBER release - deactivating eraser mode")
            local clicked = self.tool:deactivateEraser(false)
            self.tool.eraser_tool_active = false
            self:endEraserMode()
            if clicked then self:onEraserClick() end
            return true
        elseif self.tool.eraser_button_active then
            logger.info("Pencil: eraser input RELEASED:", input)
            -- The side button (when swapped to be the eraser) is a real button:
            -- pressing and releasing it without touching the screen is a click
            local clicked = self.tool:deactivateEraser(input == PencilTool.INPUT.SIDE_KEY)
            self:endEraserMode()
            if clicked then self:onEraserClick() end
            return true
        end
    end

    -- BTN_TOOL_PEN released
    if key_str:match("BTN_TOOL_PEN") or key_str:match("ToolPen") then
        logger.dbg("Pencil: BTN_TOOL_PEN release detected")
        return true
    end

    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Highlighter role released
    if role == TOOL_HIGHLIGHTER then
        logger.dbg("Pencil: highlighter input release detected:", key_str)
        return self:onStylusButtonRelease()
    end
    return false
end

function Pencil:afterHistoryChange()
    self.store:rebuildPageIndex()
    -- Group rebuild and save are slow; run them once the pen rests.
    self.groups_stale = true
    self:scheduleDeferredWork()
    self:repaintReader()
end

function Pencil:undoLastStroke()
    if self.store:undo(self.stroke_translate) then
        self:afterHistoryChange()
    end
end

function Pencil:redoLastStroke()
    if self.store:redo(self.stroke_translate) then
        self:afterHistoryChange()
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
    if not self:isEnabled() or self:isOverlayActive() then return false end

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
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Annotation/badge interception has priority over ReaderHighlight.
    if ges and ges.pos then
        local group = self:findGroupBadgeAtPoint(ges.pos.x, ges.pos.y)
            or self:findAnnotationGroupAtPoint(ges.pos.x, ges.pos.y)
        if group then
            self:showAnnotationHoldMenu(group)
            return true
        end
    end

    if self.pen_down then return true end
    local is_pen = select(1, self:isPenInput(ges))
    if not is_pen then return false end
    return true
end

-- Union a finished stroke's (screen-space) bounding box into the pending
-- post-lift refresh region, expanded by the stroke's own half-width plus a
-- small antialiasing pad. The delayed refresh then only updates this region.
function Pencil:accumulateRefreshBbox(stroke)
    if not stroke then return end
    local source_bbox = stroke.bbox or PencilGeometry.computeStrokeBbox(stroke)
    if not source_bbox then return end
    local margin = math.floor((stroke.width or 0) / 2) + 4
    local bbox = PencilGeometry.bboxExpand(source_bbox, margin)
    if self.pending_refresh_bbox then
        self.pending_refresh_bbox = PencilGeometry.bboxUnion(self.pending_refresh_bbox, bbox)
    else
        self.pending_refresh_bbox = bbox
    end
end

-- Schedule a delayed refresh after writing stops.
-- Colored strokes are first displayed in black for low latency, then
-- redrawn directly into Screen.bb with their saved color. Only the
-- accumulated stroke bbox is sent through the color refresh waveform.
function Pencil:scheduleDelayedRefresh()
    self:cancelPendingRefresh()

    local action
    action = function()
        if self.pending_refresh == action then
            self.pending_refresh = nil
        end

        local bbox = self.pending_refresh_bbox
        local color_strokes = self.pending_color_strokes

        self.pending_refresh_bbox = nil
        self.pending_color_strokes = {}

        if not bbox then
            logger.dbg("Pencil: delayed color refresh skipped: no bbox")
            return
        end

        bbox = PencilGeometry.bboxClampToScreen(
            bbox,
            Screen:getWidth(),
            Screen:getHeight()
        )

        local rx = math.floor(bbox.x0)
        local ry = math.floor(bbox.y0)
        local rw = math.ceil(bbox.x1 - bbox.x0)
        local rh = math.ceil(bbox.y1 - bbox.y0)

        if rw <= 0 or rh <= 0 then
            logger.dbg("Pencil: delayed color refresh skipped: empty bbox")
            return
        end

        -- Replace the temporary black pixels directly with the definitive
        -- colored strokes. This avoids depending on setDirty/paintTo to
        -- reconstruct pixels previously written directly into Screen.bb.
        if color_strokes then
            for _, stroke in ipairs(color_strokes) do
                if stroke
                        and stroke.page == self:getCurrentPage()
                        and not stroke.embedded then
                    self:renderStroke(Screen.bb, stroke)
                end
            end
        end

        -- Update only the area occupied by the recently finished strokes.
        Screen:refreshUI(rx, ry, rw, rh)

        logger.dbg(
            "Pencil: delayed color refresh triggered for bbox",
            rx, ry, rw, rh
        )
    end

    self.pending_refresh = action
    UIManager:scheduleIn(self.refresh_delay_ms / 1000, action)
end

-- Cancel pending refresh (called when new stroke starts)
function Pencil:cancelPendingRefresh()
    if self.pending_refresh then
        UIManager:unschedule(self.pending_refresh)
        self.pending_refresh = nil
    end
end

-- Process strokes whose annotation grouping was intentionally kept out of PEN UP.
function Pencil:flushPendingGroups()
    local pending = self.pending_group_strokes
    if not pending or #pending == 0 then return end
    self.pending_group_strokes = {}
    for _, stroke_idx in ipairs(pending) do
        if self.store.strokes[stroke_idx] then
            self:assignStrokeToGroup(stroke_idx)
        end
    end
end

-- Schedule a debounced save + bookmark flush after writing pauses.
-- NOTE: UIManager:scheduleIn() returns nil, and UIManager:unschedule() matches
-- by the action function reference. So we must store the closure itself in
-- pending_save (not scheduleIn's return value) or cancelPendingSave can never
-- cancel it — which previously caused one full save to fire per stroke.
function Pencil:scheduleDeferredWork()
    self:cancelPendingSave()
    local action
    action = function()
        if self.pending_save == action then self.pending_save = nil end
        if self.pen_down then
            self:scheduleDeferredWork()
            return
        end
        self:flushPendingGroups()
        self:rebuildStaleGroups()
        self:flushDirtyGroups()
        self:saveStrokes()
    end
    self.pending_save = action
    UIManager:scheduleIn(self.save_delay_ms / 1000, action)
end

function Pencil:cancelPendingSave()
    if self.pending_save then
        UIManager:unschedule(self.pending_save)
        self.pending_save = nil
    end
end

-- Rebuild annotation groups if a cheap in-place update (erase, undo/redo,
-- lasso) left them stale. Rebuilding re-creates every group bookmark in the
-- book, so it's batched here instead of run per action.
function Pencil:rebuildStaleGroups()
    if self.groups_stale then
        self.groups_stale = false
        self:rebuildAnnotationGroups()
    end
end

-- Repaint the page with our strokes. ReaderView is not a window, so marking
-- it dirty only refreshes the old pixels; ReaderUI (its dialog) is.
function Pencil:repaintReader()
    UIManager:setDirty(self.ui and (self.ui.dialog or self.ui) or self.view, "ui")
end

-- Run any pending deferred work immediately. Called before close, page change,
-- or any path that must persist state synchronously.
function Pencil:flushDeferredWork()
    if not self.pending_save and not self.groups_stale
            and not (self.pending_group_strokes and #self.pending_group_strokes > 0)
            and not (self.dirty_groups and next(self.dirty_groups)) then
        return
    end
    self:cancelPendingSave()
    self:flushPendingGroups()
    self:rebuildStaleGroups()
    self:flushDirtyGroups()
    self:saveStrokes()
end

-- Sync bookmarks for any groups marked dirty since the last flush. No-op when
-- the experimental bookmark sync feature is off or nothing is pending.
function Pencil:flushDirtyGroups()
    if not self.dirty_groups then return end
    if not self.experimental_bookmark_sync then
        self.dirty_groups = nil
        return
    end
    for _, group in pairs(self.dirty_groups) do
        self:syncGroupBookmark(group)
    end
    self.dirty_groups = nil
end

-- Reset color picker tracking (called when pen moves too far)
function Pencil:resetColorPickerTracking()
    self.color_picker_start_x = nil
    self.color_picker_start_y = nil
    self.color_picker_start_time = nil
end

-- Whether holding the given tool (pen or highlighter) still opens a picker.
-- The pen has two experimental pickers (color, width); the highlighter's
-- picker (color and opacity) follows the color picker option.
function Pencil:isPickerEnabledFor(tool)
    if tool == TOOL_HIGHLIGHTER then
        return self.experimental_color_picker or self.hold_menu
    end
    return self.hold_menu or self.experimental_color_picker or self.experimental_pen_width
end

-- Start timing a hold-still at (x, y) with `tool`. Does nothing (and so costs
-- nothing) when that tool has no picker to show: skipping the 10Hz poll avoids
-- an UIManager:scheduleIn closure allocation on every pen-down, real GC
-- pressure on the A53 during multi-second strokes.
function Pencil:beginPickerTracking(x, y, tool)
    if not self:isPickerEnabledFor(tool) then return end
    self.color_picker_tool = tool
    self.color_picker_start_x = x
    self.color_picker_start_y = y
    self.color_picker_start_time = time.now()
    self:scheduleColorPickerCheck()
end

-- The pen moved: if it left the hold-still tolerance, forget the hold.
function Pencil:movePickerTracking(x, y)
    if self.color_picker_start_x and self.color_picker_start_y then
        local dx = math.abs(x - self.color_picker_start_x)
        local dy = math.abs(y - self.color_picker_start_y)
        if dx > COLOR_PICKER_TOLERANCE_PIXELS or dy > COLOR_PICKER_TOLERANCE_PIXELS then
            self:resetColorPickerTracking()
        end
    end
end

-- Check if color picker should be shown (called periodically while pen is down)
function Pencil:checkColorPickerTrigger()
    local tool = self.color_picker_tool or TOOL_PEN
    if not self:isPickerEnabledFor(tool) then return end
    if not self.color_picker_start_time then return end
    if self.color_picker_showing then return end

    local elapsed_ms = time.to_ms(time.now() - self.color_picker_start_time)
    if elapsed_ms >= COLOR_PICKER_DELAY_MS then
        self:showColorPicker(self.pen_x, self.pen_y, tool)
        self:resetColorPickerTracking()
    end
end

-- Schedule periodic check for color picker trigger
function Pencil:scheduleColorPickerCheck()
    if self.color_picker_check_pending then
        UIManager:unschedule(self.color_picker_check_pending)
    end

    local plugin = self
    local action
    -- UIManager:scheduleIn() returns nil; unschedule() needs the callback.
    action = function()
        if plugin.color_picker_check_pending == action then
            plugin.color_picker_check_pending = nil
        end
        if plugin.pen_down and plugin.color_picker_start_time and not plugin.color_picker_showing then
            plugin:checkColorPickerTrigger()
            if plugin.color_picker_start_time then
                plugin:scheduleColorPickerCheck()
            end
        end
    end
    self.color_picker_check_pending = action
    UIManager:scheduleIn(0.1, action)
end

-- Cancel color picker check
function Pencil:cancelColorPickerTimer()
    if self.color_picker_check_pending then
        UIManager:unschedule(self.color_picker_check_pending)
        self.color_picker_check_pending = nil
    end
    self:resetColorPickerTracking()
end

-- Color picker widget for selecting pen color (and optionally pen width).
-- When `widths` is provided, the widget shows two rows: colors on top,
-- widths below. The width row contains black bars whose vertical thickness
-- matches the actual stroke thickness in device pixels (what-you-see is
-- what-you-draw).
local ColorPickerWidget = InputContainer:extend {
    width = nil,
    height = nil,
    actions = nil, -- Optional array of {action, label} objects (hold-pen tool menu)
    colors = nil, -- Array of {color, name} objects
    widths = nil, -- Optional array of {name, width} objects (experimental width picker)
    -- Highlighter picker: opacity percentages shown in the second row (instead
    -- of widths), each previewed as `opacity_color` over white paper
    opacities = nil,
    opacity_color = nil,
    opacity_color_name = nil,
    current_opacity = nil,
    current_color_name = nil, -- Currently selected color name (for comparison)
    current_width = nil, -- Currently selected pen width (for width selection indicator)
    callback = nil, -- callback(color_value, color_name, width_value, opacity_value, action)
    close_callback = nil,
    -- Layout constants cached after init so handlePenTap / paintTo don't
    -- recompute them. Kept on self so tests can read them too.
    _button_size = nil,
    _spacing = nil,
    _row_gap = nil,
    _padding = nil,
}

-- Build one button (action, color or width). Returns the InputContainer
-- button, which also stores its own metadata so the callback can route
-- without string-matching on name.
function ColorPickerWidget:_makeButton(item, button_size, selection_border, button_w)
    button_w = button_w or button_size
    -- Selection: colors compare by name, widths compare by width value
    local is_selected
    if item.kind == "width" then
        is_selected = (item.width_value == self.current_width)
    elseif item.kind == "opacity" then
        is_selected = (item.opacity_value == self.current_opacity)
    elseif item.kind == "color" then
        is_selected = (item.name == self.current_color_name)
    end
    local border_size = is_selected and selection_border or Size.border.thick

    local swatch
    if item.kind == "action" then
        local inner_w, inner_h = button_w - border_size * 2, button_size - border_size * 2
        swatch = FrameContainer:new{
            width = button_w,
            height = button_size,
            padding = 0,
            margin = 0,
            bordersize = border_size,
            color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = inner_h },
                TextWidget:new{
                    text = item.label,
                    face = Font:getFace("cfont", 16),
                    max_width = inner_w,
                },
            },
        }
    elseif item.kind == "width" then
        -- Truthful preview: a horizontal black bar whose height equals the
        -- stroke's actual device-pixel thickness. We deliberately do NOT
        -- scale by Screen:scaleBySize — the stroke itself is drawn in raw
        -- pixels (see paintRectRGB32 in PencilStrokes.drawThickLine), so scaling here
        -- would lie about the line weight.
        local inner = button_size - border_size * 2
        local bar_h = item.width_value
        local bar_w = math.floor(inner * 0.7)
        local bar = FrameContainer:new{
            width = bar_w,
            height = bar_h,
            padding = 0,
            margin = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_BLACK,
            WidgetContainer:new{
                dimen = Geom:new{ w = bar_w, h = bar_h },
            },
        }
        swatch = FrameContainer:new{
            width = button_size,
            height = button_size,
            padding = 0,
            margin = 0,
            bordersize = border_size,
            color = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = inner, h = inner },
                bar,
            },
        }
    elseif item.kind == "opacity" then
        -- The highlighter color at this opacity, as it looks on white paper
        swatch = FrameContainer:new{
            width = button_size,
            height = button_size,
            padding = 0,
            margin = 0,
            bordersize = border_size,
            color = Blitbuffer.COLOR_BLACK,
            background = item.preview,
            WidgetContainer:new{
                dimen = Geom:new{ w = button_size - border_size * 2, h = button_size - border_size * 2 },
            },
        }
        if Screen.night_mode and self.opacity_color_name ~= "Black" and self.opacity_color_name ~= "Gray" then
            swatch.background = swatch.background:invert()
        end
    else
        -- Regular color swatch
        local border_color = Blitbuffer.COLOR_BLACK
        if item.name == "Black" then
            border_color = Blitbuffer.Color8(0x44)
        end
        swatch = FrameContainer:new{
            width = button_size,
            height = button_size,
            padding = 0,
            margin = 0,
            bordersize = border_size,
            color = border_color,
            background = item.color_value,
            WidgetContainer:new{
                dimen = Geom:new{ w = button_size - border_size * 2, h = button_size - border_size * 2 },
            },
        }
        if Screen.night_mode and item.name ~= "Black" and item.name ~= "Gray" then
            swatch.background = swatch.background:invert()
        end
    end

    local button = InputContainer:new{
        dimen = Geom:new{ w = button_w, h = button_size },
        swatch,
        kind = item.kind,
        action = item.action,            -- nil unless an action button
        color_value = item.color_value,  -- nil for width/action items
        color_name = item.name,
        width_value = item.width_value,  -- nil for color/action items
        opacity_value = item.opacity_value, -- nil unless an opacity item
    }

    button.ges_events = {
        TapSelectColor = {
            GestureRange:new{
                ges = "tap",
                range = function() return button.dimen end,
            },
        },
    }

    local widget = self
    button.onTapSelectColor = function(btn)
        widget:_activate(btn)
        return true
    end

    return button
end

-- Run the callback for a tapped button, then close the picker.
function ColorPickerWidget:_activate(btn)
    -- Close first so an action (e.g. opening the note canvas) isn't drawn under it.
    if self.close_callback then
        self.close_callback()
    end
    if self.callback then
        self.callback(btn.color_value, btn.color_name, btn.width_value, btn.opacity_value, btn.action)
    end
end

-- Build a HorizontalGroup row of buttons from an item list. Populates the
-- supplied `info_list` in-tap-index order.
function ColorPickerWidget:_buildRow(items, button_size, spacing, selection_border, info_list, button_w)
    local group = HorizontalGroup:new{ align = "center" }
    for i, item in ipairs(items) do
        if i > 1 then
            table.insert(group, HorizontalSpan:new{ width = spacing })
        end
        local button = self:_makeButton(item, button_size, selection_border, button_w)
        table.insert(group, button)
        table.insert(info_list, button)
    end
    return group
end

function ColorPickerWidget:init()
    local button_size = Screen:scaleBySize(36)
    local spacing = Screen:scaleBySize(8)
    local row_gap = Screen:scaleBySize(8)  -- vertical gap between rows
    local padding = Screen:scaleBySize(10)
    local selection_border = Size.border.thick * 3

    self._button_size = button_size
    self._spacing = spacing
    self._row_gap = row_gap
    self._padding = padding

    -- Rows, top to bottom: actions, colors, widths. Each is optional.
    self.rows = {}
    self.action_buttons_info = {}
    self.color_buttons_info = {}
    self.width_buttons_info = {}

    local function add_row(items, info_list, button_w)
        if not items or #items == 0 then return end
        local group = self:_buildRow(items, button_size, spacing, selection_border, info_list, button_w)
        table.insert(self.rows, {
            info = info_list,
            button_w = button_w,
            width = #items * button_w + (#items - 1) * spacing,
            group = group,
        })
    end

    if self.actions then
        local items = {}
        for _, a in ipairs(self.actions) do
            table.insert(items, { kind = "action", action = a.action, label = a.label })
        end
        add_row(items, self.action_buttons_info, button_size * 2)
    end
    if self.colors then
        local items = {}
        for _, color_info in ipairs(self.colors) do
            table.insert(items, { kind = "color", name = color_info.name, color_value = color_info.color })
        end
        add_row(items, self.color_buttons_info, button_size)
    end
    if self.widths then
        local items = {}
        for _, width_info in ipairs(self.widths) do
            table.insert(items, { kind = "width", name = width_info.name, width_value = width_info.width })
        end
        add_row(items, self.width_buttons_info, button_size)
    end
    if self.opacities then
        local items = {}
        local base = (self.opacity_color or Blitbuffer.Color8(0xCC)):getColorRGB32()
        for _, percent in ipairs(self.opacities) do
            local k = percent / 100
            table.insert(items, {
                kind = "opacity", name = string.format("%d%%", percent),
                opacity_value = percent,
                preview = Blitbuffer.ColorRGB32(
                    math.floor(255 - (255 - base.r) * k + 0.5),
                    math.floor(255 - (255 - base.g) * k + 0.5),
                    math.floor(255 - (255 - base.b) * k + 0.5), 0xFF),
            })
        end
        add_row(items, self.width_buttons_info, button_size)
    end

    local inner_w = 0
    for _, row in ipairs(self.rows) do inner_w = math.max(inner_w, row.width) end
    self.width = inner_w
    self.height = #self.rows * button_size + math.max(0, #self.rows - 1) * row_gap

    local content = VerticalGroup:new{ align = "center" }
    for i, row in ipairs(self.rows) do
        if i > 1 then
            table.insert(content, VerticalSpan:new{ width = row_gap })
        end
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = button_size },
            row.group,
        })
    end

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

-- Top y (absolute) of row `i`, given the widget's top y.
function ColorPickerWidget:_rowY(top_y, i)
    return top_y + Size.border.window + self._padding + (i - 1) * (self._button_size + self._row_gap)
end

-- Hit-test one row of buttons. `row_y` is the top y of the row in absolute
-- coordinates. Returns the matching button info or nil.
function ColorPickerWidget:_hitRow(x, y, row_y, row)
    local info_list = row.info
    local button_w = row.button_w
    local spacing = self._spacing
    if #info_list == 0 then return nil end
    if y < row_y or y >= row_y + self._button_size then return nil end

    local row_start_x = self.dimen.x + (self.dimen.w - row.width) / 2
    local relative_x = x - row_start_x
    if relative_x < 0 or relative_x >= row.width then return nil end

    local stride = button_w + spacing
    local idx = math.floor(relative_x / stride) + 1
    local pos_in_slot = relative_x - (idx - 1) * stride
    if pos_in_slot >= button_w then return nil end
    if idx < 1 or idx > #info_list then return nil end
    return info_list[idx]
end

-- Handle pen/stylus tap on color picker
-- Returns true if the tap was handled (hit a button or was inside picker)
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

    for i, row in ipairs(self.rows) do
        local btn = self:_hitRow(x, y, self:_rowY(self.dimen.y, i), row)
        if btn then
            self:_activate(btn)
            return true
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
            -- Tap is inside, let the buttons handle it
            return false
        end
    end
    -- Tap is outside, close the widget without changing anything
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

    -- Update button dimens so their TapSelectColor ranges match what's
    -- painted. Mirrors the centered layout built in init().
    for i, row in ipairs(self.rows or {}) do
        local row_y = self:_rowY(paint_y, i)
        local row_start_x = paint_x + (self.dimen.w - row.width) / 2
        for j, btn in ipairs(row.info) do
            btn.dimen.x = row_start_x + (j - 1) * (row.button_w + self._spacing)
            btn.dimen.y = row_y
        end
    end
end

function ColorPickerWidget:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.dimen)
end

-- Show the hold-pen menu near the pen position: tool actions (undo, redo,
-- lasso, note) and, when their experimental options are on, colors and
-- pen widths.
function Pencil:showColorPicker(x, y, tool)
    if self.color_picker_showing then return end
    tool = tool or self.color_picker_tool or TOOL_PEN
    local is_highlighter = tool == TOOL_HIGHLIGHTER
    if is_highlighter and self.tool.highlighting then self:cancelTextHighlight() end
    self.color_picker_contact_active = true
    self.tool.highlighting = false
    self.tool.highlight_freehand = false
    if self.current_stroke then
        self.current_stroke = nil
        self.live_highlighter = nil
        self.dirty_region = nil
        self.view:paintTo(Screen.bb, 0, 0)
        self:paintTo(Screen.bb, 0, 0)
        Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
    end
    self.color_picker_showing = true
    local plugin = self
    local actions = self.hold_menu and {
        { action = "undo", label = _("Undo") }, { action = "redo", label = _("Redo") },
        { action = "lasso", label = _("Lasso") }, { action = "note", label = _("Note") },
    } or nil
    local hl = self.tool:getToolSettings(TOOL_HIGHLIGHTER)
    local colors = is_highlighter
        and (self.experimental_color_picker and self:getHighlighterColors() or nil)
        or (self.experimental_color_picker and self.available_colors or nil)
    local widths = not is_highlighter and self.experimental_pen_width and self.available_widths or nil
    local opacities = is_highlighter and self.experimental_color_picker
        and PencilTool.HIGHLIGHTER_OPACITIES or nil
    local picker = ColorPickerWidget:new{
        actions = actions, colors = colors, widths = widths, opacities = opacities,
        opacity_color = hl.color, opacity_color_name = hl.color_name,
        current_opacity = self.tool:getHighlighterOpacity(),
        current_color_name = is_highlighter and hl.color_name or self.tool:getSettings().color_name,
        current_width = self.tool:getSettings().width,
        callback = function(color, name, width, opacity, action)
            if action then plugin:runHoldMenuAction(action, x, y); return end
            if opacity then
                plugin:setHighlighterOpacity(opacity)
                UIManager:show(InfoMessage:new{ text = T(_("Highlighter opacity: %1"), string.format("%d%%", opacity)), timeout = 1 })
            elseif is_highlighter then
                plugin:setHighlighterColor(color, name)
                UIManager:show(InfoMessage:new{ text = T(_("Highlighter color: %1"), name), timeout = 1 })
            elseif width then
                plugin:setPenWidth(width)
                UIManager:show(InfoMessage:new{ text = T(_("Pen width: %1"), width), timeout = 1 })
            else
                plugin:setPenColor(color, name)
                if Screen.night_mode and name == "Black" then name = "White" end
                UIManager:show(InfoMessage:new{ text = T(_("Pen color: %1"), name), timeout = 1 })
            end
        end,
        close_callback = function()
            if not plugin.color_picker_showing then return end
            plugin.color_picker_showing = false
            UIManager:close(plugin.color_picker_widget)
            plugin.color_picker_widget = nil
            plugin.tool:resetHighlighterState()
            plugin.side_button_down = false
            plugin.live_highlighter = nil
            UIManager:setDirty(plugin.view, "ui")
        end,
    }
    local pw, ph = picker.dimen.w, picker.dimen.h
    local gap, margin = Screen:scaleBySize(30), 10
    local px = math.max(margin, math.min(x - pw / 2, Screen:getWidth() - pw - margin))
    local py = y - ph - gap
    if py < margin then py = y + gap end
    if py + ph > Screen:getHeight() - margin then py = Screen:getHeight() - ph - margin end
    picker.dimen.x, picker.dimen.y = px, py
    self.color_picker_widget = picker
    UIManager:show(picker)
    UIManager:setDirty(picker, "ui")
    logger.dbg("Pencil: hold picker shown at", px, py, "tool", tool)
end

-- Run a hold-menu action at the pen position (x, y).
function Pencil:runHoldMenuAction(action, x, y)
    if action == "undo" then
        self:undoLastStroke()
    elseif action == "redo" then
        self:redoLastStroke()
    elseif action == "lasso" then
        self:startLasso()
    elseif action == "note" then
        self:openNoteAt(x, y)
    end
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

function Pencil:startLasso()
    self.lasso = { phase = "armed" }
end

-- Drop lasso state (and the drag snapshot) without repainting.
function Pencil:clearLasso()
    local lasso = self.lasso
    if not lasso then return end
    if lasso.snapshot then
        lasso.snapshot:free()
        lasso.snapshot = nil
    end
    self.lasso = nil
end

function Pencil:cancelLasso()
    if not self.lasso then return end
    self:clearLasso()
    self:repaintReader()
end

-- Returns true while the lasso owns pen input.
function Pencil:isLassoActive()
    return self.lasso ~= nil
end

function Pencil:handleLassoSlot(slot)
    local lasso = self.lasso
    local raw_x = slot.x or self.pen_x or 0
    local raw_y = slot.y or self.pen_y or 0
    local x, y = self:transformCoordinates(raw_x, raw_y)
    local down = slot.id ~= nil and slot.id >= 0

    if lasso.phase == "armed" then
        if down then
            lasso.phase = "drawing"
            lasso.path = { { x = x, y = y } }
            self.pen_down = true
            self.dirty_region = nil
            self.stroke_fast_refresh = true
            self.last_refresh_time = time.now()
        end
    elseif lasso.phase == "drawing" then
        if down then
            local last = lasso.path[#lasso.path]
            if math.abs(x - last.x) + math.abs(y - last.y) >= 3 then
                table.insert(lasso.path, { x = x, y = y })
                self:drawLassoSegment(last.x, last.y, x, y)
            end
        else
            self.pen_down = false
            self:finishLassoPath()
        end
    elseif lasso.phase == "selected" then
        if down and not self.pen_down then
            self.pen_down = true
            local hit = self:lassoHitTest(x, y)
            if hit == "delete" then
                self:deleteLassoSelection()
            elseif hit == "done" then
                self:cancelLasso()
            elseif hit == "inside" then
                lasso.phase = "moving"
                lasso.from = { x = x, y = y }
                lasso.dx, lasso.dy = 0, 0
                lasso.preview_time = time.now()
                -- The page as shown now; the drag preview only moves an
                -- outline over it, restoring pixels from this copy.
                lasso.snapshot = Screen.bb:copy()
            else
                self:cancelLasso()
            end
        elseif not down then
            self.pen_down = false
        end
    elseif lasso.phase == "moving" then
        if down then
            lasso.dx, lasso.dy = x - lasso.from.x, y - lasso.from.y
            local now = time.now()
            if time.to_ms(now - lasso.preview_time) >= LASSO_PREVIEW_MS then
                lasso.preview_time = now
                self:previewLassoDrag()
            end
        else
            self.pen_down = false
            self:applyLassoMove()
        end
    end
    return true
end

-- Draw a piece of the lasso path as a thin gray line, refreshed in batches.
function Pencil:drawLassoSegment(x1, y1, x2, y2)
    PencilStrokes.drawThickLine(Screen.bb, x1, y1, x2, y2, 2, Blitbuffer.COLOR_DARK_GRAY)
    local x0, y0 = math.min(x1, x2) - 3, math.min(y1, y2) - 3
    local w, h = math.abs(x2 - x1) + 6, math.abs(y2 - y1) + 6
    local r = self.dirty_region
    if r then
        local rx2, ry2 = math.max(r.x + r.w, x0 + w), math.max(r.y + r.h, y0 + h)
        r.x, r.y = math.min(r.x, x0), math.min(r.y, y0)
        r.w, r.h = rx2 - r.x, ry2 - r.y
    else
        self.dirty_region = { x = x0, y = y0, w = w, h = h }
    end
    local now = time.now()
    if time.to_ms(now - self.last_refresh_time) >= self.refresh_interval_ms then
        self.last_refresh_time = now
        self:refreshDirtyRegion()
    end
end

-- Strokes that can be selected: the ones drawn on screen right now.
function Pencil:visibleStrokes()
    local out = {}
    local pages, page = self:getVisiblePages()
    for _, p in ipairs(pages) do
        for _, idx in ipairs(self.store.page_strokes[p] or {}) do
            local stroke = self.store.strokes[idx]
            if stroke then
                if stroke.page_points then
                    if self:syncStrokeToView(stroke) then table.insert(out, stroke) end
                elseif p == page then
                    table.insert(out, stroke)
                end
            end
        end
    end
    return out
end

function Pencil:finishLassoPath()
    local lasso = self.lasso
    self.dirty_region = nil
    local path = lasso.path
    if not path or #path < 3 then
        self:cancelLasso()
        return
    end
    local selected, bbox = {}, nil
    for _, stroke in ipairs(self:visibleStrokes()) do
        if PencilGeometry.strokeInPolygon(stroke, path, LASSO_MIN_RATIO) then
            table.insert(selected, stroke)
            local b = PencilGeometry.computeStrokeBbox(stroke)
            bbox = bbox and PencilGeometry.bboxUnion(bbox, b) or b
        end
    end
    lasso.path = nil
    if #selected == 0 then
        self:cancelLasso()
        return
    end
    lasso.strokes = selected
    lasso.bbox = PencilGeometry.bboxExpand(bbox, LASSO_BOX_MARGIN)
    lasso.phase = "selected"
    self:repaintLasso(false)
end

-- Selection box (offset by the current drag) and button rects.
function Pencil:lassoLayout()
    local lasso = self.lasso
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

function Pencil:lassoHitTest(x, y)
    local box, buttons = self:lassoLayout()
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
function Pencil:drawLassoOverlay(bb)
    local box, buttons = self:lassoLayout()
    bb:paintBorder(box.x, box.y, box.w, box.h, 2, Blitbuffer.COLOR_DARK_GRAY)
    if self.lasso.phase == "moving" then return end
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

function Pencil:repaintLasso(fast)
    self.view:paintTo(Screen.bb, 0, 0)
    self:paintTo(Screen.bb, 0, 0)
    if fast then
        Screen:refreshFast(0, 0, Screen:getWidth(), Screen:getHeight())
    else
        Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
    end
end

-- Move the selection outline to the current drag offset: restore the old
-- outline's pixels from the snapshot, draw the new one, refresh just that.
function Pencil:previewLassoDrag()
    local lasso = self.lasso
    local snap = lasso.snapshot
    if not snap then return end
    local box = self:lassoLayout()
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

function Pencil:deleteLassoSelection()
    local selected = self.lasso.strokes
    self:clearLasso()
    if self.store:removeStrokes(selected) then
        self.store:pushUndo({ type = "delete", strokes = selected })
    end
    self:afterHistoryChange()
end

function Pencil:applyLassoMove()
    local lasso = self.lasso
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
        self:repaintLasso(false)
        return
    end
    self:clearLasso()
    local pdeltas = self:translateStrokes(lasso.strokes, dx, dy)
    self.store:pushUndo({ type = "move", strokes = lasso.strokes, dx = dx, dy = dy, pdeltas = pdeltas })
    self:afterHistoryChange()
end

-- Shift strokes by (dx, dy) screen pixels; sign = -1 reverses a move.
-- Page-anchored strokes move in page space by pdeltas[i] (computed from the
-- view zoom on the first move and reused for undo/redo). Returns pdeltas.
function Pencil:translateStrokes(strokes, dx, dy, pdeltas, sign)
    return PencilStrokes.translate(strokes, dx, dy, pdeltas, sign, self.stroke_view)
end

-- Notes: a full-screen canvas for longer handwriting, anchored to a spot in
-- the book and shown there as a small marker. Created from the hold-pen
-- menu; reopened by tapping the marker with the pen.
--
-- note = {
--     id, datetime, page, x, y,       -- anchor; x/y are screen coords at creation
--     xpointer,                        -- EPUB: follows reflow
--     page_x, page_y,                  -- PDF: page coordinates
--     pages = { { strokes = { { points, width, color_name } } } },
-- }

local NOTE_MARKER_SIZE = 28
local NOTE_MARKER_HIT_PAD = 12

-- Screen position of a note's marker on the current view, or nil when the
-- note isn't on a visible page.
function Pencil:getNoteMarkerPos(note)
    if self.ui.paging then
        local zoom, ox, oy = self:pageAffine(note.page)
        if not zoom or not note.page_x then return nil end
        return note.page_x * zoom + ox, note.page_y * zoom + oy
    end
    if self:getGroupCurrentPage(note) ~= self:getCurrentPage() then return nil end
    local y = note.y
    if note.xpointer and self.ui.document and self.ui.document.getScreenPositionFromXPointer then
        local ok, sy = pcall(self.ui.document.getScreenPositionFromXPointer, self.ui.document, note.xpointer)
        if ok and sy then y = sy end
    end
    return note.x, y
end

function Pencil:getNoteMarkerRect(note)
    local x, y = self:getNoteMarkerPos(note)
    if not x then return nil end
    local size = NOTE_MARKER_SIZE
    local rx = math.max(0, math.min(math.floor(x - size / 2), Screen:getWidth() - size))
    local ry = math.max(0, math.min(math.floor(y - size / 2), Screen:getHeight() - size))
    return { x = rx, y = ry, w = size, h = size }
end

function Pencil:findNoteMarkerAt(x, y)
    for _, note in ipairs(self.notes or {}) do
        local r = self:getNoteMarkerRect(note)
        if r and x >= r.x - NOTE_MARKER_HIT_PAD and x <= r.x + r.w + NOTE_MARKER_HIT_PAD
                and y >= r.y - NOTE_MARKER_HIT_PAD and y <= r.y + r.h + NOTE_MARKER_HIT_PAD then
            return note
        end
    end
end

-- A small "page with lines" icon.
function Pencil:drawNoteMarkers(bb)
    for _, note in ipairs(self.notes or {}) do
        local r = self:getNoteMarkerRect(note)
        if r then
            bb:paintRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE)
            bb:paintBorder(r.x, r.y, r.w, r.h, 2, Blitbuffer.COLOR_BLACK)
            local inset = math.floor(r.w / 5)
            for i = 1, 3 do
                bb:paintRect(r.x + inset, r.y + i * math.floor(r.h / 4), r.w - 2 * inset, 2, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

-- Create a note anchored at screen position (x, y) and open it.
function Pencil:openNoteAt(x, y)
    local note = {
        id = "note_" .. os.date("%Y%m%d%H%M%S") .. "_" .. tostring(#(self.notes or {}) + 1),
        datetime = os.time(),
        page = self:getCurrentPage(),
        x = x,
        y = y,
        pages = { { strokes = {} } },
    }
    if self.ui.paging then
        local pos = self.view:screenToPageTransform({ x = x, y = y })
        if pos and pos.page then
            note.page = pos.page
            local zoom, ox, oy = self:pageAffine(pos.page)
            if zoom then
                note.page_x, note.page_y = (x - ox) / zoom, (y - oy) / zoom
            end
        end
    elseif self.ui.rolling then
        note.xpointer = self:getXPointerAtBboxCenter({ x0 = x, y0 = y, x1 = x, y1 = y })
    end
    self.notes = self.notes or {}
    table.insert(self.notes, note)
    self:openNote(note)
end

-- @param wait_lift ignore the pen contact that opened the note
function Pencil:openNote(note, wait_lift)
    if self.note_canvas then return end
    -- The canvas takes over pen input, including the rest of this contact.
    self.pen_down = false
    self.current_stroke = nil
    self.note_canvas = NoteCanvas:new{
        plugin = self,
        note = note,
        wait_lift = wait_lift,
    }
    UIManager:show(self.note_canvas)
    UIManager:setDirty(self.note_canvas, "ui")
end

local function noteHasInk(note)
    for _, page in ipairs(note.pages or {}) do
        if #page.strokes > 0 then return true end
    end
    return false
end

function Pencil:removeNote(note)
    for i, n in ipairs(self.notes or {}) do
        if n == note then
            table.remove(self.notes, i)
            return
        end
    end
end

-- Close the canvas; notes left empty are dropped.
function Pencil:closeNoteCanvas(delete)
    local canvas = self.note_canvas
    if not canvas then return end
    self.note_canvas = nil
    UIManager:close(canvas)
    if delete or not noteHasInk(canvas.note) then
        self:removeNote(canvas.note)
    end
    self:saveStrokes()
    self:repaintReader()
end

function Pencil:notesToSaveable()
    local out = {}
    for _, note in ipairs(self.notes or {}) do
        local pages = {}
        for i, page in ipairs(note.pages) do
            local strokes = {}
            for j, s in ipairs(page.strokes) do
                strokes[j] = { p = PencilGeometry.packPoints(s.points), width = s.width, color_name = s.color_name }
            end
            pages[i] = { strokes = strokes }
        end
        table.insert(out, {
            id = note.id, datetime = note.datetime, page = note.page,
            x = note.x, y = note.y, xpointer = note.xpointer,
            page_x = note.page_x, page_y = note.page_y,
            pages = pages,
        })
    end
    return out
end

function Pencil:notesFromSaved(saved)
    local notes = {}
    for _, n in ipairs(saved or {}) do
        local pages = {}
        for i, page in ipairs(n.pages or {}) do
            local strokes = {}
            for j, s in ipairs(page.strokes or {}) do
                strokes[j] = { points = PencilGeometry.unpackPoints(s.p), width = s.width, color_name = s.color_name }
            end
            pages[i] = { strokes = strokes }
        end
        if #pages == 0 then pages[1] = { strokes = {} } end
        table.insert(notes, {
            id = n.id, datetime = n.datetime, page = n.page,
            x = n.x, y = n.y, xpointer = n.xpointer,
            page_x = n.page_x, page_y = n.page_y,
            pages = pages,
        })
    end
    return notes
end

-- Full-screen writing canvas for one note. Pen input is routed here by
-- Pencil:handleStylusSlot while it's open; the top bar works with both pen
-- and finger.
NoteCanvas = InputContainer:extend{
    plugin = nil,
    note = nil,
    wait_lift = false,
    page_index = 1,
}

function NoteCanvas:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.bar_h = Screen:scaleBySize(48)
    self.page_index = 1
    self.ges_events = {
        TapBar = {
            GestureRange:new{
                ges = "tap",
                range = function() return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = self.bar_h } end,
            },
        },
    }
end

function NoteCanvas:currentPage()
    return self.note.pages[self.page_index]
end

function NoteCanvas:barButtons()
    local labels = {
        { name = "done", label = _("Done") },
        { name = "undo", label = _("Undo") },
        { name = "prev", label = _("Prev") },
        { name = "page", label = T("%1/%2", self.page_index, #self.note.pages) },
        { name = "next", label = _("Next") },
        { name = "add", label = _("+ Page") },
        { name = "delete", label = _("Delete") },
    }
    local w = math.floor(Screen:getWidth() / #labels)
    for i, b in ipairs(labels) do
        b.x, b.y, b.w, b.h = (i - 1) * w, 0, w, self.bar_h
    end
    return labels
end

function NoteCanvas:hitBar(x, y)
    if y < 0 or y >= self.bar_h then return nil end
    for _, b in ipairs(self:barButtons()) do
        if x >= b.x and x < b.x + b.w then return b.name end
    end
end

function NoteCanvas:runBarAction(name)
    local plugin = self.plugin
    if name == "done" then
        plugin:closeNoteCanvas(false)
        return
    elseif name == "delete" then
        plugin:closeNoteCanvas(true)
        return
    elseif name == "undo" then
        table.remove(self:currentPage().strokes)
    elseif name == "prev" then
        self.page_index = math.max(1, self.page_index - 1)
    elseif name == "next" then
        self.page_index = math.min(#self.note.pages, self.page_index + 1)
    elseif name == "add" then
        table.insert(self.note.pages, self.page_index + 1, { strokes = {} })
        self.page_index = self.page_index + 1
    else
        return
    end
    self:repaint()
end

function NoteCanvas:onTapBar(_, ges)
    local name = ges and ges.pos and self:hitBar(ges.pos.x, ges.pos.y)
    if name then self:runBarAction(name) end
    return true
end

function NoteCanvas:strokeColor(stroke)
    for _, c in ipairs(self.plugin.available_colors or {}) do
        if c.name == stroke.color_name then return c.color end
    end
    return Blitbuffer.COLOR_BLACK
end

function NoteCanvas:renderStroke(bb, stroke)
    local pts = stroke.points
    local color = self:strokeColor(stroke)
    if #pts == 1 then
        local half = math.floor(stroke.width / 2)
        bb:paintRectRGB32(pts[1].x - half, pts[1].y - half, stroke.width, stroke.width, color)
        return
    end
    for i = 2, #pts do
        PencilStrokes.drawThickLine(bb, pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y, stroke.width, color)
    end
end

function NoteCanvas:paintTo(bb, x, y)
    local w, h = Screen:getWidth(), Screen:getHeight()
    bb:paintRect(0, 0, w, h, Blitbuffer.COLOR_WHITE)
    local face = Font:getFace("cfont", 18)
    for _, b in ipairs(self:barButtons()) do
        bb:paintBorder(b.x, b.y, b.w, b.h, 1, Blitbuffer.COLOR_DARK_GRAY)
        local label = TextWidget:new{ text = b.label, face = face, max_width = b.w - 4 }
        local size = label:getSize()
        label:paintTo(bb, b.x + math.floor((b.w - size.w) / 2), b.y + math.floor((b.h - size.h) / 2))
        label:free()
    end
    bb:paintRect(0, self.bar_h, w, 2, Blitbuffer.COLOR_BLACK)
    for _, stroke in ipairs(self:currentPage().strokes) do
        self:renderStroke(bb, stroke)
    end
end

function NoteCanvas:repaint()
    self:paintTo(Screen.bb, 0, 0)
    Screen:refreshUI(0, 0, Screen:getWidth(), Screen:getHeight())
end

function NoteCanvas:isEraser(slot)
    local plugin = self.plugin
    return plugin.tool:getEffectiveToolForSlot(slot, plugin.side_button_down) == TOOL_ERASER
end

function NoteCanvas:eraseAt(x, y)
    local strokes = self:currentPage().strokes
    local settings = self.plugin.tool:getToolSettings(TOOL_ERASER)
    local radius = (settings and settings.width) or 20
    local erased = false
    for i = #strokes, 1, -1 do
        if PencilGeometry.isPointNearStroke(x, y, strokes[i], radius) then
            table.remove(strokes, i)
            erased = true
        end
    end
    if erased then self:repaint() end
end

-- Pen input while the canvas is open. Always consumes the event.
function NoteCanvas:handleStylus(slot)
    local plugin = self.plugin
    local down = slot.id ~= nil and slot.id >= 0
    if self.wait_lift then
        if not down then self.wait_lift = false end
        return true
    end
    local x, y = plugin:transformCoordinates(slot.x or self.last_x or 0, slot.y or self.last_y or 0)

    if not down then
        if self.stroke then
            -- Show what was drawn since the last batched refresh.
            plugin:refreshDirtyRegion()
            self.stroke = nil
        elseif self.contact and self.contact.bar then
            local name = self:hitBar(self.contact.x, self.contact.y)
            self.contact = nil
            if name then self:runBarAction(name) end
            return true
        end
        self.contact = nil
        return true
    end

    if self:isEraser(slot) then
        self.contact = self.contact or {}
        self:eraseAt(x, y)
        self.last_x, self.last_y = x, y
        return true
    end

    if not self.contact then
        -- New contact: the bar takes taps, the page takes ink.
        self.contact = { x = x, y = y, bar = y < self.bar_h }
        if self.contact.bar then return true end
        local settings = plugin.tool:getToolSettings(TOOL_PEN)
        self.stroke = { points = { { x = x, y = y } }, width = settings.width, color_name = settings.color_name }
        table.insert(self:currentPage().strokes, self.stroke)
        plugin.stroke_fast_refresh = true
        plugin.dirty_region = nil
        plugin.last_refresh_time = time.now()
        self:drawLive(x, y, x, y)
    elseif self.stroke and (x ~= self.last_x or y ~= self.last_y) then
        table.insert(self.stroke.points, { x = x, y = y })
        self:drawLive(self.last_x, self.last_y, x, y)
    end
    self.last_x, self.last_y = x, y
    return true
end

-- Draw a segment straight to the framebuffer and refresh in batches,
-- reusing the reader's low-latency path.
function NoteCanvas:drawLive(x1, y1, x2, y2)
    local plugin = self.plugin
    local width = self.stroke.width
    PencilStrokes.drawThickLine(Screen.bb, x1, y1, x2, y2, width, self:strokeColor(self.stroke))
    local pad = math.floor(width / 2) + 2
    local x0, y0 = math.min(x1, x2) - pad, math.min(y1, y2) - pad
    local w, h = math.abs(x2 - x1) + 2 * pad, math.abs(y2 - y1) + 2 * pad
    local r = plugin.dirty_region
    if r then
        local rx2, ry2 = math.max(r.x + r.w, x0 + w), math.max(r.y + r.h, y0 + h)
        r.x, r.y = math.min(r.x, x0), math.min(r.y, y0)
        r.w, r.h = rx2 - r.x, ry2 - r.y
    else
        plugin.dirty_region = { x = x0, y = y0, w = w, h = h }
    end
    local now = time.now()
    if time.to_ms(now - plugin.last_refresh_time) >= plugin.refresh_interval_ms then
        plugin.last_refresh_time = now
        plugin:refreshDirtyRegion()
    end
end

-- Highlighter colors offered to the user: all but Black, which would hide the text.
function Pencil:getHighlighterColors()
    local colors = {}
    for _, color_info in ipairs(self.available_colors) do
        if color_info.name ~= "Black" then
            table.insert(colors, color_info)
        end
    end
    return colors
end

function Pencil:setHighlighterColor(color, color_name)
    self.tool:setHighlighterColor(color_name, color)
    logger.info("Pencil: setHighlighterColor - color_name =", color_name)
    self:saveSettings()
end

function Pencil:setHighlighterOpacity(percent)
    if self.tool:setHighlighterOpacity(percent) then
        logger.info("Pencil: setHighlighterOpacity -", percent)
        self:saveSettings()
    end
end

-- Set pen color
function Pencil:setPenColor(color, color_name)
    self.tool:setColor(color_name, color)
    logger.info("Pencil: setPenColor - color_name =", color_name)
    self:saveSettings()
end

-- Set pen width. Only callable while experimental_pen_width is on
-- (the picker is the only UI path that invokes this).
function Pencil:setPenWidth(width)
    self.tool:setWidth(width)
    logger.info("Pencil: setPenWidth - width =", width)
    self:saveSettings()
end

-- Handle initial touch - fires IMMEDIATELY on first contact
-- This is critical for capturing the start of strokes without delay
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and is a backup if raw input not working
function Pencil:onDrawTouch(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Check if this is a finger touch (not pen) - let gesture system handle it
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
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

    -- Cancel any pending refresh - user is still writing
    self:cancelPendingRefresh()

    local effective_tool = self.tool:getEffectiveTool(is_eraser_end, is_highlighter, self.side_button_down)

    -- For eraser, we handle in pan (need movement to erase)
    if effective_tool == TOOL_ERASER then
        return true  -- Block but don't start stroke
    end

    -- Fallback: handle via gesture system if raw input not working
    local page = self:getCurrentPage()

    -- Start new stroke immediately with first point
    local tool_settings = self.tool:getToolSettings(effective_tool)
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

    if self.live_black_preview
        and effective_tool == TOOL_PEN
        and self.tool:getSettings().color_name ~= "Black" then
        color = Blitbuffer.COLOR_BLACK
    end
    if effective_tool == TOOL_HIGHLIGHTER then
        self.live_highlighter = PencilStrokes.drawLiveHighlighter(self.live_highlighter, Screen.bb, self.current_stroke, ges.pos.x, ges.pos.y, ges.pos.x, ges.pos.y)
    else
        local half_w = math.floor(width / 2)
        Screen.bb:paintRectRGB32(ges.pos.x - half_w, ges.pos.y - half_w, width, width, color)
    end

    return true
end

-- Check if this is a stylus/pen event (not finger)
-- Returns: is_pen (boolean), is_eraser_end (boolean), is_highlighter (boolean)
function Pencil:isPenInput(ges)
    if Device:isEmulator() then
        return true, false, false
    end

    local Input = Device.input
    if not Input or not Input.pen_slot then
        return false, false, false
    end

    local pen_slot_data = Input:getMtSlot(Input.pen_slot)
    if pen_slot_data and pen_slot_data.id and pen_slot_data.id ~= -1 then
        if pen_slot_data.tool == LINUX_TOOLTYPE.PEN then
            return true, false, false
        elseif pen_slot_data.tool == LINUX_TOOLTYPE.ERASER then
            return true, true, false
        elseif pen_slot_data.tool == LINUX_TOOLTYPE.HIGHLIGHTER then
            return true, false, true
        end
    end

    return false, false, false
end

-- Find the topmost visible pencil annotation group at a screen position.
-- Stale-rotation groups are excluded because their saved bbox is not valid in
-- the current layout; those remain accessible through their rotation badge.
function Pencil:findAnnotationGroupAtPoint(x, y)
    local page = self:getCurrentPage()
    local rotation = Screen:getRotationMode()
    local groups = self.annotation_groups or {}
    for i = #groups, 1, -1 do
        local group = groups[i]
        local bbox = group.bbox
        local same_rotation = group.image_rotation == nil
            or group.image_rotation == rotation
        if bbox and same_rotation and self:getGroupCurrentPage(group) == page
                and x >= bbox.x0 - ANNOTATION_HOLD_HIT_PAD
                and x <= bbox.x1 + ANNOTATION_HOLD_HIT_PAD
                and y >= bbox.y0 - ANNOTATION_HOLD_HIT_PAD
                and y <= bbox.y1 + ANNOTATION_HOLD_HIT_PAD then
            return group
        end
    end
    return nil
end

-- Show annotation actions after a priority long press.
function Pencil:showAnnotationHoldMenu(group)
    if not group then return end

    local dialog
    local text = trimString(group.transcription)
    local rows = {}

    if text ~= "" then
        rows[#rows + 1] = {{
            text = _("Show recognized text"),
            callback = function()
                UIManager:close(dialog)
                self:showRecognizedText(text, group)
            end,
        }}
        rows[#rows + 1] = {{
            text = _("Edit recognized text"),
            callback = function()
                UIManager:close(dialog)
                self:showAnnotationTextEditor(group)
            end,
        }}
        rows[#rows + 1] = {{
            text = _("Recognize again"),
            callback = function()
                UIManager:close(dialog)
                self:recognizeAnnotationGroup(group)
            end,
        }}
    else
        rows[#rows + 1] = {{
            text = _("Create text"),
            callback = function()
                UIManager:close(dialog)
                self:showAnnotationTextEditor(group)
            end,
        }}
        rows[#rows + 1] = {{
            text = _("Recognize this annotation"),
            callback = function()
                UIManager:close(dialog)
                self:recognizeAnnotationGroup(group)
            end,
        }}
    end

    if group.image_path then
        rows[#rows + 1] = {{
            text = _("Show saved image"),
            callback = function()
                UIManager:close(dialog)
                self:showGroupImagePreview(group)
            end,
        }}
    end

    rows[#rows + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    }}

    dialog = ButtonDialog:new{
        title = T(_("Pencil annotation - page %1"), self:getPageNumber(group.page)),
        buttons = rows,
    }
    UIManager:show(dialog)
end

-- Called on tap - create a dot or erase at point
function Pencil:onDrawTap(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- If raw input detected pen recently, block tap to prevent navigation
    -- Note: pen_down will be false by tap time, but we may have just drawn
    -- We should block taps if there's a current stroke or recent drawing
    if self.current_stroke then
        return true  -- Block tap while stroke in progress
    end

    -- Rotation badge hit-test: consume taps (pen or finger) over the camera
    -- badge of a stale-rotation annotation and open its saved image.
    if ges and ges.pos then
        local hit = self:findGroupBadgeAtPoint(ges.pos.x, ges.pos.y)
        if hit then
            logger.info("Pencil: badge tap hit group", hit.id,
                "at (", ges.pos.x, ",", ges.pos.y, ")")
            self:showGroupImagePreview(hit)
            return true
        end
    end

    -- Check if finger tap - let gesture system handle it
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local page = self:getCurrentPage()
    local effective_tool = self.tool:getEffectiveTool(is_eraser_end, is_highlighter, self.side_button_down)
    logger.dbg("Pencil: onDrawTap - effective_tool =", effective_tool)

    -- Log to debug file for analysis
    self:writeDebugLog(string.format("=== TAP at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.tool.eraser_tool_active), effective_tool))

    if effective_tool == TOOL_ERASER then
        -- Eraser: delete strokes near tap point
        logger.info("Pencil: eraser tap at", ges.pos.x, ges.pos.y, "page =", page)
        local erased = self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        if erased then
            logger.info("Pencil: erased", #erased, "strokes")
            self.store:pushUndo({ type = "delete", strokes = erased })
            self:saveStrokes()
            UIManager:setDirty(self.view, "ui")
        else
            logger.info("Pencil: eraser tap found no strokes to erase")
        end
        return true
    end

    -- Pen or Highlighter: create a dot
    local tool_settings = self.tool:getToolSettings(effective_tool)
    local stroke = PencilStrokes.newStroke(page, effective_tool, tool_settings,
        { { x = ges.pos.x, y = ges.pos.y } })

    self:anchorStrokeToPage(stroke)
    local stroke_idx = self.store:add(stroke)
    self:saveStrokes()

    -- Add to undo stack
    self.store:pushUndo({ type = "add", stroke_idx = stroke_idx })

    -- Draw directly to screen buffer
    self:renderStroke(Screen.bb, stroke)

    -- Direct framebuffer refresh for instant feedback
    local w = stroke.width
    Screen:refreshFast(ges.pos.x - w, ges.pos.y - w, w * 2, w * 2)

    return true
end

-- Called during pan - continues stroke started by onDrawTouch
-- NOTE: For pen/highlighter, raw input hook handles drawing directly for lowest latency
-- This handler blocks gestures and handles eraser mode
function Pencil:onDrawPan(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Check if raw input hook detected pen - if so, block gesture
    -- Raw input handles all drawing; this just needs to block swipe/pan gestures
    if self.pen_down then
        return true  -- Block pan gesture, raw input is drawing
    end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then return false end

    local page = self:getCurrentPage()
    local effective_tool = self.tool:getEffectiveTool(is_eraser_end, is_highlighter, self.side_button_down)

    -- Eraser mode: erase along path (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        if not self.eraser_deleted then
            self.eraser_deleted = {}
        end

        local deleted = self:eraseAtPoint(ges.pos.x, ges.pos.y, page)
        if deleted then
            for _, stroke in ipairs(deleted) do
                table.insert(self.eraser_deleted, stroke)
            end
            self.view:paintTo(Screen.bb, 0, 0)
            local rx, ry, rw, rh = self:erasedStrokesRefreshRect(deleted)
            if rx then
                Screen:refreshUI(rx, ry, rw, rh)
            else
                Screen:refreshUI()
            end
        end
        return true
    end

    -- Fallback: handle via gesture system if raw input not working
    local tool_settings = self.tool:getToolSettings(effective_tool)

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
            self.live_highlighter = PencilStrokes.drawLiveHighlighter(self.live_highlighter, Screen.bb, self.current_stroke, p1.x, p1.y, p2.x, p2.y)
        else
            PencilStrokes.drawThickLine(Screen.bb, p1.x, p1.y, p2.x, p2.y, width, color)
        end
    elseif n == 1 then
        local p = self.current_stroke.points[1]
        if effective_tool == TOOL_HIGHLIGHTER then
            self.live_highlighter = PencilStrokes.drawLiveHighlighter(self.live_highlighter, Screen.bb, self.current_stroke, p.x, p.y, p.x, p.y)
        else
            local half_w = math.floor(width / 2)
            Screen.bb:paintRectRGB32(p.x - half_w, p.y - half_w, width, width, color)
        end
    end

    return true
end

-- Called when pan ends - finalize stroke
-- NOTE: For pen/highlighter, raw input hook may have already finalized the stroke
function Pencil:onDrawPanRelease(ges)
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Let finger releases be handled by gesture system
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput(ges)
    if not is_pen then
        return false
    end

    local effective_tool = self.tool:getEffectiveTool(is_eraser_end, is_highlighter, self.side_button_down)

    -- Log pan end to debug file
    self:writeDebugLog(string.format("=== PAN END at (%d, %d) ===", ges.pos.x, ges.pos.y))
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.tool.eraser_tool_active), effective_tool))

    -- Handle eraser pan release (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        if self.eraser_deleted and #self.eraser_deleted > 0 then
            -- Add deleted strokes to undo stack
            self.store:pushUndo({ type = "delete", strokes = self.eraser_deleted })
            self:saveStrokes()
        end
        -- Always refresh screen after erasing to clear any visual artifacts
        UIManager:setDirty(self.view, "partial")
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
        self:anchorStrokeToPage(self.current_stroke)
        local stroke_idx = self.store:add(self.current_stroke)
        self:saveStrokes()

        -- Add to undo stack
        self.store:pushUndo({ type = "add", stroke_idx = stroke_idx })
        self:assignStrokeToGroup(stroke_idx)

        logger.dbg("Pencil: stroke completed with", #self.current_stroke.points, "points")
        self:accumulateRefreshBbox(self.current_stroke)
    end

    self.current_stroke = nil

    -- Schedule delayed refresh - will fire after user stops writing
    -- If user starts another stroke, the refresh will be canceled and rescheduled
    self:scheduleDelayedRefresh()

    return true
end

-- Get current page number (stable reference for both paged and rolling modes)
-- PDF strokes are anchored to page coordinates so they follow zoom, pan,
-- crop and rotation. On a paged view, screen = page * zoom + offset for
-- each visible page; this returns zoom, offset_x, offset_y for `page`, or
-- nil when the page isn't shown. Mirrors ReaderView:getSinglePageRect /
-- getScrollPageRect without allocating per point.
function Pencil:pageAffine(page)
    local view = self.view
    if not (self.ui and self.ui.paging and view and view.state) then return nil end
    if view.page_scroll then
        local acc_y = 0
        local gap = view.page_gap and view.page_gap.height or 0
        for _, st in ipairs(view.page_states or {}) do
            if st.page == page then
                return st.zoom, st.offset.x - st.visible_area.x,
                       acc_y + st.offset.y - st.visible_area.y
            end
            acc_y = acc_y + st.visible_area.h + gap
        end
        return nil
    end
    if view.state.page ~= page or not view.visible_area then return nil end
    return view.state.zoom, view.state.offset.x - view.visible_area.x,
           view.state.offset.y - view.visible_area.y
end

-- Remember which page a new stroke starts on and that page's transform, so
-- the stroke is anchored with the view it was drawn in even if it is saved
-- after a page turn.
function Pencil:captureStrokeAnchor(stroke, x, y)
    local pos = self.view:screenToPageTransform({ x = x, y = y })
    if not (pos and pos.page) then return end
    local zoom, ox, oy = self:pageAffine(pos.page)
    if not zoom or zoom == 0 then return end
    stroke._anchor_page, stroke._anchor_zoom = pos.page, zoom
    stroke._anchor_ox, stroke._anchor_oy = ox, oy
end

-- Give a finished PDF stroke page coordinates (page_points). No-op for
-- reflowable documents.
function Pencil:anchorStrokeToPage(stroke)
    if not (self.ui and self.ui.paging) or stroke.page_points then return end
    if not stroke._anchor_zoom and stroke.points and stroke.points[1] then
        self:captureStrokeAnchor(stroke, stroke.points[1].x, stroke.points[1].y)
    end
    PencilStrokes.anchorToPage(stroke)
end

-- Bring a page-anchored stroke's screen points (stroke.points) in line with
-- the current view. Cheap when the view hasn't changed.
-- @return false if the stroke's page isn't visible
function Pencil:syncStrokeToView(stroke)
    if not stroke.page_points then return true end
    return PencilStrokes.syncToView(stroke, self:pageAffine(stroke.page))
end

-- Pages whose strokes should be drawn / erased: every visible page in PDF
-- continuous mode, otherwise just the current page.
function Pencil:getVisiblePages()
    local page = self:getCurrentPage()
    if self.ui and self.ui.paging and self.view and self.view.page_scroll then
        local list = self.view:getCurrentPageList()
        if list and #list > 0 then return list, page end
    end
    return { page }, page
end

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

-- Get an XPointer for a screen-space position on the current rolling-mode
-- page. Used to remember WHERE an annotation lives (so it can be re-resolved
-- to a post-rotation page) rather than just the top of the page it was
-- drawn on. Returns nil for paging docs or when the API is unavailable.
function Pencil:getXPointerAtBboxCenter(bbox)
    if not bbox then return nil end
    if not self.ui.rolling then return nil end
    if not self.ui.document or not self.ui.document.getTextFromPositions then
        return nil
    end
    local cx = math.floor((bbox.x0 + bbox.x1) / 2)
    local cy = math.floor((bbox.y0 + bbox.y1) / 2)
    local ok, range = pcall(self.ui.document.getTextFromPositions,
        self.ui.document, { x = cx, y = cy }, { x = cx, y = cy }, true)
    if ok and range and range.pos0 then
        return range.pos0
    end
    -- Fallback: nearest-line xpointer via the current scroll top.
    if self.ui.document.getXPointer then
        local ok2, xp = pcall(self.ui.document.getXPointer, self.ui.document)
        if ok2 and xp then return xp end
    end
    return nil
end

-- Resolve a group's page number in the current layout. For paging docs (PDF)
-- the saved group.page is stable. For rolling docs (EPUB) page numbers shift
-- with rotation / font / spacing changes, so re-derive from the saved
-- XPointer if we have one. Falls back to the original page number when no
-- XPointer was stored (older groups created before this code shipped).
function Pencil:getGroupCurrentPage(group)
    if not group then return nil end
    if self.ui.rolling and group.xpointer
            and self.ui.document and self.ui.document.getPageFromXPointer then
        local ok, pn = pcall(self.ui.document.getPageFromXPointer,
            self.ui.document, group.xpointer)
        if ok and pn then return pn end
    end
    return group.page
end

-- Lazily store / upgrade an XPointer for rolling-doc groups on the current
-- page. Two paths:
--   1. Legacy group with no xpointer: drop in the page-top xpointer so at
--      least same-rotation matching keeps working.
--   2. Group whose xpointer was stored at page-top (old buggy code) or for
--      any reason isn't marked precise: when we're on the same page AND in
--      the rotation the annotation was captured at, the bbox coords are
--      valid on the current screen, so we can resolve a precise per-bbox
--      xpointer. Mark xpointer_v2 to avoid repeated work.
function Pencil:backfillGroupXPointers()
    if not self.ui.rolling then return end
    if not self.ui.document or not self.ui.document.getXPointer
            or not self.ui.document.getPageFromXPointer then
        return
    end
    local cur_page = self:getCurrentPage()
    local cur_rot = Screen:getRotationMode()
    local cur_xp_top = nil
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.page == cur_page then
            local upgraded = false
            if not group.xpointer_v2 and group.bbox
                    and (group.image_rotation == nil
                            or group.image_rotation == cur_rot) then
                local precise = self:getXPointerAtBboxCenter(group.bbox)
                if precise then
                    group.xpointer = precise
                    group.xpointer_v2 = true
                    self.image_data_dirty = true
                    upgraded = true
                end
            end
            if not upgraded and not group.xpointer then
                cur_xp_top = cur_xp_top or self.ui.document:getXPointer()
                if cur_xp_top then
                    group.xpointer = cur_xp_top
                    self.image_data_dirty = true
                end
            end
        end
    end
end

-- Assign a newly-added stroke to an annotation group (or create a new one).
-- Called after a stroke is finalized and inserted into self.store.strokes.
-- @param stroke_idx number  index of the stroke in self.store.strokes
-- @param skip_bookmark boolean  if true, skip bookmark sync (used during bootstrap)
function Pencil:assignStrokeToGroup(stroke_idx, skip_bookmark)
    local stroke = self.store.strokes[stroke_idx]
    if not stroke then return end

    local bbox = stroke.bbox or PencilGeometry.computeStrokeBbox(stroke)
    if not bbox then return end

    local stroke_time = stroke.datetime or 0
    local best_group = nil

    for _, group in ipairs(self.annotation_groups) do
        if group.page == stroke.page then
            local time_diff = math.abs(stroke_time - (group.datetime_last or group.datetime or 0))
            if time_diff <= GROUP_TIME_THRESHOLD_S then
                local dist = PencilGeometry.bboxDistance(bbox, group.bbox)
                if dist <= GROUP_SPATIAL_THRESHOLD then
                    best_group = group
                    break
                end
            end
        end
    end

    if best_group then
        -- Merge into existing group
        table.insert(best_group.stroke_indices, stroke_idx)
        best_group.bbox = PencilGeometry.bboxUnion(best_group.bbox, bbox)
        best_group.datetime_last = math.max(best_group.datetime_last or 0, stroke_time)
        -- Update tool to majority
        local pen_count, hl_count = 0, 0
        for _, si in ipairs(best_group.stroke_indices) do
            local s = self.store.strokes[si]
            if s then
                if s.tool == TOOL_HIGHLIGHTER then hl_count = hl_count + 1
                else pen_count = pen_count + 1 end
            end
        end
        best_group.tool = hl_count > pen_count and TOOL_HIGHLIGHTER or TOOL_PEN
        if not skip_bookmark then
            self:markGroupDirty(best_group)
            -- A merged stroke invalidates the previously captured image (bbox
            -- grew); re-schedule the deferred capture.
            self:removeGroupImage(best_group)
            self:scheduleGroupImageCapture(best_group)
        end
    else
        -- Create new group
        local group = {
            id = "pencil_" .. os.date("%Y%m%d%H%M%S") .. "_" .. stroke_idx,
            page = stroke.page,
            stroke_indices = { stroke_idx },
            bbox = bbox,
            datetime = stroke_time,
            datetime_last = stroke_time,
            tool = (stroke.tool == TOOL_HIGHLIGHTER) and TOOL_HIGHLIGHTER or TOOL_PEN,
        }
        -- For rolling/EPUB docs, capture an XPointer AT THE ANNOTATION'S
        -- POSITION (bbox center) so we can re-resolve which page the
        -- annotation falls on after rotation / font change. CRITICAL: only
        -- valid when we're actually viewing the page this stroke was drawn
        -- on, because getTextFromPositions reads from the currently
        -- rendered page. During a full rebuild (after erase / undo) we
        -- process strokes from every page; for off-current-page strokes
        -- we skip the xpointer and let getGroupCurrentPage fall back to
        -- the saved group.page number. Backfill upgrades them later.
        if stroke.page == self:getCurrentPage() then
            local annot_xp = self:getXPointerAtBboxCenter(bbox)
            if annot_xp then
                group.xpointer = annot_xp
                group.xpointer_v2 = true
            end
        end
        table.insert(self.annotation_groups, group)
        if not skip_bookmark then
            self:markGroupDirty(group)
            self:scheduleGroupImageCapture(group)
        end
    end
end

-- Mark a group as needing a bookmark sync on the next deferred-work flush.
-- Keeps the heavy getPageXPointer / annotation insertion off the writing path.
function Pencil:markGroupDirty(group)
    if not self.experimental_bookmark_sync then return end
    self.dirty_groups = self.dirty_groups or {}
    self.dirty_groups[group.id] = group
end

-- Rebuild all annotation groups from scratch by re-running the grouping algorithm
-- on all existing strokes sorted by datetime. Called after erase/undo operations.
function Pencil:rebuildAnnotationGroups()
    local ok, err = pcall(function()
        -- Remove all existing bookmarks for pencil groups, and cancel any
        -- pending image captures (group ids will change).
        for _, group in ipairs(self.annotation_groups) do
            self:removeGroupBookmark(group)
            self:cancelGroupImageCapture(group.id)
        end

        self.annotation_groups = {}

        -- Build list of {index, datetime} sorted by datetime
        local sorted = {}
        for i, stroke in ipairs(self.store.strokes) do
            table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
        end
        table.sort(sorted, function(a, b) return a.dt < b.dt end)

        -- Re-assign each stroke
        for _, entry in ipairs(sorted) do
            self:assignStrokeToGroup(entry.idx)
        end
    end)
    if not ok then
        logger.warn("Pencil: rebuildAnnotationGroups failed:", err)
        self.annotation_groups = self.annotation_groups or {}
    end
    -- Any JPEGs whose stem no longer matches a current group.id are now stale.
    self:purgeOrphanImages()
end

-- Get page number for bookmark display (always numeric).
function Pencil:getPageNumber(page_ref)
    if type(page_ref) == "number" then
        return page_ref
    end
    -- For XPointer (rolling docs), try to convert
    if self.ui.document and self.ui.document.getPageFromXPointer then
        local pn = self.ui.document:getPageFromXPointer(page_ref)
        if pn then return pn end
    end
    return 0
end

-- Get the bookmark page reference for a group.
-- For paging mode (PDF), this is the page number.
-- For rolling mode (EPUB), a valid XPointer, or nil. KOReader can't sort
-- an invalid one. Two make its sort fail and the book won't open (#84).
function Pencil:getBookmarkPageRef(group)
    if self.ui.rolling and self.ui.document and self.ui.document.getPageXPointer then
        local doc = self.ui.document
        local function valid(xp)
            return type(xp) == "string" and xp ~= "" and doc:isXPointerInDocument(xp)
        end
        -- The ink's own XPointer. It follows the ink through font changes
        -- and rotation.
        if valid(group.xpointer) then
            return group.xpointer
        end
        -- The page's start. Past the end of the book this is "".
        local xp = doc:getPageXPointer(group.page)
        if valid(xp) then
            return xp
        end
        return nil
    end
    return group.page
end

-- Sync a group's bookmark into KOReader's annotation system.
function Pencil:syncGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then
        logger.dbg("Pencil: annotation module not available, skipping bookmark sync")
        return
    end
    if not self.ui.annotation.annotations then
        logger.dbg("Pencil: annotations not loaded yet, skipping bookmark sync")
        return
    end

    local ok, err = pcall(function()
        -- Remove existing bookmark for this group first
        self:removeGroupBookmark(group)

        local bookmark_page = self:getBookmarkPageRef(group)
        if not bookmark_page then
            logger.dbg("Pencil: no valid position for group", group.id, "- no bookmark")
            return
        end
        local pageno = self:getPageNumber(bookmark_page)
        local chapter = ""
        if self.ui.toc and self.ui.toc.getTocTitleByPage then
            chapter = self.ui.toc:getTocTitleByPage(bookmark_page) or ""
        end

        local datetime = group.id  -- use group id as unique datetime key
        group.bookmark_datetime = datetime

        local transcription = trimString(group.transcription)
        local bookmark_text

        if transcription ~= "" then
            bookmark_text = transcription
        else
            bookmark_text = string.format(
                "Pencil annotation on page %d",
                pageno
            )
        end

        local item = {
            page = bookmark_page,
            datetime = datetime,
            text = bookmark_text,
            chapter = chapter,
        }

        if self.ui.annotation.addItem then
            self.ui.annotation:addItem(item)
            logger.dbg("Pencil: synced bookmark for group", group.id, "on page", pageno)
        else
            logger.warn("Pencil: annotation.addItem not available")
        end
    end)
    if not ok then
        logger.warn("Pencil: bookmark sync failed:", err)
    end
end

-- Remove a group's bookmark from KOReader's annotation system.
function Pencil:removeGroupBookmark(group)
    if not self.experimental_bookmark_sync then return end
    if not self.ui or not self.ui.annotation then return end
    if not group.bookmark_datetime then return end

    local ok, err = pcall(function()
        local annotations = self.ui.annotation.annotations
        if not annotations then return end

        for i, ann in ipairs(annotations) do
            if ann.datetime == group.bookmark_datetime then
                table.remove(annotations, i)
                logger.dbg("Pencil: removed bookmark for group", group.id)
                return
            end
        end
    end)
    if not ok then
        logger.warn("Pencil: bookmark removal failed:", err)
    end
end

-- Remove ALL pencil bookmarks from KOReader's annotation system.
-- Used before re-syncing to avoid duplicates.
-- Note: always runs regardless of feature flag, so disabling cleans up.
function Pencil:removeAllPencilBookmarks()
    if not self.ui or not self.ui.annotation then return end
    local annotations = self.ui.annotation.annotations
    if not annotations then return end

    -- Remove in reverse order to maintain indices
    for i = #annotations, 1, -1 do
        if annotations[i].datetime and annotations[i].datetime:match("^pencil_") then
            table.remove(annotations, i)
        end
    end
end

-- Sync all annotation groups to bookmarks (used after load/rebuild).
function Pencil:syncAllBookmarks()
    if not self.experimental_bookmark_sync then return end

    -- Clean slate: remove all pencil bookmarks first to avoid duplicates
    self:removeAllPencilBookmarks()

    for _, group in ipairs(self.annotation_groups) do
        self:syncGroupBookmark(group)
    end
    logger.info("Pencil: synced", #self.annotation_groups, "annotation group bookmarks")
end

------------------------------------------------------------------------------
-- MyScript handwriting recognition
------------------------------------------------------------------------------

function Pencil:showMyScriptSettingsDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("MyScript settings"),
        fields = {
            { description = _("Recognition language"), text = self.myscript_language or "en_US", hint = "en_US" },
            { description = _("Application key"), text = self.myscript_application_key or "" },
            { description = _("HMAC key"), text = self.myscript_hmac_key or "", text_type = "password" },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local f = dialog:getFields()
                local lang, app, hmac = trimString(f[1]), trimString(f[2]), trimString(f[3])
                if lang == "" or app == "" or hmac == "" then
                    UIManager:show(InfoMessage:new{ text = _("Language, application key, and HMAC key are required."), timeout = 3 })
                    return
                end
                self.myscript_language, self.myscript_application_key, self.myscript_hmac_key = lang, app, hmac
                self:saveSettings(); UIManager:close(dialog)
                UIManager:show(InfoMessage:new{ text = _("MyScript settings saved."), timeout = 2 })
            end },
        }},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Pencil:getLatestAnnotationGroupOnCurrentPage()
    local page, latest = self:getCurrentPage(), nil
    for _, g in ipairs(self.annotation_groups or {}) do
        if self:getGroupCurrentPage(g) == page and (not latest or (g.datetime_last or g.datetime or 0) > (latest.datetime_last or latest.datetime or 0)) then latest = g end
    end
    return latest
end

function Pencil:getMyScriptStrokesForGroup(group)
    if not group or type(group.stroke_indices) ~= "table" then return nil, { message = "Invalid annotation group" } end
    return MyScript.strokes_from_pencil({ strokes = self.store.strokes, annotation_groups = { group } }, { group_index = 1, pointer_type = "PEN", pointer_id = 0 })
end

function Pencil:showRecognizedText(text, group)
    UIManager:show(TextViewer:new{
        title = T(_("Handwriting - page %1"), self:getPageNumber(group.page)),
        text = text,
        text_settings = {},
    })
end

function Pencil:createMyScriptClient()
    return MyScript.new{
        application_key = self.myscript_application_key,
        hmac_key = self.myscript_hmac_key,
        language = self.myscript_language,
        content_type = "Text",
        client_name = "koreader-pencil-plugin",
        client_version = "1.1.0",
    }
end

-- Store text on the group and on every stroke referenced by the group.
-- A stroke keeps group id + text, which avoids ambiguity if groups are rebuilt.
function Pencil:setAnnotationGroupText(group, text, engine)
    text = trimString(text)
    if not group or text == "" then return false end

    local updated_at = os.time()
    local source = engine or "manual"
    group.transcription = text
    group.transcription_language = self.myscript_language
    group.transcription_datetime = updated_at
    group.transcription_engine = source

    for _, stroke_index in ipairs(group.stroke_indices or {}) do
        local stroke = self.store.strokes[stroke_index]
        if stroke then
            stroke.transcription = text
            stroke.transcription_group_id = group.id
            stroke.transcription_language = self.myscript_language
            stroke.transcription_datetime = updated_at
            stroke.transcription_engine = source
        end
    end

    if self.experimental_bookmark_sync then
        self:syncGroupBookmark(group)
    end
    return true
end

function Pencil:enrichAnnotationGroup(group, text)
    return self:setAnnotationGroupText(group, text, "myscript")
end

function Pencil:showAnnotationTextEditor(group)
    if not group then return end

    local dialog
    local existing_text = trimString(group.transcription)
    dialog = MultiInputDialog:new{
        title = existing_text ~= ""
            and _("Edit annotation text")
            or _("Create annotation text"),
        fields = {{
            description = _("Text"),
            text = existing_text,
            hint = _("Enter annotation text"),
        }},
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local fields = dialog:getFields()
                local edited_text = trimString(fields and fields[1])
                if edited_text == "" then
                    UIManager:show(InfoMessage:new{
                        text = _("Annotation text cannot be empty."),
                        timeout = 2,
                    })
                    return
                end
                self:setAnnotationGroupText(group, edited_text, "manual")
                self:saveStrokes()
                UIManager:close(dialog)
                UIManager:show(InfoMessage:new{
                    text = _("Annotation text saved."),
                    timeout = 2,
                })
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Pencil:recognizeGroupWithClient(client, group)
    local strokes, conversion_error = self:getMyScriptStrokesForGroup(group)
    if not strokes then
        return nil, conversion_error
    end

    local ok, text, api_error = pcall(client.recognize_text, client, strokes, {
        language = self.myscript_language,
    })
    if not ok then
        logger.warn("Pencil: MyScript call failed:", tostring(text))
        return nil, { message = tostring(text), kind = "unexpected" }
    end
    text = trimString(text)
    if text == "" then
        return nil, api_error or { message = _("No text was recognized.") }
    end

    self:enrichAnnotationGroup(group, text)
    return text
end

function Pencil:recognizeAnnotationGroup(group)
    if trimString(self.myscript_application_key) == ""
            or trimString(self.myscript_hmac_key) == "" then
        self:showMyScriptSettingsDialog()
        return
    end

    NetworkMgr:runWhenOnline(function()
        local client, client_error = self:createMyScriptClient()
        if not client then
            UIManager:show(InfoMessage:new{
                text = T(_("Invalid MyScript configuration: %1"), tostring(client_error)),
            })
            return
        end

        UIManager:show(InfoMessage:new{
            text = _("Recognizing handwriting..."),
            timeout = 1,
        })

        local text, error_value = self:recognizeGroupWithClient(client, group)
        if not text then
            local message = error_value and error_value.message or error_value
            UIManager:show(InfoMessage:new{
                text = T(_("Recognition failed: %1"), tostring(message)),
            })
            return
        end

        self:saveStrokes()
        self:showRecognizedText(text, group)
    end)
end

function Pencil:hasRecognizedAnnotations()
    for _, group in ipairs(self.annotation_groups or {}) do
        if trimString(group.transcription) ~= "" then return true end
    end
    return false
end

function Pencil:getAllRecognizedText()
    local gettext = _
    local groups = {}

    for _, group in ipairs(self.annotation_groups or {}) do
        if trimString(group.transcription) ~= "" then
            groups[#groups + 1] = group
        end
    end

    table.sort(groups, function(a, b)
                   local ap, bp = self:getPageNumber(a.page), self:getPageNumber(b.page)

                   if ap ~= bp then
                       return ap < bp
                   end

                   return (a.datetime or 0) < (b.datetime or 0)
    end)

    local parts = {}

    for index, group in ipairs(groups) do
        parts[#parts + 1] =
            T(gettext("Page %1"), self:getPageNumber(group.page))
            .. "\n"
            .. trimString(group.transcription)
    end

    return table.concat(parts, "\n\n")
end

function Pencil:showAllRecognizedText()
    local text = self:getAllRecognizedText()
    if text == "" then
        UIManager:show(InfoMessage:new{ text = _("No recognized annotations.") })
        return
    end
    UIManager:show(TextViewer:new{
        title = _("Recognized annotations"),
        text = text,
        text_settings = {},
    })
end

-- Edit every annotation that currently has text. One MultiInput field is bound
-- to one group directly, avoiding fragile parsing of page labels or separators.
function Pencil:editAllRecognizedText()
    local groups = {}
    for _, group in ipairs(self.annotation_groups or {}) do
        if trimString(group.transcription) ~= "" then
            groups[#groups + 1] = group
        end
    end
    table.sort(groups, function(a, b)
        local ap, bp = self:getPageNumber(a.page), self:getPageNumber(b.page)
        if ap ~= bp then return ap < bp end
        return (a.datetime or 0) < (b.datetime or 0)
    end)

    if #groups == 0 then
        UIManager:show(InfoMessage:new{ text = _("No recognized annotations.") })
        return
    end

    local fields = {}
    for index, group in ipairs(groups) do
        fields[index] = {
            description = T(_("Page %1 - annotation %2"),
                self:getPageNumber(group.page), index),
            text = trimString(group.transcription),
            hint = _("Enter annotation text"),
        }
    end

    local dialog
    dialog = MultiInputDialog:new{
        title = _("Edit all recognized text"),
        fields = fields,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save all"), is_enter_default = true, callback = function()
                local values = dialog:getFields()
                if not values or #values ~= #groups then
                    UIManager:show(InfoMessage:new{
                        text = _("Unable to read all annotation fields."),
                        timeout = 2,
                    })
                    return
                end

                -- Validate the whole form before mutating any group, so a single
                -- empty field cannot leave a partially updated document.
                local normalized = {}
                for index = 1, #groups do
                    normalized[index] = trimString(values[index])
                    if normalized[index] == "" then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Text for annotation %1 cannot be empty."), index),
                            timeout = 3,
                        })
                        return
                    end
                end

                local changed = 0
                for index, group in ipairs(groups) do
                    if normalized[index] ~= trimString(group.transcription) then
                        self:setAnnotationGroupText(group, normalized[index], "manual")
                        changed = changed + 1
                    end
                end
                if changed > 0 then self:saveStrokes() end
                UIManager:close(dialog)
                UIManager:show(InfoMessage:new{
                    text = T(_("Updated %1 annotation(s)."), changed),
                    timeout = 3,
                })
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Recognize every current annotation group, enrich groups and their referenced
-- strokes, then persist once. Processing continues after per-group failures.
function Pencil:recognizeAllAnnotationGroups()
    if trimString(self.myscript_application_key) == ""
            or trimString(self.myscript_hmac_key) == "" then
        self:showMyScriptSettingsDialog()
        return
    end
    if not self.annotation_groups or #self.annotation_groups == 0 then
        UIManager:show(InfoMessage:new{ text = _("No annotation groups to recognize.") })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local client, client_error = self:createMyScriptClient()
        if not client then
            UIManager:show(InfoMessage:new{
                text = T(_("Invalid MyScript configuration: %1"), tostring(client_error)),
            })
            return
        end

        local recognized, failed = 0, 0
        UIManager:show(InfoMessage:new{
            text = T(_("Recognizing %1 annotation group(s)..."), #self.annotation_groups),
            timeout = 1,
        })

        for group_index, group in ipairs(self.annotation_groups) do
            local text, error_value = self:recognizeGroupWithClient(client, group)
            if text then
                group.transcription_error = nil
                recognized = recognized + 1
            else
                local message = error_value and error_value.message or error_value
                group.transcription_error = tostring(message or _("Unknown recognition error"))
                group.transcription_error_datetime = os.time()
                failed = failed + 1
                logger.warn("Pencil: recognition failed for group", group_index,
                    group.id or "(no id)", group.transcription_error)
            end
        end

        -- Persist all group fields and all stroke-level enrichment atomically
        -- through the plugin's existing sidecar serialization path.
        self:saveStrokes()

        local summary = T(_("Recognized %1 annotation group(s)."), recognized)
        if failed > 0 then
            summary = summary .. "\n" .. T(_("Failed: %1."), failed)
        end
        UIManager:show(InfoMessage:new{ text = summary, timeout = 4 })
    end)
end

------------------------------------------------------------------------------
-- Annotation image capture & preview (issue #51)
------------------------------------------------------------------------------

-- Directory holding per-group preview JPEGs for this document.
function Pencil:getImagesDir()
    if not self.ui or not self.ui.doc_settings then return nil end
    local sidecar_dir = self.ui.doc_settings.doc_sidecar_dir
    if not sidecar_dir then return nil end
    return sidecar_dir .. "/pencil_images"
end

function Pencil:ensureImagesDir()
    local dir = self:getImagesDir()
    if not dir then return nil end
    local ok, err = lfs.mkdir(dir)
    if not ok and err ~= "File exists" then
        logger.warn("Pencil: failed to create images dir:", err)
        return nil
    end
    return dir
end

function Pencil:getGroupImagePath(group)
    local dir = self:getImagesDir()
    if not dir or not group or not group.image_path then return nil end
    return dir .. "/" .. group.image_path
end

-- Render the captured-page-context image for a group into a Blitbuffer and
-- write it as a JPEG. Returns true on success.
function Pencil:captureGroupImage(group)
    if not group or not group.bbox then return false end
    if not self.view or not self.view.paintTo then return false end

    local dir = self:ensureImagesDir()
    if not dir then return false end

    -- Only capture if the group's page matches the current pagination;
    -- otherwise ReaderView would render the wrong content. For rolling docs
    -- this uses the group's XPointer (rotation-stable) when available.
    local gpage = self:getGroupCurrentPage(group)
    if gpage ~= self:getCurrentPage() then
        logger.dbg("Pencil: captureGroupImage: page mismatch (group=", tostring(gpage),
            " current=", tostring(self:getCurrentPage()), "), deferring")
        return false
    end

    -- Capture a full-screen-width strip vertically bounded by the bbox + a
    -- small margin. This gives the user enough context (full line of text)
    -- when they preview the annotation from the bookmark list or rotation
    -- badge, instead of a tight crop that just shows the strokes.
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local rect = PencilGeometry.captureStripRect(
        group.bbox, sw, sh, IMAGE_CAPTURE_V_MARGIN_PX, IMAGE_MIN_HEIGHT_PX)
    local w = math.floor(rect.x1 - rect.x0)
    local h = math.floor(rect.y1 - rect.y0)
    if w < 8 or h < 8 then return false end

    -- Allocate offscreen buffer of the same type as Screen.bb so paintTo writes
    -- pixels in the format ReaderView expects.
    local bb_type = Screen.bb:getType()
    local ok_bb, off_bb = pcall(Blitbuffer.new, w, h, bb_type)
    if not ok_bb or not off_bb then
        logger.warn("Pencil: failed to allocate offscreen buffer for capture")
        return false
    end

    -- Paint the page (and other plugins / highlights / dogear etc.) into the
    -- offscreen buffer. The (-x, -y) offset places the captured page region
    -- at (0, 0) inside off_bb; Blitbuffer paints clip to buffer bounds.
    local x0, y0 = math.floor(rect.x0), math.floor(rect.y0)
    self._capturing = true
    local ok_paint, paint_err = pcall(self.view.paintTo, self.view, off_bb, -x0, -y0)
    self._capturing = false
    if not ok_paint then
        logger.warn("Pencil: ReaderView paint to offscreen failed:", paint_err)
        if off_bb.free then off_bb:free() end
        return false
    end

    -- Render this group's strokes over the painted page background.
    for _, idx in ipairs(group.stroke_indices or {}) do
        local stroke = self.store.strokes[idx]
        if stroke then
            self:renderStrokeOffset(off_bb, stroke, -x0, -y0)
        end
    end

    -- Downscale if longer side exceeds IMAGE_MAX_DIM (storage / encode budget).
    local final_bb = off_bb
    local longer = math.max(w, h)
    if longer > IMAGE_MAX_DIM and off_bb.scale then
        local scale = IMAGE_MAX_DIM / longer
        local sw_new = math.max(1, math.floor(w * scale))
        local sh_new = math.max(1, math.floor(h * scale))
        local ok_scale, scaled = pcall(off_bb.scale, off_bb, sw_new, sh_new)
        if ok_scale and scaled then
            final_bb = scaled
        end
    end

    -- Encode + write.
    local filename = group.id .. ".jpg"
    local fullpath = dir .. "/" .. filename
    local ok_write, write_err = pcall(final_bb.writeJPG, final_bb, fullpath, IMAGE_JPEG_QUALITY)

    -- Free buffers we own (final_bb might be the same object as off_bb after
    -- skipping the downscale path).
    if final_bb ~= off_bb and final_bb.free then final_bb:free() end
    if off_bb.free then off_bb:free() end

    if not ok_write then
        logger.warn("Pencil: failed to write JPEG:", write_err)
        return false
    end

    group.image_path = filename
    group.image_rotation = Screen:getRotationMode()
    self.image_data_dirty = true
    logger.info("Pencil: captured image for group", group.id, "rotation", group.image_rotation, "->", fullpath)
    return true
end

function Pencil:renderStrokeOffset(bb, stroke, dx, dy)
    self.stroke_render_ctx.night_mode = Screen.night_mode
    PencilStrokes.render(bb, stroke, self.stroke_render_ctx, dx, dy)
end

-- Schedule a deferred capture for the group. If a capture is already pending
-- for this group id, cancel and re-arm so we only capture once after the
-- grouping window has settled.
-- delay (optional): seconds before firing. Defaults to IMAGE_CAPTURE_DEBOUNCE_S
-- so we wait past the GROUP_TIME_THRESHOLD_S merge window before capturing a
-- fresh stroke. Backfill uses a shorter delay since no merges are pending.
function Pencil:scheduleGroupImageCapture(group, delay)
    if not group or not group.id then return end
    self.pending_image_captures = self.pending_image_captures or {}

    self:cancelGroupImageCapture(group.id)

    local cb
    cb = function()
        -- Offscreen page repaint + JPEG encode is heavy; postpone if pen is active.
        if self.pen_down or self.current_stroke then
            UIManager:scheduleIn(IMAGE_CAPTURE_DEBOUNCE_S, cb)
            return
        end
        self.pending_image_captures[group.id] = nil
        if self.pen_down then
            self:scheduleGroupImageCapture(group, 0.5)
            return
        end
        -- The group might have been deleted by the eraser by now.
        local current = nil
        for _, g in ipairs(self.annotation_groups) do
            if g.id == group.id then current = g; break end
        end
        if not current then return end
        local ok, err = pcall(self.captureGroupImage, self, current)
        if not ok then
            logger.warn("Pencil: captureGroupImage error:", err)
        end
        if self.image_data_dirty then
            self.image_data_dirty = false
            self:saveStrokes()
        end
    end

    self.pending_image_captures[group.id] = cb
    local d = delay or IMAGE_CAPTURE_DEBOUNCE_S
    UIManager:scheduleIn(d, cb)
    logger.dbg("Pencil: scheduled image capture for group", group.id, "in", d, "seconds")
end

function Pencil:cancelGroupImageCapture(group_id)
    if not self.pending_image_captures then return end
    local cb = self.pending_image_captures[group_id]
    if cb then
        UIManager:unschedule(cb)
        self.pending_image_captures[group_id] = nil
    end
end

-- Run all pending captures synchronously and clear the queue. Called on
-- document close / suspend so we don't lose freshly drawn annotations.
function Pencil:flushPendingCaptures()
    if not self.pending_image_captures then return end
    local pending = self.pending_image_captures
    self.pending_image_captures = {}
    for _, cb in pairs(pending) do
        UIManager:unschedule(cb)
        local ok, err = pcall(cb)
        if not ok then
            logger.warn("Pencil: flushPendingCaptures error:", err)
        end
    end
end

function Pencil:removeGroupImage(group)
    local path = self:getGroupImagePath(group)
    if not path then return end
    os.remove(path)
    group.image_path = nil
    group.image_rotation = nil
end

-- Delete any JPEG in pencil_images/ whose stem isn't a current group.id.
-- Called after group rebuilds (which regenerate ids) and during saveStrokes.
function Pencil:purgeOrphanImages()
    local dir = self:getImagesDir()
    if not dir then return end
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return end

    local valid = {}
    for _, g in ipairs(self.annotation_groups or {}) do
        if g.image_path then
            valid[g.image_path] = true
        end
    end

    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." and file:match("%.jpg$") and not valid[file] then
            os.remove(dir .. "/" .. file)
            logger.dbg("Pencil: purged orphan image", file)
        end
    end
end

-- Open the saved image for a group in an ImageViewer popup.
function Pencil:showGroupImagePreview(group)
    if not group then return end
    local path = self:getGroupImagePath(group)
    if not path then
        UIManager:show(InfoMessage:new{
            text = _("No saved image for this annotation yet."),
            timeout = 2,
        })
        return
    end
    local attr = lfs.attributes(path)
    if not attr then
        UIManager:show(InfoMessage:new{
            text = _("Annotation image is missing on disk."),
            timeout = 2,
        })
        return
    end
    local ImageViewer = require("ui/widget/imageviewer")
    local pageno = self:getPageNumber(group.page) or 0
    UIManager:show(ImageViewer:new{
        file = path,
        with_title_bar = true,
        title_text = T(_("Annotation - page %1"), pageno),
        fullscreen = false,
    })
end

-- Compute the on-screen badge rect for a stale-rotation group. The badge is
-- pinned to the right edge of the screen (i.e. in the margin) at a vertical
-- position proportional to the original bbox center Y, so multiple stale
-- annotations stack along the right side in roughly their original reading
-- order.
function Pencil:getGroupBadgeRect(group)
    if not group or not group.bbox or not group.image_rotation then return nil end
    local current_rot = Screen:getRotationMode()
    if current_rot == group.image_rotation then return nil end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    -- Source-rotation screen height: rotations 0/2 vs 1/3 swap width/height.
    local src_sh = sh
    if (group.image_rotation == 1 or group.image_rotation == 3) ~=
            (current_rot == 1 or current_rot == 3) then
        src_sh = sw
    end

    -- Vertical: proportional remap of the bbox center onto current screen.
    local cy = (group.bbox.y0 + group.bbox.y1) / 2
    local y_fraction = src_sh > 0 and (cy / src_sh) or 0.5
    local target_y = math.floor(y_fraction * sh)

    -- Horizontal: fixed position in the right margin. Simple and reliable;
    -- avoids depending on the document's reported page margins which can
    -- behave unexpectedly across EPUB engines.
    local badge_x = sw - IMAGE_BADGE_SIZE - IMAGE_BADGE_MARGIN_GAP

    local half = math.floor(IMAGE_BADGE_SIZE / 2)
    local x = math.max(0, math.min(sw - IMAGE_BADGE_SIZE, badge_x))
    local y = math.max(0, math.min(sh - IMAGE_BADGE_SIZE, target_y - half))
    return { x = x, y = y, w = IMAGE_BADGE_SIZE, h = IMAGE_BADGE_SIZE }
end

-- Pick a representative color for an annotation group: the first stroke's
-- saved color. Returns nil if no usable color is found, so the caller can
-- fall back to a default.
function Pencil:getGroupColor(group)
    if not group or not group.stroke_indices then return nil end
    for _, idx in ipairs(group.stroke_indices) do
        local stroke = self.store.strokes[idx]
        if stroke and stroke.color then
            return stroke.color
        end
    end
    return nil
end

function Pencil:renderRotationBadge(bb, group)
    local rect = self:getGroupBadgeRect(group)
    if not rect then return end
    -- Fill matches the annotation color so users can tell badges apart when
    -- a page has annotations in different colors. Black border for
    -- definition, white inner mark to suggest interactivity (and to keep
    -- light colors like gray / highlighter yellow visible).
    -- Must use paintRectRGB32 (not paintRect) to preserve the color channels
    -- of ColorRGB32 fills; paintRect treats the value as a luminance and
    -- would render colored fills as gray.
    local fill = self:getGroupColor(group)
            or Blitbuffer.ColorRGB32(0xCC, 0x00, 0x00, 0xFF)
    bb:paintRectRGB32(rect.x, rect.y, rect.w, rect.h, Blitbuffer.COLOR_BLACK)
    bb:paintRectRGB32(rect.x + 2, rect.y + 2, rect.w - 4, rect.h - 4, fill)
    local inset = math.floor(rect.w / 3)
    bb:paintRectRGB32(rect.x + inset, rect.y + inset,
        rect.w - 2 * inset, rect.h - 2 * inset, Blitbuffer.COLOR_WHITE)
end

-- Page-anchored (PDF) strokes render correctly in any rotation, so their
-- groups never need a rotation badge.
function Pencil:isGroupPageAnchored(group)
    local first = group.stroke_indices and self.store.strokes[group.stroke_indices[1]]
    return first ~= nil and first.page_points ~= nil
end

-- Compute the list of stale-rotation groups whose badges should be drawn on
-- the current page in the current rotation. Returns nil if no badges should
-- show (no stale groups, or suppressed because a native annotation is also
-- on this page). Shared by paintTo and findGroupBadgeAtPoint to keep
-- drawing and hit-testing in lockstep.
function Pencil:getStaleGroupsForCurrentView()
    local current_rot = Screen:getRotationMode()
    local page = self:getCurrentPage()
    local stale = nil
    local has_native = false
    for _, group in ipairs(self.annotation_groups or {}) do
        local gpage = self:getGroupCurrentPage(group)
        if gpage == page then
            if group.image_rotation == nil
                    or group.image_rotation == current_rot
                    or self:isGroupPageAnchored(group) then
                has_native = true
            elseif group.image_path then
                stale = stale or {}
                stale[#stale + 1] = group
            end
        end
    end
    if has_native then return nil end
    return stale
end

-- Hit-test the rotation badges on the current page. Mirrors the drawing-
-- logic in paintTo: a badge is tappable iff its group would have its badge
-- drawn by the current render pass.
function Pencil:findGroupBadgeAtPoint(x, y)
    local stale = self:getStaleGroupsForCurrentView()
    if not stale then return nil end
    for _, group in ipairs(stale) do
        local rect = self:getGroupBadgeRect(group)
        if rect
                and x >= rect.x - IMAGE_BADGE_HIT_PAD
                and x <= rect.x + rect.w + IMAGE_BADGE_HIT_PAD
                and y >= rect.y - IMAGE_BADGE_HIT_PAD
                and y <= rect.y + rect.h + IMAGE_BADGE_HIT_PAD then
            return group
        end
    end
    return nil
end

-- Total disk usage of pencil_images/ for the current document, in bytes.
function Pencil:getImagesSizeBytes()
    local dir = self:getImagesDir()
    if not dir then return 0 end
    local attr = lfs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return 0 end
    local total = 0
    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." then
            local fattr = lfs.attributes(dir .. "/" .. file)
            if fattr and fattr.size then total = total + fattr.size end
        end
    end
    return total
end

-- Remove all preview images for the current book and clear group references.
function Pencil:purgeAllImages()
    local dir = self:getImagesDir()
    if dir then
        local attr = lfs.attributes(dir)
        if attr and attr.mode == "directory" then
            for file in lfs.dir(dir) do
                if file ~= "." and file ~= ".." then
                    os.remove(dir .. "/" .. file)
                end
            end
        end
    end
    for _, group in ipairs(self.annotation_groups or {}) do
        group.image_path = nil
        group.image_rotation = nil
    end
    self:saveStrokes()
    UIManager:setDirty(self.view, "ui")
end

-- Re-capture missing images for groups on the currently visible page.
-- Called from onReaderReady and onPageUpdate so the user sees rotation
-- badges work without needing to redraw the annotation. Uses a short delay
-- so the page has fully rendered before we ask ReaderView to repaint into
-- our offscreen, but no merge-window wait since the group is already final.
function Pencil:backfillMissingImages()
    local page = self:getCurrentPage()
    for _, group in ipairs(self.annotation_groups or {}) do
        if self:getGroupCurrentPage(group) == page and not group.image_path then
            self:scheduleGroupImageCapture(group, 1.0)
        end
    end
end

-- Install a one-time class-level patch on ReaderBookmark so that
-- long-pressing a pencil bookmark that has a saved image opens a
-- full-screen ImageViewer popup directly, instead of the standard
-- bookmark detail dialog. Closing the ImageViewer returns to the
-- bookmark list with nothing else stacked behind it.
--
-- Falls through to the standard dialog for non-pencil bookmarks and for
-- pencil bookmarks without a saved image. Short-tap still navigates to
-- the bookmark (default behavior, untouched).
function Pencil:installBookmarkHook()
    if _bookmark_hook_installed then return end

    local ok, ReaderBookmark = pcall(require, "apps/reader/modules/readerbookmark")
    if not ok or not ReaderBookmark or not ReaderBookmark.showBookmarkDetails then
        logger.warn("Pencil: ReaderBookmark module not available, skipping hook")
        return
    end

    local original_showBookmarkDetails = ReaderBookmark.showBookmarkDetails
    function ReaderBookmark:showBookmarkDetails(item_or_index)
        local item = type(item_or_index) == "table"
            and item_or_index
            or (self.ui.annotation and self.ui.annotation.annotations
                    and self.ui.annotation.annotations[item_or_index])
        if item and item.datetime and item.datetime:match("^pencil_")
                and _active_pencil and _active_pencil.annotation_groups then
            for _, group in ipairs(_active_pencil.annotation_groups) do
                if group.id == item.datetime and group.image_path then
                    local path = _active_pencil:getGroupImagePath(group)
                    if path and lfs.attributes(path) then
                        _active_pencil:showGroupImagePreview(group)
                        return true  -- suppress standard dialog
                    end
                    break
                end
            end
        end
        return original_showBookmarkDetails(self, item_or_index)
    end

    _bookmark_hook_installed = true
    logger.info("Pencil: installed bookmark list hook")
end

function Pencil:clearPageStrokes()
    local deleted_strokes = self.store:clearPage(self:getCurrentPage())

    if not deleted_strokes then
        UIManager:show(InfoMessage:new{
            text = _("No annotations found on this page."),
            timeout = 1,
        })
        return
    end

    self:rebuildAnnotationGroups()
    self:saveStrokes()

    UIManager:show(InfoMessage:new{
        text = T(_("Cleared %1 annotation(s) from page."), #deleted_strokes),
        timeout = 1,
    })
    self:repaintReader()
end

-- Clear all strokes
function Pencil:clearAllStrokes()
    -- Remove all bookmarks for annotation groups + delete their images.
    for _, group in ipairs(self.annotation_groups) do
        self:removeGroupBookmark(group)
        self:cancelGroupImageCapture(group.id)
        self:removeGroupImage(group)
    end
    self.store:clearAll()
    self.annotation_groups = {}
    self:saveStrokes()
    -- Belt-and-suspenders: any leftover files get reaped.
    self:purgeOrphanImages()

    self:repaintReader()
end

-- ===================================================================
-- Save annotations to PDF (issue #63)
--
-- Converts this page's pencil strokes into native PDF ink annotations
-- (/Subtype /Ink) and writes them into the document file, so they are
-- visible in any PDF reader. Manual, current-page only: it relies on
-- KOReader's live ReaderView:screenToPageTransform, which is exact for
-- the page currently on screen (off-screen pages have no laid-out
-- transform). Strokes are stored in screen coordinates; we map each
-- point to native page coordinates before handing it to MuPDF.
--
-- Requires KOReader 2026.07+ for the ink setters (see the module InkAnnot
-- block near the top). Degrades gracefully: when InkAnnot is nil the menu
-- action explains what's missing.
-- ===================================================================

-- Map a stroke's screen-space points to native page coordinates.
-- transform_fn is injectable for testing; by default it uses the live
-- ReaderView transform for the current on-screen page.
function Pencil:strokeToPagePoints(stroke, transform_fn)
    transform_fn = transform_fn or function(pt)
        return self.view:screenToPageTransform({ x = pt.x, y = pt.y })
    end
    local points = {}
    for _, p in ipairs(stroke.points or {}) do
        local pp = transform_fn(p)
        if pp then
            points[#points + 1] = { x = pp.x, y = pp.y }
        end
    end
    return points
end

-- Derive the ink annotation options (color/width/opacity) for a stroke.
-- Stroke widths are stored in screen pixels, but MuPDF's border width is in
-- native page units, so it needs the same zoom division the points get from
-- screenToPageTransform. (MuPDF's ink border width is the full line width,
-- centered on the path, so no extra halving is needed.)
function Pencil:strokeToInkOpts(stroke)
    local tool = stroke.tool or TOOL_PEN
    local color = stroke.color or self.tool:getToolSettings(tool).color or Blitbuffer.COLOR_BLACK
    local rgb = color:getColorRGB32()
    local width = stroke.width or self.tool:getToolSettings(tool).width or 3
    local zoom = self.view and self.view.state and self.view.state.zoom
    if zoom and zoom > 0 then
        width = width / zoom
    end
    return {
        color = { r = rgb:getR(), g = rgb:getG(), b = rgb:getB() },
        width = width,
        -- Highlighter renders as a translucent wash at its own alpha (older
        -- highlighter strokes, saved without a color, keep the fixed 0.4); the
        -- pen is opaque.
        opacity = (tool ~= TOOL_HIGHLIGHTER) and 1.0
            or (stroke.color_name and (stroke.alpha or 0xFF) / 255 or 0.4),
    }
end

-- Create one native ink annotation on `pageno` from `strokes` (an array of
-- point-lists in native page coordinates) with the given color/width/opacity.
-- Talks to the MuPDF wrapper directly (mirrors PdfDocument:saveHighlight's
-- open/mutate/close/mark-edited dance) so no core KOReader file is patched.
-- Returns true on success, or the _checkIfWritable() reason for a read-only file.
function Pencil:writeInkAnnotation(pageno, strokes, opts)
    local doc = self.ui.document
    local can_write = doc:_checkIfWritable()
    if can_write ~= true then return can_write end

    local n = #strokes
    if n == 0 then return true end
    local ffi = InkAnnot.ffi
    local W = InkAnnot.W

    -- counts[i] = points in stroke i; vertices = flattened fz_point[].
    local counts = ffi.new("int[?]", n)
    local total = 0
    for i = 1, n do
        counts[i - 1] = #strokes[i]
        total = total + #strokes[i]
    end
    if total == 0 then return true end
    local vertices = ffi.new("fz_point[?]", total)
    local k = 0
    for i = 1, n do
        for j = 1, #strokes[i] do
            vertices[k].x = strokes[i][j].x
            vertices[k].y = strokes[i][j].y
            k = k + 1
        end
    end

    doc.is_edited = true
    local page = doc._document:openPage(pageno)
    local ctx = page.ctx
    local pdf_page = ffi.cast("pdf_page*", page.page)
    local annot = W.mupdf_pdf_create_annot(ctx, pdf_page, InkAnnot.PDF_ANNOT_INK)
    if annot ~= nil then
        W.mupdf_pdf_set_annot_ink_list(ctx, annot, n, counts, vertices)
        local color = ffi.new("float[3]")
        color[0] = opts.color.r / 255
        color[1] = opts.color.g / 255
        color[2] = opts.color.b / 255
        W.mupdf_pdf_set_annot_color(ctx, annot, 3, color)
        W.mupdf_pdf_set_annot_border_width(ctx, annot, opts.width or 1.0)
        W.mupdf_pdf_set_annot_opacity(ctx, annot, opts.opacity or 1.0)
        -- Tag the annotation so the eraser can find and delete this exact
        -- stroke's annotation later (stored in /Contents). Only auto-save
        -- passes an id; the manual per-page action leaves /Contents empty.
        if opts.annot_id then
            W.mupdf_pdf_set_annot_contents(ctx, annot, opts.annot_id)
        end
        -- Synthesize the /Rect and /AP appearance stream, so the annotation
        -- renders in any PDF viewer (not just KOReader's geometry renderer).
        W.mupdf_pdf_update_annot(ctx, annot)
    end
    page:close()
    if annot ~= nil then self._pdf_dirty = true end
    doc:resetTileCacheValidity()
    return annot ~= nil
end

-- Collect this page's KOReader text highlights (text selections made with a
-- finger or the text-mode highlighter, stored in the sidecar) so they can be
-- embedded into the PDF as native /Highlight annotations alongside the ink.
function Pencil:getPageTextHighlights(pageno)
    local result = {}
    local annotation = self.ui and self.ui.annotation
    if not (annotation and annotation.annotations) then return result end
    for _, item in ipairs(annotation.annotations) do
        -- A drawable text highlight has page boxes and a drawer style.
        if item.pboxes and item.drawer and item.page == pageno then
            result[#result + 1] = item
        end
    end
    return result
end

-- Write a single KOReader text highlight into the PDF as a native markup
-- annotation (/Highlight, /Underline or /StrikeOut per its drawer). Mirrors
-- writeInkAnnotation: create -> set geometry/color -> pdf_update_annot on the
-- same handle, which synthesizes /Rect + /AP so it renders in any PDF viewer.
-- Returns true on success, or the _checkIfWritable() reason for a read-only file.
function Pencil:writeHighlightAnnotation(pageno, item)
    if not (item.pboxes and #item.pboxes > 0) then return true end
    local doc = self.ui.document
    local can_write = doc:_checkIfWritable()
    if can_write ~= true then return can_write end

    local ffi = InkAnnot.ffi
    local W = InkAnnot.W
    local C = ffi.C

    -- pboxes {x,y,w,h} (page coords) -> fz_quad[], same mapping as KOReader's
    -- _quadpointsFromPboxes (order: ll, lr, ul, ur).
    local n = #item.pboxes
    local quads = ffi.new("fz_quad[?]", n)
    for i = 1, n do
        local b = item.pboxes[i]
        local q = quads[i - 1]
        q.ll.x = b.x;             q.ll.y = b.y + b.h - 1
        q.lr.x = b.x + b.w - 1;   q.lr.y = b.y + b.h - 1
        q.ul.x = b.x;             q.ul.y = b.y
        q.ur.x = b.x + b.w - 1;   q.ur.y = b.y
    end

    local annot_type, opacity = C.PDF_ANNOT_HIGHLIGHT, 0.5
    if item.drawer == "underscore" then
        annot_type, opacity = C.PDF_ANNOT_UNDERLINE, 1.0
    elseif item.drawer == "strikeout" then
        annot_type, opacity = C.PDF_ANNOT_STRIKE_OUT, 1.0
    end

    doc.is_edited = true
    local page = doc._document:openPage(pageno)
    local ctx = page.ctx
    local pdf_page = ffi.cast("pdf_page*", page.page)
    local annot = W.mupdf_pdf_create_annot(ctx, pdf_page, annot_type)
    if annot ~= nil then
        W.mupdf_pdf_set_annot_quad_points(ctx, annot, n, quads)
        local color = ffi.new("float[3]")
        local bb = item.color and Blitbuffer.colorFromName(item.color)
        if bb then
            local rgb = bb:getColorRGB32()
            color[0] = rgb:getR() / 255
            color[1] = rgb:getG() / 255
            color[2] = rgb:getB() / 255
        else
            color[0], color[1], color[2] = 1.0, 1.0, 0.0  -- default yellow
        end
        W.mupdf_pdf_set_annot_color(ctx, annot, 3, color)
        W.mupdf_pdf_set_annot_opacity(ctx, annot, opacity)
        W.mupdf_pdf_update_annot(ctx, annot)  -- generate /Rect + /AP
    end
    page:close()
    if annot ~= nil then self._pdf_dirty = true end
    doc:resetTileCacheValidity()
    return annot ~= nil
end

-- Persist the plugin's in-memory PDF edits (ink/highlights created or deleted
-- this session) to disk with a SINGLE incremental writeDocument, mirroring how
-- KOReader itself batches all annotation edits into one write on close.
--
-- Critically it then clears doc.is_edited, so KOReader's own PdfDocument:close
-- does NOT issue a second writeDocument on the same document handle -- two
-- stacked incremental saves corrupt the xref (MuPDF: "cannot find object").
-- That single write also captures any in-memory highlight edits KOReader made
-- (e.g. via "write highlights into PDF"), so nothing is lost.
-- Returns true if a write happened.
function Pencil:flushPdfEdits()
    if not self._pdf_dirty then return false end
    local doc = self.ui and self.ui.document
    if not (doc and doc.writeDocument) then return false end
    if not (doc._checkIfWritable and doc:_checkIfWritable() == true) then
        return false
    end
    local ok, err = pcall(function() doc:writeDocument() end)
    if not ok then
        logger.err("Pencil: flushPdfEdits writeDocument failed:", err)
        return false
    end
    self._pdf_dirty = false
    doc.is_edited = false  -- prevent KOReader's close from writing again
    logger.info("Pencil: flushed plugin PDF edits (single write)")
    return true
end

-- Older KOReader builds' addMarkupAnnotation (used by the "write highlights
-- into PDF" feature) did NOT synthesize an appearance stream, so a freshly
-- created highlight was a "dirty" PDF annotation with no /AP. Desktop PDF
-- viewers render only /AP, so those highlights were invisible on a Mac
-- (KOReader draws them from geometry, which is why they looked fine on device).
--
-- koreader/koreader-base#2457 (KOReader 2026.07+) makes addMarkupAnnotation
-- call pdf_update_annot itself, so highlights created there already carry an
-- /AP and this pass is a no-op in effect. We keep it for highlights made on
-- older builds and for files highlighted before upgrading, which still have
-- /AP-less markup annotations that only get fixed on the next change.
--
-- We fix this by running pdf_update_annot on the markup annotations of every
-- page that carries a KOReader highlight. MuPDF synthesizes an /AP ONLY for the
-- dirty (newly created) annots and no-ops on ones that already have an
-- appearance -- so we neither miss a new highlight nor rewrite/bloat the file
-- for old ones. We only bother when KOReader recorded an annotation change this
-- session (document.is_edited, set by saveHighlight/deleteHighlight when
-- write-into-PDF is on); the single close flush then writes it out.
function Pencil:ensureHighlightAppearances()
    if not (self.ui and self.ui.paging and InkAnnot) then return end
    local annotation = self.ui.annotation
    if not (annotation and annotation.annotations) then return end
    local doc = self.ui.document
    if not (doc and doc._checkIfWritable and doc:_checkIfWritable() == true) then return end
    -- Nothing changed this session -> nothing to synthesize or rewrite. This is
    -- what keeps us from appending an identical incremental update on every close.
    if not doc.is_edited then return end
    local ffi = InkAnnot.ffi
    local W = InkAnnot.W
    local C = ffi.C

    -- Only markup types get an /AP from update_annot; probe the enum once.
    local ok_types, HL, UL, SO = pcall(function()
        return C.PDF_ANNOT_HIGHLIGHT, C.PDF_ANNOT_UNDERLINE, C.PDF_ANNOT_STRIKE_OUT
    end)
    if not ok_types then return end

    local pages = {}
    for _, item in ipairs(annotation.annotations) do
        if item.drawer and item.page then pages[item.page] = true end
    end

    local tmp = ffi.new("fz_quad[1]")
    local visited = 0
    for pageno in pairs(pages) do
        pcall(function()
            local page = doc._document:openPage(pageno)
            local ctx = page.ctx
            local annot = W.mupdf_pdf_first_annot(ctx, ffi.cast("pdf_page*", page.page))
            while annot ~= nil do
                local t = W.mupdf_pdf_annot_type(ctx, annot)
                if t == HL or t == UL or t == SO then
                    -- pdf_update_annot only synthesizes an /AP when the annot is
                    -- dirty (needs_new_ap). A highlight read back from a freshly
                    -- opened page handle reports clean even when it has no /AP, so
                    -- update_annot would no-op and the highlight stays invisible in
                    -- desktop viewers. Re-set its own quad points (identical
                    -- geometry) to force the dirty flag, then update_annot actually
                    -- builds the appearance. We only get here when a highlight was
                    -- added/removed this session, so this runs at most once per such
                    -- close, not on every close.
                    local qn = W.mupdf_pdf_annot_quad_point_count(ctx, annot)
                    if qn and qn > 0 then
                        local quads = ffi.new("fz_quad[?]", qn)
                        for i = 0, qn - 1 do
                            W.mupdf_pdf_annot_quad_point(ctx, annot, i, tmp)
                            quads[i] = tmp[0]
                        end
                        W.mupdf_pdf_set_annot_quad_points(ctx, annot, qn, quads)
                    end
                    W.mupdf_pdf_update_annot(ctx, annot)
                    visited = visited + 1
                end
                annot = W.mupdf_pdf_next_annot(ctx, annot)
            end
            page:close()
        end)
    end
    -- We reached here only because is_edited was set (a highlight was added or
    -- removed this session), so flush to persist it -- new highlights now carry
    -- an /AP, and any deletion is written through our single close flush.
    self._pdf_dirty = true
    doc:resetTileCacheValidity()
    logger.info("Pencil: refreshed appearance for", visited, "highlight annotation(s)")
end

-- Write the current page's pencil strokes (as ink) and text highlights (as
-- native /Highlight annotations) into the PDF file.
function Pencil:saveCurrentPageToPdf()
    if not self.ui.paging then
        UIManager:show(InfoMessage:new{
            text = _("Saving annotations to the file is only supported for PDF documents."),
            timeout = 3,
        })
        return
    end
    if not InkAnnot then
        UIManager:show(InfoMessage:new{
            text = _("This KOReader build cannot write ink annotations. Update to KOReader 2026.07 or newer."),
        })
        return
    end

    local page = self:getCurrentPage()
    local strokes = self.store:forPage(page)
    local highlights = self:getPageTextHighlights(page)
    if #strokes == 0 and #highlights == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No annotations on this page to save."),
            timeout = 2,
        })
        return
    end

    local saved_ink, saved_hl = 0, 0
    local writable_fail = nil

    -- Pencil strokes -> ink annotations (one per stroke, keeping color/width).
    for _, stroke in ipairs(strokes) do
        if not stroke.embedded then
            local points = self:strokeToPagePoints(stroke)
            if #points >= 1 then
                local opts = self:strokeToInkOpts(stroke)
                opts.annot_id = stroke.annot_id or self:nextAnnotId()
                local ok, res = pcall(function()
                    return self:writeInkAnnotation(page, { points }, opts)
                end)
                if ok and res == true then
                    -- Tag + mark embedded, same as auto-save, so the two never
                    -- create duplicate annotations for one stroke.
                    stroke.embedded = true
                    stroke.annot_id = opts.annot_id
                    saved_ink = saved_ink + 1
                elseif ok then
                    writable_fail = res  -- read-only file
                else
                    logger.warn("Pencil: writeInkAnnotation failed:", res)
                end
            end
        end
    end

    -- Text highlights -> native markup annotations (with appearance streams).
    for _, item in ipairs(highlights) do
        local ok, res = pcall(function()
            return self:writeHighlightAnnotation(page, item)
        end)
        if ok and res == true then
            saved_hl = saved_hl + 1
        elseif ok then
            writable_fail = res  -- read-only file
        else
            logger.warn("Pencil: writeHighlightAnnotation failed:", res)
        end
    end

    local saved = saved_ink + saved_hl
    if saved == 0 then
        UIManager:show(InfoMessage:new{
            text = writable_fail
                and _("The PDF file is not writable, so annotations can't be saved.")
                or _("Failed to save annotations to the PDF."),
            timeout = 3,
        })
        return
    end

    -- The annotations are now in the in-memory document (visible immediately),
    -- but the actual file write is DEFERRED to a single write when the book is
    -- closed (see flushPdfEdits / onCloseDocument). Writing here as well would
    -- stack a second incremental save on the close write and corrupt the xref.
    -- Embedded strokes are auto-suppressed from the overlay (paintTo), so there's
    -- no double-draw to clean up and no prompt to remove them.
    UIManager:setDirty(self.view, "ui")

    local msg
    if saved_ink > 0 and saved_hl > 0 then
        msg = T(_("Added %1 pencil stroke(s) and %2 highlight(s) to this page."), saved_ink, saved_hl)
    elseif saved_ink > 0 then
        msg = T(_("Added %1 pencil stroke(s) to this page."), saved_ink)
    else
        msg = T(_("Added %1 highlight(s) to this page."), saved_hl)
    end
    UIManager:show(InfoMessage:new{
        text = msg .. "\n\n" .. _("They'll be written into the PDF file when you close the book."),
        timeout = 3,
    })
end

-- Generate a process-unique tag for an embedded ink annotation. Stored in the
-- annotation's /Contents and on the stroke, so the eraser can pair the two up.
function Pencil:nextAnnotId()
    self._annot_seq = (self._annot_seq or 0) + 1
    return string.format("kop-ink-%d-%d-%d", os.time(), self._annot_seq, math.random(1000, 9999))
end

-- Tag prefix carried in each embedded ink annotation's /Contents. Lets us
-- recognise (and only ever delete) annotations this plugin created.
local INK_TAG_PREFIX = "kop-ink-"

-- Delete every plugin-tagged ink annotation on the already-open pdf_page whose
-- /Contents tag is NOT in keep_ids (a set of tags to preserve). Foreign ink
-- (any annotation without our prefix) is never touched. Returns count deleted.
function Pencil:_pruneInkAnnotsOnPage(ctx, pdf_page, keep_ids)
    local ffi = InkAnnot.ffi
    local W = InkAnnot.W
    local deleted = 0
    local annot = W.mupdf_pdf_first_annot(ctx, pdf_page)
    while annot ~= nil do
        -- Grab next before a possible delete unlinks the current one.
        local next_annot = W.mupdf_pdf_next_annot(ctx, annot)
        if W.mupdf_pdf_annot_type(ctx, annot) == InkAnnot.PDF_ANNOT_INK then
            local cptr = W.mupdf_pdf_annot_contents(ctx, annot)
            local tag = cptr ~= nil and ffi.string(cptr) or ""
            if tag:sub(1, #INK_TAG_PREFIX) == INK_TAG_PREFIX and not keep_ids[tag] then
                W.mupdf_pdf_delete_annot(ctx, pdf_page, annot)
                deleted = deleted + 1
            end
        end
        annot = next_annot
    end
    return deleted
end

-- Remove the baked-in ink annotations for the given (just-erased) strokes.
-- Self-healing: on each affected page it keeps only the annotations claimed by
-- strokes that are *still* present, and deletes every other plugin-tagged ink
-- annotation on that page (so orphans/duplicates from earlier sessions get
-- cleaned up too). Writes the file once if anything changed, and clears the
-- erased strokes' embedded state so an undo restores them as normal overlay
-- strokes rather than invisible orphans. Returns the number of annotations
-- deleted.
function Pencil:deleteEmbeddedAnnotationsFor(strokes)
    if not (self.ui and self.ui.paging and InkAnnot) then return 0 end

    -- Which pages had an embedded stroke erased?
    local affected = {}
    local any = false
    for _, stroke in ipairs(strokes) do
        if stroke.embedded and stroke.page then
            affected[stroke.page] = true
            any = true
        end
    end
    if not any then return 0 end

    local doc = self.ui.document
    if not (doc and doc._checkIfWritable and doc:_checkIfWritable() == true) then
        return 0
    end
    local ffi = InkAnnot.ffi

    -- For each affected page, the tags we must keep = annot_ids of embedded
    -- strokes still in the live list on that page.
    local deleted = 0
    for pageno in pairs(affected) do
        local keep_ids = {}
        for _, stroke in ipairs(self.store.strokes) do
            if stroke.page == pageno and stroke.embedded and stroke.annot_id then
                keep_ids[stroke.annot_id] = true
            end
        end
        local ok, res = pcall(function()
            local page = doc._document:openPage(pageno)
            local n = self:_pruneInkAnnotsOnPage(page.ctx, ffi.cast("pdf_page*", page.page), keep_ids)
            page:close()
            return n
        end)
        if ok then
            deleted = deleted + res
        else
            logger.warn("Pencil: prune ink failed on page", pageno, res)
        end
    end

    if deleted > 0 then
        -- In-memory delete only; the disk write is deferred to flushPdfEdits()
        -- on close (one write per session).
        doc.is_edited = true
        self._pdf_dirty = true
        doc:resetTileCacheValidity()
        -- The erased ink is a baked PDF annotation, so its pixels live in the
        -- rendered page tile, not our overlay. The eraser gesture's own
        -- refreshFast only repaints the overlay with a fast waveform and leaves
        -- the baked ink ghosting on screen (which looks like "erase did
        -- nothing"). Schedule a proper "ui" refresh -- like KOReader's own
        -- deleteHighlight -- so the page tile is regenerated from the now-pruned
        -- in-memory doc and the ink actually disappears without a page turn.
        UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
        logger.info("Pencil: removed", deleted, "embedded ink annotation(s) via eraser (deferred write)")
    end

    -- Drop the embedded state on every erased stroke that had one (even if its
    -- annotation was already gone): an undo should bring it back as a normal
    -- redrawn overlay stroke that re-embeds cleanly on the next close.
    for _, stroke in ipairs(strokes) do
        if stroke.embedded or stroke.annot_id then
            stroke.embedded = nil
            stroke.annot_id = nil
        end
    end
    return deleted
end

-- Silently embed every not-yet-embedded pencil stroke into the PDF as native
-- ink annotations, then write the file once. Used by the "auto-save on close"
-- option. Unlike the manual per-page action it:
--   * covers all pages (relies on the plugin's fixed page-fit layout so the
--     live screen->page transform maps each stroke's local coords correctly),
--   * marks each embedded stroke so re-runs / re-opens never duplicate it,
--   * shows no dialogs and does not offer to remove the overlay (embedded
--     strokes stop being drawn by paintTo instead — see the `embedded` skip).
-- Text highlights are intentionally left out (KOReader keeps drawing its own
-- copy from the sidecar, which would double a baked-in /Highlight); those stay
-- on the manual per-page action. Returns the number of strokes embedded.
function Pencil:autoSaveInkToPdf()
    if not (self.ui and self.ui.paging and InkAnnot) then return 0 end

    local doc = self.ui.document
    if not (doc and doc._checkIfWritable and doc:_checkIfWritable() == true) then
        return 0
    end

    local just_embedded = {}
    local touched_pages = {}
    for _, stroke in ipairs(self.store.strokes) do
        if not stroke.embedded and stroke.page then
            local points = self:strokeToPagePoints(stroke)
            if #points >= 1 then
                local opts = self:strokeToInkOpts(stroke)
                opts.annot_id = stroke.annot_id or self:nextAnnotId()
                local ok, res = pcall(function()
                    return self:writeInkAnnotation(stroke.page, { points }, opts)
                end)
                if ok and res == true then
                    stroke.embedded = true
                    stroke.annot_id = opts.annot_id
                    just_embedded[#just_embedded + 1] = stroke
                    touched_pages[stroke.page] = true
                elseif not ok then
                    logger.warn("Pencil: autoSave writeInkAnnotation failed:", res)
                end
            end
        end
    end

    if #just_embedded == 0 then return 0 end

    -- Self-heal: on every page we just touched, drop any plugin-tagged ink
    -- annotation that isn't claimed by a current stroke (orphans/duplicates
    -- from an interrupted earlier session), so the file mirrors the live list.
    for pageno in pairs(touched_pages) do
        local keep_ids = {}
        for _, stroke in ipairs(self.store.strokes) do
            if stroke.page == pageno and stroke.embedded and stroke.annot_id then
                keep_ids[stroke.annot_id] = true
            end
        end
        pcall(function()
            local page = doc._document:openPage(pageno)
            self:_pruneInkAnnotsOnPage(page.ctx, InkAnnot.ffi.cast("pdf_page*", page.page), keep_ids)
            page:close()
        end)
    end

    -- NOTE: no writeDocument here. All mutations are in-memory; the single disk
    -- write happens in flushPdfEdits() (called on close after this), matching
    -- KOReader's own one-write-on-close model. Rollback of the embedded flags
    -- on a failed write is handled by the caller (onCloseDocument).
    self._pdf_dirty = true
    self._auto_embedded_this_close = just_embedded
    logger.info("Pencil: staged", #just_embedded, "stroke(s) for embedding on close")
    return #just_embedded
end

-- Screen-space refresh rect (x, y, w, h) covering a set of just-deleted
-- strokes, expanded by the eraser width and clamped to the screen. Returns
-- nil when no stroke has geometry, signalling the caller to refresh fully.
function Pencil:erasedStrokesRefreshRect(strokes)
    return PencilStrokes.erasedRefreshRect(strokes,
        self.tool:getToolSettings(TOOL_ERASER).width or 20, Screen:getWidth(), Screen:getHeight())
end

-- Erase strokes at a given point
-- Returns array of deleted strokes (for undo), or nil if none
-- Drop removed strokes from each group's stroke_indices and renumber the
-- rest to match self.store.strokes after table.remove.
-- @param removed array of removed stroke indices (any order)
function Pencil:shiftGroupStrokeIndices(removed)
    local sorted = {}
    for i, idx in ipairs(removed) do sorted[i] = idx end
    table.sort(sorted)
    local removed_set = {}
    for _, idx in ipairs(sorted) do removed_set[idx] = true end
    for _, group in ipairs(self.annotation_groups or {}) do
        if group.stroke_indices then
            local kept = {}
            for _, idx in ipairs(group.stroke_indices) do
                if not removed_set[idx] then
                    local shift = 0
                    for _, r in ipairs(sorted) do
                        if r < idx then shift = shift + 1 else break end
                    end
                    table.insert(kept, idx - shift)
                end
            end
            group.stroke_indices = kept
        end
    end
end

-- End of a stylus erase gesture: do the work deferred while erasing.
-- Must run before saveStrokes so the saved groups match the strokes.
function Pencil:finishEraseGesture()
    self.tool.eraser_contact = nil
    self.highlight_box_cache = nil
    self:rebuildStaleGroups()
end

-- Repaint after strokes were erased and refresh only the area they covered.
-- @param deleted array of erased strokes
-- @param fast use the fast waveform instead of the UI one
function Pencil:refreshAfterErase(deleted, fast)
    self.view:paintTo(Screen.bb, 0, 0)
    self:paintTo(Screen.bb, 0, 0)
    local bbox, margin = nil, 0
    for _, stroke in ipairs(deleted) do
        local b = PencilGeometry.computeStrokeBbox(stroke)
        if b then
            bbox = bbox and PencilGeometry.bboxUnion(bbox, b) or b
        end
        margin = math.max(margin, stroke.width or 0)
    end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local x, y, w, h = 0, 0, sw, sh
    if bbox then
        bbox = PencilGeometry.bboxClampToScreen(PencilGeometry.bboxExpand(bbox, margin + 2), sw, sh)
        x, y = math.floor(bbox.x0), math.floor(bbox.y0)
        w, h = math.ceil(bbox.x1) - x, math.ceil(bbox.y1) - y
    end
    if fast then
        Screen:refreshFast(x, y, w, h)
    else
        Screen:refreshUI(x, y, w, h)
    end
end

function Pencil:eraseAtPoint(x, y, page, defer_groups)
    -- Only strokes on the visible pages can be erased. Legacy screen-space
    -- strokes are only drawn on the current page, so they're only erasable there.
    local pages = self.ui and self.ui.paging and self:getVisiblePages() or { page }
    local deleted, indices = self.store:eraseAtPoint(x, y, pages,
        self.tool:getToolSettings(TOOL_ERASER).width,
        function(stroke, p)
            return stroke.page_points and self:syncStrokeToView(stroke)
                or (not stroke.page_points and p == page)
        end)
    if not deleted then return nil end

    if defer_groups then
        -- Rebuilding groups re-creates every group bookmark in the book,
        -- far too slow to do per eraser sample. Keep group indices valid
        -- now and rebuild once in finishEraseGesture.
        self:shiftGroupStrokeIndices(indices)
        self.groups_stale = true
    else
        self:rebuildAnnotationGroups()
    end
    -- Delete the baked-in PDF ink annotations for any embedded strokes we
    -- just erased. Done HERE (the single choke point every eraser input
    -- path funnels through) rather than at the various gesture-end sites,
    -- so it works for the stylus-eraser, hardware-button and touch paths
    -- alike. In-memory delete + tile refresh; the disk write is deferred to
    -- flushPdfEdits() on close.
    self:deleteEmbeddedAnnotationsFor(deleted)
    return deleted
end

-- Render a complete stroke
function Pencil:renderStroke(bb, stroke)
    self.stroke_render_ctx.night_mode = Screen.night_mode
    PencilStrokes.render(bb, stroke, self.stroke_render_ctx)
end

-- View module paintTo method - called by ReaderView during repaints.
-- When the captureGroupImage routine asks ReaderView to repaint into our
-- offscreen buffer, this method is invoked recursively as part of the view
-- module loop; the _capturing guard suppresses re-entry so we can paint the
-- group's strokes deliberately onto the captured page background.
function Pencil:paintTo(bb, x, y)
    if self._capturing then return end

    local page = self:getCurrentPage()
    local current_rot = Screen:getRotationMode()

    -- Backfill XPointers for legacy groups before we filter, so the
    -- rotation-aware page resolution below sees them.
    self:backfillGroupXPointers()

    -- Identify groups whose captured-image rotation no longer matches the
    -- current screen rotation. Their strokes will draw in the wrong place,
    -- so we skip them and draw a badge instead. For EPUB we match by the
    -- group's XPointer re-resolved to the current pagination, since the
    -- saved group.page would be stale across rotations.
    --
    -- Suppression: if any group on this page renders natively at the
    -- current rotation (i.e. matches current_rot, or pre-dates the feature
    -- entirely), we hide badges for OTHER stale groups on the same page so
    -- the view isn't cluttered with badges next to a visible annotation.
    -- Re-rotate to see the suppressed annotation.
    local stale_indices = nil
    local stale_groups = nil
    local groups_on_page = 0
    local groups_with_image = 0
    local has_native_annotation = false
    for _, group in ipairs(self.annotation_groups) do
        local gpage = self:getGroupCurrentPage(group)
        if gpage == page then
            groups_on_page = groups_on_page + 1
            if group.image_path then
                groups_with_image = groups_with_image + 1
            end
            if group.image_rotation == nil
                    or group.image_rotation == current_rot
                    or self:isGroupPageAnchored(group) then
                -- Renders natively (same rotation as capture, or legacy group
                -- without rotation info — render strokes as-is).
                has_native_annotation = true
            elseif group.image_path then
                stale_groups = stale_groups or {}
                stale_groups[#stale_groups + 1] = group
                stale_indices = stale_indices or {}
                for _, idx in ipairs(group.stroke_indices or {}) do
                    stale_indices[idx] = true
                end
            end
        end
    end
    if has_native_annotation then
        -- Drop badges entirely; native-rotation strokes will render below.
        stale_groups = nil
        stale_indices = nil
    end
    local stale_count = stale_groups and #stale_groups or 0
    if not self._last_paint_log
            or self._last_paint_log.page ~= page
            or self._last_paint_log.rot ~= current_rot
            or self._last_paint_log.on_page ~= groups_on_page
            or self._last_paint_log.with_image ~= groups_with_image
            or self._last_paint_log.stale ~= stale_count
            or self._last_paint_log.native ~= has_native_annotation then
        logger.info("Pencil: paintTo page=", page, " rot=", current_rot,
            " groups_on_page=", groups_on_page,
            " with_image=", groups_with_image,
            " native=", tostring(has_native_annotation),
            " badges=", stale_count)
        self._last_paint_log = {
            page = page,
            rot = current_rot,
            on_page = groups_on_page,
            with_image = groups_with_image,
            stale = stale_count,
            native = has_native_annotation,
        }
    end

    -- Render saved strokes for the visible pages (skipping stale ones).
    -- Page-anchored (PDF) strokes are valid in any rotation, so they are
    -- never treated as stale; legacy screen-space strokes only draw on the
    -- current page.
    for _, p in ipairs(self:getVisiblePages()) do
        for _, idx in ipairs(self.store.page_strokes[p] or {}) do
            local stroke = self.store.strokes[idx]
            -- Skip strokes already embedded into the PDF: MuPDF renders the
            -- baked-in ink annotation, so drawing our overlay copy too would
            -- double it (and it wouldn't rotate correctly).
            if stroke and not stroke.embedded then
                if stroke.page_points then
                    if self:syncStrokeToView(stroke) then
                        self:renderStroke(bb, stroke)
                    end
                elseif p == page and not (stale_indices and stale_indices[idx]) then
                    self:renderStroke(bb, stroke)
                end
            end
        end
    end

    -- Draw rotation-mismatch badges over the spots where the strokes would
    -- have appeared. Tapping a badge opens the saved image.
    if stale_groups then
        for _, group in ipairs(stale_groups) do
            self:renderRotationBadge(bb, group)
        end
    end

    -- Render current stroke being drawn (only if on current page)
    if self.current_stroke and self.current_stroke.page == page then
        self:renderStroke(bb, self.current_stroke)
    end

    if self.notes and #self.notes > 0 then
        self:drawNoteMarkers(bb)
    end

    if self.lasso and self.lasso.strokes then
        self:drawLassoOverlay(bb)
    end
end

function Pencil:getStrokesFilePath()
    return PencilStrokes.getFilePath(self.ui and self.ui.doc_settings)
end

-- Load strokes from our own file
function Pencil:loadStrokes()
    self.notes = {}
    local doc_settings = self.ui and self.ui.doc_settings
    local filepath = PencilStrokes.migrateFileIfNeeded(doc_settings)
    logger.info("Pencil: loadStrokes - filepath =", filepath)

    local status, data = self.store:load(filepath, {
        tool_settings = self.stroke_render_ctx.tool_settings,
        available_colors = self.available_colors,
    })

    if status == "error" then
        self.annotation_groups = {}
    elseif status == "ok" then
        self.notes = self:notesFromSaved(data.notes)

        -- Load annotation groups or bootstrap from v1 data
        if data.annotation_groups and #data.annotation_groups > 0 then
            self.annotation_groups = data.annotation_groups
            logger.info("Pencil: loaded", #self.annotation_groups, "annotation groups")
        else
            -- v1 data or no groups — bootstrap by running grouping on all strokes
            -- skip_bookmark=true because annotation module isn't ready yet during load
            logger.info("Pencil: bootstrapping annotation groups from strokes")
            self.annotation_groups = {}
            local sorted = {}
            for i, stroke in ipairs(self.store.strokes) do
                table.insert(sorted, { idx = i, dt = stroke.datetime or 0 })
            end
            table.sort(sorted, function(a, b) return a.dt < b.dt end)
            for _, entry in ipairs(sorted) do
                self:assignStrokeToGroup(entry.idx, true)
            end
        end

        PencilStrokes.rememberFilePath(doc_settings, filepath)
    end
end

-- Save strokes (and the annotation groups and notes) to our own file
function Pencil:saveStrokes()
    local filepath = self:getStrokesFilePath()
    if self.store:save(filepath, {
        annotation_groups = self.annotation_groups,
        notes = self:notesToSaveable(),
    }) then
        PencilStrokes.rememberFilePath(self.ui and self.ui.doc_settings, filepath)
    end
end

-- Handle document close
function Pencil:onCloseDocument()
    logger.info("Pencil: onCloseDocument called, strokes count =", self.store:count())

    -- Cancel any pending refresh
    self:cancelPendingRefresh()
    -- Drop any scheduled debounced save - we save unconditionally below.
    self:cancelPendingSave()
    self.dirty_groups = nil

    -- Save any in-progress stroke
    if self.current_stroke and #self.current_stroke.points >= 2 then
        logger.info("Pencil: saving in-progress stroke before close")
        self:anchorStrokeToPage(self.current_stroke)
        self.store:add(self.current_stroke)
        self.current_stroke = nil
    end

    self:teardownPenInput()
    if self.note_canvas then
        self:closeNoteCanvas(false)
    end
    self:clearLasso()
    self:rebuildStaleGroups()

    -- Run any pending deferred image captures synchronously before close so
    -- we don't lose a fresh annotation. Must happen before the final save so
    -- new image_path / image_rotation fields land in the strokes file.
    self:flushPendingCaptures()

    -- Final bookmark sync before close
    self:syncAllBookmarks()

    -- Auto-save pencil ink into the PDF file (opt-in). This only stages the
    -- annotations in memory; the actual disk write is the single flushPdfEdits()
    -- below. Must run while the document is still open/writable.
    if self.auto_save_pdf then
        local ok, err = pcall(function() self:autoSaveInkToPdf() end)
        if not ok then
            logger.err("Pencil: autoSaveInkToPdf error:", err)
        end
    end

    -- Give KOReader's text highlights an appearance stream so they're visible in
    -- desktop PDF viewers too (KOReader writes them without one). Staged only;
    -- the flush below writes everything in one pass.
    local hok, herr = pcall(function() self:ensureHighlightAppearances() end)
    if not hok then logger.err("Pencil: ensureHighlightAppearances error:", herr) end

    -- Single, final write of any in-memory PDF edits the plugin made this
    -- session (auto-saved ink, erased ink, manual per-page saves). One
    -- incremental write, then is_edited is cleared so KOReader's own close
    -- doesn't stack a second write (which corrupts the xref). Runs regardless
    -- of the auto-save toggle, since the eraser/manual paths also set dirty.
    local ok, ferr = pcall(function() self:flushPdfEdits() end)
    if not ok then logger.err("Pencil: flushPdfEdits error:", ferr) end
    -- flushPdfEdits clears _pdf_dirty on a successful write; if it's still set,
    -- the write didn't happen, so un-embed the strokes we staged this close (the
    -- sidecar must not claim they're in a file that never received them).
    if self._pdf_dirty and self._auto_embedded_this_close then
        for _, stroke in ipairs(self._auto_embedded_this_close) do
            stroke.embedded = nil
            stroke.annot_id = nil
        end
    end
    self._auto_embedded_this_close = nil

    -- Always save strokes on close (even if empty, to clear any previous data)
    logger.info("Pencil: saving strokes on document close")
    self:saveStrokes()

    -- Clear state
    self.eraser_deleted = nil
    self.store:clearHistory()

    if _active_pencil == self then _active_pencil = nil end
end

function Pencil:onSuspend()
    -- Same idea as onCloseDocument: don't lose a freshly drawn annotation
    -- across a device sleep.
    self:flushPendingCaptures()
end

-- Handle reader ready (document fully loaded)
function Pencil:onReaderReady()
    logger.info("Pencil: onReaderReady called")
    logger.info("Pencil: doc_settings available:", self.ui.doc_settings ~= nil)
    if self.ui.doc_settings then
        logger.info("Pencil: sidecar_dir:", self.ui.doc_settings.doc_sidecar_dir)
    end

    -- Force reload strokes (in case they weren't loaded in init)
    if self.store:count() == 0 then
        self:loadStrokes()
    end
    logger.info("Pencil: after loadStrokes, strokes count =", self.store:count(),
        "groups =", #self.annotation_groups)

    -- Sync annotation group bookmarks now that UI modules are ready
    self:syncAllBookmarks()

    -- Re-setup touch zones if enabled
    if self:isEnabled() and not self.touch_zones_registered then
        self:setupPenInput()
    end

    -- Lazy backfill: any group on the currently visible page that's missing
    -- an image (e.g. created in an older version, or capture was lost mid-
    -- session) gets re-captured now that ReaderView can paint the page.
    self:backfillMissingImages()
end

-- Handle read settings (document opened) - backup in case onReaderReady not called
function Pencil:onReadSettings(config)
    logger.dbg("Pencil: onReadSettings called")
    -- Only load if not already loaded
    if self.store:count() == 0 then
        self:loadStrokes()
    end
    -- Re-setup touch zones if enabled (in case they were torn down)
    if self:isEnabled() and not self.touch_zones_registered then
        self:setupPenInput()
    end
end

-- Handle page changes (paging mode)
function Pencil:onPageUpdate(pageno)
    self:clearLasso()
    -- Clear any in-progress stroke when page changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        -- Save the stroke before clearing. The inline saveStrokes below covers
        -- everything in self.store.strokes, so drop any queued debounced save first.
        self:cancelPendingSave()
        self:anchorStrokeToPage(self.current_stroke)
        self.store:pushUndo({ type = "add", stroke_idx = self.store:add(self.current_stroke) })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        -- No in-progress stroke, but a debounced save may still be queued from
        -- earlier strokes on this page. Persist it before navigating away.
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self.eraser_deleted = nil
    -- Re-schedule capture for any group on the newly visible page that's
    -- still missing an image (e.g. user turned past the original page before
    -- the debounce fired).
    self:backfillMissingImages()
end

-- Handle position changes (rolling/scroll mode)
function Pencil:onUpdatePos()
    -- Clear any in-progress stroke when position changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        self:cancelPendingSave()
        self:anchorStrokeToPage(self.current_stroke)
        self.store:pushUndo({ type = "add", stroke_idx = self.store:add(self.current_stroke) })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self.eraser_deleted = nil
    self:backfillMissingImages()
end

return Pencil
