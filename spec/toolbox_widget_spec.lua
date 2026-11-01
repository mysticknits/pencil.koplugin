--[[--
Tests for lib/toolbox.lua, the quick tool box widget.

KOReader's containers are replaced by small fakes that compute real sizes, so
the layout assertions mean something: the box must keep its size whatever the
tool or number of presets (only the box repaints, so a size change would leave
stale pixels), fit on screen, route taps to the plugin, and close cleanly.

Run with: busted spec/toolbox_widget_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

------------------------------------------------------------------------------
-- Fake KOReader widgets
------------------------------------------------------------------------------

local SCREEN = { w = 1264, h = 1680 }
local dirty, closed, shown

local function class(base)
    base = base or {}
    base.extend = function(self, o)
        o = o or {}
        o.__index = o
        return setmetatable(o, { __index = self })
    end
    base.new = function(cls, o)
        o = o or {}
        local obj = setmetatable(o, { __index = cls })
        if obj.init then obj:init() end
        return obj
    end
    return base
end

local function install_fakes()
    local color_mt = {}
    color_mt.__index = {
        invert = function(c) return setmetatable({ v = 255 - c.v }, color_mt) end,
    }
    local function Color8(v) return setmetatable({ v = v }, color_mt) end
    package.loaded["ffi/blitbuffer"] = { Color8 = Color8, COLOR_BLACK = Color8(0), COLOR_WHITE = Color8(255) }

    package.loaded["device"] = { screen = {
        getWidth = function() return SCREEN.w end,
        getHeight = function() return SCREEN.h end,
        scaleBySize = function(_, n) return n end,
        night_mode = false,
    } }
    package.loaded["ui/geometry"] = { new = function(_, o) return o end }
    package.loaded["ui/gesturerange"] = { new = function(_, o) return o end }
    package.loaded["ui/size"] = {
        border = { thin = 1, thick = 2, window = 2, default = 1 },
        padding = { small = 2, button = 4 },
    }
    package.loaded["gettext"] = function(s) return s end

    package.loaded["ui/uimanager"] = {
        show = function(_, w, mode, region) shown[#shown + 1] = { w = w, mode = mode, region = region } end,
        close = function(_, w, mode, region) closed[#closed + 1] = { w = w, mode = mode, region = region } end,
        setDirty = function(_, w, mode, region) dirty[#dirty + 1] = { w = w, mode = mode, region = region } end,
    }

    package.loaded["ui/widget/container/inputcontainer"] = class({})

    -- containers whose size follows their children
    local function sized(self) return { w = self._w, h = self._h } end
    package.loaded["ui/widget/horizontalspan"] = class({
        init = function(self) self._w, self._h = self.width, 0 end, getSize = sized })
    package.loaded["ui/widget/verticalspan"] = class({
        init = function(self) self._w, self._h = 0, self.width end, getSize = sized })
    package.loaded["ui/widget/horizontalgroup"] = class({
        getSize = function(self)
            local w, h = 0, 0
            for _, c in ipairs(self) do local s = c:getSize(); w = w + s.w; h = math.max(h, s.h) end
            return { w = w, h = h }
        end,
        paintTo = function() end,
    })
    package.loaded["ui/widget/verticalgroup"] = class({
        getSize = function(self)
            local w, h = 0, 0
            for _, c in ipairs(self) do local s = c:getSize(); h = h + s.h; w = math.max(w, s.w) end
            return { w = w, h = h }
        end,
        paintTo = function() end,
    })
    package.loaded["ui/widget/container/centercontainer"] = class({
        getSize = function(self) return { w = self.dimen.w, h = self.dimen.h } end,
        paintTo = function() end,
    })
    package.loaded["ui/widget/container/framecontainer"] = class({
        getSize = function(self)
            local s = self[1]:getSize()
            local extra = 2 * ((self.bordersize or 0) + (self.padding or 0))
            return { w = s.w + extra, h = s.h + extra }
        end,
        paintTo = function(self, bb, x, y) self.painted_at = { x = x, y = y } end,
    })
    package.loaded["ui/widget/button"] = class({
        init = function(self) self._w, self._h = self.width, 40 end,
        getSize = sized,
        paintTo = function() end,
    })
end

local function fresh_toolbox()
    install_fakes()
    package.loaded["lib/toolbox"] = nil
    package.loaded["lib/toolset"] = nil
    return require("lib/toolbox")
end

------------------------------------------------------------------------------
-- A stand-in for the plugin's provider
------------------------------------------------------------------------------

local function swatch_color(name) return { name = name } end

local PEN_COLORS, HL_COLORS = {}, {}
for _, n in ipairs({ "Black", "Red", "Orange", "Yellow", "Green", "Olive", "Cyan", "Blue", "Purple", "Gray" }) do
    PEN_COLORS[#PEN_COLORS + 1] = { name = n, color = swatch_color(n) }
end
for _, n in ipairs({ "Highlight", "Yellow", "Orange", "Olive", "Cyan" }) do
    HL_COLORS[#HL_COLORS + 1] = { name = n, color = swatch_color(n) }
end

local function make_provider(opts)
    opts = opts or {}
    local P = {
        state = { tool = "pen", color_name = "Black", width = 3, eraser_width = 20 },
        presets = opts.presets or {
            { tool = "pen", color_name = "Black", width = 3 },
            { tool = "pen", color_name = "Red", width = 3 },
            { tool = "highlighter", color_name = "Yellow", width = 20 },
        },
        undo_depth = opts.undo_depth or 2,
        calls = {},
    }
    local function log(...) P.calls[#P.calls + 1] = table.concat({ ... }, ":") end
    P.getState = function() return P.state end
    P.getPresets = function() return P.presets end
    P.colorsFor = function(tool) return tool == "highlighter" and HL_COLORS or PEN_COLORS end
    P.colorFor = function(_, name) return swatch_color(name) end
    P.setTool = function(t)
        log("setTool", t)
        P.state.tool = t
        if t == "eraser" then P.state.color_name, P.state.width = nil, P.state.eraser_width
        elseif t == "highlighter" then P.state.color_name, P.state.width = "Highlight", 20
        else P.state.color_name, P.state.width = "Black", 3 end
    end
    P.setColor = function(n) log("setColor", n); P.state.color_name = n end
    P.setWidth = function(w) log("setWidth", w); P.state.width = w end
    P.setEraserWidth = function(w) log("setEraserWidth", w); P.state.eraser_width = w; P.state.width = w end
    P.selectPreset = function(i)
        log("selectPreset", i)
        local p = P.presets[i]
        P.state.tool, P.state.color_name, P.state.width = p.tool, p.color_name, p.width
    end
    P.savePreset = function(i) log("savePreset", i) end
    P.undo = function() log("undo"); P.undo_depth = P.undo_depth - 1 end
    P.canUndo = function() return P.undo_depth > 0 end
    return P
end

-- every Swatch in the box, depth-first
local function swatches(node, out)
    out = out or {}
    if type(node) ~= "table" then return out end
    if node.kind and node.callback ~= nil or (node.kind and node.hold_callback ~= nil) then
        out[#out + 1] = node
    end
    for _, child in ipairs(node) do swatches(child, out) end
    return out
end

local function of_kind(box, kind)
    local out = {}
    for _, s in ipairs(swatches(box)) do if s.kind == kind then out[#out + 1] = s end end
    return out
end

local function buttons(node, out)
    out = out or {}
    if type(node) ~= "table" then return out end
    if node.text and node.callback and not node.kind then out[#out + 1] = node end
    for _, child in ipairs(node) do buttons(child, out) end
    return out
end

local function button(box, text)
    for _, b in ipairs(buttons(box)) do if b.text == text then return b end end
end

------------------------------------------------------------------------------

describe("ToolBox", function()
    local ToolBox

    before_each(function()
        dirty, closed, shown = {}, {}, {}
        SCREEN.w, SCREEN.h = 1264, 1680
        ToolBox = fresh_toolbox()
    end)

    local function open(provider, ax, ay, on_close)
        return ToolBox:new{ provider = provider or make_provider(), anchor_x = ax, anchor_y = ay, on_close = on_close }
    end

    describe("layout", function()
        it("builds the four rows: tools, presets, colors, widths", function()
            local box = open()
            assert.equals(5, #buttons(box))           -- Pen, Marker, Eraser, Undo, close
            assert.equals(3 + 1, #of_kind(box, "preset") + #of_kind(box, "add"))  -- 3 presets + the + slot
            assert.equals(10, #of_kind(box, "color")) -- pen palette
            assert.equals(4, #of_kind(box, "width"))  -- pen widths
        end)

        it("keeps exactly the same size across tools", function()
            local P = make_provider()
            local box = open(P)
            local w, h = box.dimen.w, box.dimen.h
            for _, tool in ipairs({ "highlighter", "eraser", "pen", "eraser", "highlighter" }) do
                P.setTool(tool)
                box:refresh()
                assert.equals(w, box.dimen.w, "width after " .. tool)
                assert.equals(h, box.dimen.h, "height after " .. tool)
                assert.equals(w, box.frame:getSize().w, "frame width after " .. tool)
                assert.equals(h, box.frame:getSize().h, "frame height after " .. tool)
            end
        end)

        it("keeps the same size from no presets to a full row", function()
            local sizes = {}
            for n = 0, 6 do
                local list = {}
                for i = 1, n do list[i] = { tool = "pen", color_name = "Black", width = i } end
                local box = open(make_provider{ presets = list })
                sizes[n] = box.frame:getSize()
            end
            for n = 1, 6 do
                assert.equals(sizes[0].h, sizes[n].h, "height with " .. n .. " presets")
                assert.equals(sizes[0].w, sizes[n].w, "width with " .. n .. " presets")
            end
        end)

        it("keeps its size on a narrow screen, and fits on it", function()
            SCREEN.w, SCREEN.h = 600, 800
            local P = make_provider()
            local box = open(P, 300, 400)
            local w, h = box.dimen.w, box.dimen.h
            assert.is_true(box.dimen.x >= 0 and box.dimen.x + w <= SCREEN.w)
            assert.is_true(box.dimen.y >= 0 and box.dimen.y + h <= SCREEN.h)
            P.setTool("eraser"); box:refresh()
            assert.equals(h, box.frame:getSize().h)
            assert.equals(w, box.frame:getSize().w)
        end)

        it("shows the marker palette (5) for the highlighter, pen palette (10) for the pen", function()
            local P = make_provider()
            local box = open(P)
            P.setTool("highlighter"); box:refresh()
            assert.equals(5, #of_kind(box, "color"))
            P.setTool("pen"); box:refresh()
            assert.equals(10, #of_kind(box, "color"))
        end)

        it("shows eraser sizes and no colors for the eraser", function()
            local P = make_provider()
            local box = open(P)
            P.setTool("eraser"); box:refresh()
            assert.equals(0, #of_kind(box, "color"))
            assert.equals(0, #of_kind(box, "width"))
            assert.equals(3, #of_kind(box, "eraser"))
        end)

        it("offers the + slot only while the row has room", function()
            local full = {}
            for i = 1, 6 do full[i] = { tool = "pen", color_name = "Black", width = i } end
            assert.equals(0, #of_kind(open(make_provider{ presets = full }), "add"))
            assert.equals(1, #of_kind(open(make_provider{ presets = {} }), "add"))
        end)

        it("is placed near the pen, or at the bottom without one", function()
            local near = open(nil, 600, 900)
            assert.is_true(near.dimen.y + near.dimen.h < 900)
            local docked = open()
            assert.is_true(docked.dimen.y > SCREEN.h / 2)
        end)
    end)

    describe("selection", function()
        it("marks the active tool, preset, color and width", function()
            local P = make_provider()
            local box = open(P)
            local selected_presets = {}
            for _, s in ipairs(of_kind(box, "preset")) do if s.selected then selected_presets[#selected_presets + 1] = s end end
            assert.equals(1, #selected_presets)   -- Black 3
            local colors = of_kind(box, "color")
            local sel = {}
            for _, c in ipairs(colors) do if c.selected then sel[#sel + 1] = c.value end end
            assert.same({ "Black" }, sel)
            local widths = {}
            for _, w in ipairs(of_kind(box, "width")) do if w.selected then widths[#widths + 1] = w.value end end
            assert.same({ 3 }, widths)
        end)

        it("follows the plugin's state after a refresh", function()
            local P = make_provider()
            local box = open(P)
            P.setColor("Blue"); P.setWidth(7); box:refresh()
            local sel = {}
            for _, c in ipairs(of_kind(box, "color")) do if c.selected then sel[#sel + 1] = c.value end end
            assert.same({ "Blue" }, sel)
            local w = {}
            for _, s in ipairs(of_kind(box, "width")) do if s.selected then w[#w + 1] = s.value end end
            assert.same({ 7 }, w)
        end)
    end)

    describe("taps", function()
        it("a color swatch sets the color and repaints only the box", function()
            local P = make_provider()
            local box = open(P)
            local red
            for _, c in ipairs(of_kind(box, "color")) do if c.value == "Red" then red = c end end
            red:onTapSwatch()
            assert.same({ "setColor:Red" }, P.calls)
            assert.equals(1, #dirty)
            assert.equals(box, dirty[1].w)       -- never the reader underneath
            assert.equals("ui", dirty[1].mode)
            assert.equals(box.dimen, dirty[1].region)
        end)

        it("a width swatch sets the width", function()
            local P = make_provider()
            local box = open(P)
            of_kind(box, "width")[3]:onTapSwatch()
            assert.same({ "setWidth:7" }, P.calls)
        end)

        it("a preset swatch selects that preset", function()
            local P = make_provider()
            local box = open(P)
            of_kind(box, "preset")[3]:onTapSwatch()
            assert.same({ "selectPreset:3" }, P.calls)
            assert.equals("highlighter", P.state.tool)
        end)

        it("holding a preset saves the pen in hand there", function()
            local P = make_provider()
            local box = open(P)
            of_kind(box, "preset")[2]:onHoldSwatch()
            assert.same({ "savePreset:2" }, P.calls)
        end)

        it("tapping or holding the + slot saves into the next slot", function()
            local P = make_provider()
            local box = open(P)
            of_kind(box, "add")[1]:onTapSwatch()
            of_kind(box, "add")[1]:onHoldSwatch()
            assert.same({ "savePreset:4", "savePreset:4" }, P.calls)
        end)

        it("an eraser size swatch sets the eraser size", function()
            local P = make_provider()
            local box = open(P)
            P.setTool("eraser"); box:refresh()
            P.calls = {}
            of_kind(box, "eraser")[3]:onTapSwatch()
            assert.same({ "setEraserWidth:40" }, P.calls)
        end)

        it("tool buttons switch tool", function()
            local P = make_provider()
            local box = open(P)
            button(box, "Marker").callback()
            button(box, "Eraser").callback()
            assert.same({ "setTool:highlighter", "setTool:eraser" }, P.calls)
        end)

        it("Undo calls the plugin, and is disabled once there is nothing to undo", function()
            local P = make_provider{ undo_depth = 1 }
            local box = open(P)
            assert.is_true(button(box, "Undo").enabled)
            button(box, "Undo").callback()
            assert.same({ "undo" }, P.calls)
            assert.is_false(button(box, "Undo").enabled)   -- rebuilt by refresh()
        end)

        it("a tap through a swatch never closes the box", function()
            local box = open()
            of_kind(box, "color")[2]:onTapSwatch()
            of_kind(box, "width")[1]:onTapSwatch()
            assert.equals(0, #closed)
        end)
    end)

    describe("closing", function()
        it("closes on a tap outside, once, and tells the plugin", function()
            local closes = 0
            local box = open(nil, 600, 900, function() closes = closes + 1 end)
            local ret = box:onTapCloseOutside(nil, { pos = { x = 5, y = 5 } })
            assert.is_true(ret)
            assert.equals(1, #closed)
            assert.equals(box, closed[1].w)
            assert.equals(1, closes)
            box:onTapCloseOutside(nil, { pos = { x = 5, y = 5 } })   -- a second tap
            assert.equals(1, #closed)
            assert.equals(1, closes)
        end)

        it("stays open on a tap inside the frame but between swatches", function()
            local box = open()
            local ret = box:onTapCloseOutside(nil, { pos = { x = box.dimen.x + 3, y = box.dimen.y + 3 } })
            assert.is_true(ret)             -- consumed: nothing falls through to the page
            assert.equals(0, #closed)
        end)

        it("closes from the x button", function()
            local box = open()
            button(box, "\u{00D7}").callback()
            assert.equals(1, #closed)
        end)

        it("does not repaint after it is closed", function()
            local box = open()
            box:close()
            local before = #dirty
            box:refresh()
            assert.equals(before, #dirty)
        end)

        it("swallows all gestures so nothing turns the page underneath", function()
            assert.is_true(ToolBox.stop_events_propagation)
        end)

        it("is not the reader, so the plugin treats it as an overlay", function()
            assert.is_not.equals("ReaderUI", ToolBox.name)
            assert.is_truthy(ToolBox.name)
        end)
    end)

    describe("painting", function()
        local function recorder()
            local calls = {}
            local bb = {}
            setmetatable(bb, { __index = function(_, name)
                return function(_, ...) calls[#calls + 1] = { name = name, args = { ... } } end
            end })
            return bb, calls
        end

        it("paints the frame at the absolute position, ignoring the paint offset", function()
            local box = open(nil, 600, 900)
            box:paintTo({}, 0, 0)
            assert.same({ x = box.dimen.x, y = box.dimen.y }, box.frame.painted_at)
        end)

        it("a width swatch paints a bar as thick as the stroke, capped to the swatch", function()
            local Swatch = ToolBox.Swatch
            local bb, calls = recorder()
            Swatch:new{ kind = "width", size = 36, value = 5 }:paintTo(bb, 0, 0)
            local bar
            for _, c in ipairs(calls) do
                if c.name == "paintRect" and c.args[4] == 5 then bar = c end
            end
            assert.is_truthy(bar, "no 5px bar painted")

            bb, calls = recorder()
            Swatch:new{ kind = "width", size = 36, value = 60 }:paintTo(bb, 0, 0)
            for _, c in ipairs(calls) do
                if c.name == "paintRect" then assert.is_true(c.args[4] <= 36) end
            end
        end)

        it("a selected swatch gets a thicker border than an unselected one", function()
            local Swatch = ToolBox.Swatch
            local function border_of(selected)
                local bb, calls = recorder()
                Swatch:new{ kind = "color", size = 36, color = swatch_color("Red"), value = "Red", selected = selected }:paintTo(bb, 0, 0)
                for _, c in ipairs(calls) do
                    if c.name == "paintBorder" then return c.args[5] end
                end
            end
            assert.is_true(border_of(true) > border_of(false))
        end)

        it("fills colors with paintRectRGB32, since paintRect would flatten them to gray", function()
            local Swatch = ToolBox.Swatch
            local function names(sw)
                local bb, calls = recorder()
                sw:paintTo(bb, 0, 0)
                local seen = {}
                for _, c in ipairs(calls) do seen[c.name] = (seen[c.name] or 0) + 1 end
                return seen, calls
            end
            local red = swatch_color("Red")
            local seen, calls = names(Swatch:new{ kind = "color", size = 36, color = red, value = "Red" })
            assert.is_truthy(seen.paintRectRGB32)
            for _, c in ipairs(calls) do
                if c.name == "paintRectRGB32" then assert.equals(red, c.args[5]) end
                if c.name == "paintRect" then assert.is_not.equals(red, c.args[5], "color went through paintRect") end
            end
            seen, calls = names(Swatch:new{ kind = "preset", size = 36, color = red, color_name = "Red", value = 3 })
            local colored = false
            for _, c in ipairs(calls) do
                if c.name == "paintRectRGB32" and c.args[5] == red then colored = true end
                if c.name == "paintRect" then assert.is_not.equals(red, c.args[5], "preset color went through paintRect") end
            end
            assert.is_true(colored)
        end)

        it("records its position when painted, for hit-testing taps", function()
            local sw = ToolBox.Swatch:new{ kind = "color", size = 36, color = swatch_color("Red"), value = "Red" }
            sw:paintTo(recorder(), 100, 200)
            assert.equals(100, sw.dimen.x)
            assert.equals(200, sw.dimen.y)
        end)

        it("night mode inverts a color swatch except black and gray, like strokes do", function()
            package.loaded["device"].screen.night_mode = true
            local Swatch = ToolBox.Swatch
            local function fill_of(name, v)
                local bb, calls = recorder()
                Swatch:new{ kind = "color", size = 36, color = { v = v, invert = function(c) return { v = 255 - c.v } end },
                    value = name }:paintTo(bb, 0, 0)
                for _, c in ipairs(calls) do
                    if (c.name == "paintRect" or c.name == "paintRectRGB32") and c.args[5] and c.args[5].v ~= 255 then return c.args[5].v end
                end
            end
            assert.equals(255 - 100, fill_of("Red", 100))
            assert.equals(100, fill_of("Gray", 100))
            package.loaded["device"].screen.night_mode = false
        end)
    end)
end)
