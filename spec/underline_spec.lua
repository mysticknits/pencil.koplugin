--[[--
Underline-by-hold tests, run against the real main.lua.
KOReader modules are replaced with permissive stubs so the plugin can be
loaded outside the reader; scheduled callbacks are captured and fired by hand.
Run with: busted spec/underline_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

-- A stub that accepts any field access or call and returns another stub.
local function make_stub()
    return setmetatable({}, {
        __index = function() return make_stub() end,
        __call = function() return make_stub() end,
    })
end

-- Geometry is a deterministic test double; plugin methods run unchanged.
local geometry = {}
function geometry.computeStrokeBbox(s)
    local b = { x0=math.huge, y0=math.huge, x1=-math.huge, y1=-math.huge }
    for _, p in ipairs(s.points) do
        b.x0, b.y0 = math.min(b.x0,p.x), math.min(b.y0,p.y)
        b.x1, b.y1 = math.max(b.x1,p.x), math.max(b.y1,p.y)
    end
    return b
end
function geometry.bboxDistance(a,b)
    local dx = math.max(0,a.x0-b.x1,b.x0-a.x1)
    local dy = math.max(0,a.y0-b.y1,b.y0-a.y1)
    return math.sqrt(dx*dx+dy*dy)
end
local scheduled = {}

local screen = {
    bb = { paintRectRGB32 = function() end },
    night_mode = false,
    getRotationMode = function() return 0 end,
    getWidth = function() return 1404 end,
    getHeight = function() return 1872 end,
    refreshFast = function() end,
    refreshUI = function() end,
}

local stubs = {
    ["lib/geometry"] = geometry,
    ["geometry"] = geometry,
    ["device"] = setmetatable({ screen = screen }, {
        __index = function() return function() return true end end,
    }),
    ["ui/uimanager"] = setmetatable({
        scheduleIn = function(_, _, fn) scheduled[fn] = true end,
        unschedule = function(_, fn) scheduled[fn] = nil end,
    }, { __index = function() return function() end end }),
    ["ui/time"] = {
        now = function() return 0 end,
        to_ms = function(t) return t end,
    },
    ["ui/widget/container/inputcontainer"] = {
        -- No stub fallback: unset fields must read as nil, as in KOReader.
        extend = function(_, o) return o or {} end,
    },
    ["gettext"] = function(s) return s end,
    ["logger"] = setmetatable({}, { __index = function() return function() end end }),
}

local function load_pencil()
    -- Lua 5.1/LuaJIT uses package.loaders; Lua 5.2+ uses
    -- package.searchers.
    local loaders = package.loaders or package.searchers

    table.insert(loaders, 2, function(name)
                     if name == "lib/geometry" then return function() return geometry end end
                     return function() return stubs[name] or make_stub() end
    end)

    local ok, result = pcall(dofile, "pencil.koplugin/main.lua")
    table.remove(loaders, 2)

    if not ok then
        error(result, 0)
    end

    return result
end

local Pencil = load_pencil()

local function fire_scheduled()
    local fns = {}
    for fn in pairs(scheduled) do table.insert(fns, fn) end
    for _, fn in ipairs(fns) do
        scheduled[fn] = nil
        fn()
    end
end

-- Three text lines occupy y = 100..120, 140..160 and 180..200.
local function in_text(pos)
    return pos.x >= 50 and pos.x <= 900 and ((pos.y >= 100 and pos.y <= 120) or (pos.y >= 140 and pos.y <= 160) or (pos.y >= 180 and pos.y <= 200))
end

local function new_pencil(opts)
    opts = opts or {}
    local saved = {}
    local p = setmetatable({
        current_tool = "pen",
        tool_settings = { pen = { color = { getColor8 = function() return { a = 0 } end }, color_name = "Black", width = 3, alpha = 1 } },
        strokes = {},
        annotation_groups = {},
        undo_stack = {},
        refresh_interval_ms = 16,
        input_debug_mode = false,
        eraser_button_active = false,
        swap_eraser_and_highlighter = false,
        experimental_text_highlight = false,
        experimental_color_picker = false,
        experimental_pen_width = false,
        underline_hold = opts.underline_hold ~= false,
        side_button_down = false,
        highlighting = false,
        pen_down = false,
        view = { paintTo = function() end },
        ui = {
            view = {
                highlight = { saved_color = "yellow" },
                screenToPageTransform = function(_, pos) return { x = pos.x, y = pos.y, page = 1 } end,
            },
            document = {
                getWordFromPosition = function(_, pos)
                    if in_text(pos) then return { word = "w", pos0 = pos, pos1 = pos } end
                end,
                getTextFromPositions = function(_, p0, p1)
                    return { text = "underlined words", pos0 = p0, pos1 = p1 }
                end,
            },
            highlight = {
                saveHighlight = function(rh)
                    table.insert(saved, rh.selected_text)
                    return #saved
                end,
                clear = function(rh) rh.selected_text = nil end,
            },
        },
    }, { __index = Pencil })
    p.isEnabled = function() return true end
    p.isOverlayActive = function() return false end
    p.transformCoordinates = function(_, x, y) return x, y end
    p.getCurrentPage = function() return 1 end
    p.paintTo = function() end
    p.indexStroke = function() end
    p.assignStrokeToGroup = function() end
    p.scheduleDeferredWork = function() end
    p.scheduleDelayedRefresh = function() end
    p.accumulateRefreshBbox = function() end
    p.cancelPendingRefresh = function() end
    p.cancelColorPickerTimer = function() end
    p.drawLineSegment = function() end
    return p, saved
end

local function slot(x, y) return { id = 1, x = x, y = y, tool = 1 } end
local function draw(p, pts)
    for _, pt in ipairs(pts) do p:handleStylusSlot(nil, slot(pt[1], pt[2])) end
end
local function lift(p) p:handleStylusSlot(nil, { id = -1, tool = 1 }) end

describe("underline by holding at line end (real main.lua)", function()
    before_each(function()
        for fn in pairs(scheduled) do scheduled[fn] = nil end
    end)

    it("turns a held horizontal line under text into a native underline", function()
        local p, saved = new_pencil()
        draw(p, { { 100, 126 }, { 200, 127 }, { 300, 126 }, { 400, 128 } })
        fire_scheduled()
        assert.are.equal(1, #saved)
        assert.are.equal("underscore", saved[1].drawer)
        assert.is_true(saved[1].pos0.x >= 50 and saved[1].pos0.x <= 900)
        assert.is_true(saved[1].pos0.y >= 100 and saved[1].pos0.y <= 120)
        lift(p)
        assert.are.equal(0, #p.strokes)
    end)

    it("keeps the ink when the pen lifts before the hold time", function()
        local p, saved = new_pencil()
        draw(p, { { 100, 126 }, { 400, 128 } })
        lift(p)
        fire_scheduled()
        assert.are.equal(0, #saved)
        assert.are.equal(1, #p.strokes)
    end)

    it("ignores lines that are too short or too steep", function()
        local p, saved = new_pencil()
        draw(p, { { 100, 126 }, { 120, 127 } })
        fire_scheduled()
        lift(p)
        draw(p, { { 100, 126 }, { 200, 200 } })
        fire_scheduled()
        assert.are.equal(0, #saved)
        assert.are.equal(1, #p.strokes)
    end)

    it("keeps the ink when there is no text above the line", function()
        local p, saved = new_pencil()
        draw(p, { { 100, 400 }, { 400, 401 } })
        fire_scheduled()
        lift(p)
        assert.are.equal(0, #saved)
        assert.are.equal(1, #p.strokes)
    end)

    it("does nothing when the option is off", function()
        local p, saved = new_pencil({ underline_hold = false })
        draw(p, { { 100, 126 }, { 400, 128 } })
        fire_scheduled()
        lift(p)
        assert.are.equal(0, #saved)
        assert.are.equal(1, #p.strokes)
    end)

    it("restarts the hold timer while the pen keeps moving", function()
        local p = new_pencil()
        draw(p, { { 100, 126 }, { 200, 127 } })
        local first = next(scheduled)
        draw(p, { { 300, 126 } })
        local count = 0
        for _ in pairs(scheduled) do count = count + 1 end
        assert.are.equal(1, count)
        assert.are.equal(first, next(scheduled)) -- same closure, rescheduled
        draw(p, { { 304, 127 } })                -- within the still tolerance
        assert.are.equal(first, next(scheduled))
    end)
end)

local function stroke(y)
    return {tool="pen", page=1, datetime=100, color_name="Red", width=3,
        points={{x=100,y=y},{x=400,y=y+1}}}
end
local function grouped()
    local p, saved = new_pencil()
    p.strokes = {stroke(126),stroke(166),stroke(500)}
    p.current_stroke = stroke(206)
    p.pen_down = true
    p.annotation_groups = {{page=1,datetime_last=100,
        bbox={x0=100,x1=400,y0=126,y1=167},stroke_indices={1,2}}}
    p.undo_stack = {{type="add",stroke_idx=1},{type="add",stroke_idx=3},
        {type="delete",strokes={stroke(600)}}}
    p.cleanup_calls = {}
    for _, name in ipairs({"cancelPendingSave","rebuildPageIndex",
            "rebuildAnnotationGroups","flushDirtyGroups","refreshDogear","saveStrokes"}) do
        local method = name
        p[method] = function() p.cleanup_calls[method] = true end
    end
    return p, saved
end
local function candidates(p)
    return #p:getUnderlineStrokeGroup(p.current_stroke,
        geometry.computeStrokeBbox(p.current_stroke))
end

describe("grouped multiline underline (real main.lua)", function()
    before_each(function()
        for fn in pairs(scheduled) do scheduled[fn] = nil end
    end)
    it("saves one multiline range in the pen color and removes only group ink", function()
        local p, saved = grouped()
        p:checkUnderlineHold()
        assert.are.equal(1,#saved)
        assert.are.equal("underscore",saved[1].drawer)
        assert.are.equal("red",saved[1].color)
        assert.is_true(saved[1].pos0.y >= 100 and saved[1].pos0.y <= 120)
        assert.is_true(saved[1].pos1.y >= 180 and saved[1].pos1.y <= 200)
        assert.are.equal(1,#p.strokes)
        assert.are.equal(500,p.strokes[1].points[1].y)
        assert.are.equal(2,#p.undo_stack)
        assert.are.equal(1,p.undo_stack[1].stroke_idx)
        assert.are.equal("delete",p.undo_stack[2].type)
        assert.is_nil(p.current_stroke)
        assert.are.equal("yellow",p.ui.view.highlight.saved_color)
        for _, name in ipairs({"cancelPendingSave","rebuildPageIndex",
                "rebuildAnnotationGroups","flushDirtyGroups","refreshDogear","saveStrokes"}) do
            assert.is_true(p.cleanup_calls[name])
        end
    end)
    it("orders lines independently of insertion order", function()
        local p, saved = grouped()
        p.annotation_groups[1].stroke_indices = {2,1}
        p:checkUnderlineHold()
        assert.is_true(saved[1].pos0.y <= 120)
        assert.is_true(saved[1].pos1.y >= 180)
    end)
    it("overrides the reader color only during saving", function()
        local p = grouped()
        p.ui.highlight.saveHighlight = function(rh)
            assert.are.equal("red",p.ui.view.highlight.saved_color)
            assert.are.equal("red",rh.selected_text.color)
            return 1
        end
        p:checkUnderlineHold()
        assert.are.equal("yellow",p.ui.view.highlight.saved_color)
    end)
    for _, mode in ipairs({"exception","false"}) do
        local failure = mode
        it("preserves ink and undo on save " .. failure, function()
            local p = grouped()
            p.ui.highlight.saveHighlight = function()
                if failure == "exception" then error("save failed") end
                return false
            end
            p:checkUnderlineHold()
            assert.are.equal(3,#p.strokes)
            assert.are.equal(3,#p.undo_stack)
            assert.is_not_nil(p.current_stroke)
            assert.are.equal("yellow",p.ui.view.highlight.saved_color)
            assert.is_nil(p.cleanup_calls.saveStrokes)
        end)
    end
    it("restores an unset reader color after a save exception", function()
        local p = grouped()
        p.ui.view.highlight.saved_color = nil
        p.ui.highlight.saveHighlight = function() error("save failed") end
        p:checkUnderlineHold()
        assert.is_nil(p.ui.view.highlight.saved_color)
    end)
    it("keeps all ink when any group line has no text", function()
        local p, saved = grouped()
        p.strokes[1] = stroke(500)
        p:checkUnderlineHold()
        assert.are.equal(0,#saved)
        assert.are.equal(3,#p.strokes)
        assert.is_not_nil(p.current_stroke)
    end)
    it("keeps ink when selection positions are invalid", function()
        local p, saved = grouped()
        p.ui.document.getTextFromPositions = function() return {} end
        p:checkUnderlineHold()
        assert.are.equal(0,#saved)
        assert.are.equal(3,#p.strokes)
    end)
    it("falls back to the current line for mixed colors", function()
        local p, saved = grouped()
        p.strokes[1].color_name = "Blue"
        p:checkUnderlineHold()
        assert.are.equal(1,#saved)
        assert.is_true(saved[1].pos0.y >= 180)
        assert.are.equal(3,#p.strokes)
    end)
    it("excludes handwriting, non-pen strokes and missing members", function()
        local p = grouped()
        p.strokes[1].points[2].y = 300
        assert.are.equal(1,candidates(p))
        p = grouped(); p.strokes[1].tool = "highlighter"
        assert.are.equal(1,candidates(p))
        p = grouped(); p.annotation_groups[1].stroke_indices = {99}
        assert.are.equal(1,candidates(p))
    end)
    it("excludes other pages and stale rotations", function()
        local p = grouped(); p.annotation_groups[1].page = 2
        assert.are.equal(1,candidates(p))
        p = grouped(); p.annotation_groups[1].image_rotation = 1
        assert.are.equal(1,candidates(p))
    end)
    it("includes exactly ten seconds but excludes older groups", function()
        local p = grouped(); p.annotation_groups[1].datetime_last = 90
        assert.are.equal(3,candidates(p))
        p.annotation_groups[1].datetime_last = 89
        assert.are.equal(1,candidates(p))
    end)
    it("includes exactly 200 pixels but excludes farther groups", function()
        local p = grouped()
        p.annotation_groups[1].bbox.y0 = 0
        p.annotation_groups[1].bbox.y1 = 6
        assert.are.equal(3,candidates(p))
        p.annotation_groups[1].bbox.y1 = 5
        assert.are.equal(1,candidates(p))
    end)
    it("still converts a single line and normalizes its color", function()
        local p, saved = grouped()
        p.annotation_groups = {}
        p.current_stroke.color_name = "Purple"
        p:checkUnderlineHold()
        assert.are.equal(1,#saved)
        assert.are.equal("purple",saved[1].color)
        assert.are.equal(3,#p.strokes)
    end)
end)
