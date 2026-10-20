--[[--
Unit tests for the strokes module (store, persistence, erasing, undo, drawing).
Run with: busted spec/pencilstrokes_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

-- KOReader modules the strokes module depends on
local function clamp(v) return math.max(0, math.min(255, v)) end
local ColorRGB32
local color_mt = {}
color_mt.__index = color_mt
function color_mt:getColorRGB32() return self end
function color_mt:invert() return ColorRGB32(255 - self.r, 255 - self.g, 255 - self.b, self.alpha) end
ColorRGB32 = function(r, g, b, a) return setmetatable({ r = clamp(r), g = clamp(g), b = clamp(b), alpha = a or 255 }, color_mt) end
local Blitbuffer = {
    ColorRGB32 = ColorRGB32,
    Color8 = function(v) return ColorRGB32(v, v, v, 255) end,
}
Blitbuffer.COLOR_BLACK = Blitbuffer.Color8(0)
package.preload["ffi/blitbuffer"] = function() return Blitbuffer end
package.preload["logger"] = function()
    return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
package.preload["libs/libkoreader-lfs"] = function() return require("lfs") end
-- minimal stand-in for KOReader's dump(): serializes plain tables to Lua source
package.preload["dump"] = function()
    local function ser(v)
        if type(v) == "table" then
            local out = {}
            for k, x in pairs(v) do
                out[#out + 1] = "[" .. ser(k) .. "]=" .. ser(x)
            end
            return "{" .. table.concat(out, ",") .. "}"
        elseif type(v) == "string" then
            return string.format("%q", v)
        end
        return tostring(v)
    end
    return ser
end

local lfs = require("lfs")
local Strokes = require("lib/pencilstrokes")
local TOOLS = require("lib/penciltool").TOOLS

local function stroke(page, points, extra)
    local s = { page = page, tool = TOOLS.PEN, width = 3, color = Blitbuffer.COLOR_BLACK,
        color_name = "Black", alpha = 255, datetime = 1000, points = points }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

-- a fake framebuffer with the rect operations KOReader's blitbuffer has
local function newBB(W, H, opts)
    opts = opts or {}
    local bb = { W = W, H = H, px = {}, calls = 0, inverse = opts.inverse and 1 or 0 }
    for y = 0, H - 1 do
        bb.px[y] = {}
        for x = 0, W - 1 do bb.px[y][x] = { 255, 255, 255 } end
    end
    local function each(x, y, w, h, f)
        bb.calls = bb.calls + 1
        for yy = math.max(0, y), math.min(H - 1, y + h - 1) do
            for xx = math.max(0, x), math.min(W - 1, x + w - 1) do f(bb.px[yy][xx]) end
        end
    end
    function bb:getInverse() return self.inverse end
    if not opts.no_multiply then
        function bb:multiplyRectRGB(x, y, w, h, c)
            each(x, y, w, h, function(p)
                p[1] = math.floor(p[1] * c.r / 255 + 0.5)
                p[2] = math.floor(p[2] * c.g / 255 + 0.5)
                p[3] = math.floor(p[3] * c.b / 255 + 0.5)
            end)
        end
    end
    if not opts.no_blend then
        function bb:blendRectRGB32(x, y, w, h, c)
            local a = c.alpha / 255
            each(x, y, w, h, function(p)
                p[1] = math.floor(p[1] * (1 - a) + c.r * a + 0.5)
                p[2] = math.floor(p[2] * (1 - a) + c.g * a + 0.5)
                p[3] = math.floor(p[3] * (1 - a) + c.b * a + 0.5)
            end)
        end
    end
    function bb:paintRectRGB32(x, y, w, h, c)
        each(x, y, w, h, function(p) p[1], p[2], p[3] = c.r, c.g, c.b end)
    end
    return bb
end
local function snapshot(bb)
    local t = {}
    for y = 0, bb.H - 1 do
        for x = 0, bb.W - 1 do
            local p = bb.px[y][x]
            t[#t + 1] = p[1] .. "," .. p[2] .. "," .. p[3]
        end
    end
    return table.concat(t, ";")
end

describe("PencilStrokes", function()
    local store

    before_each(function()
        store = Strokes:new()
    end)

    describe("stroke records", function()
        it("creates an empty stroke with the tool's settings", function()
            local s = Strokes.newStroke(4, TOOLS.PEN, { width = 5, color = "C", color_name = "Red", alpha = 255 })
            assert.equals(4, s.page)
            assert.equals(TOOLS.PEN, s.tool)
            assert.same({}, s.points)
            assert.equals(5, s.width)
            assert.equals("Red", s.color_name)
            assert.is_number(s.datetime)
            assert.is_nil(s.bbox)
        end)

        it("can start with points", function()
            local s = Strokes.newStroke(1, TOOLS.PEN, {}, { { x = 1, y = 2 } })
            assert.same({ { x = 1, y = 2 } }, s.points)
        end)

        it("shows the live pen in black only for colored pen strokes", function()
            local red = { tool = TOOLS.PEN, color_name = "Red", color = "RED" }
            assert.equals(Blitbuffer.COLOR_BLACK, Strokes.liveColor(red, true))
            assert.equals("RED", Strokes.liveColor(red, false))
            assert.equals("RED", Strokes.liveColor({ tool = TOOLS.HIGHLIGHTER, color_name = "Red", color = "RED" }, true))
            assert.equals("B", Strokes.liveColor({ tool = TOOLS.PEN, color_name = "Black", color = "B" }, true))
        end)
    end)

    describe("saved form", function()
        local ctx = {
            tool_settings = function(tool)
                if tool == TOOLS.HIGHLIGHTER then return { width = 20, color = "HLDEFAULT", alpha = 166 } end
                return { width = 3, color = "PENDEFAULT", alpha = 255 }
            end,
            available_colors = { { name = "Red", color = "RED" }, { name = "Gray", color = "GRAY" } },
        }

        it("round-trips a stroke", function()
            local s = stroke(2, { { x = 1, y = 2 }, { x = 30, y = 40 } }, { color_name = "Red", color = "RED",
                embedded = true, annot_id = "a1", transcription = "hi" })
            local saved = Strokes.toSaveable(s)
            assert.is_string(saved.p)
            assert.is_nil(saved.points)
            local back = Strokes.fromSaved(saved, ctx)
            assert.same(s.points, back.points)
            assert.equals("RED", back.color)
            assert.equals("Red", back.color_name)
            assert.is_true(back.embedded)
            assert.equals("a1", back.annot_id)
            assert.equals("hi", back.transcription)
            assert.equals(2, back.page)
            assert.is_table(back.bbox)
        end)

        it("round-trips the page coordinates of a PDF stroke", function()
            local s = stroke(2, { { x = 10, y = 20 } }, { page_points = { { x = 1.5, y = 2.5 } } })
            local saved = Strokes.toSaveable(s)
            assert.is_string(saved.pp)
            local back = Strokes.fromSaved(saved, ctx)
            assert.same({ { x = 1.5, y = 2.5 } }, back.page_points)
            assert.is_nil(Strokes.toSaveable(stroke(1, { { x = 1, y = 1 } })).pp)
            assert.is_nil(Strokes.fromSaved(Strokes.toSaveable(stroke(1, { { x = 1, y = 1 } })), ctx).page_points)
        end)

        it("uses the tool's defaults for a missing width, color or alpha", function()
            local back = Strokes.fromSaved({ page = 1, tool = TOOLS.PEN, p = "1 2" }, ctx)
            assert.equals(3, back.width)
            assert.equals("PENDEFAULT", back.color)
            assert.equals(255, back.alpha)
        end)

        it("loads strokes saved with a points array (v3 and earlier)", function()
            local back = Strokes.fromSaved({ page = 1, tool = TOOLS.PEN, points = { { x = 5, y = 6 } } }, ctx)
            assert.same({ { x = 5, y = 6 } }, back.points)
        end)

        it("keeps old highlighter strokes (no color name) opaque light gray", function()
            local back = Strokes.fromSaved({ page = 1, tool = TOOLS.HIGHLIGHTER, alpha = 128, p = "1 2" }, ctx)
            assert.equals(0xDD, back.color.r)
            assert.equals(0xFF, back.alpha)
        end)

        it("a highlighter stroke with a color name follows that color and its own alpha", function()
            local back = Strokes.fromSaved({ page = 1, tool = TOOLS.HIGHLIGHTER, alpha = 128, color_name = "Red", p = "1 2" }, ctx)
            assert.equals("RED", back.color)
            assert.equals(128, back.alpha)
        end)
    end)

    describe("store and page index", function()
        it("adds, indexes and looks up strokes by page", function()
            local a = stroke(1, { { x = 0, y = 0 } })
            local b = stroke(2, { { x = 0, y = 0 } })
            local c = stroke(1, { { x = 5, y = 5 } })
            assert.equals(1, store:add(a))
            assert.equals(2, store:add(b))
            assert.equals(3, store:add(c))
            assert.equals(3, store:count())
            assert.same({ a, c }, store:forPage(1))
            assert.same({ b }, store:forPage(2))
            assert.same({}, store:forPage(9))
            assert.is_true(store:hasOnPage(1))
            assert.is_false(store:hasOnPage(9))
        end)

        it("iterates a page's strokes with their index", function()
            local a = stroke(1, { { x = 0, y = 0 } })
            local b = stroke(2, { { x = 0, y = 0 } })
            local c = stroke(1, { { x = 5, y = 5 } })
            store:add(a); store:add(b); store:add(c)
            local seen = {}
            for s, idx in store:pageStrokes(1) do seen[#seen + 1] = { s, idx } end
            assert.same({ { a, 1 }, { c, 3 } }, seen)
            for _ in store:pageStrokes(7) do error("no strokes on page 7") end
        end)

        it("rebuilds the index from the strokes", function()
            store:add(stroke(1, { { x = 0, y = 0 } }))
            store.page_strokes = {}
            store:rebuildPageIndex()
            assert.is_true(store:hasOnPage(1))
        end)
    end)

    describe("history", function()
        local function translate_by_hand(strokes, dx, dy, _, sign)
            for _, st in ipairs(strokes) do
                for _, pt in ipairs(st.points) do pt.x = pt.x + sign * dx; pt.y = pt.y + sign * dy end
            end
        end

        it("has nothing to undo or redo at first", function()
            assert.is_false(store:canUndo())
            assert.is_false(store:canRedo())
            assert.is_false(store:undo())
            assert.is_false(store:redo())
        end)

        it("undoes and redoes an added stroke", function()
            local s = stroke(1, { { x = 0, y = 0 } })
            local idx = store:add(s)
            store:pushUndo({ type = "add", stroke_idx = idx })
            assert.is_true(store:canUndo())
            assert.is_true(store:undo())
            store:rebuildPageIndex()
            assert.equals(0, store:count())
            assert.is_true(store:canRedo())
            assert.is_false(store:canUndo())
            assert.is_true(store:redo())
            store:rebuildPageIndex()
            assert.same({ s }, store:forPage(1))
            assert.is_true(store:canUndo())
            assert.is_false(store:canRedo())
        end)

        it("an add action remembers the stroke, not its index", function()
            local first = stroke(1, { { x = 0, y = 0 } })
            local second = stroke(1, { { x = 9, y = 9 } })
            store:add(first)
            store:pushUndo({ type = "add", stroke_idx = store:add(second) })
            -- an unrelated stroke is erased: indices shift
            store:removeStrokes({ first })
            assert.is_true(store:undo())
            assert.equals(0, store:count())
        end)

        it("undoes a deletion by restoring the strokes, and redoes it", function()
            local s = stroke(3, { { x = 0, y = 0 } })
            store:pushUndo({ type = "delete", strokes = { s } })
            assert.is_true(store:undo())
            store:rebuildPageIndex()
            assert.same({ s }, store:forPage(3))
            assert.is_true(store:redo())
            assert.equals(0, store:count())
        end)

        it("undoes in reverse order", function()
            local i1 = store:add(stroke(1, { { x = 0, y = 0 } })); store:pushUndo({ type = "add", stroke_idx = i1 })
            local i2 = store:add(stroke(1, { { x = 9, y = 9 } })); store:pushUndo({ type = "add", stroke_idx = i2 })
            store:undo()
            assert.equals(1, store:count())
            store:undo()
            assert.equals(0, store:count())
        end)

        it("a new action invalidates the redo history", function()
            local i1 = store:add(stroke(1, { { x = 0, y = 0 } })); store:pushUndo({ type = "add", stroke_idx = i1 })
            store:undo()
            assert.is_true(store:canRedo())
            store:pushUndo({ type = "delete", strokes = {} })
            assert.is_false(store:canRedo())
        end)

        it("pops an action even when it can no longer be applied", function()
            store:pushUndo({ type = "add", stroke = stroke(1, { { x = 0, y = 0 } }) })  -- never added
            assert.is_true(store:undo())
            assert.is_false(store:canRedo())  -- nothing to redo: it did not apply
        end)

        it("undoes and redoes a move through the translate function of the caller", function()
            local s = stroke(1, { { x = 10, y = 10 } })
            store:add(s)
            translate_by_hand({ s }, 5, 7, nil, 1)
            store:pushUndo({ type = "move", strokes = { s }, dx = 5, dy = 7, pdeltas = {} })
            store:undo(translate_by_hand)
            assert.same({ x = 10, y = 10 }, s.points[1])
            store:redo(translate_by_hand)
            assert.same({ x = 15, y = 17 }, s.points[1])
        end)

        it("can drop the whole history", function()
            store:pushUndo({ type = "delete", strokes = {} })
            store:undo()
            store:clearHistory()
            assert.is_false(store:canUndo())
            assert.is_false(store:canRedo())
        end)
    end)

    describe("removing strokes", function()
        it("removes by reference and returns the indices, last to first", function()
            local a, b, c = stroke(1, { { x = 0, y = 0 } }), stroke(1, { { x = 1, y = 1 } }), stroke(1, { { x = 2, y = 2 } })
            store:add(a); store:add(b); store:add(c)
            assert.same({ 3, 1 }, store:removeStrokes({ a, c }))
            assert.same({ b }, store.strokes)
        end)

        it("tells on_removed which indices went, so groups can renumber", function()
            local told
            local s2 = Strokes:new({ on_removed = function(indices) told = indices end })
            local a, b = stroke(1, { { x = 0, y = 0 } }), stroke(1, { { x = 1, y = 1 } })
            s2:add(a); s2:add(b)
            s2:removeStrokes({ a })
            assert.same({ 1 }, told)
        end)

        it("returns nil, and says nothing, when no stroke is in the list", function()
            local told = false
            local s2 = Strokes:new({ on_removed = function() told = true end })
            assert.is_nil(s2:removeStrokes({ stroke(1, { { x = 0, y = 0 } }) }))
            assert.is_false(told)
        end)

        it("finds a stroke by reference, trying the remembered index first", function()
            local a, b = stroke(1, { { x = 0, y = 0 } }), stroke(1, { { x = 1, y = 1 } })
            store:add(a); store:add(b)
            assert.equals(2, store:findIndex(b))
            assert.equals(2, store:findIndex(b, 2))
            assert.equals(2, store:findIndex(b, 1))
            assert.is_nil(store:findIndex(stroke(1, {})))
        end)
    end)

    describe("erasing", function()
        -- like a real stroke, with a point every 10px (the eraser tests the points)
        local line = function(page, y)
            local points = {}
            for x = 0, 100, 10 do points[#points + 1] = { x = x, y = y } end
            return stroke(page, points)
        end

        it("removes the strokes the eraser passes over and reindexes", function()
            local keep = line(1, 200)
            store:add(line(1, 50)); store:add(keep)
            local deleted, indices = store:eraseAtPoint(50, 52, { 1 }, 20)
            assert.equals(1, #deleted)
            assert.same({ 1 }, indices)
            assert.equals(1, store:count())
            assert.same({ keep }, store:forPage(1))
        end)

        it("returns nil when nothing is near", function()
            store:add(line(1, 50))
            assert.is_nil(store:eraseAtPoint(50, 500, { 1 }, 20))
            assert.equals(1, store:count())
        end)

        it("only erases strokes of the given pages", function()
            store:add(line(2, 50))
            assert.is_nil(store:eraseAtPoint(50, 50, { 1 }, 20))
            assert.equals(1, store:count())
            assert.equals(1, #store:eraseAtPoint(50, 50, { 1, 2 }, 20))
        end)

        it("only erases what the caller says is erasable", function()
            local shown = line(1, 50)
            local hidden = line(1, 52)
            store:add(shown); store:add(hidden)
            local asked = {}
            local deleted = store:eraseAtPoint(50, 51, { 1 }, 20, function(s, p)
                asked[#asked + 1] = p
                return s == shown
            end)
            assert.same({ shown }, deleted)
            assert.same({ hidden }, store:forPage(1))
            assert.same({ 1, 1 }, asked)
        end)

        it("returns nil for an empty store", function()
            assert.is_nil(store:eraseAtPoint(1, 1, { 1 }, 20))
        end)

        it("can erase several strokes at once", function()
            store:add(line(1, 50)); store:add(line(1, 55)); store:add(line(1, 400))
            assert.equals(2, #store:eraseAtPoint(50, 52, { 1 }, 20))
            assert.equals(1, store:count())
        end)

        it("reports what it does when a log function is given", function()
            local lines = {}
            local logged = Strokes:new({ log = function(msg) lines[#lines + 1] = msg end })
            logged:add(line(1, 50))
            logged:eraseAtPoint(50, 52, { 1 }, 20)
            assert.is_true(#lines >= 3)
        end)

        it("gives the screen rect to refresh for erased strokes", function()
            local x, y, w, h = Strokes.erasedRefreshRect({ line(1, 100) }, 20, 1000, 1000)
            assert.equals(0, x)    -- -20 clamped to the screen
            assert.equals(80, y)
            assert.equals(120, w)  -- 0..100 widened by 20 on each side, clamped at x=0
            assert.equals(40, h)
        end)

        it("asks for a full refresh when the strokes have no geometry", function()
            assert.is_nil(Strokes.erasedRefreshRect({ { points = {} } }, 20, 1000, 1000))
            assert.is_nil(Strokes.erasedRefreshRect({}, 20, 1000, 1000))
            assert.is_nil(Strokes.erasedRefreshRect(nil, 20, 1000, 1000))
        end)
    end)

    describe("clearing", function()
        it("clears a page, undoably", function()
            local a = stroke(1, { { x = 0, y = 0 } })
            local b = stroke(2, { { x = 0, y = 0 } })
            store:add(a); store:add(b)
            local removed = store:clearPage(1)
            assert.same({ a }, removed)
            assert.same({ b }, store:forPage(2))
            assert.is_true(store:undo())
            store:rebuildPageIndex()
            assert.same({ a }, store:forPage(1))
        end)

        it("reports an empty page", function()
            assert.is_nil(store:clearPage(5))
            assert.is_false(store:canUndo())
        end)

        it("clears everything", function()
            store:add(stroke(1, { { x = 0, y = 0 } }))
            store:clearAll()
            assert.equals(0, store:count())
            assert.is_false(store:hasOnPage(1))
        end)
    end)

    describe("page anchoring", function()
        it("gives a stroke page coordinates from its captured anchor", function()
            local s = stroke(7, { { x = 110, y = 220 }, { x = 210, y = 420 } })
            s._anchor_page, s._anchor_zoom, s._anchor_ox, s._anchor_oy = 3, 2, 10, 20
            assert.is_true(Strokes.anchorToPage(s))
            assert.same({ { x = 50, y = 100 }, { x = 100, y = 200 } }, s.page_points)
            assert.equals(3, s.page)
            assert.equals(2, s._vz)
            assert.same({ 10, 20 }, { s._vox, s._voy })
            assert.is_nil(s._anchor_zoom)
            assert.is_nil(s._anchor_page)
        end)

        it("does nothing without an anchor or when already anchored", function()
            assert.is_false(Strokes.anchorToPage(stroke(1, { { x = 1, y = 1 } })))
            local s = stroke(1, { { x = 1, y = 1 } }, { page_points = { { x = 0, y = 0 } } })
            s._anchor_zoom = 2
            assert.is_false(Strokes.anchorToPage(s))
            assert.same({ { x = 0, y = 0 } }, s.page_points)
        end)

        it("projects page coordinates onto the screen for a view", function()
            local s = stroke(1, { { x = 0, y = 0 } }, { page_points = { { x = 50, y = 100 }, { x = 60, y = 110 } } })
            assert.is_true(Strokes.syncToView(s, 2, 10, 20))
            assert.same({ { x = 110, y = 220 }, { x = 130, y = 240 } }, s.points)
            assert.same({ 2, 10, 20 }, { s._vz, s._vox, s._voy })
        end)

        it("leaves the points alone when the view hasn't changed", function()
            local s = stroke(1, { { x = 0, y = 0 } }, { page_points = { { x = 50, y = 100 } } })
            Strokes.syncToView(s, 2, 10, 20)
            local pt = s.points[1]
            pt.x = 999  -- would be overwritten by a real sync
            assert.is_true(Strokes.syncToView(s, 2, 10, 20))
            assert.equals(999, s.points[1].x)
            assert.is_true(Strokes.syncToView(s, 3, 10, 20))
            assert.equals(160, s.points[1].x)  -- 50 * 3 + 10
        end)

        it("reports a page that isn't shown, and leaves screen strokes in sync", function()
            local s = stroke(1, { { x = 5, y = 5 } }, { page_points = { { x = 50, y = 100 } } })
            assert.is_false(Strokes.syncToView(s, nil))
            assert.same({ x = 5, y = 5 }, s.points[1])
            assert.is_true(Strokes.syncToView(stroke(1, { { x = 5, y = 5 } }), nil))
        end)

        it("drops screen points the page points no longer have", function()
            local s = stroke(1, { { x = 1, y = 1 }, { x = 2, y = 2 }, { x = 3, y = 3 } }, { page_points = { { x = 5, y = 5 } } })
            Strokes.syncToView(s, 1, 0, 0)
            assert.equals(1, #s.points)
        end)
    end)

    describe("moving strokes", function()
        local view
        view = {
            zoom = function(page) return page == 1 and 2 or nil end,
            sync = function(s) return Strokes.syncToView(s, view.zoom(s.page), 0, 0) end,
        }

        it("shifts screen strokes by the screen distance, and back", function()
            local s = stroke(1, { { x = 10, y = 10 }, { x = 20, y = 20 } })
            Strokes.translate({ s }, 5, -3, nil, 1, view)
            assert.same({ { x = 15, y = 7 }, { x = 25, y = 17 } }, s.points)
            Strokes.translate({ s }, 5, -3, nil, -1, view)
            assert.same({ { x = 10, y = 10 }, { x = 20, y = 20 } }, s.points)
        end)

        it("moves page-anchored strokes in page space, by the view zoom", function()
            local s = stroke(1, { { x = 20, y = 20 } }, { page_points = { { x = 10, y = 10 } } })
            s._vz = 2
            local pdeltas = Strokes.translate({ s }, 10, 20, nil, 1, view)
            assert.same({ { x = 5, y = 10 } }, pdeltas)
            assert.same({ { x = 15, y = 20 } }, s.page_points)
            assert.same({ { x = 30, y = 40 } }, s.points)  -- re-projected on screen
        end)

        it("reuses the page deltas, so undo and redo restore the exact position", function()
            local s = stroke(1, { { x = 20, y = 20 } }, { page_points = { { x = 10, y = 10 } } })
            s._vz = 2
            local pdeltas = Strokes.translate({ s }, 10, 20, nil, 1, view)
            Strokes.translate({ s }, 10, 20, pdeltas, -1, view)
            assert.same({ { x = 10, y = 10 } }, s.page_points)
            assert.same({ { x = 20, y = 20 } }, s.points)
        end)

        it("falls back to the screen shift when the stroke's page isn't shown", function()
            local s = stroke(2, { { x = 20, y = 20 } }, { page_points = { { x = 10, y = 10 } } })
            Strokes.translate({ s }, 10, 20, nil, 1, view)
            assert.same({ { x = 30, y = 40 } }, s.points)
            assert.same({ { x = 10, y = 10 } }, s.page_points)  -- zoom unknown: page space untouched
        end)
    end)

    describe("persistence", function()
        local dir, file
        local ctx = {
            tool_settings = function() return { width = 3, color = Blitbuffer.COLOR_BLACK, alpha = 255 } end,
            available_colors = { { name = "Black", color = Blitbuffer.COLOR_BLACK } },
        }

        before_each(function()
            dir = os.tmpname()
            os.remove(dir)
            lfs.mkdir(dir)
            file = dir .. "/pencil_strokes.lua"
        end)

        after_each(function()
            os.remove(file)
            lfs.rmdir(dir)
        end)

        it("saves and loads strokes and extra data", function()
            store.loaded = true
            store:add(stroke(1, { { x = 1, y = 2 }, { x = 3, y = 4 } }))
            store:add(stroke(2, { { x = 5, y = 6 } }))
            assert.is_true(store:save(file, { annotation_groups = { { id = "g1" } } }))

            local other = Strokes:new()
            local status, data = other:load(file, ctx)
            assert.equals("ok", status)
            assert.equals(5, data.version)
            assert.equals("g1", data.annotation_groups[1].id)
            assert.equals(2, other:count())
            assert.same({ { x = 1, y = 2 }, { x = 3, y = 4 } }, other.strokes[1].points)
            assert.is_true(other:hasOnPage(2))
            assert.is_true(other.loaded)
        end)

        it("refuses to save nothing before anything was loaded", function()
            assert.is_false(store:save(file))
            assert.is_nil(lfs.attributes(file))
        end)

        it("saves an emptied store once it was loaded (so clearing persists)", function()
            store.loaded = true
            assert.is_true(store:save(file))
            local other = Strokes:new()
            assert.equals("ok", (other:load(file, ctx)))
            assert.equals(0, other:count())
        end)

        it("does not save without a path", function()
            store.loaded = true
            assert.is_false(store:save(nil))
        end)

        it("reports a missing file and counts it as loaded", function()
            store:add(stroke(1, { { x = 0, y = 0 } }))
            assert.equals("missing", (store:load(file, ctx)))
            assert.equals(0, store:count())
            assert.is_true(store.loaded)
        end)

        it("reports no path", function()
            assert.equals("no_path", (store:load(nil, ctx)))
            assert.is_false(store.loaded)
        end)

        it("reports an unreadable file and leaves the store empty and unloaded", function()
            local f = io.open(file, "w"); f:write("this is not lua ("); f:close()
            local status = store:load(file, ctx)
            assert.equals("error", status)
            assert.equals(0, store:count())
            assert.is_false(store.loaded)
        end)
    end)

    describe("the strokes file of a document", function()
        local function settingsWith(sidecar, saved)
            local data = { pencil_strokes_path = saved }
            return {
                doc_sidecar_dir = sidecar,
                saveSetting = function(self, k, v) data[k] = v end,
                readSetting = function(self, k) return data[k] end,
                data = data,
            }
        end

        it("lives in the document's sidecar", function()
            assert.equals("/books/a.sdr/pencil_strokes.lua", Strokes.getFilePath(settingsWith("/books/a.sdr")))
        end)

        it("has no path without settings or sidecar", function()
            assert.is_nil(Strokes.getFilePath(nil))
            assert.is_nil(Strokes.getFilePath(settingsWith(nil)))
        end)

        it("remembers its path in the document settings", function()
            local s = settingsWith("/x")
            Strokes.rememberFilePath(s, "/x/pencil_strokes.lua")
            assert.equals("/x/pencil_strokes.lua", s.data.pencil_strokes_path)
        end)

        it("moves the file to the new sidecar after a rename", function()
            local base = os.tmpname(); os.remove(base); lfs.mkdir(base)
            local old, new = base .. "/old.sdr", base .. "/new.sdr"
            lfs.mkdir(old); lfs.mkdir(new)
            local f = io.open(old .. "/pencil_strokes.lua", "w"); f:write("return {}"); f:close()

            local s = settingsWith(new, old .. "/pencil_strokes.lua")
            local path = Strokes.migrateFileIfNeeded(s)
            assert.equals(new .. "/pencil_strokes.lua", path)
            assert.equals("file", lfs.attributes(path, "mode"))
            assert.is_nil(lfs.attributes(old))  -- the empty legacy sidecar was removed
            assert.equals(path, s.data.pencil_strokes_path)

            os.remove(path); lfs.rmdir(new); lfs.rmdir(base)
        end)

        it("leaves an existing file alone and remembers it", function()
            local base = os.tmpname(); os.remove(base); lfs.mkdir(base)
            local f = io.open(base .. "/pencil_strokes.lua", "w"); f:write("return {}"); f:close()
            local s = settingsWith(base)
            assert.equals(base .. "/pencil_strokes.lua", Strokes.migrateFileIfNeeded(s))
            assert.equals(base .. "/pencil_strokes.lua", s.data.pencil_strokes_path)
            os.remove(base .. "/pencil_strokes.lua"); lfs.rmdir(base)
        end)

        it("does nothing when there is no earlier file to move", function()
            local s = settingsWith("/nonexistent.sdr", "/also/nonexistent/pencil_strokes.lua")
            assert.equals("/nonexistent.sdr/pencil_strokes.lua", Strokes.migrateFileIfNeeded(s))
        end)
    end)

    describe("drawing", function()
        local ctx = { tool_settings = function() return { width = 3, color = Blitbuffer.COLOR_BLACK } end }

        it("draws a single point as a square dot", function()
            local bb = newBB(40, 40)
            Strokes.render(bb, stroke(1, { { x = 20, y = 20 } }, { width = 4, color = Blitbuffer.Color8(10) }), ctx)
            assert.equals(10, bb.px[19][19][1])
            assert.equals(10, bb.px[21][21][1])
            assert.equals(255, bb.px[22][22][1])
            assert.equals(255, bb.px[17][20][1])
        end)

        it("draws a line between points", function()
            local bb = newBB(60, 20)
            Strokes.render(bb, stroke(1, { { x = 5, y = 10 }, { x = 50, y = 10 } }, { width = 3 }), ctx)
            assert.equals(0, bb.px[10][5][1])
            assert.equals(0, bb.px[10][27][1])
            assert.equals(0, bb.px[10][50][1])
            assert.equals(255, bb.px[15][27][1])
        end)

        it("shifts a stroke by (dx, dy)", function()
            local bb = newBB(60, 20)
            Strokes.render(bb, stroke(1, { { x = 5, y = 5 } }, { width = 2 }), ctx, 20, 7)
            assert.equals(0, bb.px[12][25][1])
            assert.equals(255, bb.px[5][5][1])
        end)

        it("falls back to the tool's width and color", function()
            local bb = newBB(20, 20)
            Strokes.render(bb, { tool = TOOLS.PEN, points = { { x = 10, y = 10 } } }, ctx)
            assert.equals(0, bb.px[10][10][1])
        end)

        it("draws nothing for an empty stroke", function()
            local bb = newBB(20, 20)
            Strokes.render(bb, stroke(1, {}), ctx)
            Strokes.render(bb, nil, ctx)
            assert.equals(0, bb.calls)
        end)

        it("inverts colors in night mode, except black and gray", function()
            local bb = newBB(20, 20)
            Strokes.render(bb, stroke(1, { { x = 10, y = 10 } }, { width = 2, color = Blitbuffer.ColorRGB32(200, 0, 0, 255), color_name = "Red" }),
                { tool_settings = ctx.tool_settings, night_mode = true })
            assert.equals(55, bb.px[10][10][1])
            local bb2 = newBB(20, 20)
            Strokes.render(bb2, stroke(1, { { x = 10, y = 10 } }, { width = 2, color = Blitbuffer.Color8(30), color_name = "Gray" }),
                { tool_settings = ctx.tool_settings, night_mode = true })
            assert.equals(30, bb2.px[10][10][1])
        end)
    end)

    describe("highlighter drawing", function()
        local YELLOW = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0x33)
        local function hl(points, alpha, color)
            return { tool = TOOLS.HIGHLIGHTER, points = points, width = 20, color = color or YELLOW, alpha = alpha }
        end
        local ctx = { tool_settings = function() return { width = 20 } end }
        -- a stroke that doubles back over itself and crosses itself
        local scribble = {}
        for i = 0, 30 do scribble[#scribble + 1] = { x = 20 + i * 4, y = 60 + (i % 2) * 3 } end
        for i = 30, 0, -1 do scribble[#scribble + 1] = { x = 20 + i * 4, y = 62 } end
        for i = 0, 12 do scribble[#scribble + 1] = { x = 70, y = 20 + i * 6 } end
        local function page()
            local bb = newBB(160, 120)
            for x = 30, 120 do bb.px[58][x] = { 0, 0, 0 } end  -- a line of text
            return bb
        end

        it("shows the color on white paper and leaves the text readable", function()
            local bb = page()
            Strokes.render(bb, hl(scribble, 255), ctx)
            assert.same({ 255, 255, 0x33 }, bb.px[70][50])
            assert.same({ 0, 0, 0 }, bb.px[58][60])
            assert.same({ 255, 255, 255 }, bb.px[110][150])
        end)

        it("blends overlapping passes once: no darker than a single pass", function()
            local bb = page()
            Strokes.render(bb, hl(scribble, 255), ctx)
            local once = newBB(160, 120)
            Strokes.render(once, hl({ { x = 30, y = 70 }, { x = 120, y = 70 } }, 255), ctx)
            assert.equals(once.px[70][60][3], bb.px[70][60][3])
            local darkest = 255
            for y = 0, 119 do
                for x = 0, 159 do
                    local p = bb.px[y][x]
                    if p[1] == 255 and p[2] == 255 then darkest = math.min(darkest, p[3]) end
                end
            end
            assert.equals(0x33, darkest)
        end)

        it("mixes the color with white by alpha", function()
            local half = newBB(160, 120)
            Strokes.render(half, hl({ { x = 30, y = 70 }, { x = 120, y = 70 } }, 128), ctx)
            assert.equals(math.floor(255 - (255 - 0x33) * 128 / 255 + 0.5), half.px[70][60][3])
            local quarter = newBB(160, 120)
            Strokes.render(quarter, hl({ { x = 30, y = 70 }, { x = 120, y = 70 } }, 64), ctx)
            assert.is_true(quarter.px[70][60][3] > half.px[70][60][3])
        end)

        it("default gray at 65% is about the old light gray", function()
            local bb = newBB(160, 120)
            Strokes.render(bb, hl({ { x = 30, y = 70 }, { x = 120, y = 70 } }, 166, Blitbuffer.Color8(204)), ctx)
            assert.is_true(math.abs(bb.px[70][60][1] - 0xDD) <= 1)
        end)

        it("drawn live point by point equals the final render", function()
            local live_bb = page()
            local st = hl({}, 200)
            local live
            for i, pt in ipairs(scribble) do
                st.points[#st.points + 1] = pt
                local prev = st.points[i - 1] or pt
                live = Strokes.drawLiveHighlighter(live, live_bb, st, prev.x, prev.y, pt.x, pt.y)
            end
            local full_bb = page()
            Strokes.render(full_bb, hl(scribble, 200), ctx)
            assert.equals(snapshot(full_bb), snapshot(live_bb))
        end)

        it("a repaint in the middle of the stroke leaves no holes and no double blending", function()
            local bb = page()
            local st = hl({}, 200)
            local live
            local half_n = math.floor(#scribble / 2)
            for i = 1, half_n do
                st.points[#st.points + 1] = scribble[i]
                local prev = st.points[i - 1] or scribble[i]
                live = Strokes.drawLiveHighlighter(live, bb, st, prev.x, prev.y, scribble[i].x, scribble[i].y)
            end
            bb.px = page().px                       -- the view repaints: the page ...
            Strokes.render(bb, st, ctx)             -- ... and the stroke so far
            for i = half_n + 1, #scribble do
                st.points[#st.points + 1] = scribble[i]
                live = Strokes.drawLiveHighlighter(live, bb, st, scribble[i - 1].x, scribble[i - 1].y, scribble[i].x, scribble[i].y)
            end
            local full_bb = page()
            Strokes.render(full_bb, hl(scribble, 200), ctx)
            assert.equals(snapshot(full_bb), snapshot(bb))
        end)

        it("starts fresh coverage for a new stroke", function()
            local bb = newBB(160, 120)
            local a = hl({ { x = 50, y = 50 } }, 255)
            local live = Strokes.drawLiveHighlighter(nil, bb, a, 50, 50, 50, 50)
            local b = hl({ { x = 50, y = 50 } }, 255)
            local live2 = Strokes.drawLiveHighlighter(live, bb, b, 50, 50, 50, 50)
            assert.are_not.equals(live, live2)
            assert.equals(b, live2.stroke)
        end)

        it("caches the covered rectangles and follows a growing stroke", function()
            local s = hl({ { x = 30, y = 70 }, { x = 60, y = 70 } }, 255)
            Strokes.render(newBB(160, 120), s, ctx)
            assert.equals(2, s.hl_cache.n)
            s.points[#s.points + 1] = { x = 100, y = 70 }
            local bb = newBB(160, 120)
            Strokes.render(bb, s, ctx)
            assert.equals(3, s.hl_cache.n)
            assert.equals(0x33, bb.px[70][95][3])
        end)

        it("shifts by an offset", function()
            local bb = newBB(160, 120)
            Strokes.render(bb, hl({ { x = 30, y = 70 }, { x = 60, y = 70 } }, 255), ctx, 10, 5)
            assert.equals(0x33, bb.px[75][50][3])
            assert.equals(255, bb.px[75][15][3])
        end)

        it("a single point is a width x width square", function()
            local bb = newBB(160, 120)
            Strokes.render(bb, hl({ { x = 50, y = 50 } }, 255), ctx)
            assert.equals(0x33, bb.px[41][41][3])
            assert.equals(0x33, bb.px[59][59][3])
            assert.equals(255, bb.px[60][60][3])
            assert.equals(255, bb.px[39][50][3])
        end)

        it("a straight highlight is a single blend call", function()
            local bb = newBB(700, 60)
            Strokes.render(bb, hl({ { x = 30, y = 30 }, { x = 600, y = 30 } }, 255), ctx)
            assert.equals(1, bb.calls)
        end)

        it("alpha-blends the inverted color on an inverted screen", function()
            local bb = newBB(160, 120, { inverse = true })
            Strokes.render(bb, hl({ { x = 30, y = 70 }, { x = 120, y = 70 } }, 128), ctx)
            local a = 128 / 255
            assert.equals(math.floor(255 * (1 - a) + 0 * a + 0.5), bb.px[70][60][1])
        end)

        it("alpha-blends without multiplyRectRGB, and paints mixed-with-white without any blend support", function()
            local a = 128 / 255
            local no_mul = newBB(160, 120, { no_multiply = true })
            Strokes.render(no_mul, hl({ { x = 30, y = 70 }, { x = 120, y = 70 } }, 128), ctx)
            assert.equals(math.floor(255 * (1 - a) + 0x33 * a + 0.5), no_mul.px[70][60][3])
            local bare = newBB(160, 120, { no_multiply = true, no_blend = true })
            Strokes.render(bare, hl({ { x = 30, y = 70 }, { x = 120, y = 70 } }, 128), ctx)
            assert.equals(math.floor(255 - (255 - 0x33) * 128 / 255 + 0.5), bare.px[70][60][3])
        end)
    end)
end)
