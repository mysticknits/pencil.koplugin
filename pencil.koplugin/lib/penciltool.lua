--[[
Tool management for the Pencil plugin.

Owns everything that answers "which tool is the stylus acting as right now?":
  * the selected tool (pen / highlighter / eraser) and per-tool settings
    (width, color, alpha),
  * the eraser state (eraser end of the stylus, hardware eraser button),
  * the text-highlight mode state,
  * the swap-eraser-and-highlighter option,
  * what a stylus contact means: a click or a drag with the eraser role, text
    or freehand highlight with the highlighter role.

How the stylus behaves (roles are exchanged by the swap option):
  * pen tip: the selected tool (pen or eraser);
  * eraser role (eraser end by default): a click (touch that stays put) toggles
    the selected tool, a drag erases what it passes over and does NOT toggle;
  * highlighter role (side button by default): dragging highlights the text
    below the pen, or, if there is no text below it, draws a highlighter stroke.

It does NOT touch strokes, the screen, KOReader widgets, Dispatcher events or
G_reader_settings. main.lua feeds it settings (loadSettings) and reads them back
(exportSettings), and does the stroke-related work that follows a state change
(flushing erased strokes into the undo stack, repainting, ...).
]]

local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

local PencilTool = {}
PencilTool.__index = PencilTool

-- Tool names. These strings are also stored in saved strokes, so do not
-- change their values.
PencilTool.TOOLS = {
    PEN = "pen",
    HIGHLIGHTER = "highlighter",
    ERASER = "eraser",
}

-- Tool types from the Linux input subsystem (slot.tool)
PencilTool.LINUX_TOOLTYPE = {
    PEN = 1,
    ERASER = 2,
    HIGHLIGHTER = 3,
}

-- Physical stylus inputs, as KOReader reports them as key events. What an
-- input does (its role) depends on the swap option, see roleOfInput().
PencilTool.INPUT = {
    ERASER_KEY = "eraser_key",  -- BTN_STYLUS, key "Eraser" (eraser end on Kobo); slot.tool ERASER
    RUBBER = "rubber",          -- BTN_TOOL_RUBBER (eraser end as a tool); slot.tool ERASER
    SIDE_KEY = "side_key",      -- BTN_STYLUS2, key "Highlighter"/"Stylus" (side button); slot.tool HIGHLIGHTER
}

-- Opacities (percent) offered for the highlighter. 100 = the color as is, lower
-- values let more of the page show through.
PencilTool.HIGHLIGHTER_OPACITIES = { 20, 35, 50, 65, 80, 100 }
PencilTool.DEFAULT_HIGHLIGHTER_OPACITY = 65
-- The highlighter color is chosen by name from the plugin's color list. "Gray"
-- at 65% reproduces the light gray the highlighter always had.
PencilTool.DEFAULT_HIGHLIGHTER_COLOR_NAME = "Gray"

-- Opacity percent <-> alpha byte (0-255, the value stored in strokes)
function PencilTool.opacityToAlpha(percent)
    return math.floor(255 * percent / 100 + 0.5)
end

function PencilTool.alphaToOpacity(alpha)
    return math.floor((alpha or 255) * 100 / 255 + 0.5)
end

-- A contact that moves less than this many pixels is a click, not a drag.
PencilTool.CLICK_TOLERANCE = 10

local TOOLS = PencilTool.TOOLS
local LINUX_TOOLTYPE = PencilTool.LINUX_TOOLTYPE
local INPUT = PencilTool.INPUT

local VALID_TOOLS = {}
for _, name in pairs(TOOLS) do
    VALID_TOOLS[name] = true
end

function PencilTool:new(o)
    o = o or {}
    setmetatable(o, self)
    return o:init()
end

function PencilTool:init()
    self.current_tool = TOOLS.PEN

    self.eraser_tool_active = false  -- Physical eraser end is in use (via BTN_TOOL_RUBBER)
    self.eraser_button_active = false  -- Eraser mode via hardware eraser button or eraser end (slot.tool)
    self.erasing = false  -- A contact is currently being used to erase
    -- Text-highlight state: true while a side-button + pen-drag is building a
    -- KOReader text-highlight selection via ReaderHighlight. Sticky through
    -- pen lift so releasing the side button mid-drag doesn't abort.
    self.highlighting = false
    -- The highlighter contact in progress found no text below the pen and is
    -- drawn as a freehand highlighter stroke (decided once per contact)
    self.highlight_freehand = false
    -- Eraser-role contact in progress: { x0, y0, dragging }; nil when none
    self.eraser_contact = nil
    -- Whether the screen was touched since the eraser role was activated
    self.eraser_touched = false

    -- Per-tool settings
    self.tool_settings = {
        [TOOLS.PEN] = {
            width = 3,
            color = Blitbuffer.COLOR_BLACK,
            color_name = "Black",  -- For persistence and display
            alpha = 255,
        },
        [TOOLS.HIGHLIGHTER] = {
            width = 20,
            color = Blitbuffer.Color8(0xCC),
            color_name = PencilTool.DEFAULT_HIGHLIGHTER_COLOR_NAME,
            alpha = PencilTool.opacityToAlpha(PencilTool.DEFAULT_HIGHLIGHTER_OPACITY),
        },
        [TOOLS.ERASER] = {
            width = 20,
        },
    }

    self.swap_eraser_and_highlighter = false
    self.experimental_text_highlight = false

    return self
end

--
-- Settings (persistence itself stays in main.lua)
--

-- settings: the plugin settings table as read from G_reader_settings.
-- available_colors: array of { name = ..., color = ... }, available_widths:
-- array of { width = ... }. The saved color/width are only honored when they
-- appear in these lists, so a malformed settings file can't inject arbitrary
-- values.
function PencilTool:loadSettings(settings, available_colors, available_widths)
    settings = settings or {}
    local pen = self.tool_settings[TOOLS.PEN]

    -- Always start with the pen when opening a book
    self.current_tool = TOOLS.PEN

    self.swap_eraser_and_highlighter = settings.swap_eraser_and_highlighter or false
    self.experimental_text_highlight = settings.experimental_text_highlight or false

    -- Load pen color by name and look up the actual color value
    local color_name = settings.pen_color_name
    if color_name then
        pen.color_name = color_name
        pen.color = nil
        for _, color_info in ipairs(available_colors or {}) do
            if color_info.name == color_name then
                pen.color = color_info.color
                break
            end
        end
    end
    -- Unknown/missing color: fall back to black
    if not pen.color then
        pen.color = Blitbuffer.COLOR_BLACK
        pen.color_name = "Black"
    end

    -- Highlighter color (by name) and opacity (one of the offered percentages)
    local hl = self.tool_settings[TOOLS.HIGHLIGHTER]
    local hl_name = settings.highlighter_color_name or PencilTool.DEFAULT_HIGHLIGHTER_COLOR_NAME
    for _, color_info in ipairs(available_colors or {}) do
        if color_info.name == hl_name then
            hl.color_name = color_info.name
            hl.color = color_info.color
            break
        end
    end
    for _, percent in ipairs(PencilTool.HIGHLIGHTER_OPACITIES) do
        if percent == settings.highlighter_opacity then
            hl.alpha = PencilTool.opacityToAlpha(percent)
            break
        end
    end

    local saved_width = settings.pen_width
    if saved_width then
        for _, w in ipairs(available_widths or {}) do
            if w.width == saved_width then
                pen.width = saved_width
                break
            end
        end
    end
end

-- The tool-related keys main.lua merges into the plugin settings it saves.
function PencilTool:exportSettings()
    local pen = self.tool_settings[TOOLS.PEN]
    local hl = self.tool_settings[TOOLS.HIGHLIGHTER]
    return {
        swap_eraser_and_highlighter = self.swap_eraser_and_highlighter,
        experimental_text_highlight = self.experimental_text_highlight,
        pen_color_name = pen.color_name,
        pen_width = pen.width,
        highlighter_color_name = hl.color_name,
        highlighter_opacity = PencilTool.alphaToOpacity(hl.alpha),
    }
end

--
-- Tool settings
--

function PencilTool:setColor(name, color)
    local pen = self.tool_settings[TOOLS.PEN]
    pen.color_name = name
    pen.color = color
end

function PencilTool:setWidth(width)
    self.tool_settings[TOOLS.PEN].width = width
end

function PencilTool:setHighlighterColor(name, color)
    local hl = self.tool_settings[TOOLS.HIGHLIGHTER]
    hl.color_name = name
    hl.color = color
end

-- percent: one of HIGHLIGHTER_OPACITIES. Returns false (and changes nothing)
-- for any other value.
function PencilTool:setHighlighterOpacity(percent)
    for _, allowed in ipairs(PencilTool.HIGHLIGHTER_OPACITIES) do
        if allowed == percent then
            self.tool_settings[TOOLS.HIGHLIGHTER].alpha = PencilTool.opacityToAlpha(percent)
            return true
        end
    end
    return false
end

function PencilTool:getHighlighterOpacity()
    return PencilTool.alphaToOpacity(self.tool_settings[TOOLS.HIGHLIGHTER].alpha)
end

-- Pen settings
function PencilTool:getSettings()
    return self.tool_settings[TOOLS.PEN]
end

-- Settings of a given tool, falling back to the pen's for unknown tools.
function PencilTool:getToolSettings(tool)
    return self.tool_settings[tool] or self.tool_settings[TOOLS.PEN]
end

--
-- Tool selection
--

-- Returns the new tool, or nil if `tool` is not a known tool name.
function PencilTool:setTool(tool)
    if not VALID_TOOLS[tool] then
        return nil
    end
    self.current_tool = tool
    return self.current_tool
end

function PencilTool:getTool()
    return self.current_tool
end

-- Toggle between pen and eraser. Returns the new tool.
function PencilTool:togglePenEraser()
    local old_tool = self.current_tool
    if old_tool == TOOLS.ERASER then
        self.current_tool = TOOLS.PEN
    else
        self.current_tool = TOOLS.ERASER
    end
    logger.dbg("PencilTool: toggled from", old_tool, "to", self.current_tool)
    return self.current_tool
end

function PencilTool:isSwaped() return self.swap_eraser_and_highlighter end
function PencilTool:swapEraserHighlighter()
    self.swap_eraser_and_highlighter = not self.swap_eraser_and_highlighter
    return self.swap_eraser_and_highlighter
end

function PencilTool:isExperimentalTextHighlight() return self.experimental_text_highlight end
function PencilTool:experimentalTextHighlight()
    self.experimental_text_highlight = not self.experimental_text_highlight
    return self.experimental_text_highlight
end

-- Reset transient highlighter state without changing the selected main tool.
-- Used when a highlighter picker closes: stale button/contact state must not
-- make the next plain pen contact behave as a highlighter.
function PencilTool:resetHighlighterState()
    self.highlighting = false
    self.highlight_freehand = false
end

--
-- Callbacks and event helpers
--

--
-- Roles. Two physical inputs exist: the eraser end / eraser button (slot.tool
-- ERASER, key "Eraser" or BTN_TOOL_RUBBER) and the side button (slot.tool
-- HIGHLIGHTER, key "Highlighter"/"Stylus"). Normally the first one erases and
-- the second one highlights; "swap eraser and highlighter" exchanges what they
-- do. EVERYTHING that depends on the option goes through the two functions
-- below, so slot events and key events (press and release) always agree.
--

-- What a physical input that normally does `natural_tool` does right now.
function PencilTool:swappedRole(natural_tool)
    if not self.swap_eraser_and_highlighter then
        return natural_tool
    end
    return natural_tool == TOOLS.ERASER and TOOLS.HIGHLIGHTER or TOOLS.ERASER
end

-- Role (TOOLS.ERASER / TOOLS.HIGHLIGHTER) of the stylus input behind a slot,
-- nil for the plain pen tip.
function PencilTool:roleForSlot(slot)
    if slot.tool == LINUX_TOOLTYPE.ERASER then
        return self:swappedRole(TOOLS.ERASER)
    elseif slot.tool == LINUX_TOOLTYPE.HIGHLIGHTER then
        return self:swappedRole(TOOLS.HIGHLIGHTER)
    end
    return nil
end

-- Which physical input a key event is, nil if it is not a stylus input.
-- key_name: key.key, key_str: tostring(key).
function PencilTool.inputForKey(key_name, key_str)
    key_str = key_str or ""
    if key_name == "Eraser" then
        return INPUT.ERASER_KEY
    elseif key_str:match("BTN_TOOL_RUBBER") or key_str:match("ToolRubber") then
        return INPUT.RUBBER
    elseif key_str:match("Highlighter") or key_str:match("Stylus") then
        return INPUT.SIDE_KEY
    end
    return nil
end

function PencilTool:roleOfInput(input)
    if input == INPUT.ERASER_KEY or input == INPUT.RUBBER then
        return self:swappedRole(TOOLS.ERASER)
    elseif input == INPUT.SIDE_KEY then
        return self:swappedRole(TOOLS.HIGHLIGHTER)
    end
    return nil
end

-- Role and input of a key event; nil, nil if it is not a stylus input.
function PencilTool:roleForKey(key_name, key_str)
    local input = PencilTool.inputForKey(key_name, key_str)
    return self:roleOfInput(input), input
end

function PencilTool:isEraserToolType(slot)
    return self:roleForSlot(slot) == TOOLS.ERASER
end

function PencilTool:isHighlightingToolType(slot)
    return self:roleForSlot(slot) == TOOLS.HIGHLIGHTER
end

-- Tool in effect for a raw stylus slot. Same rules as getEffectiveTool():
-- 1. eraser role (slot.tool, or BTN_TOOL_RUBBER via eraser_tool_active) wins,
-- 2. then highlighter role (slot.tool, or the side button being held),
-- 3. otherwise the selected tool (user can toggle via gesture).
-- Using slot.tool for the highlighter too matters: the slot event can arrive
-- before the key event that sets side_button_down.
function PencilTool:getEffectiveToolForSlot(slot, side_button_down)
    return self:getEffectiveTool(
        slot.tool == LINUX_TOOLTYPE.ERASER,
        slot.tool == LINUX_TOOLTYPE.HIGHLIGHTER,
        side_button_down)
end

-- Effective tool from the booleans isPenInput() derives from the pen slot's tool type.
-- side_button_down: the stylus side button is held (= highlighter).
-- is_eraser_end / is_highlighter are the PHYSICAL inputs (slot.tool ERASER /
-- HIGHLIGHTER), the swap option is applied here.
function PencilTool:getEffectiveTool(is_eraser_end, is_highlighter, side_button_down)
    local eraser_role = (is_eraser_end and self:swappedRole(TOOLS.ERASER) == TOOLS.ERASER)
        or (is_highlighter and self:swappedRole(TOOLS.HIGHLIGHTER) == TOOLS.ERASER)
    -- Check both the tool type detection AND the BTN_TOOL_RUBBER state
    if self.eraser_tool_active or eraser_role then
        return TOOLS.ERASER
    end

    -- Side button held = highlighter mode (for hold+drag highlighting)
    local highlighter_role = (is_eraser_end and self:swappedRole(TOOLS.ERASER) == TOOLS.HIGHLIGHTER)
        or (is_highlighter and self:swappedRole(TOOLS.HIGHLIGHTER) == TOOLS.HIGHLIGHTER)
    if side_button_down or highlighter_role then
        return TOOLS.HIGHLIGHTER
    end

    return self.current_tool
end

-- Enter eraser mode (eraser role pressed or touching). rubber: the eraser end
-- itself (BTN_TOOL_RUBBER), which also stays flagged until it leaves.
-- Returns true if eraser mode was just entered, false if it already was on
-- (the slot event usually arrives before the key event).
function PencilTool:activateEraser(rubber)
    if rubber then
        self.eraser_tool_active = true
    end
    if self.eraser_button_active then
        return false
    end
    self.eraser_button_active = true
    self.eraser_contact = nil
    self.eraser_touched = false
    return true
end

-- Leave eraser mode. button_input: the eraser role was a real button (the side
-- button when swapped), for which pressing and releasing it without touching
-- the screen is a click too. Returns true if the activation amounted to a
-- click, i.e. the caller should toggle the tool.
function PencilTool:deactivateEraser(button_input)
    local clicked = false
    if self.eraser_contact then
        -- Contact still in progress when the eraser role ended: counts as lifted
        clicked = not self.eraser_contact.dragging
    elseif button_input and not self.eraser_touched then
        clicked = true
    end
    self.eraser_button_active = false
    self.eraser_contact = nil
    self.eraser_touched = false
    return clicked
end

-- Follow one eraser-role contact. active: the pen touches (slot.id >= 0), x/y
-- its screen position. Returns the phase:
--   "down"       contact started (nothing to erase yet: it may be a click)
--   "hold"       still within the click tolerance (nothing to erase)
--   "drag_start" moved beyond the tolerance: it is a drag, erase from now on
--                (the caller also erases at contact.x0/y0, see eraser_contact)
--   "drag"       drag continues: erase here
--   "drag_end"   lifted after a drag (nothing to do, must not toggle)
--   "click"      lifted without dragging: toggle the tool
--   nil          no contact in progress and none starting
function PencilTool:trackEraserContact(active, x, y)
    local contact = self.eraser_contact
    if active then
        if not contact then
            self.eraser_contact = { x0 = x, y0 = y, dragging = false }
            self.eraser_touched = true
            return "down"
        end
        if contact.dragging then
            return "drag"
        end
        local dx, dy = x - contact.x0, y - contact.y0
        if dx * dx + dy * dy > PencilTool.CLICK_TOLERANCE * PencilTool.CLICK_TOLERANCE then
            contact.dragging = true
            return "drag_start"
        end
        return "hold"
    end
    if contact then
        self.eraser_contact = nil
        return contact.dragging and "drag_end" or "click"
    end
    return nil
end

-- Detect eraser mode from slot.tool BEFORE the key events arrive (the stylus
-- callback fires before them) and update eraser_button_active.
-- Returns true when eraser mode was just activated; false when it was just
-- deactivated (eraser end switched back to the pen tip), followed by whether
-- that amounted to a click (see deactivateEraser); nil if unchanged.
-- Whatever has to happen next (resetting/flushing the list of erased strokes,
-- toggling the tool, repainting) is up to the caller.
function PencilTool:detectEraserAndUpdate(slot)
    local is_eraser = self:isEraserToolType(slot)
    if is_eraser and not self.eraser_button_active then
        logger.info("PencilTool: Eraser end detected via slot.tool, activating eraser mode")
        self:activateEraser()
        return true
    elseif not is_eraser and self.eraser_button_active then
        -- Switched from eraser end to pen tip
        logger.info("PencilTool: Pen tip detected via slot.tool, deactivating eraser mode")
        return false, self:deactivateEraser(false)
    end

    return nil
end

-- Highlighter role: highlight the text below the pen, or draw a highlighter
-- stroke if there is none. Decided once per contact, when it starts.
-- Decide what a stylus slot means for that. Changes no state itself: the caller
-- sets `highlighting` once a text highlight has really started (it can't when
-- there is no word below the pen) and `highlight_freehand` otherwise.
-- Returns nil if the slot is not part of a text highlight (carry on with the
-- normal draw/erase handling, which draws the freehand stroke), otherwise
--   "start"  - contact began, no decision yet: try a text highlight; if there
--              is no text below the pen set highlight_freehand = true and
--              carry on with the normal handling
--   "extend" - contact moved, text highlight in progress
--   "finish" - contact lifted, text highlight in progress
--   "ignore" - pen lifted, nothing in progress; nothing to do
function PencilTool:detectHighlighting(slot, side_button_down)
    if not self.experimental_text_highlight then
        self.highlight_freehand = false
        return nil
    end
    local engaged = self.highlighting or self.highlight_freehand
    if not engaged and self:getEffectiveToolForSlot(slot, side_button_down) ~= TOOLS.HIGHLIGHTER then
        return nil
    end

    if (slot.id or -1) >= 0 then
        if self.highlighting then
            return "extend"
        elseif self.highlight_freehand then
            return nil
        end
        return "start"
    end

    if self.highlighting then
        return "finish"
    elseif self.highlight_freehand then
        self.highlight_freehand = false  -- freehand contact lifted
        return nil
    end
    return "ignore"
end

return PencilTool
