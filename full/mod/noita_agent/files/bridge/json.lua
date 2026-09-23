-- Minimal, dependency-free JSON encode/decode for the bridge.
-- Only what the RPC surface needs: objects, arrays, strings, numbers, booleans, null.

json = json or {}

local escape_map = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_char(c)
  return escape_map[c] or string.format("\\u%04x", string.byte(c))
end

local function encode_string(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

local function encode_number(n)
  if n ~= n or n == math.huge or n == -math.huge then return "null" end
  if math.floor(n) == n and math.abs(n) < 1e15 then
    return string.format("%d", n)
  end
  return string.format("%.6g", n)
end

local encode_value

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

encode_value = function(v, seen)
  local tv = type(v)
  if v == nil then return "null" end
  if tv == "boolean" then return v and "true" or "false" end
  if tv == "number" then return encode_number(v) end
  if tv == "string" then return encode_string(v) end
  if tv == "table" then
    seen = seen or {}
    if seen[v] then return '"<cycle>"' end
    seen[v] = true
    local out
    if is_array(v) then
      local parts = {}
      for i = 1, #v do parts[i] = encode_value(v[i], seen) end
      out = "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for k in pairs(v) do
        if type(k) == "string" or type(k) == "number" then keys[#keys + 1] = k end
      end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      local parts = {}
      for i = 1, #keys do
        local k = keys[i]
        parts[i] = encode_string(tostring(k)) .. ":" .. encode_value(v[k], seen)
      end
      out = "{" .. table.concat(parts, ",") .. "}"
    end
    seen[v] = nil
    return out
  end
  return "null"
end

function json.encode(v)
  local ok, res = pcall(encode_value, v)
  if ok then return res end
  return "null"
end

-- ---------------------------------------------------------------- decode

local decode_value

local function skip_ws(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return j + 1
end

local function decode_string(s, i)
  local out = {}
  i = i + 1
  while true do
    local c = s:sub(i, i)
    if c == "" then error("unterminated string") end
    if c == '"' then return table.concat(out), i + 1 end
    if c == "\\" then
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        local hex = s:sub(i + 2, i + 5)
        local code = tonumber(hex, 16) or 63
        -- surrogate pair
        if code >= 0xD800 and code <= 0xDBFF and s:sub(i + 6, i + 7) == "\\u" then
          local low = tonumber(s:sub(i + 8, i + 11), 16) or 0
          code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
          i = i + 6
        end
        if code < 128 then
          out[#out + 1] = string.char(code)
        elseif code < 2048 then
          out[#out + 1] = string.char(192 + math.floor(code / 64), 128 + code % 64)
        elseif code < 65536 then
          out[#out + 1] = string.char(224 + math.floor(code / 4096),
            128 + math.floor(code / 64) % 64, 128 + code % 64)
        else
          out[#out + 1] = string.char(240 + math.floor(code / 262144),
            128 + math.floor(code / 4096) % 64,
            128 + math.floor(code / 64) % 64, 128 + code % 64)
        end
        i = i + 6
      else
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        out[#out + 1] = map[e] or e
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

local function decode_number(s, i)
  local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  local n = tonumber(num)
  if not n then error("bad number at " .. i) end
  return n, i + #num
end

local function decode_array(s, i)
  local arr = {}
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == "]" then return arr, i + 1 end
  while true do
    local v
    v, i = decode_value(s, i)
    arr[#arr + 1] = v
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "," then
      i = skip_ws(s, i + 1)
    elseif c == "]" then
      return arr, i + 1
    else
      error("expected , or ] at " .. i)
    end
  end
end

local function decode_object(s, i)
  local obj = {}
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == "}" then return obj, i + 1 end
  while true do
    local key
    if s:sub(i, i) ~= '"' then error("expected key at " .. i) end
    key, i = decode_string(s, i)
    i = skip_ws(s, i)
    if s:sub(i, i) ~= ":" then error("expected : at " .. i) end
    i = skip_ws(s, i + 1)
    local v
    v, i = decode_value(s, i)
    obj[key] = v
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "," then
      i = skip_ws(s, i + 1)
    elseif c == "}" then
      return obj, i + 1
    else
      error("expected , or } at " .. i)
    end
  end
end

decode_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then return decode_object(s, i) end
  if c == "[" then return decode_array(s, i) end
  if c == '"' then return decode_string(s, i) end
  if c == "t" and s:sub(i, i + 3) == "true" then return true, i + 4 end
  if c == "f" and s:sub(i, i + 4) == "false" then return false, i + 5 end
  if c == "n" and s:sub(i, i + 3) == "null" then return nil, i + 4 end
  if c == "" then error("unexpected end of input") end
  return decode_number(s, i)
end

function json.decode(s)
  if type(s) ~= "string" or s == "" then return nil, "empty" end
  local ok, res, err = pcall(function()
    local v = decode_value(s, 1)
    return v
  end)
  if not ok then return nil, tostring(res) end
  return res
end

return json
