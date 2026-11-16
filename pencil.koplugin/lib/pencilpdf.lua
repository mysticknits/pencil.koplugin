--[[--
PDF export support for the Pencil plugin.
Owns native PDF annotation conversion, mutation, pruning, and flush behavior.
@module lib.pencilpdf
--]]--
local Blitbuffer = require("ffi/blitbuffer")
local PencilTool = require("lib/penciltool")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local TOOL_PEN = PencilTool.TOOLS.PEN
local TOOL_HIGHLIGHTER = PencilTool.TOOLS.HIGHLIGHTER

-- Native PDF ink-annotation support (issue #63).
--
-- We call koreader-base's MuPDF wrapper directly, so this feature patches NO
-- core KOReader files. Everything we need comes from require("ffi/mupdf"):
-- koreader-base exports the ink setters as of koreader/koreader-base#2444,
-- shipped in KOReader 2026.07.
--
-- InkAnnot is nil when the symbols are absent, so on older KOReader builds the
-- feature degrades gracefully instead of erroring.
local InkAnnot = (function()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    -- Loads mupdf_h.lua, which on 2026.07+ declares the ink setters
    -- (koreader/koreader-base#2444); the probe below fails on older builds.
    if not pcall(require, "ffi/mupdf") then return nil end
    local W_ok, W = pcall(ffi.loadlib, "wrap-mupdf")
    if not W_ok or not W then return nil end
    -- Probe: the symbol resolves lazily and errors if the lib lacks it.
    if not pcall(function() return W.mupdf_pdf_set_annot_ink_list end) then return nil end
    local ink_ok, ink_type = pcall(function() return ffi.C.PDF_ANNOT_INK end)
    return { ffi = ffi, W = W, PDF_ANNOT_INK = ink_ok and ink_type or 15 }
end)()

local PencilPDF = {}

-- The feature delegates non-PDF plugin operations to its owning Pencil instance.
-- Bound methods are cached so internal calls such as self:getCurrentPage() retain
-- the Pencil receiver while PDF state remains stored on the plugin.
local instance_mt = {
    __index = function(self, key)
        local own = PencilPDF[key]
        if own ~= nil then return own end
        local plugin = rawget(self, "plugin")
        local value = plugin and plugin[key]
        if type(value) == "function" then
            local bound = function(_, ...) return value(plugin, ...) end
            rawset(self, key, bound)
            return bound
        end
        return value
    end,
    __newindex = function(self, key, value)
        local plugin = rawget(self, "plugin")
        if plugin then plugin[key] = value else rawset(self, key, value) end
    end,
}

function PencilPDF:new(args)
    assert(args and args.plugin, "PencilPDF requires a plugin")
    return setmetatable({ plugin = args.plugin }, instance_mt)
end

function PencilPDF:hasInkAnnotSupport()
    return InkAnnot ~= nil
end

-- ===================================================================
-- Save annotations to PDF (issue #63)
--
-- Converts pencil strokes into native PDF ink annotations (/Subtype /Ink)
-- so they're visible in any PDF reader. Strokes are stored in screen
-- coordinates; each stroke also records its points in native page
-- coordinates when it is drawn (PencilStrokes.anchorToPage), and those are what get
-- handed to MuPDF. All edits stay in memory until a single write on close
-- (flushPdfEdits).
--
-- Requires KOReader 2026.07+ for the ink setters (see the module InkAnnot
-- block near the top). Degrades gracefully: when InkAnnot is nil the menu
-- action explains what's missing.
-- ===================================================================

-- True when the open document is an actual .pdf file. `is_pdf` alone isn't
-- enough: PdfDocument is the provider for every MuPDF format (XPS, CBZ, FB2,
-- MOBI, DOCX, ...) and sets it on the class. Walking a non-PDF page as a
-- pdf_page* reads memory that isn't an annotation list (likely a segfault
-- pcall can't catch), so everything that touches MuPDF annotations gates on
-- this. _checkIfWritable() returns nil for anything that isn't a .pdf, and
-- true/false for a writable or read-only .pdf.
function PencilPDF:isPdfDocument()
    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf == true and doc._checkIfWritable) then return false end
    return doc:_checkIfWritable() ~= nil
end

-- True when this document's ink can be exported: a real .pdf on a KOReader
-- build with the ink setters. Page coordinates are only worth recording then;
-- for everything else they'd just double what saveStrokes writes per stroke.
function PencilPDF:canExportInk()
    return InkAnnot ~= nil and self:isPdfDocument()
end

-- The document, when PDF annotations can be written into it now: a writable
-- .pdf on a build with ink support. Otherwise nil, plus _checkIfWritable()'s
-- reason when the .pdf itself is read-only.
function PencilPDF:writablePdfDoc()
    if not self:canExportInk() then return nil end
    local doc = self.ui.document
    local can_write = doc:_checkIfWritable()
    if can_write ~= true then return nil, can_write end
    return doc
end

-- { [tag] = page } -> { [page] = { [tag] = true } }, the shape the per-page
-- deletion walk takes.
local function groupTagsByPage(tag_pages)
    local by_page = {}
    for tag, page in pairs(tag_pages) do
        by_page[page] = by_page[page] or {}
        by_page[page][tag] = true
    end
    return by_page
end

-- Round a page coordinate to 1/100 of a point: far below any visible
-- difference, and keeps the packed sidecar string short.
local function roundPageCoord(v)
    return math.floor(v * 100 + 0.5) / 100
end

-- Whether the document is shown reflowed (text_wrap). Then screenToPageTransform
-- maps to the reflowed page, not the original one, so its coordinates can't be
-- used for the PDF.
function PencilPDF:isReflowed()
    local doc = self.ui and self.ui.document
    return doc ~= nil and type(doc.configurable) == "table" and doc.configurable.text_wrap == 1
end

-- Record a stroke's points in native page coordinates, plus the zoom it was
-- drawn at. Called when a stroke is committed (its page is the one on screen,
-- so the live ReaderView transform is the one the stroke was drawn under) and,
-- for strokes saved before this existed, the first time their page is painted.
-- Embedding then uses these instead of whatever page happens to be on screen
-- at close, so mixed page sizes and later zoom/pan can't misplace the ink.
-- Every point must map to the stroke's own page; if any doesn't (e.g. scroll
-- mode put it on a neighbour or off-screen), nothing is recorded and the
-- stroke isn't embedded.
-- Nothing is recorded while the document is reflowed (see isReflowed).
-- transform_fn is injectable for testing. Returns true if points were recorded.
function PencilPDF:capturePagePoints(stroke, transform_fn)
    if stroke.page_points then return true end
    if stroke.page_points == false then return false end
    if not transform_fn then
        -- Page anchoring needs a real .pdf, not the ink setters: a stroke must
        -- follow zoom and pan even on a build that cannot embed it. Other
        -- MuPDF formats keep screen coordinates (see recordPagePoints).
        if not (self.ui and self.ui.paging and self.view and self:isPdfDocument()) then
            return false
        end
        if self:isReflowed() then return false end
        -- Paging-mode transforms only read pos.x/pos.y and return a new
        -- table, so the stroke's own points can be passed straight through.
        local view = self.view
        transform_fn = function(pt) return view:screenToPageTransform(pt) end
    end
    local src = stroke.points
    if not src or #src == 0 then return false end
    local points, zoom = {}, nil
    for i = 1, #src do
        local pp = transform_fn(src[i])
        if not (pp and pp.x and pp.y) then return false end
        if pp.page ~= nil and pp.page ~= stroke.page then return false end
        zoom = zoom or pp.zoom
        points[i] = { x = roundPageCoord(pp.x), y = roundPageCoord(pp.y) }
    end
    stroke.page_points = points
    stroke.page_zoom = zoom
    return true
end

-- capturePagePoints for a stroke that has just been drawn. A stroke drawn
-- while reflowed is marked page_points = false (persisted): its screen
-- coordinates belong to the reflowed layout, so no later backfill may map
-- them once reflow is off. It stays overlay ink.
function PencilPDF:recordPagePoints(stroke)
    if self:canExportInk() and self:isReflowed() then
        stroke.page_points = false
        return false
    end
    return self:capturePagePoints(stroke)
end

-- Derive the ink annotation options (color/width/opacity) for a stroke.
-- Stroke widths are stored in screen pixels, but MuPDF's border width is in
-- native page units, so it needs the same zoom division the points got. We use
-- the zoom the stroke was drawn at, falling back to the live zoom for strokes
-- recorded before that was stored. (MuPDF's ink border width is the full line
-- width, centered on the path, so no extra halving is needed.)
function PencilPDF:strokeToInkOpts(stroke)
    local tool = stroke.tool or TOOL_PEN
    local color = stroke.color or self.tool:getToolSettings(tool).color or Blitbuffer.COLOR_BLACK
    local rgb = color:getColorRGB32()
    local width = stroke.width or self.tool:getToolSettings(tool).width or 3
    local zoom = stroke.page_zoom
    if not (zoom and zoom > 0) then
        zoom = self.view and self.view.state and self.view.state.zoom
    end
    if zoom and zoom > 0 then
        width = width / zoom
    end
    return {
        color = { r = rgb:getR(), g = rgb:getG(), b = rgb:getB() },
        width = width,
        -- Highlighter renders as a translucent wash at its own alpha (older
        -- highlighter strokes, saved without a color, keep the fixed 0.4); the
        -- pen is opaque.
        opacity = (tool ~= TOOL_HIGHLIGHTER) and 1.0
            or (stroke.color_name and (stroke.alpha or 0xFF) / 255 or 0.4),
    }
end

-- Tag prefix carried in each embedded ink annotation's /Contents. Lets us
-- recognise (and only ever delete) annotations this plugin created.
local INK_TAG_PREFIX = "kop-ink-"

-- Delete the ink annotations on the already-open `page` whose /Contents tag
-- is in `tags` (a set). Only the given tags are touched: ink from other apps,
-- and plugin ink this sidecar doesn't own (e.g. drawn on another device), is
-- never deleted. Returns the number deleted.
local function deleteTaggedInk(page, tags)
    if next(tags) == nil then return 0 end
    local ffi = InkAnnot.ffi
    local W = InkAnnot.W
    local ctx = page.ctx
    local pdf_page = ffi.cast("pdf_page*", page.page)
    local deleted = 0
    local annot = W.mupdf_pdf_first_annot(ctx, pdf_page)
    while annot ~= nil do
        -- Grab next before a possible delete unlinks the current one.
        local next_annot = W.mupdf_pdf_next_annot(ctx, annot)
        if W.mupdf_pdf_annot_type(ctx, annot) == InkAnnot.PDF_ANNOT_INK then
            local cptr = W.mupdf_pdf_annot_contents(ctx, annot)
            local tag = cptr ~= nil and ffi.string(cptr) or ""
            if tag:sub(1, #INK_TAG_PREFIX) == INK_TAG_PREFIX and tags[tag] then
                page:deleteAnnotation(annot)  -- raises if MuPDF refuses
                deleted = deleted + 1
            end
        end
        annot = next_annot
    end
    return deleted
end

-- Build one tagged ink annotation on an already-open `page` from `points`
-- (native page coordinates). Talks to the MuPDF wrapper directly because
-- stock addInkAnnotation doesn't return the annotation handle, so we couldn't
-- tag it for the eraser. Every setter's result is checked, like stock
-- addMarkupAnnotation does: an annotation missing its ink, tag or /AP would be
-- invisible or unerasable, so on any failure the half-built annotation is
-- deleted and false returned (the stroke then stays overlay ink).
local function buildInkAnnot(page, points, opts)
    local ffi = InkAnnot.ffi
    local W = InkAnnot.W
    local ctx = page.ctx
    local pdf_page = ffi.cast("pdf_page*", page.page)
    local n = #points
    local counts = ffi.new("int[1]")
    counts[0] = n
    local vertices = ffi.new("fz_point[?]", n)
    for i = 1, n do
        vertices[i - 1].x = points[i].x
        vertices[i - 1].y = points[i].y
    end
    local color = ffi.new("float[3]")
    color[0] = opts.color.r / 255
    color[1] = opts.color.g / 255
    color[2] = opts.color.b / 255

    local annot = W.mupdf_pdf_create_annot(ctx, pdf_page, InkAnnot.PDF_ANNOT_INK)
    if annot == nil then return false end
    local ok = W.mupdf_pdf_set_annot_ink_list(ctx, annot, 1, counts, vertices)
        and W.mupdf_pdf_set_annot_color(ctx, annot, 3, color)
        and W.mupdf_pdf_set_annot_border_width(ctx, annot, opts.width or 1.0)
        and W.mupdf_pdf_set_annot_opacity(ctx, annot, opts.opacity or 1.0)
        -- The tag in /Contents is how erase, undo and clear find it later.
        and W.mupdf_pdf_set_annot_contents(ctx, annot, opts.annot_id)
        -- Synthesize the /Rect and /AP appearance stream, so the annotation
        -- renders in any PDF viewer (not just KOReader's geometry renderer).
        and W.mupdf_pdf_update_annot(ctx, annot)
    if not ok then
        page:deleteAnnotation(annot)
        return false
    end
    return true
end

-- Whether a stroke still needs embedding (neither in the file nor staged).
local function needsEmbedding(stroke)
    return stroke.page ~= nil and not stroke.embedded and not stroke.staged
end

-- Stage the given strokes' ink into the in-memory document. Staged strokes
-- are marked `staged` (in memory only, never persisted) rather than
-- `embedded`: the file isn't written until flushPdfEdits() on close, and the
-- sidecar must not claim the ink is in the file before it is.
-- settleStagedStrokes() promotes them to `embedded` once the write succeeds,
-- or un-stages them so they're retried.
--
-- Work is grouped by page: each page is opened once, any earlier copies of
-- these strokes' own tags are removed in a single walk (so re-staging after a
-- failed close can't duplicate), all new annotations are built, and the tile
-- cache is reset once at the end. Strokes without page coordinates, or whose
-- annotation MuPDF couldn't build, are skipped and stay overlay ink.
-- Returns the number staged and the _checkIfWritable() reason, if any.
function PencilPDF:stageStrokesInk(strokes)
    local doc, reason = self:writablePdfDoc()
    if not doc then return 0, reason end

    local by_page, pages = {}, {}
    for _, stroke in ipairs(strokes) do
        local points = needsEmbedding(stroke) and stroke.page_points
        if points then
            if not by_page[stroke.page] then
                by_page[stroke.page] = {}
                pages[#pages + 1] = stroke.page
            end
            table.insert(by_page[stroke.page], { stroke = stroke, points = points })
        end
    end

    local staged = 0
    for _, pageno in ipairs(pages) do
        local entries = by_page[pageno]
        local old_tags = {}
        for _, e in ipairs(entries) do
            if e.stroke.annot_id then old_tags[e.stroke.annot_id] = true end
        end
        local page
        local ok, err = pcall(function()
            page = doc._document:openPage(pageno)
            deleteTaggedInk(page, old_tags)
            for _, e in ipairs(entries) do
                local opts = self:strokeToInkOpts(e.stroke)
                opts.annot_id = e.stroke.annot_id or self:nextAnnotId()
                if buildInkAnnot(page, e.points, opts) then
                    -- Keep the tag even if the write later fails: a retry
                    -- reuses it and replaces any copy that did reach the file.
                    e.stroke.annot_id = opts.annot_id
                    e.stroke.staged = true
                    staged = staged + 1
                else
                    logger.warn("Pencil: could not build ink annotation on page", pageno)
                end
            end
        end)
        if page then page:close() end
        if not ok then logger.warn("Pencil: staging ink failed on page", pageno, err) end
    end

    if staged > 0 then
        doc.is_edited = true
        self._pdf_dirty = true
        doc:resetTileCacheValidity()
    end
    return staged
end

-- Resolve every stroke staged this session once the close flush has run:
-- `written` true promotes them to `embedded` (they're in the file now);
-- false un-stages them so the overlay keeps drawing them and the next close
-- retries. Every path that removes a stroke (erase, undo, clear) un-stages it
-- first, so the staged strokes are exactly those still in self.store.strokes.
function PencilPDF:settleStagedStrokes(written)
    for _, stroke in ipairs(self.store.strokes) do
        if stroke.staged then
            stroke.staged = nil
            if written then stroke.embedded = true end
        end
    end
end

-- The part of a KOReader text highlight that lies on `pageno`, shaped the way
-- PdfDocument:saveHighlight/deleteHighlight expect, or nil. A single-page
-- highlight is its own part. A multi-page PDF highlight has no top-level
-- pboxes; each page's boxes live in item.ext[page], and the part comes from
-- KOReader's own getSavedExtendedHighlightPage, exactly as
-- ReaderHighlight:writePdfAnnotation does it (colour fallback included).
-- `commit` copies MuPDF's adjusted boxes back after a save.
local function noop() end
function PencilPDF:highlightPartOnPage(item, pageno)
    if not item.drawer then return nil end
    if item.ext then
        local ext = item.ext[pageno]
        local rh = self.ui.highlight
        if not (ext and ext.pboxes and #ext.pboxes > 0 and rh and rh.getSavedExtendedHighlightPage) then
            return nil
        end
        local part = rh:getSavedExtendedHighlightPage(item, pageno)
        return part, function() ext.pboxes = part.pboxes end
    end
    if item.page == pageno and item.pboxes and #item.pboxes > 0 then
        return item, noop
    end
    return nil
end

-- Collect this page's KOReader text highlights (text selections made with a
-- finger or the text-mode highlighter, stored in the sidecar) so they can be
-- embedded into the PDF as native markup annotations alongside the ink.
-- Returns a list of { part = <saveHighlight-shaped item>, commit = fn }.
function PencilPDF:getPageTextHighlights(pageno)
    local result = {}
    local annotation = self.ui and self.ui.annotation
    if not (annotation and annotation.annotations) then return result end
    for _, item in ipairs(annotation.annotations) do
        local part, commit = self:highlightPartOnPage(item, pageno)
        if part then result[#result + 1] = { part = part, commit = commit } end
    end
    return result
end

-- Whether the PDF page already holds a markup annotation with this
-- highlight part's exact quad points (the same match KOReader's
-- deleteHighlight uses), so re-running the manual save never stacks
-- duplicates. Callers must have checked canExportInk().
function PencilPDF:pdfHasHighlight(pageno, part)
    local ffi = InkAnnot.ffi
    local n = #part.pboxes
    -- pboxes {x,y,w,h} -> fz_quad[], same mapping as KOReader's
    -- _quadpointsFromPboxes (which isn't exported).
    local quads = ffi.new("fz_quad[?]", n)
    for i = 1, n do
        local b = part.pboxes[i]
        local q = quads[i - 1]
        q.ll.x = b.x;             q.ll.y = b.y + b.h - 1
        q.lr.x = b.x + b.w - 1;   q.lr.y = b.y + b.h - 1
        q.ul.x = b.x;             q.ul.y = b.y
        q.ur.x = b.x + b.w - 1;   q.ur.y = b.y
    end
    local page = self.ui.document._document:openPage(pageno)
    local ok, found = pcall(page.getMarkupAnnotation, page, quads, n)
    page:close()
    return ok and found ~= nil
end

-- Write this page's text highlights into the PDF with KOReader's own
-- saveHighlight (same quads, type, colour and /AP as "write highlights into
-- PDF", and it stores MuPDF's adjusted quads back so deleteHighlight can find
-- the annotation later). Highlights already present in the file are skipped.
-- Returns the number written and the _checkIfWritable() reason, if any.
function PencilPDF:saveTextHighlightsToPdf(pageno, highlights)
    if #highlights == 0 then return 0 end
    local doc, reason = self:writablePdfDoc()
    if not doc then return 0, reason end
    local saved = 0
    for _, h in ipairs(highlights) do
        local ok, res = pcall(function()
            if self:pdfHasHighlight(pageno, h.part) then return false end
            return doc:saveHighlight(pageno, h.part)
        end)
        if not ok then
            logger.warn("Pencil: saveHighlight failed:", res)
        elseif res == nil then
            -- PdfDocument:saveHighlight returns nothing on success.
            h.commit()
            saved = saved + 1
        end
    end
    if saved > 0 then self._pdf_dirty = true end
    return saved
end

-- Delete a text highlight's markup annotations from the PDF, on every page it
-- spans, wherever the file holds one with its exact quad points. Only runs on
-- a writable .pdf (see isPdfDocument: walking a non-PDF page would crash).
-- Returns the number deleted.
function PencilPDF:deleteHighlightFromPdf(item)
    local doc = item and self:writablePdfDoc()
    if not doc then return 0 end
    local pages = {}
    if item.ext then
        for pageno in pairs(item.ext) do pages[#pages + 1] = pageno end
    elseif item.page then
        pages[1] = item.page
    end
    local deleted = 0
    for _, pageno in ipairs(pages) do
        local part = self:highlightPartOnPage(item, pageno)
        if part and self:pdfHasHighlight(pageno, part) then
            doc:deleteHighlight(pageno, part)
            deleted = deleted + 1
        end
    end
    if deleted > 0 then doc:resetTileCacheValidity() end
    return deleted
end

-- Persist the plugin's in-memory PDF edits (ink/highlights created or deleted
-- this session) to disk with a SINGLE incremental writeDocument, mirroring how
-- KOReader itself batches all annotation edits into one write on close.
--
-- Critically it then clears doc.is_edited, so KOReader's own PdfDocument:close
-- does NOT issue a second writeDocument on the same document handle -- two
-- stacked incremental saves corrupt the xref (MuPDF: "cannot find object").
-- That single write also captures any in-memory highlight edits KOReader made
-- (e.g. via "write highlights into PDF"), so nothing is lost.
--
-- We write here, rather than leaving it to PdfDocument:close, because settling
-- the staged strokes needs the write's result before the sidecar is saved,
-- and KOReader's own write only happens after our CloseDocument handler. Two
-- side effects of doing it ourselves:
--   * this write skips PdfDocument:close's DocumentRegistry reference-count
--     check (KOReader only writes when it holds the last reference);
--   * anything that edits the document after our CloseDocument handler runs
--     is not written, since is_edited is already cleared.
-- Returns true if a write happened.
function PencilPDF:flushPdfEdits()
    if not self._pdf_dirty then return false end
    local doc = self.ui and self.ui.document
    if not (doc and doc.writeDocument) then return false end
    if not (doc._checkIfWritable and doc:_checkIfWritable() == true) then
        return false
    end
    local ok, err = pcall(function() doc:writeDocument() end)
    if not ok then
        logger.err("Pencil: flushPdfEdits writeDocument failed:", err)
        return false
    end
    self._pdf_dirty = false
    doc.is_edited = false  -- prevent KOReader's close from writing again
    logger.info("Pencil: flushed plugin PDF edits (single write)")
    return true
end

-- Write the current page's pencil strokes (as ink) and text highlights (as
-- native markup annotations) into the PDF file.
function PencilPDF:saveCurrentPageToPdf()
    if not self:isPdfDocument() then
        UIManager:show(InfoMessage:new{
            text = _("Saving annotations to the file is only supported for PDF documents."),
            timeout = 3,
        })
        return
    end
    if not InkAnnot then
        UIManager:show(InfoMessage:new{
            text = _("This KOReader build cannot write ink annotations. Update to KOReader 2026.07 or newer."),
        })
        return
    end

    local page = self:getCurrentPage()
    local strokes = {}
    for _, stroke in ipairs(self.store:forPage(page)) do
        if needsEmbedding(stroke) then strokes[#strokes + 1] = stroke end
    end
    -- With KOReader's "write highlights into PDF" on, highlights are already
    -- in the document; writing them again would only duplicate them.
    local highlights = {}
    if not (self.ui.highlight and self.ui.highlight.highlight_write_into_pdf) then
        highlights = self:getPageTextHighlights(page)
    end
    if #strokes == 0 and #highlights == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No annotations on this page to save."),
            timeout = 2,
        })
        return
    end

    -- Pencil strokes -> ink annotations (one per stroke, keeping color/width).
    local saved_ink, writable_fail = self:stageStrokesInk(strokes)

    -- Text highlights -> native markup annotations (with appearance streams).
    local saved_hl, hl_fail = self:saveTextHighlightsToPdf(page, highlights)
    writable_fail = writable_fail or hl_fail

    local saved = saved_ink + saved_hl
    if saved == 0 then
        UIManager:show(InfoMessage:new{
            text = writable_fail
                and _("The PDF file is not writable, so annotations can't be saved.")
                or (#strokes == 0 and _("This page's highlights are already in the PDF."))
                or _("Failed to save annotations to the PDF."),
            timeout = 3,
        })
        return
    end

    -- The annotations are now in the in-memory document (visible immediately),
    -- but the actual file write is DEFERRED to a single write when the book is
    -- closed (see flushPdfEdits / onCloseDocument). Writing here as well would
    -- stack a second incremental save on the close write and corrupt the xref.
    -- Staged strokes are suppressed from the overlay (paintTo), so there's
    -- no double-draw to clean up and no prompt to remove them.
    UIManager:setDirty(self.view, "ui")

    local msg
    if saved_ink > 0 and saved_hl > 0 then
        msg = T(_("Added %1 pencil stroke(s) and %2 highlight(s) to this page."), saved_ink, saved_hl)
    elseif saved_ink > 0 then
        msg = T(_("Added %1 pencil stroke(s) to this page."), saved_ink)
    else
        msg = T(_("Added %1 highlight(s) to this page."), saved_hl)
    end
    UIManager:show(InfoMessage:new{
        text = msg .. "\n\n" .. _("They'll be written into the PDF file when you close the book."),
        timeout = 3,
    })
end

-- Generate a process-unique tag for an embedded ink annotation. Stored in the
-- annotation's /Contents and on the stroke, so the eraser can pair the two up.
function PencilPDF:nextAnnotId()
    self._annot_seq = (self._annot_seq or 0) + 1
    return string.format("%s%d-%d-%d", INK_TAG_PREFIX, os.time(), self._annot_seq, math.random(1000, 9999))
end

-- Remove the PDF ink annotations belonging to the given strokes, which have
-- just been erased, undone or cleared. Only those strokes' own tags are
-- deleted, so ink this sidecar doesn't know about (another device's, or from
-- before a reset) is always left alone. The delete is in memory; the disk
-- write is deferred to flushPdfEdits() on close. Each stroke's PDF state is
-- dropped so an undo brings it back as a normal overlay stroke that re-embeds
-- on the next save. Returns the number of annotations deleted.
function PencilPDF:deleteEmbeddedAnnotationsFor(strokes)
    -- Any stroke with a tag may have ink in the document (embedded, staged,
    -- or a write that landed before a crash).
    local tag_pages = {}
    for _, stroke in ipairs(strokes or {}) do
        if stroke.annot_id and stroke.page then tag_pages[stroke.annot_id] = stroke.page end
    end
    if next(tag_pages) == nil or not self:writablePdfDoc() then return 0 end

    -- Remember the deletions in the sidecar until the close write lands.
    -- The strokes leave the sidecar right away, so without this a crash or
    -- kill before close would leave their ink in the file with nothing left
    -- to erase it. The next session replays them (applyPendingInkDeletes).
    self.pending_ink_deletes = self.pending_ink_deletes or {}
    for tag, page in pairs(tag_pages) do self.pending_ink_deletes[tag] = page end

    local deleted = self:_deleteInkTagsByPage(groupTagsByPage(tag_pages))
    if deleted > 0 then
        -- The deleted ink is a baked PDF annotation, so its pixels live in the
        -- rendered page tile, not our overlay. Schedule a proper "ui" refresh
        -- -- like KOReader's own deleteHighlight -- so the tile is regenerated
        -- from the pruned in-memory doc and the ink disappears without a page
        -- turn.
        UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
        logger.info("Pencil: removed", deleted, "embedded ink annotation(s) (deferred write)")
    end

    for _, stroke in ipairs(strokes) do
        stroke.embedded = nil
        stroke.staged = nil
        stroke.annot_id = nil
    end
    return deleted
end

-- Delete tagged ink in the in-memory document, given { [pageno] = { [tag] = true } }.
-- Marks the document for the close write when anything was removed.
-- Returns the number of annotations deleted.
function PencilPDF:_deleteInkTagsByPage(tags_by_page)
    local doc = self.ui.document
    local deleted = 0
    for pageno, tags in pairs(tags_by_page) do
        local page
        local ok, res = pcall(function()
            page = doc._document:openPage(pageno)
            return deleteTaggedInk(page, tags)
        end)
        if page then page:close() end
        if ok then
            deleted = deleted + res
        else
            logger.warn("Pencil: deleting embedded ink failed on page", pageno, res)
        end
    end
    if deleted > 0 then
        doc.is_edited = true
        self._pdf_dirty = true
        doc:resetTileCacheValidity()
    end
    return deleted
end

-- Replay the deletions an earlier session queued but never wrote (it ended
-- before its close write). Only those are replayed: this session's own
-- deletions were applied when they were made. Deleting is by our own tag, so
-- replaying is harmless. Run on open, so leftover ink vanishes at once, and
-- again on close if it couldn't run then. Returns the number of annotations
-- deleted, or nil when the deletions can't be applied here (no ink support,
-- not a writable PDF), in which case the queue must be kept.
function PencilPDF:applyPendingInkDeletes()
    local unapplied = self._unapplied_ink_deletes
    if not (unapplied and next(unapplied)) then return 0 end
    if not self:writablePdfDoc() then return nil end
    local deleted = self:_deleteInkTagsByPage(groupTagsByPage(unapplied))
    self._unapplied_ink_deletes = nil
    if deleted > 0 then
        logger.info("Pencil: removed", deleted, "ink annotation(s) left by an earlier session")
    end
    return deleted
end

-- Remove the PDF ink of strokes erased by a gesture that hasn't reached its
-- pen-up yet (the page changed or the book is closing mid-erase), so the
-- annotation can't outlive its stroke.
function PencilPDF:flushPendingEraseToPdf()
    self:deleteEmbeddedAnnotationsFor(self.eraser_deleted)
    self:deleteEmbeddedAnnotationsFor(self.eraser_button_deleted)
end

-- Stage every not-yet-embedded pencil stroke as a native ink annotation. Used
-- by the "auto-save on close" option; the single disk write is flushPdfEdits()
-- right after. Each stroke is placed with the page coordinates recorded when it
-- was drawn, so this is safe for every page, not just the one on screen.
-- Strokes without recorded page coordinates are skipped and stay as overlay.
-- Text highlights are intentionally left out (KOReader keeps drawing its own
-- copy from the sidecar, which would double a baked-in /Highlight); those stay
-- on the manual per-page action. Returns the number of strokes staged.
function PencilPDF:autoSaveInkToPdf()
    local staged = self:stageStrokesInk(self.store.strokes)
    if staged > 0 then
        logger.info("Pencil: staged", staged, "stroke(s) for embedding on close")
    end
    return staged
end

-- Render a line segment using rectangles (since BlitBuffer has no native line drawing)
-- Rasterize a thick line by stamping width×width squares along the segment.
-- Steps by ~half the pen width (via Geometry.segmentStepCount) so the squares

return PencilPDF
