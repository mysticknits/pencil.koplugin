--[[--
Tests for "Save annotations to PDF" (issue #63), run against the real main.lua.

KOReader modules are replaced with permissive stubs (as in side_button_spec),
and MuPDF with a small in-memory fake: each page is a list of annotations with
a type and /Contents, which is all the plugin's ink bookkeeping looks at. That
lets these tests cover placement, the staged/embedded lifecycle and which
annotations get deleted, without a real PDF.
Run with: busted spec/pdf_export_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local PDF_ANNOT_INK = 15
local PDF_ANNOT_HIGHLIGHT = 8

-- A stub that accepts any field access or call and returns another stub.
local function make_stub()
    return setmetatable({}, {
        __index = function() return make_stub() end,
        __call = function() return make_stub() end,
    })
end

-- Fake ffi: arrays are plain tables whose struct elements spring into being.
local function struct_array()
    return setmetatable({}, { __index = function(t, k)
        local v = { ll = {}, lr = {}, ul = {}, ur = {} }
        rawset(t, k, v)
        return v
    end })
end

-- Fake libwrap-mupdf. pdf_page values are the fake pages themselves.
local W = {}
local function annot_index(annot)
    for i, a in ipairs(annot.page.annots) do
        if a == annot then return i end
    end
end
function W.mupdf_pdf_first_annot(_, page) return page.annots[1] end
function W.mupdf_pdf_next_annot(_, annot)
    return annot.page.annots[annot_index(annot) + 1]
end
function W.mupdf_pdf_annot_type(_, annot) return annot.type end
function W.mupdf_pdf_annot_contents(_, annot) return annot.contents end
function W.mupdf_pdf_delete_annot(_, page, annot)
    table.remove(page.annots, annot_index(annot))
end
function W.mupdf_pdf_create_annot(_, page, annot_type)
    local annot = { page = page, type = annot_type }
    table.insert(page.annots, annot)
    return annot
end
function W.mupdf_pdf_set_annot_ink_list(_, annot, n, counts, vertices)
    local pts = {}
    for i = 0, counts[0] - 1 do pts[#pts + 1] = { x = vertices[i].x, y = vertices[i].y } end
    annot.ink = pts
end
function W.mupdf_pdf_set_annot_contents(_, annot, s) annot.contents = s end
function W.mupdf_pdf_set_annot_border_width(_, annot, w) annot.width = w end
function W.mupdf_pdf_set_annot_color() end
function W.mupdf_pdf_set_annot_opacity() end
function W.mupdf_pdf_update_annot() end

local fake_ffi = {
    cdef = function() end,
    loadlib = function() return W end,
    C = { PDF_ANNOT_INK = PDF_ANNOT_INK },
    cast = function(_, v) return v end,
    string = function(s) return s end,
    new = function() return struct_array() end,
}

local shown = {}

local stubs = {
    ["ui/widget/container/inputcontainer"] = {
        extend = function(_, o) return setmetatable(o or {}, { __index = make_stub() }) end,
    },
    ["ui/uimanager"] = setmetatable({
        show = function(_, widget) table.insert(shown, widget) end,
    }, { __index = function() return function() end end }),
    ["ui/widget/infomessage"] = { new = function(_, o) return o end },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = {
        template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
    },
    ["logger"] = setmetatable({}, { __index = function() return function() end end }),
}

local loaders = package.loaders or package.searchers

local function load_pencil()
    local real_ffi = package.loaded["ffi"]
    package.loaded["ffi"] = fake_ffi
    table.insert(loaders, 2, function(name)
        if name == "lib/geometry" then return nil end
        return function() return stubs[name] or make_stub() end
    end)
    local Pencil = dofile("pencil.koplugin/main.lua")
    table.remove(loaders, 2)
    package.loaded["ffi"] = real_ffi
    return Pencil
end

local Pencil = load_pencil()

local function fakeColor(r, g, b)
    local c = { r = r, g = g, b = b }
    function c:getR() return self.r end
    function c:getG() return self.g end
    function c:getB() return self.b end
    function c:getColorRGB32() return self end
    return c
end

-- A fake PDF document with `pages` pages of fake annotations.
local function new_doc(opts)
    opts = opts or {}
    local pages = {}
    local doc = {
        is_pdf = opts.is_pdf ~= false,
        pages = pages,
        writes = 0,
        highlights_saved = 0,
    }
    local function page(n)
        pages[n] = pages[n] or { annots = {} }
        return pages[n]
    end
    doc._document = {
        openPage = function(_, n)
            local p = page(n)
            return {
                ctx = {},
                page = p,
                close = function() end,
                getMarkupAnnotation = function()
                    for _, a in ipairs(p.annots) do
                        if a.type == PDF_ANNOT_HIGHLIGHT then return a end
                    end
                end,
            }
        end,
    }
    function doc:_checkIfWritable() return true end
    function doc:resetTileCacheValidity() end
    function doc:writeDocument()
        if opts.write_fails then error("disk full") end
        self.writes = self.writes + 1
    end
    function doc:saveHighlight(pageno)
        self.is_edited = true
        table.insert(page(pageno).annots, { page = page(pageno), type = PDF_ANNOT_HIGHLIGHT })
        self.highlights_saved = self.highlights_saved + 1
    end
    doc.page = page
    return doc
end

-- Put a plugin ink annotation on a page, as another session/device would have.
local function add_ink(doc, pageno, tag)
    local p = doc.page(pageno)
    table.insert(p.annots, { page = p, type = PDF_ANNOT_INK, contents = tag })
end

local function ink_tags(doc, pageno)
    local tags = {}
    for _, a in ipairs(doc.page(pageno).annots) do
        if a.type == PDF_ANNOT_INK then tags[#tags + 1] = a.contents end
    end
    return tags
end

-- Single-page view: screen = page * zoom + offset, on `page`.
local function single_page_view(page, zoom, offset)
    return {
        state = { page = page, zoom = zoom },
        screenToPageTransform = function(_, pos)
            return {
                x = (pos.x - offset) / zoom,
                y = (pos.y - offset) / zoom,
                page = page,
                zoom = zoom,
            }
        end,
    }
end

local function new_pencil(opts)
    opts = opts or {}
    local doc = opts.doc or new_doc()
    local view = opts.view or single_page_view(1, 1, 0)
    local p = setmetatable({
        ui = { paging = {}, document = doc, view = view, highlight = opts.highlight,
               annotation = opts.annotation },
        view = view,
        strokes = {},
        page_strokes = {},
        undo_stack = {},
        annotation_groups = {},
        -- The stubbed InputContainer answers every missing field with a
        -- (truthy) stub, so state the plugin reads lazily is set explicitly.
        _annot_seq = 0,
        _pdf_dirty = false,
        _staged_strokes = false,
        input_debug_mode = false,
        tool_settings = {
            pen = { color = fakeColor(0, 0, 0), width = 3 },
            highlighter = { color = fakeColor(0xDD, 0xDD, 0xDD), width = 12 },
            eraser = { width = 20 },
        },
    }, { __index = Pencil })
    for _, name in ipairs({ "saveStrokes", "flushDirtyGroups", "refreshDogear",
            "rebuildAnnotationGroups", "removeGroupBookmark", "cancelGroupImageCapture",
            "removeGroupImage", "purgeOrphanImages", "assignStrokeToGroup" }) do
        p[name] = function() end
    end
    return p, doc
end

-- Add a committed stroke the way the drawing paths do.
local function draw(p, page, points, extra)
    local stroke = { page = page, tool = "pen", width = 3, points = points, datetime = 1 }
    for k, v in pairs(extra or {}) do stroke[k] = v end
    table.insert(p.strokes, stroke)
    p:indexStroke(#p.strokes, page)
    p:capturePagePoints(stroke)
    return stroke
end

describe("PDF export: placement (real main.lua)", function()
    it("records page coordinates and zoom when a stroke is committed", function()
        local p = new_pencil({ view = single_page_view(1, 2, 100) })
        local s = draw(p, 1, { { x = 300, y = 500 }, { x = 101, y = 103 } })
        assert.same({ { x = 100, y = 200 }, { x = 0.5, y = 1.5 } }, s.page_points)
        assert.equals(2, s.page_zoom)
    end)

    it("rounds page coordinates to 1/100", function()
        local p = new_pencil({ view = single_page_view(1, 3, 0) })
        local s = draw(p, 1, { { x = 10, y = 20 } })
        assert.same({ { x = 3.33, y = 6.67 } }, s.page_points)
    end)

    it("records nothing when a point maps to another page", function()
        -- e.g. the page already turned, or scroll mode put a point on a neighbour
        local p = new_pencil({ view = single_page_view(2, 1, 0) })
        local s = draw(p, 1, { { x = 10, y = 10 } })
        assert.is_nil(s.page_points)
    end)

    it("records nothing when a point can't be mapped at all", function()
        local p = new_pencil()
        local s = { page = 1, points = { { x = 1, y = 1 }, { x = 2, y = 2 } } }
        local ok = p:capturePagePoints(s, function(pt)
            if pt.x == 2 then return nil end
            return { x = pt.x, y = pt.y, page = 1 }
        end)
        assert.is_false(ok)
        assert.is_nil(s.page_points)
    end)

    it("embeds every page from its own recorded coordinates, not the page on screen", function()
        local doc = new_doc()
        local p = new_pencil({ doc = doc, view = single_page_view(1, 2, 0) })
        draw(p, 1, { { x = 20, y = 40 } })
        -- Page 2 is a different size: drawn at another zoom and offset.
        p.view = single_page_view(2, 4, 10)
        p.ui.view = p.view
        draw(p, 2, { { x = 50, y = 90 } })
        -- Close on page 1 at yet another zoom.
        p.view = single_page_view(1, 1, 0)
        p.ui.view = p.view
        assert.equals(2, p:autoSaveInkToPdf())
        assert.same({ { x = 10, y = 20 } }, doc.page(1).annots[1].ink)
        assert.same({ { x = 10, y = 20 } }, doc.page(2).annots[1].ink)
    end)

    it("skips strokes without page coordinates instead of guessing", function()
        local doc = new_doc()
        local p = new_pencil({ doc = doc, view = single_page_view(1, 1, 0) })
        local legacy = { page = 3, tool = "pen", width = 3, points = { { x = 1, y = 1 } } }
        table.insert(p.strokes, legacy)
        assert.equals(0, p:autoSaveInkToPdf())
        assert.equals(0, #doc.page(3).annots)
        assert.is_nil(legacy.staged)
    end)

    it("round-trips page coordinates through the sidecar", function()
        local p = new_pencil({ view = single_page_view(1, 2, 0) })
        local s = draw(p, 1, { { x = 3, y = 5 } })
        local back = p:strokeFromSaved(p:strokeToSaveable(s))
        assert.same(s.page_points, back.page_points)
        assert.equals(2, back.page_zoom)
    end)
end)

describe("PDF export: ink width (real main.lua)", function()
    it("divides the width by the zoom the stroke was drawn at", function()
        local p = new_pencil({ view = single_page_view(1, 4, 0) })
        local opts = p:strokeToInkOpts({ tool = "pen", width = 6, page_zoom = 2 })
        assert.equals(3, opts.width)
    end)

    it("falls back to the live zoom for strokes without a recorded one", function()
        local p = new_pencil({ view = single_page_view(1, 2, 0) })
        assert.equals(3, p:strokeToInkOpts({ tool = "pen", width = 6 }).width)
    end)

    it("leaves the width alone when no zoom is usable", function()
        local p = new_pencil()
        p.view = { state = { zoom = 0 } }
        assert.equals(6, p:strokeToInkOpts({ tool = "pen", width = 6 }).width)
    end)

    it("uses reduced opacity for the highlighter", function()
        local p = new_pencil()
        local opts = p:strokeToInkOpts({ tool = "highlighter", color = fakeColor(255, 255, 51), width = 12 })
        assert.equals(0.4, opts.opacity)
        assert.same({ r = 255, g = 255, b = 51 }, opts.color)
    end)
end)

describe("PDF export: staged until written (real main.lua)", function()
    it("doesn't mark a stroke embedded, or save it as embedded, before the write", function()
        local p = new_pencil()
        local s = draw(p, 1, { { x = 1, y = 1 } })
        p:autoSaveInkToPdf()
        assert.is_true(s.staged)
        assert.is_nil(s.embedded)
        assert.is_nil(p:strokeToSaveable(s).embedded)
        assert.is_nil(p:strokeToSaveable(s).staged)
    end)

    it("promotes staged strokes once the close write succeeds", function()
        local p, doc = new_pencil()
        local s = draw(p, 1, { { x = 1, y = 1 } })
        p:autoSaveInkToPdf()
        assert.is_true(p:flushPdfEdits())
        p:settleStagedStrokes(not p._pdf_dirty)
        assert.is_true(s.embedded)
        assert.is_nil(s.staged)
        assert.equals(1, doc.writes)
    end)

    it("rolls back manually and auto-saved strokes alike when the write fails", function()
        local doc = new_doc({ write_fails = true })
        local p = new_pencil({ doc = doc })
        local manual = draw(p, 1, { { x = 1, y = 1 } })
        p:saveCurrentPageToPdf()
        local auto = draw(p, 2, { { x = 2, y = 2 } })
        p:autoSaveInkToPdf()
        assert.is_true(manual.staged)
        assert.is_false(p:flushPdfEdits())
        p:settleStagedStrokes(not p._pdf_dirty)
        for _, s in ipairs({ manual, auto }) do
            assert.is_nil(s.embedded)
            assert.is_nil(s.staged)
        end
    end)

    it("replaces its own earlier copy when a rolled-back stroke is saved again", function()
        local p, doc = new_pencil()
        local s = draw(p, 1, { { x = 1, y = 1 } })
        p:autoSaveInkToPdf()
        local tag = s.annot_id
        p:settleStagedStrokes(false)  -- write "failed", but the ink is still there
        p:autoSaveInkToPdf()
        assert.equals(tag, s.annot_id)
        assert.same({ tag }, ink_tags(doc, 1))
    end)

    it("doesn't stage a stroke twice", function()
        local p, doc = new_pencil()
        draw(p, 1, { { x = 1, y = 1 } })
        p:saveCurrentPageToPdf()
        assert.equals(0, p:autoSaveInkToPdf())
        assert.equals(1, #ink_tags(doc, 1))
    end)
end)

describe("PDF export: only our own ink is deleted (real main.lua)", function()
    it("auto-save leaves ink from another device on the same page", function()
        local doc = new_doc()
        add_ink(doc, 1, "kop-ink-from-device-a")
        local p = new_pencil({ doc = doc })
        draw(p, 1, { { x = 1, y = 1 } })
        p:autoSaveInkToPdf()
        assert.equals(2, #ink_tags(doc, 1))
        assert.equals("kop-ink-from-device-a", ink_tags(doc, 1)[1])
    end)

    it("erasing a stroke deletes only that stroke's annotation", function()
        local doc = new_doc()
        add_ink(doc, 1, "kop-ink-from-device-a")
        add_ink(doc, 1, "foreign-app-ink")
        local p = new_pencil({ doc = doc })
        local s = draw(p, 1, { { x = 1, y = 1 } }, { embedded = true, annot_id = "kop-ink-mine" })
        add_ink(doc, 1, "kop-ink-mine")
        table.remove(p.strokes, 1)
        p:commitErase({ s })
        assert.same({ "kop-ink-from-device-a", "foreign-app-ink" }, ink_tags(doc, 1))
        assert.is_nil(s.embedded)
        assert.is_nil(s.annot_id)
        assert.is_true(p._pdf_dirty)
    end)

    it("eraseAtPoint leaves the PDF alone until the gesture is committed", function()
        local doc = new_doc()
        local p = new_pencil({ doc = doc })
        draw(p, 1, { { x = 5, y = 5 } }, { embedded = true, annot_id = "kop-ink-mine" })
        add_ink(doc, 1, "kop-ink-mine")
        local deleted = p:eraseAtPoint(5, 5, 1)
        assert.equals(1, #deleted)
        assert.equals(1, #ink_tags(doc, 1))
        p:commitErase(deleted)
        assert.equals(0, #ink_tags(doc, 1))
    end)
end)

describe("PDF export: undo and clear remove the ink (real main.lua)", function()
    it("undoing a saved stroke removes its annotation", function()
        local p, doc = new_pencil()
        draw(p, 1, { { x = 1, y = 1 } })
        table.insert(p.undo_stack, { type = "add", stroke_idx = 1 })
        p:saveCurrentPageToPdf()
        assert.equals(1, #ink_tags(doc, 1))
        p:undoLastStroke()
        assert.equals(0, #ink_tags(doc, 1))
        assert.equals(0, #p.strokes)
    end)

    it("clear page removes its ink, and undo brings strokes back as overlay", function()
        local p, doc = new_pencil()
        p.getCurrentPage = function() return 1 end
        local s = draw(p, 1, { { x = 1, y = 1 } }, { embedded = true, annot_id = "kop-ink-a" })
        add_ink(doc, 1, "kop-ink-a")
        p:clearPageStrokes()
        assert.equals(0, #ink_tags(doc, 1))
        p:undoLastStroke()
        assert.equals(1, #p.strokes)
        assert.is_nil(s.embedded)
        assert.is_nil(s.annot_id)
    end)

    it("clear all removes the ink on every page", function()
        local p, doc = new_pencil()
        draw(p, 1, { { x = 1, y = 1 } }, { embedded = true, annot_id = "kop-ink-a" })
        draw(p, 2, { { x = 1, y = 1 } }, { embedded = true, annot_id = "kop-ink-b" })
        add_ink(doc, 1, "kop-ink-a")
        add_ink(doc, 2, "kop-ink-b")
        add_ink(doc, 2, "kop-ink-other-device")
        p:clearAllStrokes()
        assert.same({}, ink_tags(doc, 1))
        assert.same({ "kop-ink-other-device" }, ink_tags(doc, 2))
    end)
end)

describe("PDF export: manual save (real main.lua)", function()
    before_each(function()
        for i = #shown, 1, -1 do shown[i] = nil end
    end)

    local function highlight_on(page)
        return { annotations = { { page = page, drawer = "lighten", pboxes = { { x = 1, y = 2, w = 3, h = 4 } } } } }
    end

    it("explains that non-PDF paging documents aren't supported", function()
        local p = new_pencil({ doc = new_doc({ is_pdf = false }) })
        assert.is_false(p:isPdfDocument())
        p:saveCurrentPageToPdf()
        assert.equals("Saving annotations to the file is only supported for PDF documents.", shown[1].text)
    end)

    it("writes highlights with KOReader's saveHighlight", function()
        local p, doc = new_pencil({ annotation = highlight_on(1) })
        p.getCurrentPage = function() return 1 end
        p:saveCurrentPageToPdf()
        assert.equals(1, doc.highlights_saved)
    end)

    it("doesn't duplicate a highlight already in the PDF", function()
        local p, doc = new_pencil({ annotation = highlight_on(1) })
        p.getCurrentPage = function() return 1 end
        p:saveCurrentPageToPdf()
        p:saveCurrentPageToPdf()
        assert.equals(1, doc.highlights_saved)
    end)

    it("leaves highlights to KOReader when it writes them into the PDF itself", function()
        local p, doc = new_pencil({
            annotation = highlight_on(1),
            highlight = { highlight_write_into_pdf = true },
        })
        p.getCurrentPage = function() return 1 end
        p:saveCurrentPageToPdf()
        assert.equals(0, doc.highlights_saved)
    end)
end)
