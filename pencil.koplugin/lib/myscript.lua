-- myscript_koreader.lua
-- MyScript iink REST API v4 client for KOReader plugins.
-- Intended location: plugins/<your-plugin>.koplugin/lib/myscript.lua

local bit = require("bit")
local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local sha2 = require("ffi/sha2")
local socketutil = require("socketutil")

local MyScript = {}
MyScript.__index = MyScript

local DEFAULT_ENDPOINT = "https://cloud.myscript.com/api/v4.0/iink/recognize"
local DEFAULT_SCALE = 25.4 / 96

local function nonempty(value)
    return type(value) == "string" and value ~= ""
end

local function trim(value)
    if type(value) ~= "string" then return value end
    return value:match("^%s*(.-)%s*$")
end

local function copy_array(values)
    local result = {}
    for i, value in ipairs(values or {}) do result[i] = value end
    return result
end

local function hex_to_binary(value)
    return (value:gsub("%x%x", function(byte)
        return string.char(tonumber(byte, 16))
    end))
end

local function xor_byte_string(value, byte)
    local result = {}
    for i = 1, #value do
        result[i] = string.char(bit.bxor(value:byte(i), byte))
    end
    return table.concat(result)
end

local function sha512_binary(value)
    local update = sha2.sha512()
    update(value)
    return hex_to_binary(update())
end

-- HMAC-SHA512, implemented on top of the SHA-512 implementation bundled with koreader-base.
local function hmac_sha512_hex(key, payload)
    local block_size = 128
    if #key > block_size then key = sha512_binary(key) end
    key = key .. string.rep("\0", block_size - #key)
    local inner = sha512_binary(xor_byte_string(key, 0x36) .. payload)
    local digest = sha512_binary(xor_byte_string(key, 0x5c) .. inner)
    return (digest:gsub(".", function(char)
        return string.format("%02x", char:byte())
    end))
end

local function decode_error(body, status)
    if nonempty(body) then
        local ok, decoded = pcall(JSON.decode, body)
        if ok and type(decoded) == "table" then
            if nonempty(decoded.message) then return decoded.message end
            if nonempty(decoded.error) then return decoded.error end
            if type(decoded.error) == "table" and nonempty(decoded.error.message) then
                return decoded.error.message
            end
        end
        return trim(body)
    end
    return status or "Unknown MyScript API error"
end

local function parse_coordinate_string(value)
    if not nonempty(value) then return nil, "p must be a non-empty coordinate string" end
    local numbers = {}
    for token in value:gmatch("%S+") do
        local number = tonumber(token)
        if not number then return nil, "Invalid coordinate: " .. token end
        numbers[#numbers + 1] = number
    end
    if #numbers == 0 or #numbers % 2 ~= 0 then
        return nil, "A stroke must contain x/y coordinate pairs"
    end
    local stroke = { x = {}, y = {} }
    for i = 1, #numbers, 2 do
        stroke.x[#stroke.x + 1] = numbers[i]
        stroke.y[#stroke.y + 1] = numbers[i + 1]
    end
    return stroke
end

local function find_strokes(input)
    if type(input) ~= "table" then return nil end
    if type(input.strokes) == "table" then return input.strokes end
    if type(input.stroke) == "table" then return input.stroke end
    if type(input.ink) == "table" and type(input.ink.strokes) == "table" then return input.ink.strokes end
    if type(input[1]) == "table" then return input end
end

local function annotation_indices(input, group_index)
    local groups = input.annotation_groups or input.annotationGroups
    local group = type(groups) == "table" and groups[group_index] or nil
    if type(group) ~= "table" then return nil end
    return group.stroke_indices or group.strokeIndices
end

local function convert_stroke(source, default_pointer_type, default_pointer_id)
    if type(source) ~= "table" then return nil, "Stroke is not a table" end
    local result, err
    local coordinates = source.p or source.points or source.coordinates
    if type(coordinates) == "string" then
        result, err = parse_coordinate_string(coordinates)
    elseif type(coordinates) == "table" and type(coordinates[1]) == "table" then
        result = { x = {}, y = {} }
        for i, point in ipairs(coordinates) do
            local x, y = tonumber(point.x), tonumber(point.y)
            if not x or not y then return nil, "Invalid point at index " .. tostring(i) end
            result.x[#result.x + 1], result.y[#result.y + 1] = x, y
        end
    elseif type(source.x) == "table" and type(source.y) == "table" then
        result = { x = copy_array(source.x), y = copy_array(source.y) }
    else
        return nil, "Stroke has neither points, a coordinate string, nor x/y arrays"
    end
    if not result then return nil, err end
    if #result.x == 0 or #result.x ~= #result.y then
        return nil, "Stroke x/y arrays are empty or have different lengths"
    end
    if type(source.pressure) == "table" and #source.pressure == #result.x then result.p = copy_array(source.pressure) end
    local times = source.t or source.timestamps
    if type(times) == "table" and #times == #result.x then result.t = copy_array(times) end
    if source.id ~= nil then result.id = tostring(source.id) end
    if source.fullStrokeId ~= nil then result.fullStrokeId = tostring(source.fullStrokeId) end
    result.pointerType = source.pointerType or source.pointer_type or default_pointer_type or "PEN"
    result.pointerId = source.pointerId or source.pointer_id or default_pointer_id or 0
    return result
end

MyScript.parse_coordinate_string = parse_coordinate_string

function MyScript.strokes_from_pencil(input, options)
    options = options or {}
    local source = find_strokes(input)
    if type(source) ~= "table" then return nil, { kind = "validation", message = "No stroke table found in input" } end
    local indices = annotation_indices(input, options.group_index or 1)
    local result = {}
    local function append(item, label)
        local stroke, err = convert_stroke(item, options.pointer_type or options.tool, options.pointer_id)
        if not stroke then return nil, "Cannot convert stroke " .. tostring(label) .. ": " .. tostring(err) end
        result[#result + 1] = stroke
        return true
    end
    if type(indices) == "table" and #indices > 0 then
        local zero_based = false
        for _, index in ipairs(indices) do if index == 0 then zero_based = true break end end
        for _, index in ipairs(indices) do
            local item = source[zero_based and index + 1 or index]
            if not item then return nil, { kind = "validation", message = "Missing referenced stroke " .. tostring(index) } end
            local ok, err = append(item, index)
            if not ok then return nil, { kind = "validation", message = err } end
        end
    else
        for i, item in ipairs(source) do
            local ok, err = append(item, i)
            if not ok then return nil, { kind = "validation", message = err } end
        end
    end
    if #result == 0 then return nil, { kind = "validation", message = "Input contains no strokes" } end
    return result
end

local function post(url, payload, headers, block_timeout, total_timeout)
    headers["Content-Length"] = tostring(#payload)
    headers["Connection"] = "close"
    local chunks = {}
    socketutil:set_timeout(block_timeout, total_timeout)
    local ok, result, code, response_headers, status = pcall(http.request, {
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(chunks),
    })
    socketutil:reset_timeout()
    local body = table.concat(chunks)
    if not ok then return nil, { kind = "transport", message = "HTTP request failed: " .. tostring(result), body = body } end
    if result == nil then return nil, { kind = "transport", message = "HTTP request failed: " .. tostring(code or status), body = body } end
    code = tonumber(code)
    if not code then return nil, { kind = "transport", message = "Invalid HTTP status", status = status, body = body } end
    return { code = code, headers = response_headers or {}, status = status, body = body }
end

function MyScript.new(options)
    options = options or {}
    local application_key = options.application_key or options.applicationKey
    local hmac_key = options.hmac_key or options.hmacKey
    if not nonempty(application_key) then return nil, "application_key is required" end
    if not nonempty(hmac_key) then return nil, "hmac_key is required" end
    local endpoint = options.endpoint or DEFAULT_ENDPOINT
    if not endpoint:match("^https://") then return nil, "endpoint must use HTTPS" end
    return setmetatable({
        application_key = application_key,
        hmac_key = hmac_key,
        endpoint = endpoint,
        language = options.language or options.lang or "en_US",
        content_type = options.content_type or options.contentType or "Text",
        scale_x = options.scale_x or options.scaleX or DEFAULT_SCALE,
        scale_y = options.scale_y or options.scaleY or DEFAULT_SCALE,
        client_name = options.client_name or "koreader-myscript-plugin",
        client_version = options.client_version or "1.0.0",
        block_timeout = options.block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
        total_timeout = options.total_timeout or socketutil.LARGE_TOTAL_TIMEOUT,
    }, MyScript)
end

function MyScript:recognize(strokes, options)
    options = options or {}
    if type(strokes) ~= "table" or #strokes == 0 then return nil, { kind = "validation", message = "At least one stroke is required" } end
    local request_body = {
        contentType = options.content_type or options.contentType or self.content_type,
        strokes = strokes,
        configuration = options.configuration or { lang = options.language or options.lang or self.language },
        scaleX = options.scale_x or options.scaleX or self.scale_x,
        scaleY = options.scale_y or options.scaleY or self.scale_y,
    }
    local ok, payload = pcall(JSON.encode, request_body)
    if not ok then return nil, { kind = "json", message = "Cannot encode JSON: " .. tostring(payload) } end
    local signature = hmac_sha512_hex(self.application_key .. self.hmac_key, payload)
    local response, err = post(self.endpoint, payload, {
        ["Accept"] = "text/plain, application/json",
        ["Content-Type"] = "application/json",
        ["applicationKey"] = self.application_key,
        ["hmac"] = signature,
        ["myscript-client-name"] = self.client_name,
        ["myscript-client-version"] = self.client_version,
    }, options.block_timeout or self.block_timeout, options.total_timeout or self.total_timeout)
    if not response then return nil, err end
    if response.code < 200 or response.code >= 300 then
        return nil, { kind = "http", code = response.code, status = response.status, headers = response.headers, body = response.body, message = decode_error(response.body, response.status) }
    end
    return response.body, nil, response
end

function MyScript:recognize_text(strokes, options)
    local body, err, response = self:recognize(strokes, options)
    if not body then return nil, err end
    local content_type = response.headers["content-type"] or response.headers["Content-Type"] or ""
    if content_type:lower():find("application/json", 1, true) then
        local ok, decoded = pcall(JSON.decode, body)
        if ok and type(decoded) == "table" then
            if nonempty(decoded.text) then return decoded.text, nil, decoded end
            if nonempty(decoded.result) then return decoded.result, nil, decoded end
        end
    end
    return trim(body), nil, response
end

return MyScript
