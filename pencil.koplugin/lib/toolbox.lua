--[[--
Quick tool box for the Pencil plugin.

A small floating panel, built from core KOReader widgets (FrameContainer,
VerticalGroup, HorizontalGroup, CenterContainer, Button), that lets the user
switch tool, pick a saved preset, color, width and eraser size without
leaving the page:

    [ Pen ][ Marker ][ Eraser ][ Undo ][ x ]     tools
    [ p1 ][ p2 ][ p3 ][ p4 ][ p5 ][ p6 ]         saved presets (hold = save here)
    [ colors ... ]                               pen / marker colors
    [ widths ... ]                               pen / marker width or eraser size

Performance contract (the pen must never lag):
  * The widget does not exist while drawing. It is created when asked for and
    freed on close, so it adds nothing to the stylus callback or to the
    reader's repaint.
  * It is the top-most window, and KOReader only repaints from the first dirty
    window upward, so opening it and changing the selection repaint just this
    panel, never the page and its strokes. The size is therefore fixed
    for the box's lifetime, so a repaint always covers what it drew before.
  * It stays open across several picks and closes only on tap outside or the
    close button, so the one reader repaint that closing causes happens once
    per visit, not once per pick.
  * Swatches are tiny widgets painted with plain bb:paintRect, with no
    Button flash cycle (forceRePaint + yieldToEPDC) on every tap.

All state lives in the plugin: the widget talks to it through `provider`.

@module pencil.lib.toolbox
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local ok_ts, Toolset = pcall(require, "lib/toolset")
if not ok_ts then Toolset = require("toolset") end

local Screen = Device.screen

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local SELECTED_BG = Blitbuffer.Color8(0xDD)

------------------------------------------------------------------------------
-- Swatch: one tappable square (a color, a width, an eraser size or a preset)
------------------------------------------------------------------------------

local Swatch = InputContainer:extend{
    name = "pencil_toolbox_swatch",
    kind = "color",       -- "color" | "width" | "eraser" | "preset" | "add"
    size = 0,
    color = nil,          -- Blitbuffer color (color, preset)
    value = nil,          -- width in px (width, eraser, preset); color name for colors
    selected = false,
    callback = nil,
    hold_callback = nil,
}

function Swatch:init()
    self.dimen = Geom:new{ w = self.size, h = self.size }
    self.ges_events = {
        TapSwatch = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldSwatch = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

function Swatch:getSize() return self.dimen end

-- Same night-mode rule as the strokes themselves (see Pencil:addRawPoint).
local function displayColor(color, name)
    if color and Screen.night_mode and name ~= "Black" and name ~= "Gray" then
        return color:invert()
    end
    return color
end

-- Fill with a palette color. Blitbuffer:paintRect flattens its color to a gray
-- level (it calls getColor8), which is why every swatch came out gray on a color
-- screen; paintRectRGB32 keeps the color. Pencil's own strokes use it for the
-- same reason. (The fallback is for builds without it; those are gray-only.)
local function fill(bb, x, y, w, h, color)
    if bb.paintRectRGB32 then
        bb:paintRectRGB32(x, y, w, h, color)
    else
        bb:paintRect(x, y, w, h, color)
    end
end

function Swatch:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    local border = self.selected and Size.border.thick * 3 or Size.border.thin
    bb:paintRect(x, y, w, h, WHITE)
    local ix, iy = x + border, y + border
    local iw, ih = w - 2 * border, h - 2 * border

    if self.kind == "color" then
        fill(bb, ix, iy, iw, ih, displayColor(self.color, self.value) or BLACK)
    elseif self.kind == "width" then
        local bar_h = Toolset.sampleBarHeight(self.value, ih)
        local bar_w = math.floor(iw * 0.7)
        bb:paintRect(ix + math.floor((iw - bar_w) / 2), iy + math.floor((ih - bar_h) / 2),
            bar_w, bar_h, BLACK)
    elseif self.kind == "eraser" then
        -- an outlined square as big as the eraser's reach, as far as it fits
        local side = math.max(4, math.min(self.value, math.min(iw, ih) - 2))
        bb:paintBorder(ix + math.floor((iw - side) / 2), iy + math.floor((ih - side) / 2),
            side, side, Size.border.thin, BLACK)
    elseif self.kind == "add" then
        -- a plus: hold or tap to store the pen in hand here
        local t = math.max(2, Size.border.thick)
        local len = math.floor(math.min(iw, ih) * 0.5)
        bb:paintRect(ix + math.floor((iw - len) / 2), iy + math.floor((ih - t) / 2), len, t, BLACK)
        bb:paintRect(ix + math.floor((iw - t) / 2), iy + math.floor((ih - len) / 2), t, len, BLACK)
    elseif self.kind == "preset" then
        -- a short stroke in the preset's own color and (capped) thickness
        local bar_h = Toolset.sampleBarHeight(self.value, ih - 4)
        local bar_w = iw - 8
        local bx, by = ix + 4, iy + math.floor((ih - bar_h) / 2)
        fill(bb, bx, by, bar_w, bar_h, displayColor(self.color, self.color_name) or BLACK)
        if self.is_highlighter then
            -- a hairline under a marker stroke tells it apart from a pen
            bb:paintRect(bx, by + bar_h + 1, bar_w, 1, BLACK)
        end
    end
    bb:paintBorder(x, y, w, h, border, BLACK)
end

function Swatch:onTapSwatch()
    if self.callback then self.callback() end
    return true
end

function Swatch:onHoldSwatch()
    if self.hold_callback then self.hold_callback() end
    return true
end

------------------------------------------------------------------------------
-- ToolBox
------------------------------------------------------------------------------

local ToolBox = InputContainer:extend{
    name = "pencil_toolbox",   -- not "ReaderUI": the plugin sees an overlay and leaves the pen to us
    provider = nil,            -- see Pencil:showToolBox
    anchor_x = nil,            -- where the pen is (nil: bottom centre)
    anchor_y = nil,
    on_close = nil,
    -- swallow every gesture so a stray swipe or hold can't turn the page under us
    stop_events_propagation = true,
}

-- Exposed for tests.
ToolBox.Swatch = Swatch

function ToolBox:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.base = Screen:scaleBySize(36)
    self.gap = Screen:scaleBySize(8)
    self.padding = Screen:scaleBySize(10)
    self.row_gap = Screen:scaleBySize(8)
    local border = Size.border.window
    local screen_margin = Screen:scaleBySize(10)

    -- The widest row decides the width: ten pen colors, unless the screen is narrower.
    local p = self.provider
    local widest = math.max(#p.colorsFor("pen"), #p.colorsFor("highlighter"),
        Toolset.PRESET_CAP, 5)
    local natural = widest * self.base + (widest - 1) * self.gap
    local max_inner = sw - 2 * (screen_margin + self.padding + border)
    self.inner_w = math.min(natural, max_inner)
    -- One swatch size for every row, set by the widest, so the box keeps its size
    -- whatever the number of presets or the tool.
    self.swatch_size = Toolset.fitItemSize(widest, self.inner_w, self.base, self.gap, Screen:scaleBySize(20))

    self:_build()

    local x, y = Toolset.place(sw, sh, self.dimen.w, self.dimen.h, self.anchor_x, self.anchor_y,
        { gap = Screen:scaleBySize(30), margin = screen_margin })
    self.dimen.x, self.dimen.y = x, y

    self.ges_events = {
        TapCloseOutside = { GestureRange:new{
            ges = "tap",
            range = function() return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } end,
        } },
    }
end

local function centered(inner_w, group)
    return CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = group:getSize().h },
        group,
    }
end

-- A row of equally sized swatches, shrunk to fit the box.
function ToolBox:_swatchRow(specs)
    local group = HorizontalGroup:new{ align = "center" }
    for i, spec in ipairs(specs) do
        if i > 1 then group[#group + 1] = HorizontalSpan:new{ width = self.gap } end
        spec.size = self.swatch_size
        group[#group + 1] = Swatch:new(spec)
    end
    return centered(self.inner_w, group)
end

-- (Re)build the contents from the plugin's current state. The size comes out the
-- same every time (rows keep their height), which `refresh` relies on.
function ToolBox:_build()
    local p = self.provider
    local st = p.getState()
    local rows = VerticalGroup:new{ align = "center" }

    -- Row 1: tools
    local tools = {
        { id = "pen",         label = _("Pen") },
        { id = "highlighter", label = _("Marker") },
        { id = "eraser",      label = _("Eraser") },
    }
    local n_buttons = #tools + 2
    local btn_gap = self.gap
    local btn_w = math.floor((self.inner_w - (n_buttons - 1) * btn_gap) / n_buttons)
    local tool_row = HorizontalGroup:new{ align = "center" }
    local function addButton(spec)
        if #tool_row > 0 then tool_row[#tool_row + 1] = HorizontalSpan:new{ width = btn_gap } end
        spec.width = btn_w
        spec.show_parent = self
        spec.text_font_size = 18
        spec.padding = Size.padding.small
        tool_row[#tool_row + 1] = Button:new(spec)
    end
    for _i, t in ipairs(tools) do
        local selected = st.tool == t.id
        addButton{
            text = t.label,
            bordersize = selected and Size.border.thick * 2 or Size.border.thin,
            background = selected and SELECTED_BG or nil,
            callback = function() p.setTool(t.id); self:refresh() end,
        }
    end
    addButton{
        text = _("Undo"),
        enabled = p.canUndo(),
        bordersize = Size.border.thin,
        callback = function() p.undo(); self:refresh() end,
    }
    addButton{
        text = "\u{00D7}",   -- ×
        bordersize = Size.border.thin,
        callback = function() self:close() end,
    }
    rows[#rows + 1] = centered(self.inner_w, tool_row)
    rows[#rows + 1] = VerticalSpan:new{ width = self.row_gap }

    -- Row 2: saved presets. A hold stores the pen in hand in that slot (one
    -- past the last slot adds a new one, up to the cap).
    local presets = p.getPresets()
    local specs = {}
    for i, pr in ipairs(presets) do
        local c = p.colorFor(pr.tool, pr.color_name)
        specs[#specs + 1] = {
            kind = "preset", color = c, color_name = pr.color_name, value = pr.width,
            is_highlighter = pr.tool == "highlighter",
            selected = st.tool == pr.tool and st.color_name == pr.color_name and st.width == pr.width,
            callback = function() p.selectPreset(i); self:refresh() end,
            hold_callback = function() p.savePreset(i); self:refresh() end,
        }
    end
    if #presets < Toolset.PRESET_CAP then
        local slot = #presets + 1
        specs[#specs + 1] = {
            kind = "add",
            callback = function() p.savePreset(slot); self:refresh() end,
            hold_callback = function() p.savePreset(slot); self:refresh() end,
        }
    end
    rows[#rows + 1] = self:_swatchRow(specs)
    rows[#rows + 1] = VerticalSpan:new{ width = self.row_gap }

    -- Row 3: colors. The row keeps its height for the eraser, which has no color,
    -- so the box never changes size.
    if st.tool == "eraser" then
        rows[#rows + 1] = VerticalSpan:new{ width = self.swatch_size }
    else
        local cspecs = {}
        for _i, ci in ipairs(p.colorsFor(st.tool)) do
            cspecs[#cspecs + 1] = {
                kind = "color", color = ci.color, value = ci.name,
                selected = st.color_name == ci.name,
                callback = function() p.setColor(ci.name); self:refresh() end,
            }
        end
        rows[#rows + 1] = (self:_swatchRow(cspecs))
    end
    rows[#rows + 1] = VerticalSpan:new{ width = self.row_gap }

    -- Row 4: widths, or eraser sizes
    local wspecs = {}
    if st.tool == "eraser" then
        for _i, w in ipairs(Toolset.ERASER_WIDTHS) do
            wspecs[#wspecs + 1] = {
                kind = "eraser", value = w, selected = st.eraser_width == w,
                callback = function() p.setEraserWidth(w); self:refresh() end,
            }
        end
    else
        local list = st.tool == "highlighter" and Toolset.HIGHLIGHTER_WIDTHS or Toolset.PEN_WIDTHS
        for _i, w in ipairs(list) do
            wspecs[#wspecs + 1] = {
                kind = "width", value = w, selected = st.width == w,
                callback = function() p.setWidth(w); self:refresh() end,
            }
        end
    end
    rows[#rows + 1] = (self:_swatchRow(wspecs))

    self.frame = FrameContainer:new{
        background = WHITE,
        bordersize = Size.border.window,
        padding = self.padding,
        rows,
    }
    self[1] = self.frame
    local size = self.frame:getSize()
    if self.dimen then
        -- the size is fixed once shown; only a first build sets it
        self.dimen.w = (self.dimen.w or 0) > 0 and self.dimen.w or size.w
        self.dimen.h = (self.dimen.h or 0) > 0 and self.dimen.h or size.h
    else
        self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    end
end

-- Rebuild from the plugin's state and repaint just this panel.
function ToolBox:refresh()
    if self._closed then return end
    self:_build()
    UIManager:setDirty(self, "ui", self.dimen)
end

function ToolBox:paintTo(bb, x, y)
    -- absolute placement: the box is shown at (0, 0) and positioned by dimen
    if self.frame then self.frame:paintTo(bb, self.dimen.x, self.dimen.y) end
end

function ToolBox:onTapCloseOutside(_, ges)
    if ges and ges.pos and self.dimen then
        local px, py = ges.pos.x, ges.pos.y
        local inside = px >= self.dimen.x and px < self.dimen.x + self.dimen.w
            and py >= self.dimen.y and py < self.dimen.y + self.dimen.h
        if inside then return true end   -- a miss between swatches: consume, stay open
    end
    self:close()
    return true
end

function ToolBox:close()
    if self._closed then return end
    self._closed = true
    UIManager:close(self, "ui", self.dimen)
    if self.on_close then self.on_close() end
end

function ToolBox:onCloseWidget()
    self._closed = true
end

return ToolBox
