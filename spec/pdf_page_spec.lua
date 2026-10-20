--[[--
Page-anchored PDF stroke tests, run against the real main.lua.
KOReader modules are replaced with permissive stubs; the ReaderView is a
small fake that maps screen <-> page the same way ReaderView does
(screen = page * zoom + offset - visible_area, pages stacked in scroll mode).
Run with: busted spec/pdf_page_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"
-- Use the right package loader table for Lua 5.1+ compatibility
local loaders = package.loaders or package.searchers

-- A stub that accepts any field access or call and returns another stub.
local function make_stub()
    return setmetatable({}, {
        __index = function() return make_stub() end,
        __call = function() return make_stub() end,
    })
end

local screen = {
    bb = { paintRectRGB32 = function() end },
    night_mode = false,
    getWidth = function() return 1404 end,
    getHeight = function() return 1872 end,
    getRotationMode = function() return 0 end,
    refreshFast = function() end,
    refreshUI = function() end,
}

local stubs = {
    ["device"] = setmetatable({ screen = screen }, {
        __index = function() return function() return true end end,
    }),
    ["ui/uimanager"] = setmetatable({}, { __index = function() return function() end end }),
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
    table.insert(loaders, 2, function(name)
        if name == "lib/geometry" or name == "lib/penciltool" or name == "lib/pencilstrokes" then return nil end
        return function() return stubs[name] or make_stub() end
    end)
    local Pencil = dofile("pencil.koplugin/main.lua")
    table.remove(loaders, 2)
    return Pencil
end

local Pencil = load_pencil()
local PencilStrokes = require("lib/pencilstrokes")
local PencilTool = require("lib/penciltool")
local make_tool = dofile("spec/helpers/make_tool.lua")

-- Fake ReaderView for a paged document.
local function new_view(opts)
    local view = {
        page_scroll = opts.scroll or false,
        page_gap = { height = 8 },
        state = { page = opts.page or 1, zoom = opts.zoom or 1, offset = { x = opts.ox or 0, y = opts.oy or 0 } },
        visible_area = { x = opts.vx or 0, y = opts.vy or 0, w = 1404, h = 1872 },
        page_states = opts.page_states,
        paintTo = function() end,
    }
    function view:screenToPageTransform(pos)
        if self.page_scroll then
            local acc_y = 0
            for _, st in ipairs(self.page_states) do
                local top = acc_y + st.offset.y
                if pos.y < top + st.visible_area.h or _ == #self.page_states then
                    return {
                        x = (st.visible_area.x + pos.x - st.offset.x) / st.zoom,
                        y = (st.visible_area.y + pos.y - top) / st.zoom,
                        page = st.page,
                    }
                end
                acc_y = acc_y + st.visible_area.h + self.page_gap.height
            end
        end
        return {
            x = (self.visible_area.x + pos.x - self.state.offset.x) / self.state.zoom,
            y = (self.visible_area.y + pos.y - self.state.offset.y) / self.state.zoom,
            page = self.state.page,
        }
    end
    function view:getCurrentPageList()
        local pages = {}
        if self.page_scroll then
            for _, st in ipairs(self.page_states) do table.insert(pages, st.page) end
        else
            table.insert(pages, self.state.page)
        end
        return pages
    end
    return view
end

-- Rebuild a stroke from its saved form the way the plugin does on load
local function load_saved(p, saved)
    return PencilStrokes.fromSaved(saved, {
        tool_settings = p.stroke_render_ctx.tool_settings,
        available_colors = p.available_colors,
    })
end

local function new_pencil(view, opts)
    opts = opts or {}
    local rendered = {}
    local p = setmetatable({
        tool = make_tool(PencilTool, { tool_settings = {
            pen = { color = { getColor8 = function() return { a = 0 } end }, color_name = "Black", width = 3, alpha = 1 },
            eraser = { width = 10 },
        } }),
        available_colors = {},
        annotation_groups = {},
        refresh_interval_ms = 16,
        input_debug_mode = false,
        experimental_color_picker = false,
        experimental_pen_width = false,
        underline_hold = false,
        side_button_down = false,
        pen_down = false,
        view = view,
        ui = opts.epub and { rolling = {}, view = view } or { paging = {}, view = view },
    }, { __index = Pencil })
    p:initStrokeStore()
    p.isEnabled = function() return true end
    p.isOverlayActive = function() return false end
    p.transformCoordinates = function(_, x, y) return x, y end
    p.getCurrentPage = function(self) return self.view.state.page end
    p.assignStrokeToGroup = function() end
    p.scheduleDeferredWork = function() end
    p.scheduleDelayedRefresh = function() end
    p.cancelPendingRefresh = function() end
    p.cancelColorPickerTimer = function() end
    p.drawLineSegment = function() end
    p.backfillGroupXPointers = function() end
    p.renderStroke = function(_, _, stroke)
        table.insert(rendered, { x = stroke.points[1].x, y = stroke.points[1].y })
    end
    p.rebuildAnnotationGroups = function() end
    return p, rendered
end

local function draw(p, pts)
    for _, pt in ipairs(pts) do p:handleStylusSlot(nil, { id = 1, x = pt[1], y = pt[2], tool = 1 }) end
    p:handleStylusSlot(nil, { id = -1, tool = 1 })
end

local function near(a, b) return math.abs(a - b) < 1e-6 end

describe("PDF page-anchored strokes (real main.lua)", function()
    it("stores page coordinates for a stroke drawn while zoomed", function()
        local view = new_view({ zoom = 2, ox = 100, oy = 50 })
        local p = new_pencil(view)
        draw(p, { { 300, 250 }, { 500, 250 } })
        local s = p.store.strokes[1]
        assert.are.equal(1, s.page)
        assert.is_true(near(s.page_points[1].x, 100) and near(s.page_points[1].y, 100))
        assert.is_true(near(s.page_points[2].x, 200) and near(s.page_points[1].y, 100))
    end)

    it("follows a zoom and pan change when repainting", function()
        local view = new_view({ zoom = 2, ox = 100, oy = 50 })
        local p, rendered = new_pencil(view)
        draw(p, { { 300, 250 }, { 500, 250 } })
        view.state.zoom, view.state.offset = 1, { x = 0, y = 0 }
        p:paintTo(screen.bb, 0, 0)
        assert.are.same({ x = 100, y = 100 }, rendered[#rendered])
        assert.are.equal(100, p.store.strokes[1].points[1].x)
    end)

    it("erases a stroke at its new position after zooming, not the old one", function()
        local view = new_view({ zoom = 2, ox = 100, oy = 50 })
        local p = new_pencil(view)
        draw(p, { { 300, 250 }, { 500, 250 } })
        view.state.zoom, view.state.offset = 1, { x = 0, y = 0 }
        assert.is_nil(p:eraseAtPoint(300, 250, 1, true))  -- where it was drawn
        assert.are.equal(1, #p:eraseAtPoint(100, 100, 1, true))  -- where it is now
    end)

    it("anchors with the view the stroke started in, even if saved after a page turn", function()
        local view = new_view({ zoom = 2, ox = 100, oy = 50 })
        local p = new_pencil(view)
        p:handleStylusSlot(nil, { id = 1, x = 300, y = 250, tool = 1 })
        p:handleStylusSlot(nil, { id = 1, x = 500, y = 250, tool = 1 })
        view.state.page, view.state.zoom = 2, 1
        p:onUpdatePos()
        local s = p.store.strokes[1]
        assert.are.equal(1, s.page)
        assert.is_true(near(s.page_points[1].x, 100) and near(s.page_points[1].y, 100))
    end)

    it("anchors to the right page in continuous mode", function()
        local states = {
            { page = 3, zoom = 1, offset = { x = 0, y = 0 }, visible_area = { x = 0, y = 0, w = 1404, h = 600 } },
            { page = 4, zoom = 1, offset = { x = 0, y = 0 }, visible_area = { x = 0, y = 0, w = 1404, h = 1000 } },
        }
        local view = new_view({ scroll = true, page = 3, page_states = states })
        local p, rendered = new_pencil(view)
        draw(p, { { 200, 700 }, { 300, 700 } }) -- 700 is past page 3 (600) + gap (8)
        local s = p.store.strokes[1]
        assert.are.equal(4, s.page)
        assert.is_true(near(s.page_points[1].y, 92))
        p:paintTo(screen.bb, 0, 0)
        assert.are.same({ x = 200, y = 700 }, rendered[#rendered])
    end)

    it("does not draw strokes of pages that aren't shown", function()
        local view = new_view({ page = 1 })
        local p, rendered = new_pencil(view)
        draw(p, { { 10, 10 }, { 60, 10 } })
        view.state.page = 2
        p:paintTo(screen.bb, 0, 0)
        assert.are.equal(0, #rendered)
    end)

    it("saves and loads page coordinates", function()
        local view = new_view({ zoom = 2, ox = 100, oy = 50 })
        local p = new_pencil(view)
        draw(p, { { 300, 250 }, { 500, 250 } })
        local saved = PencilStrokes.toSaveable(p.store.strokes[1])
        assert.are.equal("100.0 100.0 200.0 100.0", saved.pp)
        local loaded = load_saved(p, saved)
        assert.are.same({ { x = 100, y = 100 }, { x = 200, y = 100 } }, loaded.page_points)
    end)

    it("leaves EPUB strokes in screen coordinates", function()
        local view = new_view({})
        local p = new_pencil(view, { epub = true })
        draw(p, { { 10, 10 }, { 60, 10 } })
        assert.is_nil(p.store.strokes[1].page_points)
        assert.is_nil(PencilStrokes.toSaveable(p.store.strokes[1]).pp)
    end)
end)
