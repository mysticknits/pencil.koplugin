--[[--
Round-trip tests for the stroke save format, run against the real main.lua.
KOReader modules are replaced with permissive stubs so the plugin can be
loaded outside the reader.
Run with: busted spec/save_format_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"
-- Use the right package loader table for Lua 5.1+ compatibility
local loaders = package.loaders or package.searchers

-- A stub that accepts any field access or call and returns another stub.
local function make_stub()
    return setmetatable({}, {
        __index = function() return make_stub() end,
        __call = function() return make_stub() end,
    })
end

local stubs = {
    ["ui/widget/container/inputcontainer"] = {
        extend = function(_, o) return setmetatable(o or {}, { __index = make_stub() }) end,
    },
    ["gettext"] = function(s) return s end,
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
local PencilTool = require("lib/penciltool")
local PencilStrokes = require("lib/pencilstrokes")

-- Rebuild a stroke from its saved form the way the plugin does on load
local function load_saved(p, saved)
    return PencilStrokes.fromSaved(saved, {
        tool_settings = function(tool) return p.tool_settings[tool] or p.tool_settings.pen end,
        available_colors = p.available_colors,
    })
end

local function new_pencil()
    return setmetatable({
        tool_settings = { pen = { color = "black", width = 3, alpha = 1 } },
        available_colors = { { name = "Black", color = "black" } },
    }, { __index = Pencil })
end

describe("stroke save format (real main.lua)", function()
    local stroke = {
        page = 7, tool = "pen", width = 4, alpha = 1, datetime = 1700000000,
        color_name = "Black",
        points = { { x = 10, y = 20 }, { x = 11, y = 22 }, { x = 15, y = 30 } },
    }

    it("saves points as a packed v4 string", function()
        local saved = PencilStrokes.toSaveable(stroke)
        assert.are.equal("10 20 11 22 15 30", saved.p)
        assert.is_nil(saved.points)
    end)

    it("round-trips a stroke through save and load", function()
        local p = new_pencil()
        local loaded = load_saved(p, PencilStrokes.toSaveable(stroke))
        assert.are.same(stroke.points, loaded.points)
        assert.are.equal(7, loaded.page)
        assert.are.equal(4, loaded.width)
        assert.are.equal("black", loaded.color)
    end)

    it("still loads v3 strokes that store a points array", function()
        local loaded = load_saved(new_pencil(), {
            page = 2, tool = "pen", color_name = "Black",
            points = { { x = 1, y = 2 }, { x = 3, y = 4 } },
        })
        assert.are.same({ { x = 1, y = 2 }, { x = 3, y = 4 } }, loaded.points)
    end)

    it("loads a stroke with no points as an empty array", function()
        local loaded = load_saved(new_pencil(), { page = 1, tool = "pen" })
        assert.are.same({}, loaded.points)
    end)
end)
