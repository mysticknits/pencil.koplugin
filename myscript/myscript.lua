-- myscript.lua
-- Lua client for MyScript iink REST API v4.
local https = require("ssl.https")
local ltn12 = require("ltn12")
local cjson = require("cjson.safe")
local hmac = require("openssl.hmac")

local MyScript = {}
MyScript.__index = MyScript

local DEFAULT_ENDPOINT = "https://cloud.myscript.com/api/v4.0/iink/recognize"
local DEFAULT_CA_FILE = "/etc/ssl/certs/ca-certificates.crt"
local DEFAULT_SCALE = 25.4 / 96

local function nonempty(value)
    return type(value) == "string" and value ~= ""
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
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

local function hex(value)
    return (value:gsub(".", function(char)
        return string.format("%02x", string.byte(char))
    end))
end

local function compute_hmac(application_key, hmac_key, payload)
    local context, err = hmac.new(application_key .. hmac_key, "sha512")
    if not context then
        return nil, "Cannot initialize HMAC-SHA512: " .. tostring(err)
    end

    local ok, update_err = context:update(payload)
    if not ok then
        return nil, "Cannot update HMAC-SHA512: " .. tostring(update_err)
    end

    local digest, final_err = context:final()
    if not digest then
        return nil, "Cannot finalize HMAC-SHA512: " .. tostring(final_err)
    end

    return hex(digest)
end

local function decode_error(body, status)
    local decoded = cjson.decode(body or "")
    if type(decoded) == "table" then
        if nonempty(decoded.message) then return decoded.message end
        if nonempty(decoded.error) then return decoded.error end
        if type(decoded.error) == "table" and nonempty(decoded.error.message) then
            return decoded.error.message
        end
    end

    if nonempty(body) then return trim(body) end
    return status or "Unknown MyScript API error"
end

local function parse_coordinate_string(value)
    if not nonempty(value) then
        return nil, "p must be a non-empty coordinate string"
    end

    local numbers = {}
    for token in value:gmatch("%S+") do
        local number = tonumber(token)
        if not number then return nil, "Invalid coordinate: " .. token end
        numbers[#numbers + 1] = number
    end

    if #numbers == 0 or #numbers % 2 ~= 0 then
        return nil, "A stroke must contain x/y coordinate pairs"
    end

    local stroke = {x = {}, y = {}}
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
    if type(input.ink) == "table" and type(input.ink.strokes) == "table" then
        return input.ink.strokes
    end
    if type(input[1]) == "table" then return input end
end

local function annotation_indices(input, group_index)
    local groups = input.annotation_groups or input.annotationGroups
    if type(groups) ~= "table" then return nil end

    local group = groups[group_index]
    if type(group) ~= "table" then return nil end

    return group.stroke_indices or group.strokeIndices
end

local function convert_stroke(source, default_pointer_type, default_pointer_id)
    if type(source) ~= "table" then return nil, "Stroke is not a table" end

    local result, err
    local coordinates = source.p or source.points or source.coordinates
    if type(coordinates) == "string" then
        result, err = parse_coordinate_string(coordinates)
    elseif type(source.x) == "table" and type(source.y) == "table" then
        result = {x = copy_array(source.x), y = copy_array(source.y)}
    else
        return nil, "Stroke has neither a coordinate string nor x/y arrays"
    end

    if not result then return nil, err end
    if #result.x == 0 or #result.x ~= #result.y then
        return nil, "Stroke x/y arrays are empty or have different lengths"
    end

    -- source.p is a coordinate string, not pressure.
    if type(source.pressure) == "table" and #source.pressure == #result.x then
        result.p = copy_array(source.pressure)
    end

    local times = source.t or source.timestamps
    if type(times) == "table" and #times == #result.x then
        result.t = copy_array(times)
    end

    if source.id ~= nil then result.id = tostring(source.id) end
    if source.fullStrokeId ~= nil then
        result.fullStrokeId = tostring(source.fullStrokeId)
    end

    result.pointerType = source.pointerType
        or source.pointer_type
        or default_pointer_type
        or "PEN"
    result.pointerId = source.pointerId
        or source.pointer_id
        or default_pointer_id
        or 0

    return result
end

MyScript.parse_coordinate_string = parse_coordinate_string

function MyScript.strokes_from_pencil(input, options)
    options = options or {}

    local source = find_strokes(input)
    if type(source) ~= "table" then error("No stroke table found in input", 2) end

    local indices = annotation_indices(input, options.group_index or 1)
    local result = {}

    local function append(item, label)
        local stroke, err = convert_stroke(
            item,
            options.pointer_type or options.tool,
            options.pointer_id
        )
        if not stroke then
            error("Cannot convert stroke " .. tostring(label) .. ": " .. tostring(err), 3)
        end
        result[#result + 1] = stroke
    end

    if type(indices) == "table" and #indices > 0 then
        local zero_based = false
        for _, index in ipairs(indices) do
            if index == 0 then
                zero_based = true
                break
            end
        end

        for _, index in ipairs(indices) do
            local item = source[zero_based and index + 1 or index]
            if not item then error("Missing referenced stroke " .. tostring(index), 2) end
            append(item, index)
        end
    else
        for i, item in ipairs(source) do append(item, i) end
    end

    if #result == 0 then error("Input contains no strokes", 2) end
    return result
end

local function https_post(url, payload, headers, ca_file, protocol)
    if not file_exists(ca_file) then
        return nil, {
            kind = "tls_configuration",
            message = "CA bundle not found: " .. ca_file
        }
    end

    headers["content-length"] = tostring(#payload)
    headers["connection"] = "close"

    local chunks = {}
    local request = {
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(chunks),
        verify = "peer",
        cafile = ca_file,
        options = "all"
    }
    if nonempty(protocol) then request.protocol = protocol end

    local ok, result, code, response_headers, status = pcall(https.request, request)
    local body = table.concat(chunks)

    if not ok then
        return nil, {
            kind = "transport",
            message = "HTTPS request failed: " .. tostring(result),
            body = body
        }
    end
    if result == nil then
        return nil, {
            kind = "transport",
            message = "HTTPS request failed: " .. tostring(code or status),
            body = body
        }
    end

    code = tonumber(code)
    if not code then
        return nil, {
            kind = "transport",
            message = "Invalid HTTP status",
            status = status,
            body = body
        }
    end

    return {
        code = code,
        headers = response_headers or {},
        status = status,
        body = body
    }
end

function MyScript.new(options)
    options = options or {}

    local application_key = options.application_key or options.applicationKey
    local hmac_key = options.hmac_key or options.hmacKey
    if not nonempty(application_key) then error("application_key is required", 2) end
    if not nonempty(hmac_key) then error("hmac_key is required", 2) end

    local ca_file = options.ca_file or options.cafile or DEFAULT_CA_FILE
    if not file_exists(ca_file) then error("CA bundle not found: " .. ca_file, 2) end

    return setmetatable({
        application_key = application_key,
        hmac_key = hmac_key,
        endpoint = options.endpoint or DEFAULT_ENDPOINT,
        ca_file = ca_file,
        protocol = options.protocol,
        language = options.language or options.lang or "en_US",
        content_type = options.content_type or options.contentType or "Text",
        scale_x = options.scale_x or options.scaleX or DEFAULT_SCALE,
        scale_y = options.scale_y or options.scaleY or DEFAULT_SCALE,
        client_name = options.client_name or "lua-myscript-client",
        client_version = options.client_version or "1.0.0",
        debug = options.debug == true
    }, MyScript)
end

function MyScript:recognize(strokes, options)
    options = options or {}
    if type(strokes) ~= "table" or #strokes == 0 then
        return nil, {kind = "validation", message = "At least one stroke is required"}
    end

    local request_body = {
        contentType = options.content_type or options.contentType or self.content_type,
        strokes = strokes,
        configuration = {lang = options.language or options.lang or self.language},
        scaleX = options.scale_x or options.scaleX or self.scale_x,
        scaleY = options.scale_y or options.scaleY or self.scale_y
    }
    if type(options.configuration) == "table" then
        request_body.configuration = options.configuration
    end

    local payload, json_err = cjson.encode(request_body)
    if not payload then
        return nil, {kind = "json", message = "Cannot encode JSON: " .. tostring(json_err)}
    end

    if self.debug or options.debug then
        io.stderr:write("\nMyScript request JSON:\n", payload, "\n\n")
    end

    local signature, hmac_err = compute_hmac(
        self.application_key,
        self.hmac_key,
        payload
    )
    if not signature then
        return nil, {kind = "authentication", message = hmac_err}
    end

    local response, transport_err = https_post(self.endpoint, payload, {
        ["accept"] = "text/plain, application/json",
        ["content-type"] = "application/json",
        ["applicationkey"] = self.application_key,
        ["hmac"] = signature,
        ["myscript-client-name"] = self.client_name,
        ["myscript-client-version"] = self.client_version
    }, self.ca_file, self.protocol)

    if not response then return nil, transport_err end
    if response.code < 200 or response.code >= 300 then
        return nil, {
            kind = "http",
            code = response.code,
            status = response.status,
            headers = response.headers,
            body = response.body,
            message = decode_error(response.body, response.status)
        }
    end

    return response.body, nil, response
end

function MyScript:recognize_text(strokes, options)
    local body, err, response = self:recognize(strokes, options)
    if not body then return nil, err end

    local content_type = ""
    if response and response.headers then
        content_type = response.headers["content-type"]
            or response.headers["Content-Type"]
            or ""
    end

    if content_type:lower():find("application/json", 1, true) then
        local decoded = cjson.decode(body)
        if type(decoded) == "table" then
            if nonempty(decoded.text) then return decoded.text, nil, decoded end
            if nonempty(decoded.result) then return decoded.result, nil, decoded end
        end
    end

    return trim(body), nil, response
end

return MyScript
