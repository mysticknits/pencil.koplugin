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

local InkAnnot = (function()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    -- Pulls in fz_point / pdf_annot / pdf_page / PDF_ANNOT_INK and loads the lib.
    if not pcall(require, "ffi/mupdf") then return nil end
    pcall(ffi.cdef, [[
        void *mupdf_pdf_set_annot_ink_list(fz_context *, pdf_annot *, int, const int *, const fz_point *);
        void *mupdf_pdf_set_annot_border_width(fz_context *, pdf_annot *, float);
        void *mupdf_pdf_update_annot(fz_context *, pdf_annot *);
    ]])
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
-- Converts this page's pencil strokes into native PDF ink annotations
-- (/Subtype /Ink) and writes them into the document file, so they are
-- visible in any PDF reader. Manual, current-page only: it relies on
-- KOReader's live ReaderView:screenToPageTransform, which is exact for
-- the page currently on screen (off-screen pages have no laid-out
-- transform). Strokes are stored in screen coordinates; we map each
-- point to native page coordinates before handing it to MuPDF.
--
-- Requires KOReader 2026.07+ for the ink setters (see the module InkAnnot
-- block near the top). Degrades gracefully: when InkAnnot is nil the menu
-- action explains what's missing.
-- ===================================================================

-- Map a stroke's screen-space points to native page coordinates.
-- transform_fn is injectable for testing; by default it uses the live
-- ReaderView transform for the current on-screen page.
function PencilPDF:strokeToPagePoints(stroke, transform_fn)
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

-- Derive the ink annotation options (color/width/opacity) for a stroke.
-- Stroke widths are stored in screen pixels, but MuPDF's border width is in
-- native page units, so it needs the same zoom division the points get from
-- screenToPageTransform. (MuPDF's ink border width is the full line width,
-- centered on the path, so no extra halving is needed.)
function PencilPDF:strokeToInkOpts(stroke)
    local tool = stroke.tool or TOOL_PEN
    local color = stroke.color or self.tool:getToolSettings(tool).color or Blitbuffer.COLOR_BLACK
    local rgb = color:getColorRGB32()
    local width = stroke.width or self.tool:getToolSettings(tool).width or 3
    local zoom = self.view and self.view.state and self.view.state.zoom
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

-- Create one native ink annotation on `pageno` from `strokes` (an array of
-- point-lists in native page coordinates) with the given color/width/opacity.
-- Talks to the MuPDF wrapper directly (mirrors PdfDocument:saveHighlight's
-- open/mutate/close/mark-edited dance) so no core KOReader file is patched.
-- Returns true on success, or the _checkIfWritable() reason for a read-only file.
function PencilPDF:writeInkAnnotation(pageno, strokes, opts)
    local doc = self.ui.document
    local can_write = doc:_checkIfWritable()
    if can_write ~= true then return can_write end

    local n = #strokes
    if n == 0 then return true end
    local ffi = InkAnnot.ffi
    local W = InkAnnot.W

    -- counts[i] = points in stroke i; vertices = flattened fz_point[].
    local counts = ffi.new("int[?]", n)
    local total = 0
    for i = 1, n do
        counts[i - 1] = #strokes[i]
        total = total + #strokes[i]
    end
    if total == 0 then return true end
    local vertices = ffi.new("fz_point[?]", total)
    local k = 0
    for i = 1, n do
        for j = 1, #strokes[i] do
            vertices[k].x = strokes[i][j].x
            vertices[k].y = strokes[i][j].y
            k = k + 1
        end
    end

    doc.is_edited = true
    local page = doc._document:openPage(pageno)
    local ctx = page.ctx
    local pdf_page = ffi.cast("pdf_page*", page.page)
    local annot = W.mupdf_pdf_create_annot(ctx, pdf_page, InkAnnot.PDF_ANNOT_INK)
    if annot ~= nil then
        W.mupdf_pdf_set_annot_ink_list(ctx, annot, n, counts, vertices)
        local color = ffi.new("float[3]")
        color[0] = opts.color.r / 255
        color[1] = opts.color.g / 255
        color[2] = opts.color.b / 255
        W.mupdf_pdf_set_annot_color(ctx, annot, 3, color)
        W.mupdf_pdf_set_annot_border_width(ctx, annot, opts.width or 1.0)
        W.mupdf_pdf_set_annot_opacity(ctx, annot, opts.opacity or 1.0)
        -- Tag the annotation so the eraser can find and delete this exact
        -- stroke's annotation later (stored in /Contents). Only auto-save
        -- passes an id; the manual per-page action leaves /Contents empty.
        if opts.annot_id then
            W.mupdf_pdf_set_annot_contents(ctx, annot, opts.annot_id)
        end
        -- Synthesize the /Rect and /AP appearance stream, so the annotation
        -- renders in any PDF viewer (not just KOReader's geometry renderer).
        W.mupdf_pdf_update_annot(ctx, annot)
    end
    page:close()
    if annot ~= nil then self._pdf_dirty = true end
    doc:resetTileCacheValidity()
    return annot ~= nil
end

-- Collect this page's KOReader text highlights (text selections made with a
-- finger or the text-mode highlighter, stored in the sidecar) so they can be
-- embedded into the PDF as native /Highlight annotations alongside the ink.
function PencilPDF:getPageTextHighlights(pageno)
    local result = {}
    local annotation = self.ui and self.ui.annotation
    if not (annotation and annotation.annotations) then return result end
    for _, item in ipairs(annotation.annotations) do
        -- A drawable text highlight has page boxes and a drawer style.
        if item.pboxes and item.drawer and item.page == pageno then
            result[#result + 1] = item
        end
    end
    return result
end

-- Write a single KOReader text highlight into the PDF as a native markup
-- annotation (/Highlight, /Underline or /StrikeOut per its drawer). Mirrors
-- writeInkAnnotation: create -> set geometry/color -> pdf_update_annot on the
-- same handle, which synthesizes /Rect + /AP so it renders in any PDF viewer.
-- Returns true on success, or the _checkIfWritable() reason for a read-only file.
function PencilPDF:writeHighlightAnnotation(pageno, item)
    if not (item.pboxes and #item.pboxes > 0) then return true end
    local doc = self.ui.document
    local can_write = doc:_checkIfWritable()
    if can_write ~= true then return can_write end

    local ffi = InkAnnot.ffi
    local W = InkAnnot.W
    local C = ffi.C

    -- pboxes {x,y,w,h} (page coords) -> fz_quad[], same mapping as KOReader's
    -- _quadpointsFromPboxes (order: ll, lr, ul, ur).
    local n = #item.pboxes
    local quads = ffi.new("fz_quad[?]", n)
    for i = 1, n do
        local b = item.pboxes[i]
        local q = quads[i - 1]
        q.ll.x = b.x;             q.ll.y = b.y + b.h - 1
        q.lr.x = b.x + b.w - 1;   q.lr.y = b.y + b.h - 1
        q.ul.x = b.x;             q.ul.y = b.y
        q.ur.x = b.x + b.w - 1;   q.ur.y = b.y
    end

    local annot_type, opacity = C.PDF_ANNOT_HIGHLIGHT, 0.5
    if item.drawer == "underscore" then
        annot_type, opacity = C.PDF_ANNOT_UNDERLINE, 1.0
    elseif item.drawer == "strikeout" then
        annot_type, opacity = C.PDF_ANNOT_STRIKE_OUT, 1.0
    end

    doc.is_edited = true
    local page = doc._document:openPage(pageno)
    local ctx = page.ctx
    local pdf_page = ffi.cast("pdf_page*", page.page)
    local annot = W.mupdf_pdf_create_annot(ctx, pdf_page, annot_type)
    if annot ~= nil then
        W.mupdf_pdf_set_annot_quad_points(ctx, annot, n, quads)
        local color = ffi.new("float[3]")
        local bb = item.color and Blitbuffer.colorFromName(item.color)
        if bb then
            local rgb = bb:getColorRGB32()
            color[0] = rgb:getR() / 255
            color[1] = rgb:getG() / 255
            color[2] = rgb:getB() / 255
        else
            color[0], color[1], color[2] = 1.0, 1.0, 0.0  -- default yellow
        end
        W.mupdf_pdf_set_annot_color(ctx, annot, 3, color)
        W.mupdf_pdf_set_annot_opacity(ctx, annot, opacity)
        W.mupdf_pdf_update_annot(ctx, annot)  -- generate /Rect + /AP
    end
    page:close()
    if annot ~= nil then self._pdf_dirty = true end
    doc:resetTileCacheValidity()
    return annot ~= nil
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

-- Older KOReader builds' addMarkupAnnotation (used by the "write highlights
-- into PDF" feature) did NOT synthesize an appearance stream, so a freshly
-- created highlight was a "dirty" PDF annotation with no /AP. Desktop PDF
-- viewers render only /AP, so those highlights were invisible on a Mac
-- (KOReader draws them from geometry, which is why they looked fine on device).
--
-- koreader/koreader-base#2457 (KOReader 2026.07+) makes addMarkupAnnotation
-- call pdf_update_annot itself, so highlights created there already carry an
-- /AP and this pass is a no-op in effect. We keep it for highlights made on
-- older builds and for files highlighted before upgrading, which still have
-- /AP-less markup annotations that only get fixed on the next change.
--
-- We fix this by running pdf_update_annot on the markup annotations of every
-- page that carries a KOReader highlight. MuPDF synthesizes an /AP ONLY for the
-- dirty (newly created) annots and no-ops on ones that already have an
-- appearance -- so we neither miss a new highlight nor rewrite/bloat the file
-- for old ones. We only bother when KOReader recorded an annotation change this
-- session (document.is_edited, set by saveHighlight/deleteHighlight when
-- write-into-PDF is on); the single close flush then writes it out.
function PencilPDF:ensureHighlightAppearances()
    if not (self.ui and self.ui.paging and InkAnnot) then return end
    local annotation = self.ui.annotation
    if not (annotation and annotation.annotations) then return end
    local doc = self.ui.document
    if not (doc and doc._checkIfWritable and doc:_checkIfWritable() == true) then return end
    -- Nothing changed this session -> nothing to synthesize or rewrite. This is
    -- what keeps us from appending an identical incremental update on every close.
    if not doc.is_edited then return end
    local ffi = InkAnnot.ffi
    local W = InkAnnot.W
    local C = ffi.C

    -- Only markup types get an /AP from update_annot; probe the enum once.
    local ok_types, HL, UL, SO = pcall(function()
        return C.PDF_ANNOT_HIGHLIGHT, C.PDF_ANNOT_UNDERLINE, C.PDF_ANNOT_STRIKE_OUT
    end)
    if not ok_types then return end

    local pages = {}
    for _, item in ipairs(annotation.annotations) do
        if item.drawer and item.page then pages[item.page] = true end
    end

    local tmp = ffi.new("fz_quad[1]")
    local visited = 0
    for pageno in pairs(pages) do
        pcall(function()
            local page = doc._document:openPage(pageno)
            local ctx = page.ctx
            local annot = W.mupdf_pdf_first_annot(ctx, ffi.cast("pdf_page*", page.page))
            while annot ~= nil do
                local t = W.mupdf_pdf_annot_type(ctx, annot)
                if t == HL or t == UL or t == SO then
                    -- pdf_update_annot only synthesizes an /AP when the annot is
                    -- dirty (needs_new_ap). A highlight read back from a freshly
                    -- opened page handle reports clean even when it has no /AP, so
                    -- update_annot would no-op and the highlight stays invisible in
                    -- desktop viewers. Re-set its own quad points (identical
                    -- geometry) to force the dirty flag, then update_annot actually
                    -- builds the appearance. We only get here when a highlight was
                    -- added/removed this session, so this runs at most once per such
                    -- close, not on every close.
                    local qn = W.mupdf_pdf_annot_quad_point_count(ctx, annot)
                    if qn and qn > 0 then
                        local quads = ffi.new("fz_quad[?]", qn)
                        for i = 0, qn - 1 do
                            W.mupdf_pdf_annot_quad_point(ctx, annot, i, tmp)
                            quads[i] = tmp[0]
                        end
                        W.mupdf_pdf_set_annot_quad_points(ctx, annot, qn, quads)
                    end
                    W.mupdf_pdf_update_annot(ctx, annot)
                    visited = visited + 1
                end
                annot = W.mupdf_pdf_next_annot(ctx, annot)
            end
            page:close()
        end)
    end
    -- We reached here only because is_edited was set (a highlight was added or
    -- removed this session), so flush to persist it -- new highlights now carry
    -- an /AP, and any deletion is written through our single close flush.
    self._pdf_dirty = true
    doc:resetTileCacheValidity()
    logger.info("Pencil: refreshed appearance for", visited, "highlight annotation(s)")
end

-- Write the current page's pencil strokes (as ink) and text highlights (as
-- native /Highlight annotations) into the PDF file.
function PencilPDF:saveCurrentPageToPdf()
    if not self.ui.paging then
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
    local strokes = self.store:forPage(page)
    local highlights = self:getPageTextHighlights(page)
    if #strokes == 0 and #highlights == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No annotations on this page to save."),
            timeout = 2,
        })
        return
    end

    local saved_ink, saved_hl = 0, 0
    local writable_fail = nil

    -- Pencil strokes -> ink annotations (one per stroke, keeping color/width).
    for _, stroke in ipairs(strokes) do
        if not stroke.embedded then
            local points = self:strokeToPagePoints(stroke)
            if #points >= 1 then
                local opts = self:strokeToInkOpts(stroke)
                opts.annot_id = stroke.annot_id or self:nextAnnotId()
                local ok, res = pcall(function()
                    return self:writeInkAnnotation(page, { points }, opts)
                end)
                if ok and res == true then
                    -- Tag + mark embedded, same as auto-save, so the two never
                    -- create duplicate annotations for one stroke.
                    stroke.embedded = true
                    stroke.annot_id = opts.annot_id
                    saved_ink = saved_ink + 1
                elseif ok then
                    writable_fail = res  -- read-only file
                else
                    logger.warn("Pencil: writeInkAnnotation failed:", res)
                end
            end
        end
    end

    -- Text highlights -> native markup annotations (with appearance streams).
    for _, item in ipairs(highlights) do
        local ok, res = pcall(function()
            return self:writeHighlightAnnotation(page, item)
        end)
        if ok and res == true then
            saved_hl = saved_hl + 1
        elseif ok then
            writable_fail = res  -- read-only file
        else
            logger.warn("Pencil: writeHighlightAnnotation failed:", res)
        end
    end

    local saved = saved_ink + saved_hl
    if saved == 0 then
        UIManager:show(InfoMessage:new{
            text = writable_fail
                and _("The PDF file is not writable, so annotations can't be saved.")
                or _("Failed to save annotations to the PDF."),
            timeout = 3,
        })
        return
    end

    -- The annotations are now in the in-memory document (visible immediately),
    -- but the actual file write is DEFERRED to a single write when the book is
    -- closed (see flushPdfEdits / onCloseDocument). Writing here as well would
    -- stack a second incremental save on the close write and corrupt the xref.
    -- Embedded strokes are auto-suppressed from the overlay (paintTo), so there's
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
    return string.format("kop-ink-%d-%d-%d", os.time(), self._annot_seq, math.random(1000, 9999))
end

-- Tag prefix carried in each embedded ink annotation's /Contents. Lets us
-- recognise (and only ever delete) annotations this plugin created.
local INK_TAG_PREFIX = "kop-ink-"

-- Delete every plugin-tagged ink annotation on the already-open pdf_page whose
-- /Contents tag is NOT in keep_ids (a set of tags to preserve). Foreign ink
-- (any annotation without our prefix) is never touched. Returns count deleted.
function PencilPDF:_pruneInkAnnotsOnPage(ctx, pdf_page, keep_ids)
    local ffi = InkAnnot.ffi
    local W = InkAnnot.W
    local deleted = 0
    local annot = W.mupdf_pdf_first_annot(ctx, pdf_page)
    while annot ~= nil do
        -- Grab next before a possible delete unlinks the current one.
        local next_annot = W.mupdf_pdf_next_annot(ctx, annot)
        if W.mupdf_pdf_annot_type(ctx, annot) == InkAnnot.PDF_ANNOT_INK then
            local cptr = W.mupdf_pdf_annot_contents(ctx, annot)
            local tag = cptr ~= nil and ffi.string(cptr) or ""
            if tag:sub(1, #INK_TAG_PREFIX) == INK_TAG_PREFIX and not keep_ids[tag] then
                W.mupdf_pdf_delete_annot(ctx, pdf_page, annot)
                deleted = deleted + 1
            end
        end
        annot = next_annot
    end
    return deleted
end

-- Remove the baked-in ink annotations for the given (just-erased) strokes.
-- Self-healing: on each affected page it keeps only the annotations claimed by
-- strokes that are *still* present, and deletes every other plugin-tagged ink
-- annotation on that page (so orphans/duplicates from earlier sessions get
-- cleaned up too). Writes the file once if anything changed, and clears the
-- erased strokes' embedded state so an undo restores them as normal overlay
-- strokes rather than invisible orphans. Returns the number of annotations
-- deleted.
function PencilPDF:deleteEmbeddedAnnotationsFor(strokes)
    if not (self.ui and self.ui.paging and InkAnnot) then return 0 end

    -- Which pages had an embedded stroke erased?
    local affected = {}
    local any = false
    for _, stroke in ipairs(strokes) do
        if stroke.embedded and stroke.page then
            affected[stroke.page] = true
            any = true
        end
    end
    if not any then return 0 end

    local doc = self.ui.document
    if not (doc and doc._checkIfWritable and doc:_checkIfWritable() == true) then
        return 0
    end
    local ffi = InkAnnot.ffi

    -- For each affected page, the tags we must keep = annot_ids of embedded
    -- strokes still in the live list on that page.
    local deleted = 0
    for pageno in pairs(affected) do
        local keep_ids = {}
        for _, stroke in ipairs(self.store.strokes) do
            if stroke.page == pageno and stroke.embedded and stroke.annot_id then
                keep_ids[stroke.annot_id] = true
            end
        end
        local ok, res = pcall(function()
            local page = doc._document:openPage(pageno)
            local n = self:_pruneInkAnnotsOnPage(page.ctx, ffi.cast("pdf_page*", page.page), keep_ids)
            page:close()
            return n
        end)
        if ok then
            deleted = deleted + res
        else
            logger.warn("Pencil: prune ink failed on page", pageno, res)
        end
    end

    if deleted > 0 then
        -- In-memory delete only; the disk write is deferred to flushPdfEdits()
        -- on close (one write per session).
        doc.is_edited = true
        self._pdf_dirty = true
        doc:resetTileCacheValidity()
        -- The erased ink is a baked PDF annotation, so its pixels live in the
        -- rendered page tile, not our overlay. The eraser gesture's own
        -- refreshFast only repaints the overlay with a fast waveform and leaves
        -- the baked ink ghosting on screen (which looks like "erase did
        -- nothing"). Schedule a proper "ui" refresh -- like KOReader's own
        -- deleteHighlight -- so the page tile is regenerated from the now-pruned
        -- in-memory doc and the ink actually disappears without a page turn.
        UIManager:setDirty(self.ui.dialog or self.ui.view, "ui")
        logger.info("Pencil: removed", deleted, "embedded ink annotation(s) via eraser (deferred write)")
    end

    -- Drop the embedded state on every erased stroke that had one (even if its
    -- annotation was already gone): an undo should bring it back as a normal
    -- redrawn overlay stroke that re-embeds cleanly on the next close.
    for _, stroke in ipairs(strokes) do
        if stroke.embedded or stroke.annot_id then
            stroke.embedded = nil
            stroke.annot_id = nil
        end
    end
    return deleted
end

-- Silently embed every not-yet-embedded pencil stroke into the PDF as native
-- ink annotations, then write the file once. Used by the "auto-save on close"
-- option. Unlike the manual per-page action it:
--   * covers all pages (relies on the plugin's fixed page-fit layout so the
--     live screen->page transform maps each stroke's local coords correctly),
--   * marks each embedded stroke so re-runs / re-opens never duplicate it,
--   * shows no dialogs and does not offer to remove the overlay (embedded
--     strokes stop being drawn by paintTo instead — see the `embedded` skip).
-- Text highlights are intentionally left out (KOReader keeps drawing its own
-- copy from the sidecar, which would double a baked-in /Highlight); those stay
-- on the manual per-page action. Returns the number of strokes embedded.
function PencilPDF:autoSaveInkToPdf()
    if not (self.ui and self.ui.paging and InkAnnot) then return 0 end

    local doc = self.ui.document
    if not (doc and doc._checkIfWritable and doc:_checkIfWritable() == true) then
        return 0
    end

    local just_embedded = {}
    local touched_pages = {}
    for _, stroke in ipairs(self.store.strokes) do
        if not stroke.embedded and stroke.page then
            local points = self:strokeToPagePoints(stroke)
            if #points >= 1 then
                local opts = self:strokeToInkOpts(stroke)
                opts.annot_id = stroke.annot_id or self:nextAnnotId()
                local ok, res = pcall(function()
                    return self:writeInkAnnotation(stroke.page, { points }, opts)
                end)
                if ok and res == true then
                    stroke.embedded = true
                    stroke.annot_id = opts.annot_id
                    just_embedded[#just_embedded + 1] = stroke
                    touched_pages[stroke.page] = true
                elseif not ok then
                    logger.warn("Pencil: autoSave writeInkAnnotation failed:", res)
                end
            end
        end
    end

    if #just_embedded == 0 then return 0 end

    -- Self-heal: on every page we just touched, drop any plugin-tagged ink
    -- annotation that isn't claimed by a current stroke (orphans/duplicates
    -- from an interrupted earlier session), so the file mirrors the live list.
    for pageno in pairs(touched_pages) do
        local keep_ids = {}
        for _, stroke in ipairs(self.store.strokes) do
            if stroke.page == pageno and stroke.embedded and stroke.annot_id then
                keep_ids[stroke.annot_id] = true
            end
        end
        pcall(function()
            local page = doc._document:openPage(pageno)
            self:_pruneInkAnnotsOnPage(page.ctx, InkAnnot.ffi.cast("pdf_page*", page.page), keep_ids)
            page:close()
        end)
    end

    -- NOTE: no writeDocument here. All mutations are in-memory; the single disk
    -- write happens in flushPdfEdits() (called on close after this), matching
    -- KOReader's own one-write-on-close model. Rollback of the embedded flags
    -- on a failed write is handled by the caller (onCloseDocument).
    self._pdf_dirty = true
    self._auto_embedded_this_close = just_embedded
    logger.info("Pencil: staged", #just_embedded, "stroke(s) for embedding on close")
    return #just_embedded
end


return PencilPDF
