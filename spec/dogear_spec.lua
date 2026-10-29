-- Tests for keeping KOReader's dogear (folded page corner) in sync when ink
-- is erased. Unlike most specs here, this loads the real main.lua with
-- KOReader modules stubbed out, so it exercises the shipped functions.

package.path = "pencil.koplugin/?.lua;" .. package.path

-- A stand-in that tolerates any field access or call made while main.lua
-- loads (widget classes, Blitbuffer colours, Device.screen, ...).
local function permissive()
    local stub = {}
    return setmetatable(stub, {
        __index = function() return permissive() end,
        __call = function() return permissive() end,
    })
end

local set_dirty_calls
local scheduled -- tasks passed to UIManager:scheduleIn, run by hand

local function loadPencil()
    local stubbed = {
        "ffi/blitbuffer", "ui/widget/container/centercontainer", "datastorage",
        "device", "dispatcher", "ui/widget/container/framecontainer", "ui/geometry",
        "ui/gesturerange", "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
        "ui/widget/verticalgroup", "ui/widget/verticalspan", "ui/size",
        "ui/widget/infomessage", "ui/widget/container/widgetcontainer",
        "libs/libkoreader-lfs", "ui/time", "ffi/util",
    }
    for _, name in ipairs(stubbed) do
        package.loaded[name] = permissive()
    end
    package.loaded["ui/widget/container/inputcontainer"] = {
        extend = function(_, class) return class end,
    }
    package.loaded["ui/uimanager"] = {
        setDirty = function(_, widget, refresh)
            table.insert(set_dirty_calls, { widget = widget, refresh = refresh })
        end,
        scheduleIn = function(_, _, action)
            table.insert(scheduled, action)
        end,
        unschedule = function() end,
    }
    package.loaded["logger"] = {
        dbg = function() end, info = function() end,
        warn = function() end, err = function() end,
    }
    package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
    package.loaded["main"] = nil
    return dofile("pencil.koplugin/main.lua")
end

local Pencil = loadPencil()

-- Minimal fake of ReaderBookmark + ReaderView: the corner shows when the
-- current page has a non-highlight bookmark, like KOReader's own lookup.
local function makePencil(annotations, current_page)
    local view = {
        dogear_visible = false,
        dialog = { name = "readerui" },
        dogear = { getRefreshRegion = function() return { x = 0, y = 0, w = 10, h = 10 } end },
    }
    local ui = { annotation = { annotations = annotations } }
    ui.bookmark = {
        getCurrentPageNumber = function() return current_page end,
        setDogearVisibility = function(_, page)
            local visible = false
            for _, item in ipairs(ui.annotation.annotations) do
                if not item.drawer and item.page == page then
                    visible = true
                end
            end
            view.dogear_visible = visible
        end,
    }
    local pencil = setmetatable({
        ui = ui,
        view = view,
        undo_stack = {},
        experimental_bookmark_sync = true,
        saves = 0,
    }, { __index = Pencil })
    function pencil:saveStrokes() self.saves = self.saves + 1 end
    return pencil
end

describe("dogear refresh", function()
    before_each(function()
        set_dirty_calls = {}
    end)

    it("lowers the corner once the page's pencil bookmark is gone", function()
        local pencil = makePencil({}, 5)
        pencil.view.dogear_visible = true -- stale: bookmark was removed directly

        pencil:refreshDogear()

        assert.is_false(pencil.view.dogear_visible)
        assert.equals(1, #set_dirty_calls)
        assert.equals(pencil.view.dialog, set_dirty_calls[1].widget)
        local mode, region = set_dirty_calls[1].refresh()
        assert.equals("ui", mode)
        assert.equals(10, region.w)
    end)

    it("keeps the corner when another bookmark is still on the page", function()
        local pencil = makePencil({ { page = 5, datetime = "user bookmark" } }, 5)
        pencil.view.dogear_visible = true

        pencil:refreshDogear()

        assert.is_true(pencil.view.dogear_visible)
        assert.equals(0, #set_dirty_calls) -- nothing changed, no repaint
    end)

    it("ignores highlights on the page", function()
        local pencil = makePencil({ { page = 5, drawer = "lighten" } }, 5)
        pencil.view.dogear_visible = true

        pencil:refreshDogear()

        assert.is_false(pencil.view.dogear_visible)
    end)

    it("does nothing without KOReader's bookmark module", function()
        local pencil = makePencil({}, 5)
        pencil.ui.bookmark = nil
        pencil.view.dogear_visible = true

        pencil:refreshDogear()

        assert.is_true(pencil.view.dogear_visible)
        assert.equals(0, #set_dirty_calls)
    end)
end)

describe("commitErase", function()
    before_each(function()
        set_dirty_calls = {}
    end)

    it("records undo, re-adds surviving bookmarks, lowers the corner, and saves", function()
        local pencil = makePencil({}, 5)
        pencil.view.dogear_visible = true
        local synced = {}
        function pencil:syncGroupBookmark(group) table.insert(synced, group.id) end
        pencil.dirty_groups = { pencil_b = { id = "pencil_b" } }
        local erased = { { page = 5 } }

        pencil:commitErase(erased)

        assert.equals(1, #pencil.undo_stack)
        assert.equals("delete", pencil.undo_stack[1].type)
        assert.equals(erased, pencil.undo_stack[1].strokes)
        assert.same({ "pencil_b" }, synced)
        assert.is_nil(pencil.dirty_groups)
        assert.is_false(pencil.view.dogear_visible)
        assert.equals(1, pencil.saves)
    end)

    it("does nothing when nothing was erased", function()
        local pencil = makePencil({}, 5)
        pencil.view.dogear_visible = true

        pencil:commitErase({})
        pencil:commitErase(nil)

        assert.equals(0, #pencil.undo_stack)
        assert.equals(0, pencil.saves)
        assert.is_true(pencil.view.dogear_visible)
    end)
end)

describe("deferred save", function()
    before_each(function()
        set_dirty_calls = {}
        scheduled = {}
    end)

    it("folds the corner when it adds new ink's bookmark", function()
        local pencil = makePencil({}, 5)
        pencil.save_delay_ms = 1500
        function pencil:syncGroupBookmark()
            table.insert(self.ui.annotation.annotations, { page = 5, datetime = "pencil_a" })
        end
        pencil.dirty_groups = { pencil_a = { id = "pencil_a" } }

        pencil:scheduleDeferredWork()
        assert.equals(1, #scheduled)
        assert.is_false(pencil.view.dogear_visible) -- not until the save runs

        scheduled[1]()

        assert.is_true(pencil.view.dogear_visible)
        assert.equals(1, #set_dirty_calls)
        assert.equals(1, pencil.saves)
    end)
end)
