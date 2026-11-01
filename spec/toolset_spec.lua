--[[--
Unit tests for lib/toolset.lua: preset validation, storage, the previous-tool
swap, sizing and box placement. Pure Lua, no KOReader stubs.

Run with: busted spec/toolset_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local Toolset = require("lib/toolset")

local COLORS = { Black = true, Red = true, Blue = true, Yellow = true, Highlight = true }

local function preset(tool, color, width)
    return { tool = tool, color_name = color, width = width }
end

describe("Toolset.defaults", function()
    it("are all valid presets and fill the row", function()
        local d = Toolset.defaults()
        assert.equals(Toolset.PRESET_CAP, #d)
        for _, p in ipairs(d) do
            assert.is_true(Toolset.isValid(p, COLORS), p.tool .. "/" .. p.color_name)
        end
    end)

    it("returns a fresh list each time", function()
        local a, b = Toolset.defaults(), Toolset.defaults()
        a[1].width = 99
        assert.equals(3, b[1].width)
    end)
end)

describe("Toolset.isValidWidth", function()
    it("accepts whole pixels within bounds", function()
        assert.is_true(Toolset.isValidWidth(1))
        assert.is_true(Toolset.isValidWidth(20))
        assert.is_true(Toolset.isValidWidth(Toolset.MAX_WIDTH))
    end)

    it("rejects zero, negatives, fractions, huge values and non-numbers", function()
        for _, bad in ipairs({ 0, -3, 2.5, Toolset.MAX_WIDTH + 1, 1e9, "7", true }) do
            assert.is_false(Toolset.isValidWidth(bad), tostring(bad))
        end
        assert.is_false(Toolset.isValidWidth(nil))
        assert.is_false(Toolset.isValidWidth(0 / 0))
    end)
end)

describe("Toolset.isValid", function()
    it("rejects the eraser and unknown tools as presets", function()
        assert.is_false(Toolset.isValid(preset("eraser", "Black", 10), COLORS))
        assert.is_false(Toolset.isValid(preset("laser", "Black", 3), COLORS))
    end)

    it("rejects a color that is not in the palette", function()
        assert.is_false(Toolset.isValid(preset("pen", "Chartreuse", 3), COLORS))
    end)

    it("rejects non-tables and missing fields", function()
        assert.is_false(Toolset.isValid(nil, COLORS))
        assert.is_false(Toolset.isValid("pen", COLORS))
        assert.is_false(Toolset.isValid({ tool = "pen", width = 3 }, COLORS))
        assert.is_false(Toolset.isValid({ tool = "pen", color_name = "Black" }, COLORS))
    end)

    it("skips the palette check when none is given", function()
        assert.is_true(Toolset.isValid(preset("pen", "Anything", 3)))
    end)
end)

describe("Toolset.normalize", function()
    it("falls back to the defaults for nil, junk and an empty list", function()
        for _, saved in ipairs({ {}, "nope", 42 }) do
            local out = Toolset.normalize(saved, COLORS)
            assert.equals(Toolset.PRESET_CAP, #out)
        end
        assert.equals(Toolset.PRESET_CAP, #Toolset.normalize(nil, COLORS))
    end)

    it("keeps valid presets in order and drops invalid ones", function()
        local out = Toolset.normalize({
            preset("pen", "Red", 5),
            preset("pen", "Chartreuse", 5),   -- unknown color
            preset("pen", "Blue", 500),       -- absurd width
            preset("highlighter", "Yellow", 20),
        }, COLORS)
        assert.equals(2, #out)
        assert.equals("Red", out[1].color_name)
        assert.equals("Yellow", out[2].color_name)
    end)

    it("falls back to defaults when everything saved is invalid", function()
        local out = Toolset.normalize({ preset("pen", "Chartreuse", 5) }, COLORS)
        assert.equals(Toolset.PRESET_CAP, #out)
    end)

    it("caps the list at the row size", function()
        local many = {}
        for i = 1, 20 do many[i] = preset("pen", "Black", i) end
        assert.equals(Toolset.PRESET_CAP, #Toolset.normalize(many, COLORS))
    end)

    it("returns copies, so editing the result leaves the saved table alone", function()
        local saved = { preset("pen", "Red", 5) }
        local out = Toolset.normalize(saved, COLORS)
        out[1].width = 9
        assert.equals(5, saved[1].width)
    end)

    it("rounds a fractional width to whole pixels", function()
        local out = Toolset.normalize({ preset("pen", "Red", 4.6) }, COLORS)
        assert.equals(5, out[1].width)
    end)
end)

describe("Toolset.same / find", function()
    it("compares tool, color and width", function()
        assert.is_true(Toolset.same(preset("pen", "Red", 3), preset("pen", "Red", 3)))
        assert.is_false(Toolset.same(preset("pen", "Red", 3), preset("pen", "Red", 5)))
        assert.is_false(Toolset.same(preset("pen", "Red", 3), preset("highlighter", "Red", 3)))
        assert.is_false(Toolset.same(preset("pen", "Red", 3), nil))
    end)

    it("finds the slot of an equal preset", function()
        local list = { preset("pen", "Black", 3), preset("pen", "Red", 3) }
        assert.equals(2, Toolset.find(list, preset("pen", "Red", 3)))
        assert.is_nil(Toolset.find(list, preset("pen", "Blue", 3)))
    end)
end)

describe("Toolset.store", function()
    local function three()
        return { preset("pen", "Black", 3), preset("pen", "Red", 3), preset("pen", "Blue", 3) }
    end

    it("replaces a slot", function()
        local list = three()
        assert.equals(2, Toolset.store(list, 2, preset("highlighter", "Yellow", 20), COLORS))
        assert.equals("highlighter", list[2].tool)
        assert.equals(3, #list)
    end)

    it("appends in the slot just past the end", function()
        local list = three()
        assert.equals(4, Toolset.store(list, 4, preset("pen", "Black", 7), COLORS))
        assert.equals(4, #list)
    end)

    it("refuses a gap, slot 0 and a slot past the cap", function()
        local list = three()
        assert.is_nil(Toolset.store(list, 6, preset("pen", "Black", 7), COLORS))
        assert.is_nil(Toolset.store(list, 0, preset("pen", "Black", 7), COLORS))
        local full = {}
        for i = 1, Toolset.PRESET_CAP do full[i] = preset("pen", "Black", i) end
        assert.is_nil(Toolset.store(full, Toolset.PRESET_CAP + 1, preset("pen", "Red", 3), COLORS))
        assert.equals(Toolset.PRESET_CAP, #full)
    end)

    it("refuses an invalid preset and leaves the list alone", function()
        local list = three()
        assert.is_nil(Toolset.store(list, 1, preset("pen", "Chartreuse", 3), COLORS))
        assert.equals("Black", list[1].color_name)
    end)

    it("never leaves two identical presets: the duplicate is removed", function()
        local list = three()   -- Black, Red, Blue
        -- Blue already exists in slot 3; storing it into slot 1 replaces Black
        -- and drops the old Blue, so the row has one Blue and one slot fewer
        local idx = Toolset.store(list, 1, preset("pen", "Blue", 3), COLORS)
        assert.equals(1, idx)
        assert.equals(2, #list)
        assert.equals("Blue", list[1].color_name)
        assert.equals("Red", list[2].color_name)
    end)

    it("reports the shifted slot when the duplicate sat before the target", function()
        local list = three()   -- Black, Red, Blue
        -- Black (slot 1) is stored into slot 3: Black leaves slot 1, Red and Blue
        -- move up, and the stored preset replaces what was Blue, now in slot 2
        local idx = Toolset.store(list, 3, preset("pen", "Black", 3), COLORS)
        assert.equals(2, idx)
        assert.equals(2, #list)
        assert.equals("Red", list[1].color_name)
        assert.equals("Black", list[2].color_name)
    end)

    it("storing a preset into its own slot changes nothing", function()
        local list = three()
        assert.equals(2, Toolset.store(list, 2, preset("pen", "Red", 3), COLORS))
        assert.equals(3, #list)
        assert.equals("Red", list[2].color_name)
    end)

    it("stores a copy", function()
        local list = three()
        local p = preset("pen", "Black", 9)
        Toolset.store(list, 1, p, COLORS)
        p.width = 1
        assert.equals(9, list[1].width)
    end)
end)

describe("previous tool bookkeeping", function()
    local pen = { tool = "pen", color_name = "Black", width = 3 }
    local marker = { tool = "highlighter", color_name = "Yellow", width = 20 }

    it("swap flips current and previous", function()
        local cur, prev = Toolset.swap(pen, marker)
        assert.equals(marker, cur)
        assert.equals(pen, prev)
    end)

    it("swap with no previous tool changes nothing", function()
        local cur, prev = Toolset.swap(pen, nil)
        assert.equals(pen, cur)
        assert.is_nil(prev)
    end)

    it("swapping twice returns to the start", function()
        local c1, p1 = Toolset.swap(pen, marker)
        local c2, p2 = Toolset.swap(c1, p1)
        assert.equals(pen, c2)
        assert.equals(marker, p2)
    end)

    it("remember records the tool being left", function()
        local prev = Toolset.remember(pen, marker, nil)
        assert.is_true(Toolset.same(pen, prev))
    end)

    it("remember keeps the old previous when nothing really changed", function()
        local old = { tool = "eraser", width = 20 }
        assert.equals(old, Toolset.remember(pen, { tool = "pen", color_name = "Black", width = 3 }, old))
    end)

    it("remember stores a copy, not the live state", function()
        local live = { tool = "pen", color_name = "Black", width = 3 }
        local prev = Toolset.remember(live, marker, nil)
        live.width = 99
        assert.equals(3, prev.width)
    end)
end)

describe("Toolset.fitItemSize", function()
    it("keeps the base size when everything fits", function()
        assert.equals(36, Toolset.fitItemSize(10, 1000, 36, 8, 20))
    end)

    it("shrinks to fit a narrow box", function()
        local size = Toolset.fitItemSize(10, 300, 36, 8, 20)
        assert.is_true(size < 36)
        assert.is_true(10 * size + 9 * 8 <= 300)
    end)

    it("never goes below the minimum", function()
        assert.equals(20, Toolset.fitItemSize(10, 50, 36, 8, 20))
    end)

    it("handles an empty row", function()
        assert.equals(36, Toolset.fitItemSize(0, 300, 36, 8, 20))
    end)
end)

describe("Toolset.sampleBarHeight", function()
    it("is the stroke's real width when it fits", function()
        assert.equals(5, Toolset.sampleBarHeight(5, 30))
    end)

    it("is capped to the swatch interior", function()
        assert.equals(30, Toolset.sampleBarHeight(40, 30))
    end)

    it("is at least one pixel", function()
        assert.equals(1, Toolset.sampleBarHeight(0, 30))
    end)
end)

describe("Toolset.place", function()
    local SW, SH = 1264, 1680
    local BW, BH = 420, 230

    local function onScreen(x, y)
        return x >= 0 and y >= 0 and x + BW <= SW and y + BH <= SH
    end

    it("goes above the pen, centred on it", function()
        local x, y = Toolset.place(SW, SH, BW, BH, 600, 900)
        assert.equals(600 - BW / 2, x)
        assert.is_true(y + BH < 900)
        assert.is_true(onScreen(x, y))
    end)

    it("goes below the pen when there is no room above", function()
        local x, y = Toolset.place(SW, SH, BW, BH, 600, 100)
        assert.is_true(y > 100)
        assert.is_true(onScreen(x, y))
    end)

    it("stays on screen at every edge and corner", function()
        for _, ax in ipairs({ 0, 5, SW / 2, SW - 5, SW }) do
            for _, ay in ipairs({ 0, 5, SH / 2, SH - 5, SH }) do
                local x, y = Toolset.place(SW, SH, BW, BH, ax, ay)
                assert.is_true(onScreen(x, y), ax .. "," .. ay .. " -> " .. x .. "," .. y)
            end
        end
    end)

    it("puts the box at the bottom centre without an anchor", function()
        local x, y = Toolset.place(SW, SH, BW, BH, nil, nil)
        assert.equals(math.floor((SW - BW) / 2), x)
        assert.is_true(y > SH / 2)
        assert.is_true(onScreen(x, y))
    end)

    it("copes with a box wider than a tiny screen", function()
        local x = Toolset.place(300, 400, 420, 230, 150, 200)
        assert.is_true(x >= 0)
    end)
end)
