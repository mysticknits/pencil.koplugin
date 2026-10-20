--[[--
Integration tests for the stylus side button, run against the real main.lua.
KOReader modules are replaced with permissive stubs so the plugin can be
loaded outside the reader; only UIManager:show is recorded.
Run with: busted spec/side_button_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"
-- Use the right package loader table for Lua 5.1+ compatibility
local loaders = package.loaders or package.searchers

-- A stub that accepts any field access or call and returns another stub.
local function make_stub()
    local stub = {}
    return setmetatable(stub, {
        __index = function() return make_stub() end,
        __call = function() return make_stub() end,
    })
end

local shown = {}

local stubs = {
    ["ui/widget/container/inputcontainer"] = {
        -- No stub fallback: unset fields must read as nil, as in KOReader.
        extend = function(_, o) return o or {} end,
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

local TOOL_TYPE_PEN = 1
local TOOL_TYPE_HIGHLIGHTER = 3

local function new_pencil(opts)
    local p = setmetatable({
        tool = make_tool(PencilTool, { text_highlight = opts.text_highlight }),
        input_debug_mode = false,
    }, { __index = Pencil })
    p:initStrokeStore()
    p.isEnabled = function() return true end
    p.isOverlayActive = function() return false end
    p.saveSettings = function() end
    p.getCurrentPage = function() return 1 end
    p.startTextHighlight = function(self) self.tool.highlighting = true; return true end
    p.extendTextHighlight = function() end
    p.finishTextHighlight = function(self) self.tool.highlighting = false end
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
        assert.are.equal("pen", p.tool.current_tool)
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
        assert.are.equal("pen", p.tool.current_tool)
        assert.is_false(p.tool.highlighting)
    end)

    it("quick press without drawing does not switch the tool (the eraser role's click does)", function()
        local p = new_pencil({ text_highlight = true })
        p:onStylusButtonPress()
        p:onStylusButtonRelease()
        assert.are.equal("pen", p.tool.current_tool)
        assert.are.equal(0, #shown)
        assert.is_false(p.side_button_down)
    end)
end)
