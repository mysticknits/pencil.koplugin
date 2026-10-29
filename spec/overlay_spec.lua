-- Tests for isOverlayActive and showToast: which widgets on top of the reader
-- keep the pen from drawing. Like dogear_spec, this loads the real main.lua
-- with KOReader modules stubbed out.

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

local UIManager = { _window_stack = {}, shown = {} }
function UIManager:show(widget) table.insert(self.shown, widget) end

local function loadPencil()
    local stubbed = {
        "ffi/blitbuffer", "ui/widget/container/centercontainer", "datastorage",
        "device", "dispatcher", "ui/widget/container/framecontainer", "ui/geometry",
        "ui/gesturerange", "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
        "ui/widget/verticalgroup", "ui/widget/verticalspan", "ui/size",
        "ui/widget/container/widgetcontainer",
        "libs/libkoreader-lfs", "ui/time", "ffi/util",
    }
    for _, name in ipairs(stubbed) do
        package.loaded[name] = permissive()
    end
    package.loaded["ui/widget/container/inputcontainer"] = {
        extend = function(_, class) return class end,
    }
    package.loaded["ui/widget/infomessage"] = {
        new = function(_, args) return args end,
    }
    package.loaded["ui/uimanager"] = UIManager
    package.loaded["logger"] = {
        dbg = function() end, info = function() end,
        warn = function() end, err = function() end,
    }
    package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
    package.loaded["main"] = nil
    return dofile("pencil.koplugin/main.lua")
end

local Pencil = loadPencil()

local function stack(...)
    UIManager._window_stack = {}
    for _, widget in ipairs({ ... }) do
        table.insert(UIManager._window_stack, { widget = widget })
    end
end

local reader = { name = "ReaderUI" }

describe("isOverlayActive", function()
    it("is false with only the reader shown", function()
        stack(reader)
        assert.is_false(Pencil:isOverlayActive())
    end)

    it("is true with a menu or dialog on top", function()
        stack(reader, { name = "ConfigDialog" })
        assert.is_true(Pencil:isOverlayActive())
    end)

    it("ignores toasts on top of the reader", function()
        stack(reader, { toast = true })
        assert.is_false(Pencil:isOverlayActive())
    end)

    it("still sees a dialog under a toast", function()
        stack(reader, { name = "ConfigDialog" }, { toast = true })
        assert.is_true(Pencil:isOverlayActive())
    end)

    it("ignores invisible widgets", function()
        stack(reader, { invisible = true })
        assert.is_false(Pencil:isOverlayActive())
    end)
end)

describe("showToast", function()
    local notified

    before_each(function()
        notified = {}
        package.loaded["ui/widget/notification"] = {
            SOURCE_DISPATCHER = 0x0020,
            SOURCE_ALWAYS_SHOW = 0x8000,
            notify = function(_, text, source)
                table.insert(notified, { text = text, source = source })
            end,
        }
    end)

    it("always shows confirmations from the side button and picker", function()
        Pencil:showToast("Pen color: Green")
        assert.same({ { text = "Pen color: Green", source = 0x8000 } }, notified)
    end)

    it("lets gesture confirmations follow the reader's notification settings", function()
        Pencil:showToast("Eraser selected", true)
        assert.same({ { text = "Eraser selected", source = 0x0020 } }, notified)
    end)
end)
