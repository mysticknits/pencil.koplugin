-- UI/presentation layer for the Pencil KOReader plugin.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local Size = require("ui/size")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local TextWidget = require("ui/widget/textwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local PencilTool = require("lib/penciltool")
local TOOL_PEN = PencilTool.TOOLS.PEN
local TOOL_HIGHLIGHTER = PencilTool.TOOLS.HIGHLIGHTER
local TOOL_ERASER = PencilTool.TOOLS.ERASER
local function trimString(v) return tostring(v or ""):match("^%s*(.-)%s*$") end
local M = {}

function M.buildHighlighterMenu(self)
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

function M.addToMainMenu(self, menu_items)
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
            },
            {
                text = _("Eraser click switches pen/eraser"),
                help_text = _("Off: the eraser erases whatever it touches, and a quick press of the side button switches between pen and eraser. On: a click of the eraser (a touch that stays put) switches between pen and eraser and a drag erases; the side button only highlights, with a freehand highlighter stroke where there is no text to highlight."),
                checked_func = function()
                    return self.tool:isEraserClickMode()
                end,
                callback = function()
                    self.tool:toggleEraserClickMode()
                    self.side_button_used_for_highlight = false
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
                                self:refreshDogear()
                                UIManager:show(InfoMessage:new{
                                    text = _("Bookmark sync enabled. Pencil annotations will appear in the Bookmarks menu."),
                                    timeout = 3,
                                })
                            else
                                self:removeAllPencilBookmarks()
                                self:refreshDogear()
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
                        help_text = _("When enabled, holding the stylus side button during a pen drag creates a native KOReader text highlight on the words under the pen, like a long-press \xe2\x86\x92 Highlight. When disabled, the side button draws a highlighter stroke. (With \"Eraser click switches pen/eraser\" on, a highlighter stroke is also drawn where there is no text under the pen.) Off by default because this is a new integration and has edge cases. Requires a stylus that sends BTN_STYLUS2."),
                        checked_func = function()
                            return self.tool:isExperimentalTextHighlight()
                        end,
                        callback = function()
                            self.tool:experimentalTextHighlight()
                            self:saveSettings()
                            if self.tool:isExperimentalTextHighlight() then
                                UIManager:show(InfoMessage:new{
                                    text = self.tool:isEraserClickMode()
                                        and _("Text highlight enabled. Hold the side button while dragging the pen across words; away from text it draws a highlighter stroke.")
                                        or _("Text highlight enabled. Hold the side button while dragging the pen across words."),
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
                            return self.ui.paging ~= nil and self:hasInkAnnotSupport()
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
function M.showAnnotationStatus(self)
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
function M.showColorPicker(self, x, y, tool)
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
                plugin:showToast(T(_("Highlighter opacity: %1"), string.format("%d%%", opacity)))
            elseif is_highlighter then
                plugin:setHighlighterColor(color, name)
                plugin:showToast(T(_("Highlighter color: %1"), name))
            elseif width then
                plugin:setPenWidth(width)
                plugin:showToast(T(_("Pen width: %1"), width))
            else
                plugin:setPenColor(color, name)
                if Screen.night_mode and name == "Black" then name = "White" end
                plugin:showToast(T(_("Pen color: %1"), name))
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
function M.showAnnotationHoldMenu(self, group)
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
function M.showMyScriptSettingsDialog(self)
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

function M.showRecognizedText(self, text, group)
    UIManager:show(TextViewer:new{
        title = T(_("Handwriting - page %1"), self:getPageNumber(group.page)),
        text = text,
        text_settings = {},
    })
end

function M.showAnnotationTextEditor(self, group)
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

function M.showAllRecognizedText(self)
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
function M.editAllRecognizedText(self)
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
function M.showGroupImagePreview(self, group)
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

return M
