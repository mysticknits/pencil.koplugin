--[[--
Integration tests for the stylus side button, run against the real main.lua.
KOReader modules are replaced with permissive stubs so the plugin can be
loaded outside the reader; only UIManager:show is recorded.
Run with: busted spec/side_button_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

-- A stub that accepts any field access or call and returns another stub.
local function make_stub()
    local stub = {}
    return setmetatable(stub, {
        __index = function() return make_stub() end,
        __call = function() return make_stub() end,
    })
end

local shown = {}

-- Tool confirmations are KOReader notifications, loaded when first shown.
package.loaded["ui/widget/notification"] = {
    SOURCE_DISPATCHER = 0x0020,
    SOURCE_ALWAYS_SHOW = 0x8000,
    notify = function(_, text) table.insert(shown, { text = text }) end,
}

local stubs = {
    ["ui/widget/container/inputcontainer"] = {
        extend = function(_, o) return setmetatable(o or {}, { __index = make_stub() }) end,
    },
    ["ui/uimanager"] = setmetatable({
        show = function(_, widget) table.insert(shown, widget) end,
    }, { __index = function() return function() end end }),
    ["ui/widget/infomessage"] = {
        new = function(_, o) return o end,
    },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = {
        template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
    },
    ["logger"] = setmetatable({}, { __index = function() return function() end end }),
    ["ui/geometry"] = {
        new = function(_, o) return o end,
    },
}

-- package.loaders in Lua 5.1 (CI), package.searchers in newer Lua.
local loaders = package.loaders or package.searchers

local function load_pencil()
    table.insert(loaders, 2, function(name)
        if name == "lib/geometry" then return nil end
        return function() return stubs[name] or make_stub() end
    end)
    local Pencil = dofile("pencil.koplugin/main.lua")
    table.remove(loaders, 2)
    return Pencil
end

local Pencil = load_pencil()

local TOOL_TYPE_PEN = 1
local TOOL_TYPE_HIGHLIGHTER = 3

local function new_pencil(opts)
    local p = setmetatable({
        current_tool = "pen",
        experimental_text_highlight = opts.text_highlight,
        swap_eraser_and_highlighter = false,
        input_debug_mode = false,
        eraser_button_active = false,
        highlighting = false,
        undo_stack = {},
    }, { __index = Pencil })
    p.isEnabled = function() return true end
    p.isOverlayActive = function() return false end
    p.saveSettings = function() end
    p.startTextHighlight = function(self) self.highlighting = true end
    p.extendTextHighlight = function() end
    p.finishTextHighlight = function(self) self.highlighting = false end
    return p
end

-- Side button held while the pen drags across text, then released.
local function side_button_highlight(p)
    p:onStylusButtonPress()
    p:handleStylusSlot(nil, { id = 1, x = 10, y = 10, tool = TOOL_TYPE_HIGHLIGHTER })
    p:handleStylusSlot(nil, { id = 1, x = 50, y = 10, tool = TOOL_TYPE_HIGHLIGHTER })
    p:handleStylusSlot(nil, { id = -1, tool = TOOL_TYPE_HIGHLIGHTER })
    p:onStylusButtonRelease()
end

describe("stylus side button (real main.lua)", function()
    before_each(function()
        for i = #shown, 1, -1 do shown[i] = nil end
    end)

    it("text highlight does not switch the tool to eraser", function()
        local p = new_pencil({ text_highlight = true })
        side_button_highlight(p)
        assert.are.equal("pen", p.current_tool)
    end)

    it("text highlight does not show a tool toast", function()
        local p = new_pencil({ text_highlight = true })
        side_button_highlight(p)
        assert.are.equal(0, #shown)
    end)

    it("releasing the button mid-drag does not toggle the tool", function()
        local p = new_pencil({ text_highlight = true })
        p:onStylusButtonPress()
        p:handleStylusSlot(nil, { id = 1, x = 10, y = 10, tool = TOOL_TYPE_HIGHLIGHTER })
        p:onStylusButtonRelease()
        p:handleStylusSlot(nil, { id = 1, x = 50, y = 10, tool = TOOL_TYPE_PEN })
        p:handleStylusSlot(nil, { id = -1, tool = TOOL_TYPE_PEN })
        assert.are.equal("pen", p.current_tool)
        assert.is_false(p.highlighting)
    end)

    it("quick press without drawing still toggles pen and eraser", function()
        local p = new_pencil({ text_highlight = true })
        p:onStylusButtonPress()
        p:onStylusButtonRelease()
        assert.are.equal("eraser", p.current_tool)
        assert.are.equal(1, #shown)
        p:onStylusButtonPress()
        p:onStylusButtonRelease()
        assert.are.equal("pen", p.current_tool)
    end)
end)

-- A reader whose ReaderHighlight records what the side-button path asks of it.
local function new_reader(opts)
    local calls = {}
    local rh = {
        onHoldPan = function(self, _, ges)
            table.insert(calls, { "onHoldPan", ges.pos.x, ges.pos.y })
            self.selected_text = { text = "two pages", pos0 = "start", pos1 = "next page" }
            return opts.hold_pan_result
        end,
        saveHighlight = function() table.insert(calls, { "saveHighlight" }) end,
        _resetHoldTimer = function() end,
        clear = function() table.insert(calls, { "clear" }) end,
    }
    local ui = {
        highlight = rh,
        view = {
            highlight = { temp = {} },
            screenToPageTransform = function(_, pos) return { x = pos.x, y = pos.y, page = 6 } end,
        },
        document = {
            getWordFromPosition = function()
                return { word = "open", pos0 = "start", pos1 = "start+4", sbox = {} }
            end,
            getTextFromPositions = function()
                table.insert(calls, { "getTextFromPositions" })
                return { text = "this page", pos0 = "start", pos1 = "end" }
            end,
        },
    }
    return ui, rh, calls
end

local function new_highlighting_pencil(ui)
    local p = setmetatable({ ui = ui, highlighting = false }, { __index = Pencil })
    p.transformCoordinates = function(_, x, y) return x, y end
    return p
end

describe("side button highlight across pages (real main.lua)", function()
    it("starts with the state KOReader's corner scroll needs", function()
        local ui, rh = new_reader({})
        rh.allow_hold_pan_corner_scroll = true
        rh.was_in_some_corner = true
        new_highlighting_pencil(ui):startTextHighlight(10, 20)
        assert.are.equal("start", rh.selected_text_start_xpointer)
        assert.is_false(rh.allow_hold_pan_corner_scroll)
        assert.is_nil(rh.was_in_some_corner)
    end)

    it("extends the selection through ReaderHighlight:onHoldPan", function()
        local ui, rh, calls = new_reader({})
        local p = new_highlighting_pencil(ui)
        p:startTextHighlight(10, 20)
        p:extendTextHighlight(1200, 1600)
        assert.are.same({ { "onHoldPan", 1200, 1600 } }, calls)
        assert.are.equal("two pages", rh.selected_text.text)
    end)

    it("still highlights within the page when long-press is set to do nothing", function()
        local ui, rh, calls = new_reader({ hold_pan_result = false })
        local p = new_highlighting_pencil(ui)
        p:startTextHighlight(10, 20)
        p:extendTextHighlight(300, 40)
        assert.are.equal("getTextFromPositions", calls[2][1])
        assert.are.equal("this page", rh.selected_text.text)
    end)

    it("saves before clearing, which returns to page mode", function()
        local ui, _, calls = new_reader({})
        local p = new_highlighting_pencil(ui)
        p:startTextHighlight(10, 20)
        p:extendTextHighlight(1200, 1600)
        p:finishTextHighlight()
        assert.are.equal("saveHighlight", calls[2][1])
        assert.are.equal("clear", calls[3][1])
        assert.is_false(p.highlighting)
    end)
end)
