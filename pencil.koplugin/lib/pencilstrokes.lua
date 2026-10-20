--[[
Strokes for the Pencil plugin.

Owns everything about the strokes themselves:
  * the stroke record (newStroke) and its saved form (toSaveable / fromSaved),
  * the store of a document's strokes: the list, the per-page index, the
    undo/redo history, erasing and clearing,
  * the page anchoring of PDF strokes (page coordinates <-> screen points),
  * saving to / loading from the plugin's strokes file,
  * drawing strokes into a blitbuffer, including the translucent highlighter.

It does NOT deal with input, the screen refresh, KOReader widgets, annotation
groups, bookmarks or PDF export. main.lua feeds it what it needs (tool
settings, colors, the file path, the screen's night mode) and does what follows
a change (rebuilding annotation groups, saving, repainting).

A stroke is a plain table:
  page, tool, points = { {x=,y=}, ... }, width, color (Blitbuffer color),
  color_name, alpha (0-255), datetime, bbox, and optionally page_points (PDF
  strokes: the same points in page coordinates, the source of truth; points are
  then the screen projection for the current view), embedded, annot_id and the
  MyScript transcription fields.
]]

local Blitbuffer = require("ffi/blitbuffer")
local PencilGeometry = require("lib/geometry")
local PencilTool = require("lib/penciltool")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local TOOLS = PencilTool.TOOLS

local PencilStrokes = {}
PencilStrokes.__index = PencilStrokes

-- Name of the setting (in the document's metadata) that remembers where the
-- strokes file is, to recover it after KOReader moves a document's sidecar.
PencilStrokes.PATH_SETTING = "pencil_strokes_path"
PencilStrokes.FILE_NAME = "pencil_strokes.lua"
-- 5: v4's packed points plus optional MyScript transcription metadata.
-- Strokes saved as an array of {x=,y=} tables (v3 and earlier) still load.
PencilStrokes.FILE_VERSION = 5

--
-- Stroke records
--

-- A new, empty stroke for `tool` using that tool's settings (width, color,
-- color_name, alpha). points: optional initial points.
function PencilStrokes.newStroke(page, tool, settings, points)
    return {
        page = page,
        tool = tool,
        points = points or {},
        width = settings.width,
        color = settings.color,
        color_name = settings.color_name,
        alpha = settings.alpha,
        datetime = os.time(),
        bbox = nil, -- incrementally maintained; avoids O(points) work at PEN UP
    }
end

-- The pen color shown while writing when "live black preview" is on: the pen
-- is drawn black and gets its real color after the delayed refresh.
function PencilStrokes.liveColor(stroke, live_black_preview)
    if live_black_preview
        and stroke.tool == TOOLS.PEN
        and stroke.color_name
        and stroke.color_name ~= "Black" then
        return Blitbuffer.COLOR_BLACK
    end
    return stroke.color
end

-- Convert a stroke for saving (no non-serializable values)
function PencilStrokes.toSaveable(stroke)
    return {
        page = stroke.page,
        tool = stroke.tool,
        width = stroke.width,
        alpha = stroke.alpha,
        datetime = stroke.datetime,
        -- v4: points packed as a single "x y x y ..." string instead of an
        -- array of {x=,y=} tables, so the serializer doesn't walk every point.
        p = PencilGeometry.packPoints(stroke.points),
        -- PDF strokes: page coordinates, the source of truth for rendering.
        pp = stroke.page_points and PencilGeometry.packPoints(stroke.page_points) or nil,
        color_name = stroke.color_name,  -- Save color name for persistence
        embedded = stroke.embedded,      -- true once written into the PDF file
        annot_id = stroke.annot_id,      -- tag of its PDF annotation (for the eraser)
        transcription = stroke.transcription,
        transcription_group_id = stroke.transcription_group_id,
        transcription_language = stroke.transcription_language,
        transcription_datetime = stroke.transcription_datetime,
        transcription_engine = stroke.transcription_engine,
    }
end

-- Convert a saved stroke back to a usable one.
-- ctx.tool_settings(tool): settings of a tool (width, color, alpha defaults)
-- ctx.available_colors: array of { name =, color = } to look color names up in
function PencilStrokes.fromSaved(saved, ctx)
    local tool = saved.tool or TOOLS.PEN
    local tool_settings = ctx.tool_settings(tool)

    -- Look up color from color_name
    local color = tool_settings.color
    if saved.color_name then
        for _, color_info in ipairs(ctx.available_colors or {}) do
            if color_info.name == saved.color_name then
                color = color_info.color
                break
            end
        end
    end

    -- Highlighter strokes saved before the highlighter had a choosable color have
    -- no color name: they keep the opaque light gray they were drawn with, and
    -- must not follow the highlighter color chosen now.
    local alpha = saved.alpha or tool_settings.alpha
    if tool == TOOLS.HIGHLIGHTER and not saved.color_name then
        color = Blitbuffer.Color8(0xDD)
        alpha = 0xFF
    end

    -- Points: v4 stores a packed "x y ..." string in `p`; v3 and earlier store
    -- an array of {x=,y=} tables in `points`. Reconstruct the in-memory
    -- {x=,y=} array either way.
    local points
    if saved.p ~= nil then
        points = PencilGeometry.unpackPoints(saved.p)
    else
        points = saved.points or {}
    end

    local stroke = {
        page = saved.page,
        tool = saved.tool,
        width = saved.width or tool_settings.width,
        color = color,
        color_name = saved.color_name,
        alpha = alpha,
        datetime = saved.datetime,
        points = points,
        embedded = saved.embedded,
        annot_id = saved.annot_id,
        transcription = saved.transcription,
        transcription_group_id = saved.transcription_group_id,
        transcription_language = saved.transcription_language,
        transcription_datetime = saved.transcription_datetime,
        transcription_engine = saved.transcription_engine,
        page_points = saved.pp and PencilGeometry.unpackPoints(saved.pp) or nil,
    }
    stroke.bbox = PencilGeometry.computeStrokeBbox(stroke)
    return stroke
end

--
-- Page anchoring (PDF strokes follow zoom, pan, crop and rotation)
--

-- Give a finished stroke page coordinates (page_points) from the anchor it
-- captured when it started (_anchor_page/_zoom/_ox/_oy: the page under its first
-- point and that page's transform). Returns false if it has no anchor or already
-- has page points.
function PencilStrokes.anchorToPage(stroke)
    if stroke.page_points then return false end
    local zoom = stroke._anchor_zoom
    if not zoom then return false end
    local ox, oy = stroke._anchor_ox, stroke._anchor_oy
    local page_points = {}
    for i, pt in ipairs(stroke.points) do
        page_points[i] = { x = (pt.x - ox) / zoom, y = (pt.y - oy) / zoom }
    end
    stroke.page_points = page_points
    stroke.page = stroke._anchor_page
    -- The screen points already match this view.
    stroke._vz, stroke._vox, stroke._voy = zoom, ox, oy
    stroke._anchor_page, stroke._anchor_zoom = nil, nil
    stroke._anchor_ox, stroke._anchor_oy = nil, nil
    return true
end

-- Bring a page-anchored stroke's screen points (stroke.points) in line with a
-- view: screen = page * zoom + offset. Cheap when the view hasn't changed.
-- zoom == nil means the stroke's page isn't shown. Returns false in that case.
function PencilStrokes.syncToView(stroke, zoom, ox, oy)
    local pp = stroke.page_points
    if not pp then return true end
    if not zoom then return false end
    if stroke._vz == zoom and stroke._vox == ox and stroke._voy == oy then
        return true
    end
    local points = stroke.points or {}
    for i, q in ipairs(pp) do
        local pt = points[i]
        if not pt then
            pt = {}
            points[i] = pt
        end
        pt.x = q.x * zoom + ox
        pt.y = q.y * zoom + oy
    end
    for i = #points, #pp + 1, -1 do points[i] = nil end
    stroke.points = points
    stroke._vz, stroke._vox, stroke._voy = zoom, ox, oy
    return true
end

-- Shift strokes by (dx, dy) screen pixels; sign = -1 reverses a move.
-- Page-anchored strokes move in page space by pdeltas[i] (computed from the
-- view zoom on the first move and reused for undo/redo). Returns pdeltas.
-- view.zoom(page): zoom of a page in the current view (nil if not shown)
-- view.sync(stroke): syncToView for the current view
function PencilStrokes.translate(strokes, dx, dy, pdeltas, sign, view)
    sign = sign or 1
    pdeltas = pdeltas or {}
    for i, stroke in ipairs(strokes) do
        local shifted = false
        if stroke.page_points then
            local d = pdeltas[i]
            if not d then
                local zoom = stroke._vz or view.zoom(stroke.page)
                d = { x = zoom and dx / zoom or 0, y = zoom and dy / zoom or 0 }
                pdeltas[i] = d
            end
            for _, q in ipairs(stroke.page_points) do
                q.x = q.x + sign * d.x
                q.y = q.y + sign * d.y
            end
            stroke._vz = nil
            shifted = view.sync(stroke)
        end
        if not shifted then
            for _, pt in ipairs(stroke.points) do
                pt.x = pt.x + sign * dx
                pt.y = pt.y + sign * dy
            end
        end
    end
    return pdeltas
end

--
-- The strokes file of a document
--

-- Path of the strokes file in the document's sidecar directory, nil if the
-- document settings (or their sidecar) are not available.
function PencilStrokes.getFilePath(doc_settings)
    if not doc_settings then
        logger.warn("Pencil: doc_settings not available")
        return nil
    end
    local sidecar_dir = doc_settings.doc_sidecar_dir
    if sidecar_dir then
        return sidecar_dir .. "/" .. PencilStrokes.FILE_NAME
    end
    logger.warn("Pencil: sidecar_dir not available")
    return nil
end

-- Store the plugin-owned strokes file path in the document metadata.
function PencilStrokes.rememberFilePath(doc_settings, filepath)
    if doc_settings and filepath then
        doc_settings:saveSetting(PencilStrokes.PATH_SETTING, filepath)
    end
end

-- Recover pencil_strokes.lua after KOReader moves metadata.lua to a new
-- sidecar following a document rename. Both paths are assumed to be on the
-- same filesystem, so os.rename provides an atomic move. Returns the path the
-- strokes file should be read from / written to (nil without a sidecar).
function PencilStrokes.migrateFileIfNeeded(doc_settings)
    local current = PencilStrokes.getFilePath(doc_settings)
    if not current or not doc_settings then return current end

    if lfs.attributes(current, "mode") == "file" then
        PencilStrokes.rememberFilePath(doc_settings, current)
        return current
    end

    local previous = doc_settings:readSetting(PencilStrokes.PATH_SETTING)
    if type(previous) ~= "string" or previous == "" or previous == current
            or lfs.attributes(previous, "mode") ~= "file" then
        return current
    end

    local old_sidecar = previous:match("^(.*)/[^/]+$")
    local moved, err = os.rename(previous, current)
    if not moved then
        logger.warn("Pencil: failed to move strokes file from", previous,
            "to", current, "error:", err)
        return current
    end

    PencilStrokes.rememberFilePath(doc_settings, current)
    logger.info("Pencil: moved strokes file from", previous, "to", current)

    -- rmdir only succeeds when the legacy sidecar is empty. If KOReader or
    -- another plugin left data there, it is preserved without extra handling.
    if old_sidecar then
        local removed = lfs.rmdir(old_sidecar)
        if removed then
            logger.info("Pencil: removed empty legacy sidecar", old_sidecar)
        end
    end

    return current
end

--
-- The store of a document's strokes
--

-- opts.log: optional function(message) for detailed diagnostics (the plugin's
-- input debug log); nil = no diagnostics.
-- opts.on_removed: optional function(indices) called after strokes were removed
-- from the list by removeStrokes (indices, sorted from last to first, are
-- those the strokes had); whatever keeps indices into the list (annotation
-- groups) renumbers itself there.
function PencilStrokes:new(opts)
    local o = setmetatable({}, self)
    o.log = opts and opts.log or nil
    o.on_removed = opts and opts.on_removed or nil
    o.strokes = {}
    o.page_strokes = {}  -- Index: page -> array of indices into `strokes`
    -- History: { type = "add", stroke = }, { type = "delete", strokes = {} } or
    -- { type = "move", strokes = {}, dx =, dy =, pdeltas = {} }
    o.undo_stack = {}
    o.redo_stack = {}
    o.loaded = false     -- Set true after successful load
    return o
end

function PencilStrokes:count()
    return #self.strokes
end

--
-- Page index
--

-- Index a stroke by page for quick lookup
function PencilStrokes:indexStroke(stroke_idx, page)
    if not self.page_strokes[page] then
        self.page_strokes[page] = {}
    end
    table.insert(self.page_strokes[page], stroke_idx)
end

function PencilStrokes:rebuildPageIndex()
    self.page_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        self:indexStroke(i, stroke.page)
    end
end

-- Iterate the strokes of a page: for stroke, idx in store:pageStrokes(page).
-- Allocates nothing per stroke, so it is fine in a paint loop.
function PencilStrokes:pageStrokes(page)
    local indices = self.page_strokes[page]
    local i = 0
    return function()
        if not indices then return nil end
        while true do
            i = i + 1
            local idx = indices[i]
            if idx == nil then return nil end
            local stroke = self.strokes[idx]
            if stroke then return stroke, idx end
        end
    end
end

-- Strokes of a page, as an array
function PencilStrokes:forPage(page)
    local result = {}
    for stroke in self:pageStrokes(page) do
        table.insert(result, stroke)
    end
    return result
end

function PencilStrokes:hasOnPage(page)
    local indices = self.page_strokes[page]
    return indices ~= nil and #indices > 0
end

--
-- Adding, removing, history
--

-- Append a stroke and index it. Returns its index.
function PencilStrokes:add(stroke)
    table.insert(self.strokes, stroke)
    local idx = #self.strokes
    self:indexStroke(idx, stroke.page)
    return idx
end

-- Index of a stroke in the list, trying the remembered index first.
function PencilStrokes:findIndex(stroke, hint)
    if hint and self.strokes[hint] == stroke then return hint end
    for i, s in ipairs(self.strokes) do
        if s == stroke then return i end
    end
end

-- Record an undoable action. "add" actions keep a reference to the stroke so
-- undo/redo still find it after other strokes were erased (indices shift).
-- Any new action invalidates the redo history.
function PencilStrokes:pushUndo(action)
    if action.type == "add" and not action.stroke and action.stroke_idx then
        action.stroke = self.strokes[action.stroke_idx]
    end
    table.insert(self.undo_stack, action)
    self.redo_stack = {}
end

function PencilStrokes:canUndo()
    return #self.undo_stack > 0
end

function PencilStrokes:canRedo()
    return #self.redo_stack > 0
end

function PencilStrokes:clearHistory()
    self.undo_stack = {}
    self.redo_stack = {}
end

-- Remove strokes by reference (not rebuilding the page index: the caller does,
-- once it is done). Returns the indices they had, sorted from last to first
-- (nil if none was in the list); on_removed is told about them.
function PencilStrokes:removeStrokes(strokes)
    local indices = {}
    for _, stroke in ipairs(strokes) do
        local idx = self:findIndex(stroke)
        if idx then table.insert(indices, idx) end
    end
    if #indices == 0 then return nil end
    table.sort(indices, function(a, b) return a > b end)
    for _, idx in ipairs(indices) do
        table.remove(self.strokes, idx)
    end
    if self.on_removed then self.on_removed(indices) end
    return indices
end

-- Undo (undoing = true) or redo an action. Returns the action to push on the
-- opposite stack, or nil if nothing could be applied.
-- translate(strokes, dx, dy, pdeltas, sign): how to move strokes ("move"
-- actions); it depends on the view, so the caller provides it.
function PencilStrokes:applyHistoryAction(action, undoing, translate)
    if action.type == "add" then
        local stroke = action.stroke or (action.stroke_idx and self.strokes[action.stroke_idx])
        if not stroke then return nil end
        if undoing then
            if not self:removeStrokes({ stroke }) then return nil end
        else
            table.insert(self.strokes, stroke)
        end
        return { type = "add", stroke = stroke }
    elseif action.type == "delete" then
        if undoing then
            for _, stroke in ipairs(action.strokes) do
                table.insert(self.strokes, stroke)
            end
        elseif not self:removeStrokes(action.strokes) then
            return nil
        end
        return { type = "delete", strokes = action.strokes }
    elseif action.type == "move" then
        translate(action.strokes, action.dx, action.dy, action.pdeltas, undoing and -1 or 1)
        return action
    end
end

-- Undo the last action. Returns true if there was one (even if it could not be
-- applied any more), false if the history was empty. The page index is NOT
-- rebuilt, nor anything that follows from the change (annotation groups,
-- saving, repaint): the caller does that.
function PencilStrokes:undo(translate)
    local action = table.remove(self.undo_stack)
    if not action then return false end
    local redo = self:applyHistoryAction(action, true, translate)
    if redo then table.insert(self.redo_stack, redo) end
    return true
end

function PencilStrokes:redo(translate)
    local action = table.remove(self.redo_stack)
    if not action then return false end
    local undo = self:applyHistoryAction(action, false, translate)
    if undo then table.insert(self.undo_stack, undo) end
    return true
end

-- Remove the strokes at these indices (any order) and rebuild the page index.
-- Returns them as an array.
local function removeIndices(self, indices)
    local sorted = {}
    for _, idx in ipairs(indices) do
        table.insert(sorted, idx)
    end
    -- Reverse order to maintain indices during removal
    table.sort(sorted, function(a, b) return a > b end)

    local removed = {}
    for _, idx in ipairs(sorted) do
        if self.strokes[idx] then
            table.insert(removed, self.strokes[idx])
            table.remove(self.strokes, idx)
        end
    end
    self:rebuildPageIndex()
    return removed
end

-- Remove every stroke of a page and make it undoable. Returns the removed
-- strokes (nil if the page had none).
function PencilStrokes:clearPage(page)
    local indices = self.page_strokes[page]
    if not indices or #indices == 0 then
        return nil
    end
    local removed = removeIndices(self, indices)
    if #removed > 0 then
        self:pushUndo({ type = "delete", strokes = removed })
    end
    return removed
end

function PencilStrokes:clearAll()
    self.strokes = {}
    self.page_strokes = {}
end

-- Erase the strokes that pass within `threshold` of (x, y). Only strokes
-- indexed under one of `pages` are looked at, and only those for which
-- erasable(stroke, page) is true (it knows about the view: a PDF stroke must be
-- projected on the screen first). The strokes are removed from the list and the
-- page index is rebuilt; annotation groups are not told (the caller does).
-- Returns the removed strokes (for undo) and the indices they had (sorted from
-- last to first), or nil if there was nothing to erase.
function PencilStrokes:eraseAtPoint(x, y, pages, threshold, erasable)
    local log = self.log
    if log then
        log(string.format("ERASE: searching %d strokes at (%d, %d)", #self.strokes, x, y))
    end

    if #self.strokes == 0 then
        if log then log("ERASE: no strokes exist") end
        return nil
    end

    local deleted = {}
    local indices_to_remove = {}

    -- Iterate only strokes on the given pages via the page index. Keeps the
    -- per-sample erase cost O(strokes-on-page) instead of O(total-strokes).
    for _, p in ipairs(pages) do
        local page_indices = self.page_strokes[p] or {}
        for _, i in ipairs(page_indices) do
            local stroke = self.strokes[i]
            if stroke and (not erasable or erasable(stroke, p)) then
                if log and stroke.points and #stroke.points > 0 then
                    local min_x, max_x = stroke.points[1].x, stroke.points[1].x
                    local min_y, max_y = stroke.points[1].y, stroke.points[1].y
                    for _, pt in ipairs(stroke.points) do
                        if pt.x < min_x then min_x = pt.x end
                        if pt.x > max_x then max_x = pt.x end
                        if pt.y < min_y then min_y = pt.y end
                        if pt.y > max_y then max_y = pt.y end
                    end
                    log(string.format("ERASE: stroke %d bounds: (%d-%d, %d-%d), eraser at (%d,%d) threshold=%d",
                        i, min_x, max_x, min_y, max_y, x, y, threshold))
                end
                if PencilGeometry.isPointNearStroke(x, y, stroke, threshold) then
                    table.insert(deleted, stroke)
                    table.insert(indices_to_remove, i)
                    if log then log(string.format("ERASE: found stroke %d to delete", i)) end
                end
            end
        end
    end

    if #indices_to_remove == 0 then
        return nil
    end
    -- Remove strokes (in reverse order to maintain indices)
    table.sort(indices_to_remove, function(a, b) return a > b end)
    for _, idx in ipairs(indices_to_remove) do
        table.remove(self.strokes, idx)
    end
    self:rebuildPageIndex()
    if log then log(string.format("ERASE: deleted %d strokes", #deleted)) end
    return deleted, indices_to_remove
end

-- Screen-space refresh rect (x, y, w, h) covering a set of just-deleted
-- strokes, expanded by `margin` and clamped to the screen. Returns nil when no
-- stroke has geometry, signalling the caller to refresh fully.
function PencilStrokes.erasedRefreshRect(strokes, margin, screen_w, screen_h)
    if type(strokes) ~= "table" or #strokes == 0 then return nil end
    local bbox = nil
    for _, s in ipairs(strokes) do
        local b = PencilGeometry.computeStrokeBbox(s)
        if b then
            bbox = bbox and PencilGeometry.bboxUnion(bbox, b) or b
        end
    end
    if not bbox then return nil end
    bbox = PencilGeometry.bboxExpand(bbox, margin or 20)
    bbox = PencilGeometry.bboxClampToScreen(bbox, screen_w, screen_h)
    local w = bbox.x1 - bbox.x0
    local h = bbox.y1 - bbox.y0
    if w <= 0 or h <= 0 then return nil end
    return bbox.x0, bbox.y0, w, h
end

--
-- Persistence
--

-- Load the strokes file into the store. ctx: see fromSaved.
-- Returns a status and, for "ok", the file's data (the caller owns whatever
-- else the file holds, e.g. annotation groups):
--   "ok", data   strokes loaded
--   "no_path"    no file path (nothing loaded, store emptied)
--   "missing"    the file doesn't exist yet (store emptied; counts as loaded)
--   "error", err the file could not be read (store emptied)
function PencilStrokes:load(filepath, ctx)
    if not filepath then
        logger.warn("Pencil: no filepath available for loading strokes")
        self:clearAll()
        return "no_path"
    end

    -- Check if file exists
    local file_exists = io.open(filepath, "r")
    if not file_exists then
        logger.info("Pencil: strokes file does not exist yet:", filepath)
        self:clearAll()
        self.loaded = true
        return "missing"
    end
    file_exists:close()

    local ok, data = pcall(dofile, filepath)
    if ok and data and data.strokes then
        -- Convert saved strokes back to usable format
        self.strokes = {}
        for i, saved in ipairs(data.strokes) do
            self.strokes[i] = PencilStrokes.fromSaved(saved, ctx)
        end
        self:rebuildPageIndex()
        self.loaded = true
        logger.info("Pencil: loaded", #self.strokes, "strokes from", filepath)
        return "ok", data
    end

    logger.warn("Pencil: failed to load strokes from", filepath, "error:", data)
    self:clearAll()
    return "error", data
end

-- Save the strokes to `filepath`. extra: other fields to store in the file
-- (e.g. annotation_groups). Returns true on success.
function PencilStrokes:save(filepath, extra)
    logger.info("Pencil: saveStrokes - filepath =", filepath, "strokes count =", #self.strokes)

    if not filepath then
        logger.warn("Pencil: no filepath available for saving strokes")
        return false
    end

    -- Safety: don't save empty data if strokes were never successfully loaded
    -- (prevents data loss if a crash causes save before load completes)
    if #self.strokes == 0 and not self.loaded then
        logger.warn("Pencil: refusing to save empty strokes (strokes never loaded)")
        return false
    end

    -- Convert strokes to saveable format (remove non-serializable values)
    local saveable_strokes = {}
    for i, stroke in ipairs(self.strokes) do
        saveable_strokes[i] = PencilStrokes.toSaveable(stroke)
    end

    local data = {
        version = PencilStrokes.FILE_VERSION,
        strokes = saveable_strokes,
    }
    for key, value in pairs(extra or {}) do
        data[key] = value
    end

    local f, err = io.open(filepath, "w")
    if not f then
        logger.err("Pencil: failed to open file for writing:", filepath, "error:", err)
        return false
    end
    f:write("return " .. require("dump")(data))
    f:close()
    logger.info("Pencil: saved", #self.strokes, "strokes to", filepath)
    return true
end

--
-- Drawing
--

function PencilStrokes.drawThickLine(bb, x1, y1, x2, y2, width, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local half_w = math.floor(width / 2)

    if dist < 1 then
        -- Just draw a single point
        bb:paintRectRGB32(x1 - half_w, y1 - half_w, width, width, color)
        return
    end

    -- Inclusive 0..steps loop emits both endpoints (t=0 and t=1).
    local steps = PencilGeometry.segmentStepCount(dist, width)
    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x1 + dx * t)
        local y = math.floor(y1 + dy * t)
        bb:paintRectRGB32(x - half_w, y - half_w, width, width, color)
    end
end

-- Highlighter strokes are translucent: they are blended into the page, never
-- painted over it, so the text underneath stays readable. Returns
-- blend(x, y, w, h) for the given color and alpha (0-255).
--   * normal screen: multiply by the color mixed with white at `alpha`, the way
--     KOReader draws its own colored highlights (text stays dark, and on white
--     paper the result is the color at `alpha`);
--   * inverted screen (software night mode): alpha-blend the inverted color,
--     as KOReader does, because multiply doesn't work on a dark background;
--   * KOReader without multiplyRectRGB: plain alpha-blend; without any blend
--     support: paint the color mixed with white, opaque.
function PencilStrokes.getHighlighterBlender(bb, color, alpha)
    alpha = alpha or 0xFF
    local c = (color or Blitbuffer.Color8(0xDD)):getColorRGB32()
    local r, g, b = c.r, c.g, c.b
    local k = alpha / 255
    local function mixWithWhite()
        return Blitbuffer.ColorRGB32(
            math.floor(255 - (255 - r) * k + 0.5),
            math.floor(255 - (255 - g) * k + 0.5),
            math.floor(255 - (255 - b) * k + 0.5), 0xFF)
    end

    if bb.getInverse and bb:getInverse() == 1 and bb.blendRectRGB32 then
        local over = Blitbuffer.ColorRGB32(r, g, b, alpha):invert()
        return function(x, y, w, h) bb:blendRectRGB32(x, y, w, h, over) end
    elseif bb.multiplyRectRGB then
        local mul = mixWithWhite()
        return function(x, y, w, h) bb:multiplyRectRGB(x, y, w, h, mul) end
    elseif bb.blendRectRGB32 then
        local over = Blitbuffer.ColorRGB32(r, g, b, alpha)
        return function(x, y, w, h) bb:blendRectRGB32(x, y, w, h, over) end
    end
    local opaque = mixWithWhite()
    return function(x, y, w, h) bb:paintRectRGB32(x, y, w, h, opaque) end
end

-- Blend a whole highlighter stroke into bb (shifted by dx, dy). Every pixel is
-- blended once, however much the brush stamps overlap. The covered rectangles
-- are cached on the stroke (they only depend on its points and width).
-- default_width: used for a stroke without a width.
function PencilStrokes.paintHighlighterStroke(bb, stroke, dx, dy, default_width)
    local points = stroke.points
    if not points or #points < 1 then return end
    local width = stroke.width or default_width or 20
    local cache = stroke.hl_cache
    if not cache or cache.n ~= #points or cache.width ~= width then
        cache = {
            n = #points,
            width = width,
            rects = PencilGeometry.strokeCoverageRects(points, width),
        }
        stroke.hl_cache = cache
    end
    local blend = PencilStrokes.getHighlighterBlender(bb, stroke.color, stroke.alpha)
    dx, dy = dx or 0, dy or 0
    for _, r in ipairs(cache.rects) do
        blend(r.x + dx, r.y + dy, r.w, r.h)
    end
end

-- Draw the next piece (x1,y1 -> x2,y2; x1,y1 == x2,y2 for the first point) of the
-- highlighter stroke being written straight into bb. Only the pixels not
-- blended yet are blended, so overlapping stamps don't darken. `live` is the
-- state returned by the previous call for this stroke (nil for the first);
-- keep the returned value and pass it back.
function PencilStrokes.drawLiveHighlighter(live, bb, stroke, x1, y1, x2, y2)
    if not live or live.stroke ~= stroke then
        live = {
            stroke = stroke,
            cov = PencilGeometry.newCoverage(),
            blend = PencilStrokes.getHighlighterBlender(bb, stroke.color, stroke.alpha),
        }
    end
    local width = stroke.width
    local stamps = PencilGeometry.segmentStamps(x1, y1, x2, y2, width)
    for i = 1, #stamps, 2 do
        local rects = PencilGeometry.coverageAddRect(live.cov, stamps[i], stamps[i + 1], width, width, true)
        for _, r in ipairs(rects) do
            live.blend(r.x, r.y, r.w, r.h)
        end
    end
    return live
end

-- Draw a complete stroke into bb, shifted by (dx, dy).
-- ctx.tool_settings(tool): defaults for strokes missing a width/color
-- ctx.night_mode: the screen is inverted, colors (but black and gray) are too
function PencilStrokes.render(bb, stroke, ctx, dx, dy)
    if not stroke or not stroke.points or #stroke.points < 1 then
        return
    end
    dx, dy = dx or 0, dy or 0
    local tool = stroke.tool or TOOLS.PEN
    local defaults = ctx and ctx.tool_settings and ctx.tool_settings(tool) or {}

    -- Highlighter: translucent, blended with its own color and alpha
    if tool == TOOLS.HIGHLIGHTER then
        PencilStrokes.paintHighlighterStroke(bb, stroke, dx, dy, defaults.width)
        return
    end

    local width = stroke.width or defaults.width or 3
    -- Get color directly (it's already a Blitbuffer color)
    local color = stroke.color or defaults.color or Blitbuffer.COLOR_BLACK

    -- Reinvert color in night mode (if it's not black or gray)
    if ctx and ctx.night_mode and stroke.color_name ~= "Black" and stroke.color_name ~= "Gray" then
        color = color:invert()
    end

    if #stroke.points == 1 then
        -- Single point (dot)
        local p = stroke.points[1]
        local half_w = math.floor(width / 2)
        bb:paintRectRGB32(p.x + dx - half_w, p.y + dy - half_w, width, width, color)
    else
        -- Multiple points - draw line segments
        for i = 2, #stroke.points do
            local p1 = stroke.points[i - 1]
            local p2 = stroke.points[i]
            PencilStrokes.drawThickLine(bb, p1.x + dx, p1.y + dy, p2.x + dx, p2.y + dy, width, color)
        end
    end
end

return PencilStrokes
