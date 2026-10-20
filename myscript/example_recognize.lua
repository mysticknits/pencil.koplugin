-- example_recognize.lua
-- Usage: lua example_recognize.lua pencil_strokes.lua [ca_bundle]

local MyScript = require("myscript")

local input_file = arg[1]
if not input_file then
    io.stderr:write("Usage: lua example_recognize.lua pencil_strokes.lua [ca_bundle]\n")
    os.exit(1)
end

local ca_bundle = arg[2] or "/etc/ssl/certs/ca-certificates.crt"
local application_key = os.getenv("MYSCRIPT_APPLICATION_KEY")
local hmac_key = os.getenv("MYSCRIPT_HMAC_KEY")
local language = os.getenv("MYSCRIPT_LANGUAGE") or "fr_FR"
local debug = os.getenv("MYSCRIPT_DEBUG") == "1"

if not application_key or application_key == "" then
    io.stderr:write("ERROR: MYSCRIPT_APPLICATION_KEY is not defined\n")
    os.exit(1)
end
if not hmac_key or hmac_key == "" then
    io.stderr:write("ERROR: MYSCRIPT_HMAC_KEY is not defined\n")
    os.exit(1)
end
local f = io.open(ca_bundle, "rb")
if not f then
    io.stderr:write("ERROR: CA bundle not found: " .. ca_bundle .. "\n")
    os.exit(1)
end
f:close()

print("Loading strokes from: " .. input_file)
print("Language: " .. language)
print("CA bundle: " .. ca_bundle)

local ok, pencil = pcall(dofile, input_file)
if not ok then
    io.stderr:write("ERROR: cannot load input: " .. tostring(pencil) .. "\n")
    os.exit(1)
end

local client = MyScript.new({
    application_key = application_key,
    hmac_key = hmac_key,
    ca_file = ca_bundle,
    language = language,
    debug = debug
    -- If required by an old LuaSec build, add: protocol = "tlsv1_2"
})

local convert_ok, strokes = pcall(MyScript.strokes_from_pencil, pencil, {
    group_index = 1,
    pointer_type = "PEN",
    pointer_id = 0
})
if not convert_ok then
    io.stderr:write("ERROR: " .. tostring(strokes) .. "\n")
    os.exit(1)
end

print(string.format("Loaded %d strokes", #strokes))
for i = 1, math.min(3, #strokes) do
    print(string.format("Stroke %d: x=%d, y=%d", i, #strokes[i].x, #strokes[i].y))
end

local text, err = client:recognize_text(strokes, {
    lang = language,
    scale_x = 25.4 / 96,
    scale_y = 25.4 / 96,
    debug = debug
})

if not text then
    io.stderr:write("\nRecognition failed\n")
    io.stderr:write("Message : " .. tostring(err.message) .. "\n")
    if err.kind then io.stderr:write("Kind    : " .. tostring(err.kind) .. "\n") end
    if err.code then io.stderr:write("HTTP    : " .. tostring(err.code) .. "\n") end
    if err.body and err.body ~= "" then
        io.stderr:write("\nServer response:\n" .. tostring(err.body) .. "\n")
    end
    os.exit(1)
end

print("\nRecognized text")
print("----------------------------------------")
print(text)
print("----------------------------------------")
