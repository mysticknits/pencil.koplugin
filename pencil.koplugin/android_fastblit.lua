--[[--
Android-only behaviour for the Pencil plugin.

main.lua loads this file only when Device:isAndroid() is true, so nothing
here runs on Kobo or other platforms. It owns three things:

1. Stroke refresh. On Android every refresh, however small the region,
   copies the whole shadow blitbuffer into the native window
   (framebuffer_android:_updateWindow), which on a 13" 3200x2400 panel costs
   tens of milliseconds. Asking for that 60 times a second starves the main
   loop and the ink appears seconds late. So while drawing we refresh at
   most 10 times a second and, on monochrome panels, with the fast e-ink
   waveform instead of the UI one.

2. Region-limited window update (experimental, off by default). Android's
   ANativeWindow_lock() accepts dirty bounds and copies the untouched area
   back from the previously posted buffer itself, so a stroke only needs its
   own small rectangle blitted. This uses koreader-base internals
   (android.app.window, Screen._updatePartial, the window format cdefs) that
   may change between releases, hence the toggle. Any failure falls back to
   path 1 for the rest of the session.

3. An on-screen timing readout per stroke, so testers can report where the
   time goes without pulling logs off the device.
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")

local Screen = Device.screen

local M = {}

-- Refresh interval while drawing (ms) for each path.
M.INTERVAL_PLAIN_MS = 100
M.INTERVAL_REGION_MS = 40

-- After this many failed strokes in a row the region path stays off
-- until the option is toggled; below it, the next stroke tries again.
M.MAX_REGION_FAILURES = 3

-- Counters shown by the timing readout; reset at stroke start.
M.stats = { refresh_n = 0, blit_n = 0, blit_us = 0, eink_us = 0, cb_n = 0, cb_us = 0 }

-- Builds the region-limited refresh function, or returns nil (with a
-- reason) when something it needs is missing on this KOReader build.
function M.install()
    local ok_android, android = pcall(require, "android")
    if not ok_android or type(android) ~= "table" or not android.lib then
        return nil, "android module unavailable"
    end
    if not (android.getEinkConstants and android.isEinkFull and android.app) then
        return nil, "android.getEinkConstants/isEinkFull/app missing"
    end
    local ffi = require("ffi")
    local C = ffi.C
    local BB = require("ffi/blitbuffer")
    -- Missing cdefs raise on access; probe them safely.
    local ok_cdef = pcall(function()
        return C.WINDOW_FORMAT_RGBA_8888, C.WINDOW_FORMAT_RGBX_8888, C.WINDOW_FORMAT_RGB_565
    end)
    if not ok_cdef then
        return nil, "window format cdefs missing"
    end
    if not Screen._updatePartial then
        return nil, "Screen._updatePartial missing"
    end

    local _full, _partial, _full_ui, _partial_ui, fast, _delay_page, _delay_ui, delay_fast = android.getEinkConstants()
    local eink_full = android.isEinkFull()
    local buffer = ffi.new("ANativeWindow_Buffer[1]")
    local dirty = ffi.new("ARect[1]")

    local function refresh(x, y, w, h)
        local t0 = time.now()
        local ext_bb = Screen.full_bb or Screen.bb
        x, y, w, h = ext_bb:getBoundedRect(x, y, w, h)
        if not w or w <= 0 or h <= 0 then return end
        local px, py, pw, ph = ext_bb:getPhysicalRect(x, y, w, h)

        local window = android.app.window
        if window == nil then return end

        dirty[0].left = px
        dirty[0].top = py
        dirty[0].right = px + pw
        dirty[0].bottom = py + ph
        if android.lib.ANativeWindow_lock(window, buffer, dirty) < 0 then
            return
        end

        local b = buffer[0]
        local bb
        if b.format == C.WINDOW_FORMAT_RGBA_8888 or b.format == C.WINDOW_FORMAT_RGBX_8888 then
            bb = BB.new(b.width, b.height, BB.TYPE_BBRGB32, b.bits, b.stride * 4, b.stride)
        elseif b.format == C.WINDOW_FORMAT_RGB_565 then
            bb = BB.new(b.width, b.height, BB.TYPE_BBRGB16, b.bits, b.stride * 2, b.stride)
        end

        if bb then
            -- The system may have widened the dirty bounds (e.g. when it
            -- could not copy the rest back); honour what it returns.
            local d = dirty[0]
            local dx, dy = d.left, d.top
            local dw, dh = d.right - d.left, d.bottom - d.top
            -- Blit in physical space: the window buffer is unrotated, so
            -- drop the shadow buffer's rotation for the duration of the copy.
            local rot = ext_bb:getRotation()
            local inv = ext_bb:getInverse()
            ext_bb:setRotation(0)
            if inv == 1 and bb:getType() == ext_bb:getType() then
                bb:invertblitFrom(ext_bb, dx, dy, dx, dy, dw, dh)
            else
                bb:blitFrom(ext_bb, dx, dy, dx, dy, dw, dh)
                if inv == 1 then
                    bb:invertRect(dx, dy, dw, dh)
                end
            end
            ext_bb:setRotation(rot)
        end

        android.lib.ANativeWindow_unlockAndPost(window)
        local t1 = time.now()

        if eink_full then
            Screen:_updatePartial(fast, delay_fast, x, y, w, h)
        end
        local t2 = time.now()
        local st = M.stats
        st.blit_n = st.blit_n + 1
        st.blit_us = st.blit_us + time.to_us(t1 - t0)
        st.eink_us = st.eink_us + time.to_us(t2 - t1)
    end

    return refresh
end

-- Called from Pencil:init() after settings are loaded, and again when the
-- experimental toggle changes. Installs plugin.stroke_refresh, which
-- addRawPoint() uses in place of Screen:refreshUI().
function M.setup(plugin)
    plugin.android = M
    M.fast_waveform = not (Device.hasColorScreen and Device:hasColorScreen())
    M.region_refresh = nil
    M.region_error = nil
    M.region_failures = 0
    plugin.refresh_interval_ms = M.INTERVAL_PLAIN_MS

    if plugin.experimental_android_fast_refresh then
        M.enableRegion(plugin)
    end

    plugin.stroke_refresh = function(self, x, y, w, h)
        M.stats.refresh_n = M.stats.refresh_n + 1
        if M.region_refresh then
            local ok, err = pcall(M.region_refresh, x, y, w, h)
            if ok then return end
            logger.warn("Pencil: Android region refresh failed, using plain refresh:", tostring(err))
            M.region_refresh = nil
            M.region_error = tostring(err)
            M.region_failures = M.region_failures + 1
            self.refresh_interval_ms = M.INTERVAL_PLAIN_MS
            if M.region_failures >= M.MAX_REGION_FAILURES then
                -- Say so: a silent fallback reads as "the pen got slower"
                -- with no way to tell why. Toggling the option retries.
                local Notification = require("ui/widget/notification")
                UIManager:show(Notification:new{
                    text = _("Android fast refresh stopped, using the normal refresh. Toggle it in Pencil > Experimental to retry."),
                    timeout = 6,
                })
            end
        end
        if M.fast_waveform then
            Screen:refreshFast(x, y, w, h)
        else
            -- UI waveform for proper colour rendering on colour panels
            Screen:refreshUI(x, y, w, h)
        end
    end
end

-- Stylus callback wrapper: same as plugin:handleStylusSlot, with timing
-- when the readout is on.
function M.handleSlot(plugin, input, slot)
    if not plugin.show_timing then
        return plugin:handleStylusSlot(input, slot)
    end
    local t0 = time.now()
    local r = plugin:handleStylusSlot(input, slot)
    M.stats.cb_n = M.stats.cb_n + 1
    M.stats.cb_us = M.stats.cb_us + time.to_us(time.now() - t0)
    return r
end

-- Install the region path, or record why it is unavailable.
function M.enableRegion(plugin)
    local ok, fn, why = pcall(M.install)
    if ok and fn then
        M.region_refresh = fn
        plugin.refresh_interval_ms = M.INTERVAL_REGION_MS
        logger.info("Pencil: Android region refresh enabled")
        return true
    end
    M.region_error = tostring(ok and why or fn)
    logger.warn("Pencil: Android region refresh unavailable:", M.region_error)
    return false
end

function M.strokeStart(plugin)
    -- A refresh that threw mid-stroke (a window being rebuilt during a
    -- rotation, say) need not cost the fast path for the whole session:
    -- try again on the next stroke, up to MAX_REGION_FAILURES in a row.
    if plugin.experimental_android_fast_refresh and not M.region_refresh
            and M.region_failures > 0 and M.region_failures < M.MAX_REGION_FAILURES then
        M.enableRegion(plugin)
    end
    if not plugin.show_timing then return end
    local st = M.stats
    st.refresh_n, st.blit_n, st.blit_us, st.eink_us, st.cb_n, st.cb_us = 0, 0, 0, 0, 0, 0
    M.timing_t0 = time.now()
end

-- Called from endRawStroke() while plugin.current_stroke is still set.
function M.strokeEnd(plugin)
    -- Show what was drawn since the last paced refresh. Without this the
    -- end of every stroke (up to one interval of ink, most of a short
    -- stroke) waits for the delayed refresh after writing stops.
    local r = plugin.dirty_region
    if r and plugin.stroke_refresh then
        plugin.dirty_region = nil
        local rx = math.max(0, math.floor(r.x))
        local ry = math.max(0, math.floor(r.y))
        local rw = math.min(Screen:getWidth() - rx, math.ceil(r.w))
        local rh = math.min(Screen:getHeight() - ry, math.ceil(r.h))
        if rw > 0 and rh > 0 then
            plugin:stroke_refresh(rx, ry, rw, rh)
        end
    end
    if M.region_refresh and M.region_failures > 0 then
        -- A whole stroke on the region path after a failure: forgiven.
        M.region_failures = 0
        M.region_error = nil
    end
    if not plugin.show_timing then return end
    local st = M.stats
    local pts = plugin.current_stroke and #plugin.current_stroke.points or 0
    local cb_avg = st.cb_n > 0 and (st.cb_us / st.cb_n / 1000) or 0
    local total_ms = M.timing_t0 and time.to_ms(time.now() - M.timing_t0) or 0
    local path = M.region_refresh and "region" or (M.fast_waveform and "fast" or "ui")
    if M.region_error then path = path .. " (fallback: " .. M.region_error .. ")" end
    local blit = ""
    if st.blit_n > 0 then
        blit = string.format(" blit %.1fms eink %.1fms x%d",
            st.blit_us / st.blit_n / 1000, st.eink_us / st.blit_n / 1000, st.blit_n)
    end
    local touch_rot = Screen.getTouchRotation and Screen:getTouchRotation() or -1
    local msg = string.format("%d pts %dms | input %.2fms x%d | %s every %dms x%d%s | rot %d touch %d %dx%d",
        pts, total_ms, cb_avg, st.cb_n, path, plugin.refresh_interval_ms, st.refresh_n, blit,
        Screen:getRotationMode(), touch_rot, Screen:getWidth(), Screen:getHeight())
    logger.info("Pencil timing:", msg)
    local Notification = require("ui/widget/notification")
    UIManager:show(Notification:new{ text = msg, timeout = 6 })
end

-- Entries appended to Pencil > Experimental on Android.
function M.menuItems(plugin)
    local InfoMessage = require("ui/widget/infomessage")
    return {
        {
            text = _("Android fast refresh"),
            help_text = _("While drawing, update only the stroke's rectangle of the screen instead of the whole screen buffer. Cuts pen lag on large panels. Uses KOReader internals that may change between releases; if it fails, Pencil retries on the next stroke and, after three failures in a row, says so and uses the normal refresh until you toggle it again."),
            checked_func = function()
                return plugin.experimental_android_fast_refresh
            end,
            callback = function()
                plugin.experimental_android_fast_refresh = not plugin.experimental_android_fast_refresh
                plugin:saveSettings()
                M.setup(plugin)
                UIManager:show(InfoMessage:new{
                    text = plugin.experimental_android_fast_refresh
                        and (M.region_refresh and _("Android fast refresh enabled.")
                             or _("Android fast refresh is not available on this KOReader build. Using the normal refresh."))
                        or _("Android fast refresh disabled."),
                    timeout = 3,
                })
            end,
        },
        {
            text = _("Show drawing timing on screen"),
            help_text = _("After each stroke, show how long input handling and screen updates took, and the rotation the device reports. For lag and rotation bug reports."),
            checked_func = function()
                return plugin.show_timing == true
            end,
            callback = function()
                plugin.show_timing = not plugin.show_timing
            end,
        },
    }
end

return M
