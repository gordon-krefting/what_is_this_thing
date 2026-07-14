-- Minimal JSON decoder (decode-only). Written for Lightroom's Lua 5.1 runtime;
-- avoid 5.2+-only syntax so it runs unmodified there.
local JSON = {}

local function skipWhitespace(s, i)
    local _, e = s:find('^[ \t\n\r]*', i)
    return e + 1
end

local parseValue

local escapes = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

local function utf8Encode(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(
            0xC0 + math.floor(code / 0x40),
            0x80 + (code % 0x40)
        )
    else
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40)
        )
    end
end

local function parseString(s, i)
    -- s:sub(i,i) == '"'
    i = i + 1
    local buf = {}
    while true do
        local c = s:sub(i, i)
        if c == '' then
            error('JSON parse error: unterminated string')
        elseif c == '"' then
            i = i + 1
            break
        elseif c == '\\' then
            local nc = s:sub(i + 1, i + 1)
            if nc == 'u' then
                local hex = s:sub(i + 2, i + 5)
                local code = tonumber(hex, 16) or 0
                buf[#buf + 1] = utf8Encode(code)
                i = i + 6
            elseif escapes[nc] then
                buf[#buf + 1] = escapes[nc]
                i = i + 2
            else
                buf[#buf + 1] = nc
                i = i + 2
            end
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    return table.concat(buf), i
end

local function parseNumber(s, i)
    local _, e, numStr = s:find('^(-?%d+%.?%d*[eE]?[+-]?%d*)', i)
    if not numStr then
        error('JSON parse error: invalid number at position ' .. i)
    end
    return tonumber(numStr), e + 1
end

local function parseArray(s, i)
    i = i + 1 -- skip '['
    local arr = {}
    i = skipWhitespace(s, i)
    if s:sub(i, i) == ']' then
        return arr, i + 1
    end
    while true do
        local value
        value, i = parseValue(s, i)
        arr[#arr + 1] = value
        i = skipWhitespace(s, i)
        local c = s:sub(i, i)
        if c == ',' then
            i = skipWhitespace(s, i + 1)
        elseif c == ']' then
            i = i + 1
            break
        else
            error('JSON parse error: expected , or ] at position ' .. i)
        end
    end
    return arr, i
end

local function parseObject(s, i)
    i = i + 1 -- skip '{'
    local obj = {}
    i = skipWhitespace(s, i)
    if s:sub(i, i) == '}' then
        return obj, i + 1
    end
    while true do
        i = skipWhitespace(s, i)
        if s:sub(i, i) ~= '"' then
            error('JSON parse error: expected string key at position ' .. i)
        end
        local key
        key, i = parseString(s, i)
        i = skipWhitespace(s, i)
        if s:sub(i, i) ~= ':' then
            error('JSON parse error: expected : at position ' .. i)
        end
        i = skipWhitespace(s, i + 1)
        local value
        value, i = parseValue(s, i)
        obj[key] = value
        i = skipWhitespace(s, i)
        local c = s:sub(i, i)
        if c == ',' then
            i = skipWhitespace(s, i + 1)
        elseif c == '}' then
            i = i + 1
            break
        else
            error('JSON parse error: expected , or } at position ' .. i)
        end
    end
    return obj, i
end

parseValue = function(s, i)
    i = skipWhitespace(s, i)
    local c = s:sub(i, i)
    if c == '"' then
        return parseString(s, i)
    elseif c == '{' then
        return parseObject(s, i)
    elseif c == '[' then
        return parseArray(s, i)
    elseif c == 't' and s:sub(i, i + 3) == 'true' then
        return true, i + 4
    elseif c == 'f' and s:sub(i, i + 4) == 'false' then
        return false, i + 5
    elseif c == 'n' and s:sub(i, i + 3) == 'null' then
        return nil, i + 4
    elseif c == '-' or c:match('%d') then
        return parseNumber(s, i)
    else
        error('JSON parse error: unexpected character "' .. c .. '" at position ' .. i)
    end
end

function JSON.decode(s)
    local value = parseValue(s, 1)
    return value
end

return JSON
