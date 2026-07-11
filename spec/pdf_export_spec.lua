--[[--
Unit tests for the "Save annotations to PDF" coordinate/option mapping (issue #63).

The ffi/MuPDF write path can't run under busted, so these tests cover the pure,
plugin-owned logic: screen->page point conversion and per-stroke ink options.
The mock methods mirror Pencil:strokeToPagePoints / Pencil:strokeToInkOpts in
pencil.koplugin/main.lua.
Run with: busted spec/pdf_export_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local TOOL_PEN = "pen"
local TOOL_HIGHLIGHTER = "highlighter"

-- Fake Blitbuffer color exposing the accessors the real code uses.
local function fakeColor(r, g, b)
    local c = { r = r, g = g, b = b }
    function c:getR() return self.r end
    function c:getG() return self.g end
    function c:getB() return self.b end
    function c:getColorRGB32() return self end  -- already RGB
    return c
end

-- Minimal Pencil-like object carrying copies of the shipped methods.
local function createMockPencil()
    local mock = {
        tool_settings = {
            pen = { color = fakeColor(0, 0, 0), width = 3 },
            highlighter = { color = fakeColor(0xDD, 0xDD, 0xDD), width = 12 },
        },
    }

    -- Copy of Pencil:strokeToPagePoints (transform injected for testing).
    function mock:strokeToPagePoints(stroke, transform_fn)
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

    -- Copy of Pencil:strokeToInkOpts.
    function mock:strokeToInkOpts(stroke)
        local tool = stroke.tool or TOOL_PEN
        local color = stroke.color or self.tool_settings[tool].color
        local rgb = color:getColorRGB32()
        return {
            color = { r = rgb:getR(), g = rgb:getG(), b = rgb:getB() },
            width = stroke.width or self.tool_settings[tool].width or 3,
            opacity = (tool == TOOL_HIGHLIGHTER) and 0.4 or 1.0,
        }
    end

    return mock
end

describe("strokeToPagePoints", function()
    -- Mirror ReaderView:getSinglePagePosition math: page = (visible + screen - offset) / zoom
    local function transform(zoom, offset)
        return function(pt)
            return {
                x = (pt.x - offset) / zoom,
                y = (pt.y - offset) / zoom,
            }
        end
    end

    it("maps identity transform 1:1", function()
        local pencil = createMockPencil()
        local stroke = { points = { { x = 10, y = 20 }, { x = 30, y = 40 } } }
        local pts = pencil:strokeToPagePoints(stroke, transform(1, 0))
        assert.equals(2, #pts)
        assert.equals(10, pts[1].x)
        assert.equals(20, pts[1].y)
        assert.equals(30, pts[2].x)
        assert.equals(40, pts[2].y)
    end)

    it("applies zoom and offset", function()
        local pencil = createMockPencil()
        -- zoom 2, offset 100: screen (300,500) -> page (100,200)
        local stroke = { points = { { x = 300, y = 500 } } }
        local pts = pencil:strokeToPagePoints(stroke, transform(2, 100))
        assert.equals(1, #pts)
        assert.equals(100, pts[1].x)
        assert.equals(200, pts[1].y)
    end)

    it("skips points the transform can't resolve", function()
        local pencil = createMockPencil()
        local stroke = { points = { { x = 1, y = 1 }, { x = 2, y = 2 }, { x = 3, y = 3 } } }
        local drop_middle = function(pt)
            if pt.x == 2 then return nil end
            return { x = pt.x, y = pt.y }
        end
        local pts = pencil:strokeToPagePoints(stroke, drop_middle)
        assert.equals(2, #pts)
        assert.equals(1, pts[1].x)
        assert.equals(3, pts[2].x)
    end)

    it("returns empty list for a stroke with no points", function()
        local pencil = createMockPencil()
        local pts = pencil:strokeToPagePoints({ points = {} }, transform(1, 0))
        assert.equals(0, #pts)
    end)
end)

describe("strokeToInkOpts", function()
    it("uses full opacity for the pen", function()
        local pencil = createMockPencil()
        local opts = pencil:strokeToInkOpts({ tool = TOOL_PEN, color = fakeColor(255, 0, 0), width = 5 })
        assert.equals(1.0, opts.opacity)
        assert.equals(5, opts.width)
        assert.same({ r = 255, g = 0, b = 0 }, opts.color)
    end)

    it("uses reduced opacity for the highlighter", function()
        local pencil = createMockPencil()
        local opts = pencil:strokeToInkOpts({ tool = TOOL_HIGHLIGHTER, color = fakeColor(255, 255, 51), width = 12 })
        assert.equals(0.4, opts.opacity)
        assert.equals(12, opts.width)
        assert.same({ r = 255, g = 255, b = 51 }, opts.color)
    end)

    it("falls back to tool defaults when the stroke omits color/width", function()
        local pencil = createMockPencil()
        local opts = pencil:strokeToInkOpts({ tool = TOOL_PEN })
        assert.equals(3, opts.width)              -- tool_settings.pen.width
        assert.same({ r = 0, g = 0, b = 0 }, opts.color)  -- tool_settings.pen.color
    end)

    it("defaults to the pen tool when tool is unset", function()
        local pencil = createMockPencil()
        local opts = pencil:strokeToInkOpts({ color = fakeColor(1, 2, 3), width = 7 })
        assert.equals(1.0, opts.opacity)
        assert.same({ r = 1, g = 2, b = 3 }, opts.color)
    end)
end)
