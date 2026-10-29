--[[
Emulator only: make the mouse act as the stylus.

KOReader treats the emulator's mouse as a finger, so the Pencil plugin falls
back to its gesture path, which draws without refreshing the screen (fine on
e-ink, invisible on a desktop window until you let go). Marking the mouse's
touch slot as the pen slot sends mouse input through KOReader's stylus routing
instead, the same low-latency path the pen uses on a Kobo.

Clicks that start in the top or bottom eighth of the screen stay a finger, so
they open KOReader's top menu and settings menu as on a device.

Two keys stand in for the Kobo stylus buttons while you drag:
  E  eraser end   (the Kobo's "Eraser" button)
  H  side button  (the Kobo's "Highlighter" button: hold to highlight,
                   tap to toggle pencil/eraser)
In the emulator those keys no longer type letters.

Installed by integration/run.sh into the emulator's patches folder.
--]]
local Device = require("device")
local logger = require("logger")

local input = Device.input
if not (Device:isEmulator() and input and input.routeStylusEvents) then
    return
end

local MENU_BAND = 1/8 -- KOReader's top-menu and bottom-menu tap zones
local TOOL_TYPE_FINGER, TOOL_TYPE_PEN = 0, 1
local mouse_slot = input.main_finger_slot
input.pen_slot = mouse_slot

-- Keyboard stand-ins for the stylus buttons, named as on a Kobo so the
-- plugin's key handling runs unchanged. SDL key codes: e = 101, h = 104.
local BUTTON_KEYS = { [101] = "Eraser", [104] = "Highlighter" }
for code, name in pairs(BUTTON_KEYS) do
    input.event_map[code] = name
end

-- On a Kobo, KOReader turns these buttons into eraser/highlighter pen input.
-- It skips that in the emulator, so do it here.
local held = {}
local handleKeyBoardEv = input.handleKeyBoardEv
function input:handleKeyBoardEv(ev)
    local name = BUTTON_KEYS[ev.code]
    if name then
        local down = ev.value ~= 0
        -- macOS resends a held key as fresh presses. Stylus buttons don't
        -- repeat, and the plugin reads each press as a new button press
        -- (a held side button would end as a "tap" and toggle the tool).
        if down and held[name] then
            return
        end
        held[name] = down or nil
        if name == "Eraser" then
            self.stylus_eraser_active = down
        else
            self.stylus_highlighter_active = down
        end
    end
    return handleKeyBoardEv(self, ev)
end

local contact_id      -- id of the current mouse contact
local contact_is_finger -- true when that contact started in a menu band

local routeStylusEvents = input.routeStylusEvents
function input:routeStylusEvents()
    -- Check for a release now: routing removes slots the plugin handled, and
    -- the emulator reuses the same contact id for every click.
    local lifted = false
    for _, slot in ipairs(self.MTSlots or {}) do
        if slot.slot == mouse_slot then
            if slot.id and slot.id >= 0 and slot.id ~= contact_id then
                -- A new click: decide once where it started.
                local height = Device.screen:getHeight()
                contact_id = slot.id
                contact_is_finger = slot.y ~= nil
                    and (slot.y < height * MENU_BAND or slot.y > height * (1 - MENU_BAND))
            elseif slot.id == -1 then
                lifted = true
            end
        end
    end

    -- The mouse reports no tool type. Mark drags as a pen, as the Kobo does,
    -- so KOReader can switch them to eraser or highlighter.
    for _, slot in ipairs(self.MTSlots or {}) do
        if slot.slot == mouse_slot then
            slot.tool = contact_is_finger and TOOL_TYPE_FINGER or TOOL_TYPE_PEN
        end
    end

    if contact_is_finger then
        -- Hide the mouse from stylus routing so KOReader sees a finger.
        self.pen_slot = nil
        routeStylusEvents(self)
        self.pen_slot = mouse_slot
    else
        routeStylusEvents(self)
    end

    -- Forget the contact once it lifts.
    if lifted then
        contact_id, contact_is_finger = nil, nil
    end
end

-- The plugin's gesture fallback treats every emulator gesture as the pen,
-- which would swallow the menu taps above. Make it see those as a finger.
local function inMenuBand(ges)
    local y = ges and ges.pos and ges.pos.y
    if not y then return false end
    local height = Device.screen:getHeight()
    return y < height * MENU_BAND or y > height * (1 - MENU_BAND)
end

local PluginLoader = require("pluginloader")
local createPluginInstance = PluginLoader.createPluginInstance
function PluginLoader:createPluginInstance(plugin, attr)
    if plugin.name == "pencil" and plugin.isPenInput and not plugin._menu_band_patched then
        local isPenInput = plugin.isPenInput
        plugin.isPenInput = function(pencil, ges)
            if inMenuBand(ges) then
                return false, false, false
            end
            return isPenInput(pencil, ges)
        end
        plugin._menu_band_patched = true
    end
    return createPluginInstance(self, plugin, attr)
end

logger.info("Pencil dev patch: mouse is the stylus except in the menu bands; E = eraser end, H = side button")
