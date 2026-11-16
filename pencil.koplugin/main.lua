--[[--
Pencil plugin for KOReader.
Enables freehand drawing and annotation with stylus on supported devices.

@module koplugin.pencil
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")

local Geom = require("ui/geometry")
local PencilUI = require("ui")
local PencilInput = require("pencilinput")

-- Some Android file managers flatten the plugin folder on extraction; accept
-- geometry.lua next to main.lua as well as in lib/.
local ok_geom, PencilGeometry = pcall(require, "lib/geometry")
if not ok_geom then
    PencilGeometry = require("geometry")
end
local PencilTool = require("lib/penciltool")
local PencilStrokes = require("lib/pencilstrokes")
local PencilNotes = require("lib/pencilnotes")
local PencilLasso = require("lib/pencillasso")
local PencilPDF = require("lib/pencilpdf")
local Screen = Device.screen
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local MyScript = require("lib/myscript")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local time = require("ui/time")
local function trimString(v) return tostring(v or ""):match("^%s*(.-)%s*$") end
local util = require("ffi/util")

-- Check if device supports touch input
if not Device:isTouchDevice() then
    return { disabled = true }
end

-- Tool types (managed by lib/penciltool.lua)
local TOOL_PEN = PencilTool.TOOLS.PEN
local TOOL_HIGHLIGHTER = PencilTool.TOOLS.HIGHLIGHTER
local TOOL_ERASER = PencilTool.TOOLS.ERASER
local LINUX_TOOLTYPE = PencilTool.LINUX_TOOLTYPE

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

local Pencil = InputContainer:extend{
    PALM_GRACE_MS = PALM_GRACE_MS,
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
    side_button_used_for_highlight = false,  -- button was used while drawing a highlight
    eraser_touching = false,                 -- eraser role currently touching the screen

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

-- Input methods live in input.lua; public Pencil method names stay unchanged.
Pencil.setupStylusCallback = PencilInput.setupStylusCallback
Pencil.installPalmFilter = PencilInput.installPalmFilter
Pencil.ensureStylusCallback = PencilInput.ensureStylusCallback
Pencil.isPalmSlot = PencilInput.isPalmSlot
Pencil.filterPalmSlots = PencilInput.filterPalmSlots
Pencil.transformCoordinates = PencilInput.transformCoordinates
Pencil.handleStylusSlot = PencilInput.handleStylusSlot
Pencil.routeStylusSlot = PencilInput.routeStylusSlot
Pencil.teardownStylusCallback = PencilInput.teardownStylusCallback

-- Presentation methods live in ui.lua; public Pencil method names stay unchanged.
Pencil.buildHighlighterMenu = PencilUI.buildHighlighterMenu
Pencil.addToMainMenu = PencilUI.addToMainMenu
Pencil.showAnnotationStatus = PencilUI.showAnnotationStatus
Pencil.showColorPicker = PencilUI.showColorPicker
Pencil.showAnnotationHoldMenu = PencilUI.showAnnotationHoldMenu
Pencil.showMyScriptSettingsDialog = PencilUI.showMyScriptSettingsDialog
Pencil.showRecognizedText = PencilUI.showRecognizedText
Pencil.showAnnotationTextEditor = PencilUI.showAnnotationTextEditor
Pencil.showAllRecognizedText = PencilUI.showAllRecognizedText
Pencil.editAllRecognizedText = PencilUI.editAllRecognizedText
Pencil.showGroupImagePreview = PencilUI.showGroupImagePreview

-- PDF export methods live in lib/pencilpdf.lua; public Pencil method names stay unchanged.
for _, name in ipairs({
    "hasInkAnnotSupport", "isPdfDocument", "canExportInk", "writablePdfDoc", "isReflowed",
    "capturePagePoints", "recordPagePoints",
    "strokeToInkOpts", "stageStrokesInk", "settleStagedStrokes",
    "getPageTextHighlights", "pdfHasHighlight", "saveTextHighlightsToPdf", "deleteHighlightFromPdf",
    "flushPdfEdits", "saveCurrentPageToPdf", "nextAnnotId",
    "deleteEmbeddedAnnotationsFor", "applyPendingInkDeletes", "flushPendingEraseToPdf",
    "autoSaveInkToPdf",
}) do
    Pencil[name] = function(self, ...)
        local feature = rawget(self, "pdf_feature")
        if not feature then
            feature = PencilPDF:new{ plugin = self }
            self.pdf_feature = feature
        end
        return feature[name](feature, ...)
    end
end

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
    self.notes_feature = PencilNotes:new{ plugin = self }
    self.lasso_feature = PencilLasso:new{ plugin = self }
    self.pdf_feature = PencilPDF:new{ plugin = self }

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
    local tool = self.tool:togglePenEraser()
    local display_name = tool == TOOL_PEN and _("pencil") or _("eraser")
    self:showToast(T(_("Tool: %1"), display_name), true)
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
    self:showToast(_("Pencil tool: pencil"), true)
    return true
end

function Pencil:onPencilSelectEraser()
    self.tool:setTool(TOOL_ERASER)
    self:showToast(_("Eraser selected"), true)
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

-- Stylus/touch input handling lives in input.lua.
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

    self:noteHighlighterUse(tool)
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
    self:paintTo(Screen.bb)
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

-- Save the current ReaderHighlight selection as a native highlight, in the
-- style chosen in the menu (default: the reader's own highlight style).
-- Used when a held line is turned into a highlight; text selected with the
-- highlighter tool keeps the reader's own style.
-- ReaderHighlight:saveHighlight builds the item from the view's saved_drawer
-- and saved_color, so those are set for the duration of the call and restored
-- afterwards: the reader's own highlight settings are never changed.
-- @return ok, err of the protected call
function Pencil:saveNativeHighlight(rh)
    local drawer, color = self.tool:getNativeHighlightStyle()
    local hl = drawer and self.ui.view and self.ui.view.highlight
    if not hl then
        return pcall(rh.saveHighlight, rh, false)
    end
    local old_drawer, old_color = hl.saved_drawer, hl.saved_color
    hl.saved_drawer, hl.saved_color = drawer, color
    local ok, err = pcall(rh.saveHighlight, rh, false)
    hl.saved_drawer, hl.saved_color = old_drawer, old_color
    return ok, err
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
    -- The style is the reader's default one unless the underline option is on.

    local rh = self.ui.highlight
    rh.selected_text = selected
    local saved, err = self:saveNativeHighlight(rh)
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
        local stroke_idx = self:commitStroke(self.current_stroke)
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
        -- Schedule delayed refresh for clean display after writing stops.
        -- Not when nothing was saved, e.g. a hold that opened the color
        -- picker: a fast refresh over it would grey out its swatches.
        self:scheduleDelayedRefresh()
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

    -- State ReaderHighlight:onHold sets up for onHoldPan's corner scroll
    -- (see extendTextHighlight). The start xpointer is only there in EPUBs.
    rh.selected_text_start_xpointer = word.pos0
    rh.allow_hold_pan_corner_scroll = false
    rh.was_in_some_corner = nil

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

    -- Let ReaderHighlight extend the selection as it does for a finger
    -- long-press drag. In EPUBs, that scrolls on to the next page when the
    -- pen goes into the bottom right corner (back at the top left), so a
    -- highlight can cross pages. Lifting undoes the scroll (rh:clear() in
    -- finishTextHighlight). It returns false when long-press is set to "Do
    -- nothing"; we still highlight then, within the page.
    local ok_pan, handled = pcall(rh.onHoldPan, rh, nil,
        { pos = Geom:new{ x = screen_x, y = screen_y, w = 0, h = 0 } })
    if not ok_pan then
        logger.warn("Pencil: onHoldPan failed:", tostring(handled))
    elseif handled ~= false then
        self:_paintTempSelection()
        return
    end

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
        -- Always the reader's own highlight style: the underline option only
        -- applies to a held line turned into a highlight (underlineTextAbove).
        local ok, err = pcall(rh.saveHighlight, rh, false)
        if not ok then
            logger.warn("Pencil: saveHighlight failed:", tostring(err))
        end
    end

    -- Stop the long-hold timer onHoldPan starts; we don't show its menu.
    if rh and rh._resetHoldTimer then
        pcall(rh._resetHoldTimer, rh, true)
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
    local item = self.ui.annotation.annotations[index]
    local ok = pcall(self.ui.highlight.deleteHighlight, self.ui.highlight, index)
    -- Annotation indices and rendered boxes shift after a removal.
    self.highlight_box_cache = nil
    if ok then
        self._pdf_dirty = true
        -- KOReader only deletes the PDF copy when "write highlights into PDF"
        -- is on, but "Save annotations to PDF (this page)" can put it in the
        -- file with that setting off. Remove whatever copy is still there.
        local dok, derr = pcall(self.deleteHighlightFromPdf, self, item)
        if not dok then logger.warn("Pencil: deleting highlight from PDF failed:", derr) end
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
    -- ReaderUI is the document view itself — anything else is an overlay.
    -- Like getTopmostVisibleWidget, skip widgets marked invisible (transient
    -- decorations that paint but don't capture input, e.g. TrapWidget). Also
    -- skip toasts, which KOReader passes input through, like our own
    -- confirmations (see showToast).
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local widget = stack[i].widget
        if not widget.invisible and not widget.toast then
            return (widget.name or widget.id) ~= "ReaderUI"
        end
    end
    return false
end

-- Show a short confirmation (tool, color, width) as a KOReader notification:
-- a small banner at the top of the screen, out of the writing area. It's a
-- toast, which KOReader passes input through and isOverlayActive skips, so a
-- stroke started while one is showing is drawn in full. Gesture actions pass
-- from_gesture so they follow the reader's notification settings, like other
-- gestures do; the side button and color picker always show theirs.
function Pencil:showToast(text, from_gesture)
    local Notification = require("ui/widget/notification")
    Notification:notify(text, from_gesture and Notification.SOURCE_DISPATCHER
        or Notification.SOURCE_ALWAYS_SHOW)
end

-- Set enabled state (global setting)
function Pencil:setEnabled(enabled)
    G_reader_settings:saveSetting("pencil_annotation_enabled", enabled)
end

-- Drawing with the side button held counts as using it for highlighting, so
-- its release isn't taken for a quick press (which toggles pen/eraser).
function Pencil:noteHighlighterUse(tool)
    if self.side_button_down and tool == TOOL_HIGHLIGHTER then
        self.side_button_used_for_highlight = true
    end
end

-- Handle stylus button press (down event)
-- Highlighter-role button (the side button, or the eraser end when swapped):
-- while it is down the pen highlights (a freehand highlighter stroke, or text
-- with the "Text highlight" option).
function Pencil:onStylusButtonPress()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    self.side_button_down = true
    self.side_button_used_for_highlight = false

    logger.dbg("Pencil: side button pressed")
    return true
end

-- Handle stylus button release (up event)
function Pencil:onStylusButtonRelease()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    local was_down = self.side_button_down
    self.side_button_down = false

    -- If the button was NOT used for highlighting (no drawing while held),
    -- treat it as a quick press to toggle between pen and eraser. (With the
    -- "Eraser click" option the eraser's click does that instead.)
    if was_down and not self.side_button_used_for_highlight
            and not self.tool:isEraserClickMode() then
        logger.dbg("Pencil: side button quick press - toggling pen/eraser")
        self:togglePenEraser()
    else
        logger.dbg("Pencil: highlight complete, back to", self.tool:getTool())
    end

    self.side_button_used_for_highlight = false
    return true
end

-- Toggle between pen and eraser
function Pencil:togglePenEraser()
    self.tool:togglePenEraser()
    self:saveSettings()
    local display_name = self.tool:getTool() == TOOL_PEN and _("pencil") or _("eraser")
    self:showToast(T(_("Tool: %1"), display_name))
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

-- "Eraser click" mode: a click with the eraser role (eraser end touching
-- without dragging, or the eraser button pressed and released) switches
-- between pen and eraser.
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
            self:commitErase(self.eraser_button_deleted)
        end
        self.tool:deactivateEraser()
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
            if clicked and self.tool:isEraserClickMode() then self:onEraserClick() end
            return true
        elseif self.tool.eraser_button_active then
            logger.info("Pencil: eraser input RELEASED:", input)
            -- (Eraser click mode) The side button, when swapped to be the
            -- eraser, is a real button: pressing and releasing it without
            -- touching the screen is a click
            local clicked = self.tool:deactivateEraser(input == PencilTool.INPUT.SIDE_KEY)
            self:endEraserMode()
            if clicked and self.tool:isEraserClickMode() then self:onEraserClick() end
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

-- The strokes an undo/redo is about to remove: undoing an "add", redoing a
-- "delete". Their ink is taken out of the PDF too, if it was saved there.
local function strokesLeaving(self, action, leaving_type)
    if not action or action.type ~= leaving_type then return nil end
    if leaving_type == "add" then
        local stroke = action.stroke or (action.stroke_idx and self.store.strokes[action.stroke_idx])
        return stroke and { stroke } or nil
    end
    return action.strokes
end

function Pencil:undoLastStroke()
    local leaving = strokesLeaving(self, self.store.undo_stack[#self.store.undo_stack], "add")
    if leaving then self:deleteEmbeddedAnnotationsFor(leaving) end
    if self.store:undo(self.stroke_translate) then
        self:afterHistoryChange()
    end
end

function Pencil:redoLastStroke()
    local leaving = strokesLeaving(self, self.store.redo_stack[#self.store.redo_stack], "delete")
    if leaving then self:deleteEmbeddedAnnotationsFor(leaving) end
    if self.store:redo(self.stroke_translate) then
        self:afterHistoryChange()
    end
end

function Pencil:setupPenInput()
    if self.touch_zones_registered then return end

    logger.dbg("Pencil: setting up touch zones")

   -- Setup stylus callback for lowest latency pen capture
    PencilInput.setupStylusCallback(self)
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
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "paging_pan_release",
                "rolling_pan_release",
                "readerhighlight_pan_release",
            },
            handler = function()
                return self:onDrawPanRelease()
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
            handler = function()
                return self:onDrawSwipe()
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
function Pencil:onDrawSwipe()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- If raw input detected pen, block swipe to prevent page turns
    if self.pen_down then return true end

    -- Fallback: check pen input via gesture system's slot data
    local is_pen, _ = self:isPenInput()
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
    local is_pen = select(1, self:isPenInput())
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
        -- New ink's bookmark is only added here, so fold the page corner now
        -- rather than on the next page turn.
        self:refreshDogear()
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

-- Recheck KOReader's dogear (the folded page corner) for the current page.
-- The plugin adds and removes its bookmarks directly in the annotation list,
-- and KOReader only rechecks the dogear on page turns, so without this the
-- corner stays down after the ink it marked is erased.
function Pencil:refreshDogear()
    local bookmark = self.ui and self.ui.bookmark
    local view = self.view
    if not (bookmark and bookmark.setDogearVisibility and bookmark.getCurrentPageNumber
            and view and view.dogear) then
        return
    end
    local was_visible = view.dogear_visible
    local ok, err = pcall(function()
        bookmark:setDogearVisibility(bookmark:getCurrentPageNumber())
    end)
    if not ok then
        logger.warn("Pencil: dogear refresh failed:", err)
        return
    end
    if view.dogear_visible ~= was_visible then
        -- Same refresh KOReader uses when toggling a bookmark by hand.
        UIManager:setDirty(view.dialog, function()
            return "ui", view.dogear:getRefreshRegion()
        end)
    end
end

-- Finish an eraser pass: record it for undo, re-add bookmarks for the ink
-- that survived (erasing rebuilds every group and drops their bookmarks),
-- update the dogear, and save.
function Pencil:commitErase(deleted)
    if not deleted or #deleted == 0 then return end
    self.store:pushUndo({ type = "delete", strokes = deleted })
    -- Every eraser input path ends here, so this is where the strokes' baked
    -- PDF ink is removed: one page-tile refresh per gesture, not per hit.
    self:deleteEmbeddedAnnotationsFor(deleted)
    -- Erasing defers the group rebuild; the bookmarks below need current groups.
    self:rebuildStaleGroups()
    self:flushDirtyGroups()
    self:refreshDogear()
    self:saveStrokes()
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
    -- Check every 100ms for trigger. Store the closure itself, not
    -- scheduleIn's nil return, so cancelColorPickerTimer can unschedule it
    -- (see scheduleDeferredWork).
    local action
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
function Pencil:runHoldMenuAction(action, x, y)
    if action == "undo" then
        self:undoLastStroke()
    elseif action == "redo" then
        self:redoLastStroke()
    elseif action == "lasso" then
        self.lasso_feature:start()
    elseif action == "note" then
        self.notes_feature:openAt(x, y)
    end
end

-- Lasso selection is owned by self.lasso_feature (lib/pencillasso.lua).

-- Shift strokes by (dx, dy) screen pixels; sign = -1 reverses a move.
-- Page-anchored strokes move in page space by pdeltas[i] (computed from the
-- view zoom on the first move and reused for undo/redo). Returns pdeltas.
function Pencil:translateStrokes(strokes, dx, dy, pdeltas, sign)
    return PencilStrokes.translate(strokes, dx, dy, pdeltas, sign, self.stroke_view)
end

-- Notes are owned by self.notes_feature (lib/pencilnotes.lua).

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
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput()
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

    self:noteHighlighterUse(effective_tool)

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
function Pencil:isPenInput()
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
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput()
    if not is_pen then
        return false
    end

    local page = self:getCurrentPage()
    local effective_tool = self.tool:getEffectiveTool(is_eraser_end, is_highlighter, self.side_button_down)
    self:noteHighlighterUse(effective_tool)
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

    local stroke_idx = self:commitStroke(stroke)
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
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput()
    if not is_pen then return false end

    local page = self:getCurrentPage()
    local effective_tool = self.tool:getEffectiveTool(is_eraser_end, is_highlighter, self.side_button_down)
    self:noteHighlighterUse(effective_tool)

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
function Pencil:onDrawPanRelease()
    if not self:isEnabled() or self:isOverlayActive() then return false end

    -- Let finger releases be handled by gesture system
    local is_pen, is_eraser_end, is_highlighter = self:isPenInput()
    if not is_pen then
        return false
    end

    local effective_tool = self.tool:getEffectiveTool(is_eraser_end, is_highlighter, self.side_button_down)

    self:noteHighlighterUse(effective_tool)

    -- Log pan end to debug file
    self:writeDebugLog(string.format("  is_eraser_end=%s eraser_tool_active=%s effective_tool=%s",
        tostring(is_eraser_end), tostring(self.tool.eraser_tool_active), effective_tool))

    -- Handle eraser pan release (raw input doesn't handle eraser)
    if effective_tool == TOOL_ERASER then
        if self.eraser_deleted and #self.eraser_deleted > 0 then
            -- Add deleted strokes to undo stack
            self:commitErase(self.eraser_deleted)
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
        local stroke_idx = self:commitStroke(self.current_stroke)
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
    if stroke.page_points ~= nil then return false end
    -- Only real .pdf files are anchored, and not while reflowed
    -- (recordPagePoints marks those).
    if not (self.ui and self.ui.paging and self:isPdfDocument()) or self:isReflowed() then
        stroke._anchor_page, stroke._anchor_zoom = nil, nil
        stroke._anchor_ox, stroke._anchor_oy = nil, nil
        return false
    end
    if not stroke._anchor_zoom and stroke.points and stroke.points[1] then
        self:captureStrokeAnchor(stroke, stroke.points[1].x, stroke.points[1].y)
    end
    return PencilStrokes.anchorToPage(stroke)
end

-- Add a finished stroke to the list and the page index, and record its page
-- coordinates for PDF export while its page is still the one on screen
-- (skipped when `view_moved`). Every drawing path commits through here.
-- Returns the stroke's index.
function Pencil:commitStroke(stroke, view_moved)
    -- Anchor first: it can change the page the stroke belongs to
    local anchored = self:anchorStrokeToPage(stroke)
    local idx = self.store:add(stroke)
    if not anchored and not view_moved then self:recordPagePoints(stroke) end
    return idx
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

        -- Drop bookmarks still queued for the old groups. Without this, ink
        -- erased before its queued bookmark was added left a bookmark (and the
        -- page's folded corner) behind. Regrouping below re-queues every group
        -- that still has ink.
        self.dirty_groups = nil

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

    NetworkMgr:runWhenOnline(
        function()
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

            -- Run recognition in a subprocess to avoid blocking UI
            local _pid, pipe_fd = util.runInSubProcess(
                function(_child_pid, write_fd)
                    local text, error_value = self:recognizeGroupWithClient(client, group)
                    local result = { text = text, error_value = error_value }
                    -- Serialize result as JSON for communication
                    local json = require("json")
                    local output = json.encode(result)
                    util.writeToFD(write_fd, output, true)
                end,
                true, false)

        if pipe_fd then
            local json = require("json")
            local function check_pipe()
                local avail = util.getNonBlockingReadSize(pipe_fd)
                if avail and avail > 0 then
                    -- Now safe to read all and block, since data is ready
                    local output = util.readAllFromFD(pipe_fd)
                    local result = json.decode(output)
                    if not result.text then
                        local message = result.error_value and result.error_value.message or result.error_value
                        UIManager:show(InfoMessage:new{
                            text = T(_("Recognition failed: %1"), tostring(message)),
                        })
                        return
                    end
                    group.transcription = result.text
                    group.transcription_language = self.myscript_language
                    self:saveStrokes()
                    self:showRecognizedText(result.text, group)
                else
                    -- Schedule next check (using KOReader's timer)
                    UIManager:scheduleIn(0.1, check_pipe)
                end
            end
            check_pipe()
        else
            UIManager:show(InfoMessage:new{
                text = _("Failed to start recognition subprocess."),
            })
        end
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

    for _, group in ipairs(groups) do
        parts[#parts + 1] =
            T(gettext("Page %1"), self:getPageNumber(group.page))
            .. "\n"
            .. trimString(group.transcription)
    end

    return table.concat(parts, "\n\n")
end

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

    -- The strokes' baked PDF ink goes too (undo then restores them as overlay
    -- ink that re-embeds on the next save).
    self:deleteEmbeddedAnnotationsFor(deleted_strokes)
    self:rebuildAnnotationGroups()
    self:flushDirtyGroups()
    self:refreshDogear()
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
    -- Remove every stroke's ink from the PDF as well.
    self:deleteEmbeddedAnnotationsFor(self.store.strokes)
    self.store:clearAll()
    self.annotation_groups = {}
    self:refreshDogear()
    self:saveStrokes()
    -- Belt-and-suspenders: any leftover files get reaped.
    self:purgeOrphanImages()

    self:repaintReader()
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
    self:paintTo(Screen.bb)
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
    -- Embedded PDF ink for these strokes is removed once, at pen-up, by
    -- commitErase (each removal regenerates the page tile, which would
    -- flash the e-ink panel on every hit mid-gesture).
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
function Pencil:paintTo(bb)
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
            -- Skip strokes embedded (or staged) into the PDF: MuPDF renders the
            -- baked-in ink annotation, so drawing our overlay copy too would
            -- double it (and it wouldn't rotate correctly).
            if stroke and not (stroke.embedded or stroke.staged) then
                -- Strokes saved before page coordinates were recorded get
                -- them now, under the same transform the overlay is drawn
                -- with. Tried once per session so a stroke that can't be
                -- mapped doesn't cost a transform on every repaint.
                if stroke.page_points == nil and not stroke._page_points_tried
                        and not self:isReflowed() then
                    stroke._page_points_tried = true
                    self:capturePagePoints(stroke)
                end
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

    if self.notes_feature then
        self.notes_feature:paintTo(bb)
    end

    if self.lasso_feature then
        self.lasso_feature:paintTo(bb)
    end
end

function Pencil:getStrokesFilePath()
    return PencilStrokes.getFilePath(self.ui and self.ui.doc_settings)
end

-- Load strokes from our own file
function Pencil:loadStrokes()
    self.notes_feature = self.notes_feature or PencilNotes:new{ plugin = self }
    self.notes_feature:deserialize(nil)
    local doc_settings = self.ui and self.ui.doc_settings
    local filepath = PencilStrokes.migrateFileIfNeeded(doc_settings)
    logger.info("Pencil: loadStrokes - filepath =", filepath)
    local was_too_new = self.strokes_file_too_new
    self.strokes_file_too_new = false

    local status, data = self.store:load(filepath, {
        tool_settings = self.stroke_render_ctx.tool_settings,
        available_colors = self.available_colors,
    })

    if status == "too_new" then
        -- Written by a newer Pencil: left untouched, and not saved over
        -- (PencilStrokes refuses to write it).
        self.annotation_groups = {}
        self.strokes_file_too_new = true
        if not was_too_new then
            UIManager:nextTick(function()
                UIManager:show(InfoMessage:new{
                    text = _("This book's ink was saved by a newer version of Pencil. Update Pencil to see it.\n\nUntil then, Pencil won't save ink for this book, so the newer ink stays safe."),
                })
            end)
        end
        return
    end
    if status == "error" then
        self.annotation_groups = {}
    elseif status == "ok" then
        self.notes_feature:deserialize(data.notes)

        -- { [tag] = page }: PDF ink deletions a session queued but didn't
        -- write. All of them are still unapplied in this session's document.
        self.pending_ink_deletes = {}
        self._unapplied_ink_deletes = {}
        if type(data.pending_ink_deletes) == "table" then
            for tag, page in pairs(data.pending_ink_deletes) do
                if type(tag) == "string" and type(page) == "number" then
                    self.pending_ink_deletes[tag] = page
                    self._unapplied_ink_deletes[tag] = page
                end
            end
        end

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
        notes = self.notes_feature and self.notes_feature:serialize() or {},
        -- PDF ink deleted in memory but not yet written to the file.
        pending_ink_deletes = (self.pending_ink_deletes and next(self.pending_ink_deletes))
            and self.pending_ink_deletes or nil,
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
        self:commitStroke(self.current_stroke)
        self.current_stroke = nil
    end

    self:teardownPenInput()
    if self.notes_feature and self.notes_feature:isOpen() then
        self.notes_feature:close(false)
    end
    if self.lasso_feature then self.lasso_feature:clear() end
    self:rebuildStaleGroups()

    -- Run any pending deferred image captures synchronously before close so
    -- we don't lose a fresh annotation. Must happen before the final save so
    -- new image_path / image_rotation fields land in the strokes file.
    self:flushPendingCaptures()

    -- Final bookmark sync before close
    self:syncAllBookmarks()

    -- An erase gesture still in progress never reaches its pen-up handler.
    self:flushPendingEraseToPdf()
    -- Make sure every queued ink deletion is in the document for the write.
    local pok, pres = pcall(self.applyPendingInkDeletes, self)
    if not pok then logger.err("Pencil: applyPendingInkDeletes error:", pres) end
    local deletes_applied = pok and pres ~= nil

    -- Auto-save pencil ink into the PDF file (opt-in). This only stages the
    -- annotations in memory; the actual disk write is the single flushPdfEdits()
    -- below. Must run while the document is still open/writable.
    if self.auto_save_pdf then
        local ok, err = pcall(function() self:autoSaveInkToPdf() end)
        if not ok then
            logger.err("Pencil: autoSaveInkToPdf error:", err)
        end
    end

    -- Single, final write of any in-memory PDF edits the plugin made this
    -- session (auto-saved ink, erased ink, manual per-page saves). One
    -- incremental write, then is_edited is cleared so KOReader's own close
    -- doesn't stack a second write (which corrupts the xref). Runs regardless
    -- of the auto-save toggle, since the eraser/manual paths also set dirty.
    local ok, ferr = pcall(function() self:flushPdfEdits() end)
    if not ok then logger.err("Pencil: flushPdfEdits error:", ferr) end
    -- flushPdfEdits clears _pdf_dirty only on a successful write. Only then do
    -- strokes staged this session (by auto-save or the manual action) become
    -- `embedded`; otherwise they're un-staged so the sidecar never claims ink
    -- the file didn't receive, and the next close retries them.
    self:settleStagedStrokes(not self._pdf_dirty)
    -- Likewise the queued deletions are done once the file has them (or
    -- nothing needed writing); otherwise they stay queued for next time.
    if deletes_applied and not self._pdf_dirty then
        self.pending_ink_deletes = {}
        self._unapplied_ink_deletes = nil
    end

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
    -- across a device sleep. The debounced save only runs once writing
    -- pauses, so ink from the last moments before sleep may not be on disk.
    self:flushDeferredWork()
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

    -- Finish PDF ink deletions an earlier session didn't get to write.
    local pok, perr = pcall(self.applyPendingInkDeletes, self)
    if not pok then logger.err("Pencil: applyPendingInkDeletes error:", perr) end

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
function Pencil:onReadSettings()
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
function Pencil:onPageUpdate()
    if self.lasso_feature then self.lasso_feature:clear() end
    -- The page is redrawn in full, so the region the last strokes touched no
    -- longer needs its own refresh; don't let it widen the next page's.
    self.pending_refresh_bbox = nil
    -- Clear any in-progress stroke when page changes
    if self.current_stroke and #self.current_stroke.points >= 2 then
        -- Save the stroke before clearing. The inline saveStrokes below covers
        -- everything in self.store.strokes, so drop any queued debounced save first.
        self:cancelPendingSave()
        self.store:pushUndo({ type = "add", stroke_idx = self:commitStroke(self.current_stroke, true) })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        -- No in-progress stroke, but a debounced save may still be queued from
        -- earlier strokes on this page. Persist it before navigating away.
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    -- An erase gesture cut short by the page change never reaches its pen-up:
    -- take the PDF ink of what it erased out now.
    self:flushPendingEraseToPdf()
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
        self.store:pushUndo({ type = "add", stroke_idx = self:commitStroke(self.current_stroke, true) })
        self:flushDirtyGroups()
        self:saveStrokes()
    else
        self:flushDeferredWork()
    end
    self.current_stroke = nil
    self:flushPendingEraseToPdf()
    self.eraser_deleted = nil
    self:backfillMissingImages()
end

return Pencil
