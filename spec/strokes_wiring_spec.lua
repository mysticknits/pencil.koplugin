--[[--
How main.lua uses lib/pencilstrokes.lua: saving and loading (with annotation
groups and notes), erasing, clearing and rendering, run against the real
main.lua, the real library and real files.
KOReader modules are replaced with permissive stubs so the plugin can be
loaded outside the reader.
Run with: busted spec/strokes_wiring_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"
-- Use the right package loader table for Lua 5.1+ compatibility
local loaders = package.loaders or package.searchers

local lfs = require("lfs")

-- A stub that accepts any field access or call and returns another stub.
local function make_stub()
    return setmetatable({}, {
        __index = function() return make_stub() end,
        __call = function() return make_stub() end,
    })
end

local function color(r, g, b, a)
    return { r = r, g = g, b = b, alpha = a or 255, getColorRGB32 = function(self) return self end,
        invert = function(self) return color(255 - self.r, 255 - self.g, 255 - self.b, self.alpha) end }
end
local Blitbuffer = {
    ColorRGB32 = color,
    Color8 = function(v) return color(v, v, v) end,
}
Blitbuffer.COLOR_BLACK = Blitbuffer.Color8(0)

-- minimal stand-in for KOReader's dump(): serializes plain tables to Lua source
local function serialize(v)
    if type(v) == "table" then
        local out = {}
        for k, x in pairs(v) do out[#out + 1] = "[" .. serialize(k) .. "]=" .. serialize(x) end
        return "{" .. table.concat(out, ",") .. "}"
    elseif type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

-- the strokes library requires it lazily, when saving
package.preload["dump"] = function() return serialize end

local shown = {}
local stubs = {
    ["ui/uimanager"] = setmetatable({
        show = function(_, widget) shown[#shown + 1] = widget.text end,
    }, { __index = function() return function() end end }),
    ["ui/widget/container/inputcontainer"] = {
        -- No stub fallback: unset fields must read as nil, as in KOReader.
        extend = function(_, o) return o or {} end,
    },
    ["ui/widget/infomessage"] = { new = function(_, o) return o end },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = {
        -- the %1, %2 ... template KOReader's T() uses
        template = function(fmt, ...)
            local args = { ... }
            return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
    },
    ["logger"] = setmetatable({}, { __index = function() return function() end end }),
    ["libs/libkoreader-lfs"] = lfs,
    ["dump"] = serialize,
    ["ffi/blitbuffer"] = Blitbuffer,
    ["device"] = setmetatable({
        isTouchDevice = function() return true end,
        screen = setmetatable({
            getWidth = function() return 1000 end,
            getHeight = function() return 1000 end,
            night_mode = false,
        }, { __index = function() return make_stub() end }),
    }, { __index = function() return make_stub() end }),
}

local function load_pencil()
    table.insert(loaders, 2, function(name)
        if name == "lib/geometry" or name == "lib/penciltool" or name == "lib/pencilstrokes" then return nil end
        return function() return stubs[name] or make_stub() end
    end)
    local Pencil = dofile("pencil.koplugin/main.lua")
    table.remove(loaders, 2)
    return Pencil
end

local Pencil = load_pencil()
local PencilTool = require("lib/penciltool")
local make_tool = dofile("spec/helpers/make_tool.lua")

local function new_dir()
    local dir = os.tmpname()
    os.remove(dir)
    lfs.mkdir(dir)
    return dir
end

local function remove_dir(dir)
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then os.remove(dir .. "/" .. name) end
    end
    lfs.rmdir(dir)
end

local function new_pencil(dir, opts)
    opts = opts or {}
    local settings = {}
    local p = setmetatable({
        calls = {},
        view = {},
        notes = {},
        annotation_groups = {},
        pending_group_strokes = {},
        tool = make_tool(PencilTool, { tool_settings = { eraser = { width = 20 } } }),
        available_colors = { { name = "Black", color = Blitbuffer.COLOR_BLACK } },
        ui = {
            paging = opts.paging and {} or nil,
            doc_settings = dir and {
                doc_sidecar_dir = dir,
                saveSetting = function(_, k, v) settings[k] = v end,
                readSetting = function(_, k) return settings[k] end,
            } or nil,
        },
        settings = settings,
    }, { __index = Pencil })
    p:initStrokeStore()
    function p:rebuildAnnotationGroups() self.calls[#self.calls + 1] = "rebuild_groups" end
    function p:deleteEmbeddedAnnotationsFor(deleted) self.calls[#self.calls + 1] = "delete_embedded:" .. #deleted end
    function p:assignStrokeToGroup(idx, skip_bookmark)
        self.calls[#self.calls + 1] = "assign:" .. idx .. (skip_bookmark and ":skip" or "")
        self.annotation_groups[#self.annotation_groups + 1] = { id = "g" .. idx, stroke_indices = { idx } }
    end
    function p:getCurrentPage() return 1 end
    function p:repaintReader() self.calls[#self.calls + 1] = "repaint" end
    return p
end

local function line(page, y, extra)
    local points = {}
    for x = 0, 100, 10 do points[#points + 1] = { x = x, y = y } end
    local stroke = { page = page, tool = "pen", width = 3, color = Blitbuffer.COLOR_BLACK, color_name = "Black",
        alpha = 255, datetime = 1000 + y, points = points }
    for k, v in pairs(extra or {}) do stroke[k] = v end
    return stroke
end

local function has(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end

describe("strokes in main.lua", function()
    local dir

    before_each(function()
        dir = new_dir()
        shown = {}
    end)

    after_each(function()
        remove_dir(dir)
    end)

    describe("saving and loading", function()
        it("round-trips strokes with their groups", function()
            local p = new_pencil(dir)
            p.store.loaded = true
            p.store:add(line(1, 50))
            p.store:add(line(2, 200, { page_points = { { x = 1, y = 2 }, { x = 3, y = 4 } } }))
            p.annotation_groups = { { id = "gA", stroke_indices = { 1, 2 } } }
            p:saveStrokes()
            assert.equals("file", lfs.attributes(dir .. "/pencil_strokes.lua", "mode"))
            assert.equals(dir .. "/pencil_strokes.lua", p.settings.pencil_strokes_path)

            local q = new_pencil(dir)
            q:loadStrokes()
            assert.equals(2, q.store:count())
            assert.is_true(q.store.loaded)
            assert.is_true(q.store:hasOnPage(2))
            assert.same({ { x = 1, y = 2 }, { x = 3, y = 4 } }, q.store.strokes[2].page_points)
            assert.equals("gA", q.annotation_groups[1].id)
            assert.is_false(has(q.calls, "assign:1:skip"))
        end)

        it("bootstraps the groups, oldest stroke first, when the file has none", function()
            local p = new_pencil(dir)
            p.store.loaded = true
            p.store:add(line(1, 900))   -- datetime 1900
            p.store:add(line(1, 100))   -- datetime 1100: older
            p:saveStrokes()

            local q = new_pencil(dir)
            q:loadStrokes()
            assert.same({ "assign:2:skip", "assign:1:skip" }, q.calls)
        end)

        it("treats a missing file as an empty, loaded document and leaves the groups", function()
            local p = new_pencil(dir)
            p.annotation_groups = { { id = "keep" } }
            p.store:add(line(1, 50))
            p:loadStrokes()
            assert.equals(0, p.store:count())
            assert.is_true(p.store.loaded)
            assert.equals("keep", p.annotation_groups[1].id)
        end)

        it("resets the groups when the file cannot be read", function()
            local f = io.open(dir .. "/pencil_strokes.lua", "w"); f:write("garbage ("); f:close()
            local p = new_pencil(dir)
            p.annotation_groups = { { id = "x" } }
            p:loadStrokes()
            assert.equals(0, p.store:count())
            assert.is_false(p.store.loaded)
            assert.same({}, p.annotation_groups)
        end)

        it("never overwrites a file it could not read with an empty store", function()
            local f = io.open(dir .. "/pencil_strokes.lua", "w"); f:write("garbage ("); f:close()
            local p = new_pencil(dir)
            p:loadStrokes()
            p:saveStrokes()
            assert.equals("garbage (", io.open(dir .. "/pencil_strokes.lua"):read("*a"))
        end)

        it("does nothing without a sidecar", function()
            local p = new_pencil(nil)
            p:loadStrokes()
            p:saveStrokes()
            assert.equals(0, p.store:count())
            assert.is_false(p.store.loaded)
        end)

        it("gives a stroke saved with a color name that color back", function()
            local p = new_pencil(dir)
            p.store.loaded = true
            p.store:add(line(1, 50))
            p:saveStrokes()
            local q = new_pencil(dir)
            q:loadStrokes()
            assert.equals("Black", q.store.strokes[1].color_name)
            assert.equals(Blitbuffer.COLOR_BLACK, q.store.strokes[1].color)
        end)
    end)

    describe("erasing", function()
        it("removes the stroke, rebuilds the groups and deletes the embedded PDF ink", function()
            local p = new_pencil(dir)
            p.store:add(line(1, 50)); p.store:add(line(1, 300))
            local deleted = p:eraseAtPoint(50, 52, 1)
            assert.equals(1, #deleted)
            assert.equals(1, p.store:count())
            assert.same({ "rebuild_groups", "delete_embedded:1" }, p.calls)
        end)

        it("returns nil without side effects when nothing is near", function()
            local p = new_pencil(dir)
            p.store:add(line(1, 50))
            assert.is_nil(p:eraseAtPoint(900, 900, 1))
            assert.same({}, p.calls)
        end)

        it("uses the eraser width as its reach", function()
            local p = new_pencil(dir)
            p.store:add(line(1, 50))
            assert.is_nil(p:eraseAtPoint(50, 80, 1))
            assert.is_not_nil(p:eraseAtPoint(50, 65, 1))
        end)

        it("defers the group rebuild during a gesture, keeping group indices valid", function()
            local p = new_pencil(dir)
            p.store:add(line(1, 50)); p.store:add(line(1, 300))
            p.annotation_groups = { { id = "g1", stroke_indices = { 1 } }, { id = "g2", stroke_indices = { 2 } } }
            p:eraseAtPoint(50, 52, 1, true)
            assert.is_true(p.groups_stale)
            assert.is_false(has(p.calls, "rebuild_groups"))
            assert.equals(1, p.annotation_groups[2].stroke_indices[1])  -- renumbered by on_removed
        end)

        it("on a PDF erases what is on any visible page, projected for the current view", function()
            local p = new_pencil(dir, { paging = true })
            function p:getVisiblePages() return { 1, 2 } end
            function p:pageAffine(page)
                if page == 1 then return 1, 0, 0 end
                if page == 2 then return 1, 0, 0 end
            end
            local a = line(1, 50, { page_points = { { x = 50, y = 50 } }, points = { { x = 0, y = 0 } } })
            local b = line(2, 50, { page_points = { { x = 50, y = 50 } }, points = { { x = 0, y = 0 } } })
            p.store:add(a); p.store:add(b)
            local deleted = p:eraseAtPoint(50, 52, 1)
            assert.equals(2, #deleted)  -- the strokes were projected to (50, 50) before testing
        end)

        it("leaves a PDF stroke alone when its page isn't shown", function()
            local p = new_pencil(dir, { paging = true })
            function p:getVisiblePages() return { 1 } end
            function p:pageAffine(page) if page == 1 then return 1, 0, 0 end end
            local hidden = line(2, 50, { page_points = { { x = 50, y = 50 } }, points = { { x = 50, y = 50 } } })
            p.store:add(hidden)
            assert.is_nil(p:eraseAtPoint(50, 50, 1))
        end)

        it("erases a legacy screen stroke only on the current page", function()
            local p = new_pencil(dir, { paging = true })
            function p:getVisiblePages() return { 1, 2 } end
            function p:pageAffine() return 1, 0, 0 end
            p.store:add(line(2, 50))
            assert.is_nil(p:eraseAtPoint(50, 52, 1))
            assert.equals(1, #p:eraseAtPoint(50, 52, 2))
        end)

        it("gives the rect to refresh, widened by the eraser width", function()
            local p = new_pencil(dir)
            local x, y, w, h = p:erasedStrokesRefreshRect({ line(1, 100) })
            assert.same({ 0, 80, 120, 40 }, { x, y, w, h })
        end)
    end)

    describe("clearing", function()
        it("clears the page, undoably", function()
            local p = new_pencil(dir)
            p.store.loaded = true
            p.store:add(line(1, 50)); p.store:add(line(1, 60)); p.store:add(line(2, 70))
            p:clearPageStrokes()
            assert.equals("Cleared 2 annotation(s) from page.", shown[1])
            assert.equals(1, p.store:count())
            assert.is_true(has(p.calls, "rebuild_groups"))
            assert.is_true(has(p.calls, "repaint"))
            assert.is_true(p.store:canUndo())
        end)

        it("says when the page has nothing to clear", function()
            local p = new_pencil(dir)
            p:clearPageStrokes()
            assert.equals("No annotations found on this page.", shown[1])
            assert.is_false(p.store:canUndo())
        end)
    end)

    describe("drawing", function()
        local bb = function()
            return { last = nil, paintRectRGB32 = function(self, _, _, _, _, c) self.last = c end }
        end

        it("renders a stroke, inverting colors in night mode", function()
            local p = new_pencil(dir)
            local screen = require("device").screen
            local red = line(1, 50, { points = { { x = 5, y = 5 } }, width = 2, color = color(200, 0, 0), color_name = "Red" })
            local b = bb()
            p:renderStroke(b, red)
            assert.equals(200, b.last.r)
            screen.night_mode = true
            b = bb()
            p:renderStroke(b, red)
            assert.equals(55, b.last.r)
            screen.night_mode = false
        end)

        it("renders a stroke shifted by an offset", function()
            local p = new_pencil(dir)
            local painted
            local b = { paintRectRGB32 = function(_, x, y) painted = { x, y } end }
            p:renderStrokeOffset(b, line(1, 50, { points = { { x = 10, y = 10 } }, width = 2 }), 100, 200)
            assert.same({ 109, 209 }, painted)
        end)
    end)
end)
