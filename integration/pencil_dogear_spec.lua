-- Integration test: runs inside KOReader's own test harness against a real
-- ReaderUI and EPUB, not the stubbed specs in spec/. See integration/README.md.
--
-- Draws and erases ink through the plugin's gesture handlers (the path the
-- emulator's mouse uses) and checks KOReader's dogear (folded page corner).

describe("Pencil dogear", function()
    local DocSettings, DocumentRegistry, ReaderUI, UIManager, Screen, Geom
    local sample_epub = "spec/front/unit/data/juliet.epub"
    local readerui, pencil

    setup(function()
        require("commonrequire")
        disable_plugins()
        G_reader_settings:saveSetting("pencil_annotation_enabled", true)
        G_reader_settings:saveSetting("pencil_annotation_settings", {
            experimental_bookmark_sync = true,
        })
        load_plugin("pencil.koplugin")
        DocSettings = require("docsettings")
        DocumentRegistry = require("document/documentregistry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        Screen = require("device").screen
        Geom = require("ui/geometry")
    end)

    before_each(function()
        local doc_settings = DocSettings:open(sample_epub)
        -- purge() leaves files it doesn't know about, like the plugin's own.
        os.remove(doc_settings.doc_sidecar_dir .. "/pencil_strokes.lua")
        doc_settings:purge()
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_epub),
        }
        readerui.status.enabled = false
        UIManager:show(readerui)
        pencil = readerui.pencil
        assert.truthy(pencil, "pencil plugin not loaded")
        assert.equals(0, #pencil.strokes)
        readerui.rolling:onGotoPage(10)
    end)

    after_each(function()
        readerui:closeDocument()
        readerui:onClose()
    end)

    local function gesture(x, y, start_x, start_y)
        return {
            pos = Geom:new{ x = x, y = y, w = 0, h = 0 },
            start_pos = start_x and Geom:new{ x = start_x, y = start_y, w = 0, h = 0 } or nil,
        }
    end

    -- Draw a horizontal line at height y, like a mouse drag in the emulator.
    -- Unless skip_flush is set, also run the plugin's delayed save, which is
    -- what actually adds the new ink's bookmark.
    local function drawLine(y, skip_flush)
        pencil.current_tool = "pen"
        assert.is_true(pencil:onDrawTouch(gesture(100, y)))
        for x = 110, 200, 10 do
            pencil:onDrawPan(gesture(x, y, 100, y))
        end
        pencil:onDrawPanRelease(gesture(200, y))
        if not skip_flush then
            pencil:flushDirtyGroups()
        end
    end

    -- Erase across the line at height y, then lift the eraser.
    local function eraseLine(y)
        pencil.current_tool = "eraser"
        pencil:onDrawTouch(gesture(150, y))
        pencil:onDrawPan(gesture(150, y, 150, y))
        pencil:onDrawPanRelease(gesture(150, y))
        pencil.current_tool = "pen"
    end

    local function pencilBookmarkCount()
        local n = 0
        for _, item in ipairs(readerui.annotation.annotations) do
            if item.datetime and item.datetime:match("^pencil_") then
                n = n + 1
            end
        end
        return n
    end

    -- What a page turn would do: recheck the corner for the current page.
    local function recheckCorner()
        readerui.bookmark:setDogearVisibility(readerui.bookmark:getCurrentPageNumber())
    end

    it("lifts the corner when all ink on the page is erased", function()
        drawLine(300)
        assert.equals(1, pencilBookmarkCount())
        recheckCorner()
        assert.is_true(readerui.view.dogear_visible)

        eraseLine(300)

        assert.equals(0, #pencil.strokes)
        assert.equals(0, pencilBookmarkCount())
        assert.is_false(readerui.view.dogear_visible)
    end)

    it("keeps the corner and the bookmark for ink that survives", function()
        drawLine(300)
        -- A second group: same page, but far enough away to group separately.
        drawLine(700)
        assert.equals(2, #pencil.annotation_groups)
        assert.equals(2, pencilBookmarkCount())
        recheckCorner()
        assert.is_true(readerui.view.dogear_visible)

        eraseLine(300)

        assert.equals(1, #pencil.strokes)
        assert.equals(1, pencilBookmarkCount())
        assert.is_true(readerui.view.dogear_visible)
    end)

    it("leaves no bookmark when ink is erased before its bookmark was added", function()
        drawLine(300, true) -- erase within the save delay, as a quick user would
        assert.equals(0, pencilBookmarkCount())

        eraseLine(300)
        -- The delayed save runs later; it must not add a bookmark for gone ink.
        pencil:flushDirtyGroups()

        assert.equals(0, #pencil.strokes)
        assert.equals(0, pencilBookmarkCount())
        recheckCorner()
        assert.is_false(readerui.view.dogear_visible)
    end)

    it("restores the corner when the erase is undone", function()
        drawLine(300)
        eraseLine(300)
        assert.is_false(readerui.view.dogear_visible)

        pencil:undoLastStroke()

        assert.equals(1, #pencil.strokes)
        assert.equals(1, pencilBookmarkCount())
        assert.is_true(readerui.view.dogear_visible)
    end)
end)
