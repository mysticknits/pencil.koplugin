--[[--
Pencil input handling for KOReader.
Owns stylus callback registration, palm/touch detection, and raw stylus dispatch.
@module koplugin.pencil.input
--]]--
local Device = require("device")
local Screen = Device.screen
local PencilGeometry = require("lib/geometry")
local PencilTool = require("lib/penciltool")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")

local TOOL_HIGHLIGHTER = PencilTool.TOOLS.HIGHLIGHTER
local TOOL_ERASER = PencilTool.TOOLS.ERASER
local LINUX_TOOLTYPE = PencilTool.LINUX_TOOLTYPE


local M = {}
local _palm_filter_installed = false

-- Setup stylus callback for lowest latency pen capture
-- Uses the new Input:registerStylusCallback() API that intercepts stylus events
-- before they reach the gesture detector
function M.setupStylusCallback(self)
    if self.stylus_callback_registered then return end

    local Input = Device.input
    if not Input or not Input.registerStylusCallback then
        logger.warn("Pencil: stylus callback API not available")
        return
    end

    local plugin = self

    -- Register the stylus callback
    -- Callback receives: input (Input object), slot (table with slot, id, x, y, tool, timev)
    -- Return true to "dominate" (remove from gesture detection)
    self._stylus_cb = function(input, slot)
        return plugin:handleStylusSlot(input, slot)
    end
    Input:registerStylusCallback(self._stylus_cb)

    self.stylus_callback_registered = true
    logger.info("Pencil: stylus callback registered")
    self:installPalmFilter(Input)
end

-- Wrap Input:routeStylusEvents (runs on every touch frame, before gesture
-- detection) so finger slots can be dropped while the pen is in use.
-- Installed once per Input object; it defers to the active plugin instance.
function M.installPalmFilter(self, input)
    if _palm_filter_installed or not input.routeStylusEvents then return end
    local route = input.routeStylusEvents
    local plugin = self
    input.routeStylusEvents = function(inp, ...)
        plugin:ensureStylusCallback(inp)
        route(inp, ...)
        plugin:filterPalmSlots(inp)
    end
    _palm_filter_installed = true
end

-- Other plugins (Ink Away, for one) register their own stylus callback while
-- open and unregister it on close without restoring ours, which would leave
-- the reader deaf to the pen. Put ours back once the reader is on top again.
function M.ensureStylusCallback(self, input)
    if not (self.stylus_callback_registered and self._stylus_cb) then return end
    if input.stylus_callback ~= nil or not input.registerStylusCallback then return end
    if self:isOverlayActive() then return end
    input:registerStylusCallback(self._stylus_cb)
    logger.info("Pencil: stylus callback restored")
end

-- Is a slot routed to us as a stylus actually a palm? The pen tip always
-- reports tool 1, so its slot is learned from that. Tool 2/3 is trusted only
-- on the pen's slot, or while the Kobo eraser / side button latch is held
-- (input.lua then rewrites the pen's tool 1 to 2/3). Approach adapted from
-- Ink Away's Stylus.classify (EmirErtorer/ink-away.koplugin, MIT).
function M.isPalmSlot(self, input, slot)
    local tool = slot.tool
    if tool == 1 then
        self.learned_pen_slot = slot.slot
        return false
    end
    if tool ~= 2 and tool ~= 3 then return false end
    if slot.slot == nil then return false end  -- can't tell without a slot number
    if input then
        if input.pen_slot ~= nil and slot.slot == input.pen_slot then return false end
        -- Latch names: KOReader 2026.07+ (stylus_*) and the older patched
        -- input.lua shipped with this plugin (kobo_*).
        if tool == 2 and (input.stylus_eraser_active or input.kobo_eraser_active) then return false end
        if tool == 3 and (input.stylus_highlighter_active or input.kobo_highlighter_active) then return false end
    end
    if self.learned_pen_slot ~= nil and slot.slot == self.learned_pen_slot then return false end
    return true
end

-- Drop finger contacts that start while the pen is near or was just used.
-- A dropped contact stays dropped until its lift (which is dropped too), and
-- contacts that started before stay untouched, so the gesture detector never
-- sees half a contact.
function M.filterPalmSlots(self, input)
    local slots = input.MTSlots
    if not slots or #slots == 0 then return end
    self.palm_slots = self.palm_slots or {}
    self.finger_slots = self.finger_slots or {}
    local enabled = self.palm_rejection and self:isEnabled()

    local suppress = false
    if enabled then
        local pen = input.ev_slots and input.pen_slot and input.ev_slots[input.pen_slot]
        local pen_tool = pen and pen.tool
        if pen_tool == 1 or pen_tool == 2 then
            suppress = true  -- pen (tip or eraser) is in proximity
        elseif self.last_stylus_time
                and time.to_ms(time.now() - self.last_stylus_time) <= (self.PALM_GRACE_MS or 800) then
            suppress = true
        end
    end

    for i = #slots, 1, -1 do
        local s = slots[i]
        local is_pen = s.slot == input.pen_slot or s.tool == 1 or s.tool == 2 or s.tool == 3
        if not is_pen and s.slot ~= nil then
            local key = s.slot
            local lifting = not s.id or s.id < 0
            if self.palm_slots[key] then
                table.remove(slots, i)
                if lifting then self.palm_slots[key] = nil end
            elseif self.finger_slots[key] then
                if lifting then self.finger_slots[key] = nil end
            elseif not lifting then
                if suppress then
                    self.palm_slots[key] = true
                    table.remove(slots, i)
                else
                    self.finger_slots[key] = true
                end
                if self.input_debug_mode then
                    local pen = input.ev_slots and input.pen_slot and input.ev_slots[input.pen_slot]
                    self:writeDebugLog(string.format(
                        "PALM: touch start slot=%s id=%s x=%s y=%s -> %s (enabled=%s pen_slot_tool=%s stylus_age_ms=%s)",
                        tostring(key), tostring(s.id), tostring(s.x), tostring(s.y),
                        suppress and "DROPPED" or "passed", tostring(enabled),
                        tostring(pen and pen.tool),
                        self.last_stylus_time and tostring(time.to_ms(time.now() - self.last_stylus_time)) or "never"))
                end
            end
        end
    end
end

-- Transform stylus coordinates based on screen rotation
-- Raw stylus coordinates are in hardware space; framebuffer expects logical (rotated) space
function M.transformCoordinates(self, x, y)
    local rotation = Screen:getRotationMode()
    return PencilGeometry.transformForRotation(x, y, rotation, Screen:getWidth(), Screen:getHeight())
end

-- Handle a stylus slot from the callback
-- slot = {slot=N, id=N, x=N, y=N, tool=N, timev=timestamp}
-- id >= 0 means contact active, id == -1 means contact lifted
function M.handleStylusSlot(self, input, slot)
    local handled = self:routeStylusSlot(input, slot)
    if slot.id and slot.id >= 0 then
        if handled then self.owns_contact = true end
    else
        self.owns_contact = false
    end
    return handled
end

function M.routeStylusSlot(self, input, slot)
    -- A resting palm can reach us looking like the eraser: Linux reports a
    -- rejected touch as MT_TOOL_PALM (2), the eraser's tool number, and
    -- input.lua routes any tool 2/3 slot here. Swallow it so it neither
    -- erases nor becomes a gesture.
    if self:isPalmSlot(input, slot) then
        if self.input_debug_mode then
            self:writeDebugLog(string.format("PALM: stylus-looking slot=%s tool=%s id=%s x=%s y=%s swallowed",
                tostring(slot.slot), tostring(slot.tool), tostring(slot.id), tostring(slot.x), tostring(slot.y)))
        end
        return true
    end
    -- Remembered for palm rejection (see filterPalmSlots)
    self.last_stylus_time = time.now()
    if self.notes_feature and self.notes_feature:handleStylus(slot) then
        return true
    end

    -- Debug logging at the very start to see slot.tool
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS SLOT: id=%d x=%d y=%d tool=%d eraser_active=%s",
            slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.tool.eraser_button_active)))
    end

    -- Leave new contacts to a menu or overlay on top of the reader. A contact
    -- that started on the page is still followed to its lift if an overlay
    -- opens meanwhile, like the color picker shown while the pen is held
    -- still: handing over the rest would make the lift a tap outside the
    -- picker, closing it, and we'd never see the pen go up (#72). We just
    -- stop drawing and erasing under the overlay.
    local overlay = self:isOverlayActive()
    if overlay and not self.owns_contact then return false end

    -- Detect eraser end via slot.tool BEFORE key events arrive
    -- This handles the timing issue where stylus callback fires before key events
    local click_mode = self.tool:isEraserClickMode()
    local eraser_change, eraser_clicked = self.tool:detectEraserAndUpdate(slot)
    if eraser_change == true then
        self.eraser_button_deleted = {}
    elseif eraser_change == false then
        -- Switched from eraser end to pen tip
        self:endEraserMode()
        if click_mode and eraser_clicked then self:onEraserClick() end
    end

    -- Eraser role (eraser end, or hardware button) - works even if pencil disabled.
    -- "Eraser click" mode:
    --   click (touch that stays put) = toggle pen/eraser, nothing is erased
    --   drag = erase what the pen passes over, tool is NOT toggled
    if self.tool.eraser_button_active and click_mode then
        local touching = slot.id and slot.id >= 0
        local x, y
        if touching then
            x, y = self:transformCoordinates(slot.x or self.pen_x, slot.y or self.pen_y)
        end
        local phase = self.tool:trackEraserContact(touching, x, y)
        if phase == "drag_start" then
            -- Also erase where the pen first touched down
            local contact = self.tool.eraser_contact
            if not overlay then
                self:eraseWithEraserRole(contact.x0, contact.y0)
                self:eraseWithEraserRole(x, y)
            end
        elseif phase == "drag" then
            -- The digitizer reports at a high rate; only erase when the
            -- eraser actually moved.
            if not overlay and (x ~= self.pen_x or y ~= self.pen_y) then
                self:eraseWithEraserRole(x, y)
            end
        elseif phase == "drag_end" then
            -- The contact itself has ended: finalize this erase gesture now.
            self:finishEraseGesture()
            UIManager:setDirty(self.view, "ui")
        elseif phase == "click" then
            self:onEraserClick()
        end
        return true
    end

    -- Default: the eraser end/button erases what it touches and passes over.
    -- Works even if pencil is disabled.
    if self.tool.eraser_button_active and not click_mode then
        if slot.id and slot.id >= 0 then
            local x, y = self:transformCoordinates(slot.x or self.pen_x, slot.y or self.pen_y)
            -- The digitizer reports at a high rate; erase on first touch, then
            -- only when the eraser actually moved.
            if not overlay and (not self.eraser_touching or x ~= self.pen_x or y ~= self.pen_y) then
                self:eraseWithEraserRole(x, y)
            end
            self.eraser_touching = true
        elseif self.eraser_touching then
            -- Eraser lifted off the screen (button/end still active)
            self.eraser_touching = false
            self:finishEraseGesture()
            UIManager:setDirty(self.view, "ui")
        end
        return true
    end

    -- Highlighter role with the "Text highlight" option: highlight the text
    -- below the pen. Without the option the role draws a highlighter stroke
    -- (handled further down). Text highlights go through KOReader's
    -- ReaderHighlight. Sticky: once a text
    -- highlight starts, we stay in it until pen lift even if the side button is
    -- released mid-drag.
    -- A pen touching down while a picker is up taps the picker, even with the
    -- highlighter button held (otherwise it would start a highlight under it)
    if self.color_picker_showing and self.color_picker_widget and not self.pen_down
            and slot.id and slot.id >= 0 then
        local px, py = self:transformCoordinates(slot.x or 0, slot.y or 0)
        if self.color_picker_widget:handlePenTap(px, py) then
            return true
        end
    end

    -- The hold that opened the picker must not transition back into a text or
    -- freehand highlight behind the popup. Consume it until the pen is lifted;
    -- the following contact can then select a picker item normally.
    if self.color_picker_contact_active then
        if not slot.id or slot.id < 0 then
            self.color_picker_contact_active = false
            self.pen_down = false
            self.current_stroke = nil
            self.live_highlighter = nil
            self.tool.highlighting = false
            self.tool.highlight_freehand = false
            self:cancelColorPickerTimer()
        end
        return true
    end

    local highlight_step = self.tool:detectHighlighting(slot, self.side_button_down)
    -- Mark the side button as used so its release isn't treated as a quick
    -- press (which would toggle to the eraser).
    if highlight_step then self.side_button_used_for_highlight = true end
    if highlight_step == "extend" then
        self:extendTextHighlight(slot.x or 0, slot.y or 0)
        -- Holding the highlighter still over text opens the picker too
        local hx, hy = self:transformCoordinates(slot.x or 0, slot.y or 0)
        self.pen_x, self.pen_y = hx, hy
        self:movePickerTracking(hx, hy)
        return true
    elseif highlight_step == "finish" then
        self:cancelColorPickerTimer()
        self:finishTextHighlight()
        return true
    elseif highlight_step == "ignore" then
        return true
    elseif highlight_step == "start" then
        if self:startTextHighlight(slot.x or 0, slot.y or 0) then
            local hx, hy = self:transformCoordinates(slot.x or 0, slot.y or 0)
            self.pen_x, self.pen_y = hx, hy
            self:beginPickerTracking(hx, hy, TOOL_HIGHLIGHTER)
            return true
        end
        if self.tool:isEraserClickMode() then
            -- No text below the pen: this contact draws a freehand highlighter
            -- stroke (handled below, effective tool is the highlighter)
            self.tool.highlight_freehand = true
        else
            -- No word below the pen (yet): nothing is drawn; a word found
            -- later in the drag starts the highlight then.
            return true
        end
    end

    if not self:isEnabled() then return false end

    -- Log in debug mode
    if self.input_debug_mode then
        self:writeDebugLog(string.format("STYLUS: slot=%d id=%d x=%d y=%d tool=%d pen_down=%s tool=%s",
            slot.slot or -1, slot.id or -1, slot.x or 0, slot.y or 0, slot.tool or -1,
            tostring(self.pen_down), self.tool:getTool()))
    end

    -- Determine effective tool: eraser role, then highlighter role (slot.tool
    -- or side button held), then the selected tool. Same rule as the gesture path.
    local effective_tool = self.tool:getEffectiveToolForSlot(slot, self.side_button_down)
    if self.input_debug_mode and effective_tool == TOOL_ERASER and slot.tool == LINUX_TOOLTYPE.ERASER then
        self:writeDebugLog(string.format("ERASER END detected via slot.tool=%d", slot.tool))
    end

    -- Handle eraser mode
    if effective_tool == TOOL_ERASER then
        if self.input_debug_mode and not self.tool.erasing then
            self:writeDebugLog(string.format("ERASER MODE: pen_down=%s slot.id=%d",
                tostring(self.pen_down), slot.id or -1))
        end
        if slot.id and slot.id >= 0 then
            -- Eraser is touching - erase at this position
            local first_touch = false
            if not self.pen_down then
                self.pen_down = true
                self.tool.erasing = true
                self.eraser_deleted = {}
                first_touch = true
                if self.input_debug_mode then
                    self:writeDebugLog("=== ERASER DOWN ===")
                end
            end

            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            -- Erase on first touch OR when position changes
            if first_touch or x ~= self.pen_x or y ~= self.pen_y then
                local page = self:getCurrentPage()
                if self.input_debug_mode then
                    self:writeDebugLog(string.format("ERASE ATTEMPT at (%d, %d) page=%s erasing=%s",
                        x, y, tostring(page), tostring(self.tool.erasing)))
                end
                local deleted = not overlay and self:eraseAtPoint(x, y, page, true)
                if deleted then
                    for _, stroke in ipairs(deleted) do
                        table.insert(self.eraser_deleted, stroke)
                    end
                    self:refreshAfterErase(deleted, false)
                    if self.input_debug_mode then
                        self:writeDebugLog(string.format("ERASED %d strokes at (%d, %d)", #deleted, x, y))
                    end
                end
                self.pen_x = x
                self.pen_y = y
            end
        else
            -- Eraser lifted
            if self.pen_down and self.tool.erasing then
                self.pen_down = false
                self.tool.erasing = false

                local deleted = self.eraser_deleted
                self.eraser_deleted = nil

                if deleted and #deleted > 0 then
                    -- Rebuild once after all samples, before persisting groups.
                    self:finishEraseGesture()
                    self:commitErase(deleted)
                else
                    -- No deletion: clear transient gesture state without a rebuild.
                    self.tool.eraser_contact = nil
                    self.highlight_box_cache = nil
                end
                UIManager:setDirty(self.view, "ui")
                if self.input_debug_mode then
                    self:writeDebugLog("=== ERASER UP ===")
                end
            end
        end
        return true  -- Dominate: remove from gesture detection
    end

    if self.lasso_feature and self.lasso_feature:isActive() then
        return self.lasso_feature:handleStylus(slot)
    end

    -- Handle pen/highlighter mode
    if slot.id and slot.id >= 0 then
        -- Pen down or moving
        if not self.pen_down then
            -- Pen down on a note marker opens the note.
            if self.notes_feature then
                local mx, my = self:transformCoordinates(slot.x or 0, slot.y or 0)
                local note = self.notes_feature:findMarkerAt(mx, my)
                if note then
                    self.notes_feature:open(note, true)
                    return true
                end
            end

            -- Start new stroke. (Pen taps on an open color picker never get
            -- here: new contacts go to the overlay, whose buttons handle them.)
            self.pen_down = true
            self.tool.erasing = false
            self:cancelPendingRefresh()
            self:cancelColorPickerTimer()
            self:startRawStroke(effective_tool)
            -- Record initial position and timestamp for color picker trigger
            local raw_x = slot.x or 0
            local raw_y = slot.y or 0
            local x, y = self:transformCoordinates(raw_x, raw_y)
            -- Record the touch-down point itself, so a tap with no movement
            -- (a dot) still produces a stroke and strokes start where the pen
            -- landed instead of at the first move.
            if slot.x and slot.y then
                self:addRawPoint(x, y)
            end
            self.pen_x = x
            self.pen_y = y
            -- Hold still to open the pen's or the highlighter's picker
            self:beginPickerTracking(x, y, effective_tool)
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN DOWN ===")
            end
        else
            -- Pen is moving
            local raw_x = slot.x or self.pen_x
            local raw_y = slot.y or self.pen_y
            local x, y = self:transformCoordinates(raw_x, raw_y)
            if x ~= self.pen_x or y ~= self.pen_y then
                -- Pen moved too far from where it came down: no picker
                self:movePickerTracking(x, y)
                if not overlay then
                    self:addRawPoint(x, y)
                    self:trackUnderlineHold(x, y)
                end
                self.pen_x = x
                self.pen_y = y
            end
        end
    else
        -- Pen lifted (id == -1)
        if self.pen_down and not self.tool.erasing then
            self.pen_down = false
            self:cancelColorPickerTimer()
            self:cancelUnderlineHold()
            self:endRawStroke()
            if self.input_debug_mode then
                self:writeDebugLog("=== PEN UP ===")
            end
        end
    end

    return true  -- Dominate: remove from gesture detection
end

-- Teardown stylus callback
function M.teardownStylusCallback(self)
    if not self.stylus_callback_registered then return end

    local Input = Device.input
    if Input and Input.unregisterStylusCallback then
        Input:unregisterStylusCallback()
    end

    self.stylus_callback_registered = false
    self.pen_down = false
    logger.info("Pencil: stylus callback unregistered")
end


return M
