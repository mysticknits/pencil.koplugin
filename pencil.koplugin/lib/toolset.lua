--[[--
Tool set logic for the Pencil quick tool box.

Pure functions, no KOReader dependencies, so they are unit-tested with busted
(see spec/toolset_spec.lua). Nothing here runs while the pen is drawing: it is
only used when the tool box opens, when a tool is picked, and when settings
are loaded or saved.

A "preset" is a small table: { tool = "pen"|"highlighter", color_name = string,
width = integer }. The eraser is not a preset; it is a tool with its own size.

@module pencil.lib.toolset
--]]--

local Toolset = {}

-- How many saved presets the tool box shows (one row).
Toolset.PRESET_CAP = 6

-- Tools a preset may use.
Toolset.PRESET_TOOLS = { pen = true, highlighter = true }

-- Sane bounds for a width read back from the settings file.
Toolset.MIN_WIDTH = 1
Toolset.MAX_WIDTH = 60

-- Width choices per tool (device pixels, drawn as-is: see Pencil:drawThickLine).
-- Pen widths stay in step with Pencil's `available_widths`.
Toolset.PEN_WIDTHS = { 3, 5, 7, 9 }
Toolset.HIGHLIGHTER_WIDTHS = { 12, 20, 30, 40 }
Toolset.ERASER_WIDTHS = { 10, 20, 40 }

-- The presets a fresh install starts with.
function Toolset.defaults()
    return {
        { tool = "pen",         color_name = "Black",     width = 3  },
        { tool = "pen",         color_name = "Black",     width = 7  },
        { tool = "pen",         color_name = "Red",       width = 3  },
        { tool = "pen",         color_name = "Blue",      width = 3  },
        { tool = "highlighter", color_name = "Highlight", width = 20 },
        { tool = "highlighter", color_name = "Yellow",    width = 20 },
    }
end

local function copy(p)
    return { tool = p.tool, color_name = p.color_name, width = p.width }
end
Toolset.copy = copy

-- Is `w` a width we are willing to draw with? Whole pixels within bounds, so a
-- hand-edited settings file can't inject an absurd or fractional width.
function Toolset.isValidWidth(w)
    return type(w) == "number" and w == math.floor(w)
        and w >= Toolset.MIN_WIDTH and w <= Toolset.MAX_WIDTH
end

-- Is `p` a usable preset? `valid_colors` is a set: color_name -> true.
function Toolset.isValid(p, valid_colors)
    if type(p) ~= "table" then return false end
    if not Toolset.PRESET_TOOLS[p.tool] then return false end
    if type(p.color_name) ~= "string" then return false end
    if valid_colors and not valid_colors[p.color_name] then return false end
    if type(p.width) ~= "number" or p.width ~= p.width then return false end
    if p.width < Toolset.MIN_WIDTH or p.width > Toolset.MAX_WIDTH then return false end
    return true
end

-- Clean a preset list read from the settings file: drop anything malformed (a
-- color that no longer exists, a hand-edited width), cap the length, and fall
-- back to the defaults when nothing usable is left. Never returns nil.
function Toolset.normalize(saved, valid_colors)
    local out = {}
    if type(saved) == "table" then
        for _, p in ipairs(saved) do
            if #out >= Toolset.PRESET_CAP then break end
            if Toolset.isValid(p, valid_colors) then
                out[#out + 1] = { tool = p.tool, color_name = p.color_name,
                                  width = math.floor(p.width + 0.5) }
            end
        end
    end
    if #out == 0 then
        for _, p in ipairs(Toolset.defaults()) do
            if Toolset.isValid(p, valid_colors) then out[#out + 1] = p end
        end
    end
    return out
end

-- Do two presets draw the same?
function Toolset.same(a, b)
    if not (a and b) then return false end
    return a.tool == b.tool and a.color_name == b.color_name and a.width == b.width
end

-- Index of the preset equal to `p` in `list`, or nil.
function Toolset.find(list, p)
    for i, q in ipairs(list) do
        if Toolset.same(q, p) then return i end
    end
    return nil
end

-- Store `p` in slot `idx` (1..PRESET_CAP). A slot just past the end appends.
-- An equal preset already in another slot is moved rather than duplicated, so
-- the row never shows two identical swatches. Returns the slot it ended up in,
-- or nil when `idx` is out of range or `p` is not a valid preset.
function Toolset.store(list, idx, p, valid_colors)
    if not Toolset.isValid(p, valid_colors) then return nil end
    if type(idx) ~= "number" or idx < 1 or idx > math.min(#list + 1, Toolset.PRESET_CAP) then
        return nil
    end
    local dup = Toolset.find(list, p)
    if dup and dup ~= idx then
        table.remove(list, dup)
        if dup < idx then idx = idx - 1 end
    end
    list[idx] = copy(p)
    return idx
end

-- "Previous tool" bookkeeping, so one gesture can flip between two tools (like
-- ink-away's pen swap). `cur` and `prev` are plain state tables:
-- { tool, color_name, width }. Returns (new_cur, new_prev). With no previous
-- state yet, nothing changes.
function Toolset.swap(cur, prev)
    if not prev then return cur, prev end
    return prev, cur
end

-- Record that `new` replaces `cur`: the old one becomes "previous", unless the
-- two are the same thing (re-picking the active tool must not wipe the
-- previous one). Returns the new "previous".
function Toolset.remember(cur, new, prev)
    if cur and new and not Toolset.same(cur, new) then
        return copy(cur)
    end
    return prev
end

-- Item size so `count` items with `gap` between them fit in `avail_w`: the base
-- size when it fits, otherwise shrunk, never below `min_size`.
function Toolset.fitItemSize(count, avail_w, base, gap, min_size)
    if count <= 0 then return base end
    local needed = count * base + (count - 1) * gap
    if needed <= avail_w then return base end
    local size = math.floor((avail_w - (count - 1) * gap) / count)
    return math.max(min_size or 1, size)
end

-- Height of the sample bar drawn in a width swatch: the stroke's real
-- thickness, but never taller than the swatch interior.
function Toolset.sampleBarHeight(width, inner)
    return math.max(1, math.min(width, inner))
end

-- Where to put the box (top-left) for an anchor point (the pen, or nil for the
-- middle-bottom of the screen): above the anchor when there is room, else below,
-- always fully on screen. Same idea the color picker used, in one tested place.
-- @return x, y
function Toolset.place(sw, sh, bw, bh, ax, ay, opts)
    opts = opts or {}
    local gap = opts.gap or 30
    local margin = opts.margin or 10
    if not ax or not ay then
        return math.floor((sw - bw) / 2), math.max(margin, sh - bh - margin * 4)
    end
    local x = ax - bw / 2
    local y = ay - bh - gap
    if x < margin then x = margin end
    if x + bw > sw - margin then x = sw - bw - margin end
    if y < margin then y = ay + gap end                    -- no room above
    if y + bh > sh - margin then y = sh - bh - margin end  -- final clamp
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    return math.floor(x), math.floor(y)
end

return Toolset
