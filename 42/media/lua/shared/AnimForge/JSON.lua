AnimForge = AnimForge or {}
AnimForge.JSON = {}

local function escapeString(s)
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, "\"", "\\\"")
    s = string.gsub(s, "\n", "\\n")
    s = string.gsub(s, "\r", "\\r")
    s = string.gsub(s, "\t", "\\t")
    return s
end

local function isArrayLike(t)
    local maxN = 0
    local count = 0
    for k, _ in pairs(t) do
        count = count + 1
        if type(k) ~= "number" then return false end
        if k > maxN then maxN = k end
    end
    return count == maxN
end

local encodeValue
local function encodeArray(t)
    local parts = {}
    for i = 1, #t do
        parts[i] = encodeValue(t[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function encodeObject(t)
    local parts = {}
    local i = 0
    for k, v in pairs(t) do
        i = i + 1
        parts[i] = "\"" .. escapeString(tostring(k)) .. "\":" .. encodeValue(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encodeValue = function(v)
    local tp = type(v)
    if tp == "nil" then return "null" end
    if tp == "boolean" then if v then return "true" else return "false" end end
    if tp == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    end
    if tp == "string" then return "\"" .. escapeString(v) .. "\"" end
    if tp == "table" then
        if isArrayLike(v) then return encodeArray(v) end
        return encodeObject(v)
    end
    return "null"
end

function AnimForge.JSON.encode(v)
    return encodeValue(v)
end

local src
local pos

local function skipWS()
    while pos <= #src do
        local c = string.sub(src, pos, pos)
        if c == " " or c == "\t" or c == "\n" or c == "\r" then
            pos = pos + 1
        else
            return
        end
    end
end

local function parseError(msg)
    error("AnimForge.JSON parse error at " .. pos .. ": " .. msg)
end

local function decodeString()
    if string.sub(src, pos, pos) ~= "\"" then parseError("expected string") end
    pos = pos + 1
    local parts = {}
    while pos <= #src do
        local c = string.sub(src, pos, pos)
        if c == "\"" then
            pos = pos + 1
            return table.concat(parts)
        end
        if c == "\\" then
            local nc = string.sub(src, pos + 1, pos + 1)
            if nc == "n" then parts[#parts + 1] = "\n"
            elseif nc == "r" then parts[#parts + 1] = "\r"
            elseif nc == "t" then parts[#parts + 1] = "\t"
            elseif nc == "\"" then parts[#parts + 1] = "\""
            elseif nc == "\\" then parts[#parts + 1] = "\\"
            elseif nc == "/" then parts[#parts + 1] = "/"
            elseif nc == "b" then parts[#parts + 1] = "\b"
            elseif nc == "f" then parts[#parts + 1] = "\f"
            elseif nc == "u" then
                local hex = string.sub(src, pos + 2, pos + 5)
                local n = tonumber(hex, 16)
                if n and n < 128 then
                    parts[#parts + 1] = string.char(n)
                else
                    parts[#parts + 1] = "?"
                end
                pos = pos + 4
            else
                parseError("bad escape \\" .. nc)
            end
            pos = pos + 2
        else
            parts[#parts + 1] = c
            pos = pos + 1
        end
    end
    parseError("unterminated string")
end

local function decodeNumber()
    local start = pos
    if string.sub(src, pos, pos) == "-" then pos = pos + 1 end
    while pos <= #src do
        local c = string.sub(src, pos, pos)
        if (c >= "0" and c <= "9") or c == "." or c == "e" or c == "E" or c == "+" or c == "-" then
            pos = pos + 1
        else
            break
        end
    end
    local n = tonumber(string.sub(src, start, pos - 1))
    if not n then parseError("bad number") end
    return n
end

local function decodeLiteral()
    if string.sub(src, pos, pos + 3) == "true" then pos = pos + 4; return true end
    if string.sub(src, pos, pos + 4) == "false" then pos = pos + 5; return false end
    if string.sub(src, pos, pos + 3) == "null" then pos = pos + 4; return nil end
    parseError("bad literal at '" .. string.sub(src, pos, pos + 4) .. "'")
end

local decodeValue
local function decodeArray()
    pos = pos + 1
    local t = {}
    skipWS()
    if string.sub(src, pos, pos) == "]" then pos = pos + 1; return t end
    while true do
        t[#t + 1] = decodeValue()
        skipWS()
        local c = string.sub(src, pos, pos)
        if c == "]" then pos = pos + 1; return t end
        if c ~= "," then parseError("expected ',' or ']'") end
        pos = pos + 1
        skipWS()
    end
end

local function decodeObject()
    pos = pos + 1
    local t = {}
    skipWS()
    if string.sub(src, pos, pos) == "}" then pos = pos + 1; return t end
    while true do
        skipWS()
        local k = decodeString()
        skipWS()
        if string.sub(src, pos, pos) ~= ":" then parseError("expected ':'") end
        pos = pos + 1
        skipWS()
        t[k] = decodeValue()
        skipWS()
        local c = string.sub(src, pos, pos)
        if c == "}" then pos = pos + 1; return t end
        if c ~= "," then parseError("expected ',' or '}'") end
        pos = pos + 1
    end
end

decodeValue = function()
    skipWS()
    local c = string.sub(src, pos, pos)
    if c == "{" then return decodeObject() end
    if c == "[" then return decodeArray() end
    if c == "\"" then return decodeString() end
    if c == "-" or (c >= "0" and c <= "9") then return decodeNumber() end
    return decodeLiteral()
end

function AnimForge.JSON.decode(s)
    src = s
    pos = 1
    return decodeValue()
end
