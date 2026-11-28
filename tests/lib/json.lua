-- A small JSON encoder and decoder standing in for rex.json in tests.
-- Keys are sorted, like Rex's encoder; a table with keys 1..n is an array.
local json = {}

local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do if t[i] == nil then return false end end
  return n > 0
end

function json.encode(v)
  local kind = type(v)
  if kind == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c) return ("\\u%04x"):format(c:byte()) end) .. '"'
  elseif kind == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then return ("%d"):format(v) end
    return ("%.17g"):format(v)
  elseif kind == "boolean" then return tostring(v)
  elseif kind == "nil" then return "null"
  end
  assert(kind == "table", "can't encode a " .. kind)
  if is_array(v) then
    local parts = {}
    for i = 1, #v do parts[i] = json.encode(v[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = json.encode(tostring(k)) .. ":" .. json.encode(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function json.decode(s)
  local i = 1
  local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
  local value
  local function str()
    local out = {}
    i = i + 1
    while true do
      local c = s:sub(i, i)
      if c == '"' then i = i + 1 return table.concat(out) end
      if c == "\\" then
        local e = s:sub(i + 1, i + 1)
        if e == "u" then
          local n = tonumber(s:sub(i + 2, i + 5), 16)
          if n < 0x80 then out[#out + 1] = string.char(n)
          elseif n < 0x800 then out[#out + 1] = string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64)
          else out[#out + 1] = string.char(0xE0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64) end
          i = i + 6
        else
          out[#out + 1] = ({ n = "\n", r = "\r", t = "\t", b = "\b", f = "\f" })[e] or e
          i = i + 2
        end
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end
  function value()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      local t = {}
      i = i + 1
      ws()
      if s:sub(i, i) == "}" then i = i + 1 return t end
      while true do
        ws()
        local k = str()
        ws()
        assert(s:sub(i, i) == ":", "bad JSON at " .. i)
        i = i + 1
        t[k] = value()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == "}" then return t end
        assert(d == ",", "bad JSON at " .. i)
      end
    elseif c == "[" then
      local t = {}
      i = i + 1
      ws()
      if s:sub(i, i) == "]" then i = i + 1 return t end
      while true do
        local v = value()
        if v ~= nil then t[#t + 1] = v end
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == "]" then return t end
        assert(d == ",", "bad JSON at " .. i)
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
    else
      local num = s:match("^-?[%d%.eE+-]+", i)
      i = i + #num
      return tonumber(num)
    end
  end
  return value()
end

return json
