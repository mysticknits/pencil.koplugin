--[[--
Tests for the Android-only module, run with KOReader stubbed out.
Run with: busted spec/android_spec.lua
--]]--

package.path = package.path .. ";pencil.koplugin/?.lua"

local calls
local shown -- widgets passed to UIManager:show

local Screen = {
    refreshFast = function(_, x, y, w, h) table.insert(calls, { "fast", x, y, w, h }) end,
    refreshUI = function(_, x, y, w, h) table.insert(calls, { "ui", x, y, w, h }) end,
    getRotationMode = function() return 0 end,
    getTouchRotation = function() return 0 end,
    getWidth = function() return 100 end,
    getHeight = function() return 200 end,
}

local Device = {
    screen = Screen,
    hasColorScreen = function() return false end,
}

local stubs = {
    ["device"] = Device,
    ["ui/uimanager"] = { show = function(_, widget) table.insert(shown, widget) end },
    ["ui/widget/infomessage"] = { new = function(_, o) return o end },
    ["ui/widget/notification"] = { new = function(_, o) return o end },
    ["logger"] = setmetatable({}, { __index = function() return function() end end }),
    ["ui/time"] = { now = function() return 0 end, to_us = function() return 0 end, to_ms = function() return 0 end },
    ["gettext"] = function(s) return s end,
}

local function load_android()
    for name, stub in pairs(stubs) do package.loaded[name] = stub end
    package.loaded["android_fastblit"] = nil
    -- No "android" module here, as on any non-Android build.
    package.loaded["android"] = nil
    return require("android_fastblit")
end

local function new_plugin(opts)
    return {
        experimental_android_fast_refresh = opts.fast_refresh or false,
        android_eink_every = opts.eink_every,
        refresh_interval_ms = 16,
        saveSettings = function() end,
        handleStylusSlot = function() return true end,
    }
end

describe("android_fastblit", function()
    local android

    before_each(function()
        calls = {}
        shown = {}
        android = load_android()
    end)

    it("paces the stroke refresh at 10 Hz with the fast waveform", function()
        local p = new_plugin({})
        android.setup(p)
        assert.are.equal(android, p.android)
        assert.are.equal(100, p.refresh_interval_ms)
        p:stroke_refresh(1, 2, 3, 4)
        assert.are.same({ { "fast", 1, 2, 3, 4 } }, calls)
    end)

    it("uses the UI waveform on colour panels", function()
        Device.hasColorScreen = function() return true end
        local p = new_plugin({})
        android.setup(p)
        p:stroke_refresh(1, 2, 3, 4)
        assert.are.equal("ui", calls[1][1])
        Device.hasColorScreen = function() return false end
    end)

    it("leaves the region refresh off by default", function()
        local p = new_plugin({})
        android.setup(p)
        assert.is_nil(android.region_refresh)
    end)

    it("falls back to the plain refresh when the region path is unavailable", function()
        local p = new_plugin({ fast_refresh = true })
        android.setup(p)
        assert.is_nil(android.region_refresh)
        assert.are.equal(100, p.refresh_interval_ms)
        p:stroke_refresh(1, 2, 3, 4)
        assert.are.equal("fast", calls[1][1])
    end)

    it("retries the region path on the next stroke after a failure", function()
        local p = new_plugin({ fast_refresh = true })
        android.setup(p)
        -- Pretend the region path was installed, then throws once.
        android.region_refresh = function() error("window gone") end
        p.refresh_interval_ms = android.INTERVAL_REGION_MS
        p:stroke_refresh(1, 2, 3, 4)
        assert.is_nil(android.region_refresh)
        assert.are.equal(100, p.refresh_interval_ms)
        assert.are.same({ { "fast", 1, 2, 3, 4 } }, calls)
        assert.are.equal(1, android.region_failures)
        assert.truthy(android.region_error:find("window gone", 1, true))
        assert.are.equal(0, #shown)                    -- one failure: no nagging yet
        -- Next stroke: the path is tried again and, when it installs, used.
        local installed = function() table.insert(calls, { "region" }) end
        android.install = function() return installed end
        android.strokeStart(p)
        assert.are.equal(installed, android.region_refresh)
        assert.are.equal(android.INTERVAL_REGION_MS, p.refresh_interval_ms)
        p:stroke_refresh(5, 6, 7, 8)
        assert.are.same({ "region" }, calls[2])
        -- A clean stroke on the region path forgives the failure.
        android.strokeEnd(p)
        assert.are.equal(0, android.region_failures)
        assert.is_nil(android.region_error)
    end)

    it("gives up and says so after repeated failures, until the option is toggled", function()
        local p = new_plugin({ fast_refresh = true })
        android.setup(p)
        local throwing = function() error("window gone") end
        android.install = function() return throwing end
        for i = 1, android.MAX_REGION_FAILURES do
            android.strokeStart(p)
            if i == 1 then android.region_refresh = throwing; p.refresh_interval_ms = android.INTERVAL_REGION_MS end
            assert.are.equal(throwing, android.region_refresh)
            p:stroke_refresh(1, 2, 3, 4)
            android.strokeEnd(p)
            assert.is_nil(android.region_refresh)
            assert.are.equal(i, android.region_failures)
        end
        assert.are.equal(1, #shown)
        assert.truthy(shown[1].text:find("fast refresh stopped", 1, true))
        -- Past the limit, strokes no longer retry and do not nag again.
        android.strokeStart(p)
        assert.is_nil(android.region_refresh)
        p:stroke_refresh(1, 2, 3, 4)
        assert.are.equal(1, #shown)
        assert.are.equal(android.MAX_REGION_FAILURES, android.region_failures)
        -- Toggling calls setup, which starts over.
        android.setup(p)
        assert.are.equal(0, android.region_failures)
        assert.is_nil(android.region_error)
    end)

    it("keeps the saved e-ink cadence", function()
        local p = new_plugin({ eink_every = 4 })
        android.setup(p)
        assert.are.equal(4, android.eink_every)
    end)

    it("passes stylus slots through to the plugin", function()
        local p = new_plugin({})
        android.setup(p)
        local got
        p.handleStylusSlot = function(_, input, slot) got = slot; return true end
        assert.is_true(android.handleSlot(p, nil, { id = 1 }))
        assert.are.same({ id = 1 }, got)
    end)

    it("adds its entries to the Experimental menu", function()
        local p = new_plugin({})
        android.setup(p)
        local items = android.menuItems(p)
        assert.are.equal("Android fast refresh", items[1].text)
        assert.is_false(items[1].checked_func())
    end)
end)
