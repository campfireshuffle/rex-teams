-- Reads Rex's format="vt" output into rows of styled cells. Rex writes only
-- SGR (m), cursor-forward (C), \r\n between rows and OSC 8 links, so this is
-- all a screen read needs. Pure Lua; pane.lua and vendors.lua use it.
local vt = {}

local function sgr(st, params)
  local p = {}
  for n in (params == "" and "0" or params):gmatch("[^;]+") do p[#p + 1] = n end
  local i = 1
  while i <= #p do
    local raw = p[i]
    local n = tonumber(raw:match("^(%d+)")) or 0
    if raw:find(":") then -- colon subparameters, such as 4:3 or 38:2::r:g:b
      if n == 38 then st.fg = raw elseif n == 48 then st.bg = raw elseif n == 4 then st.ul = raw ~= "4:0" end
    elseif n == 0 then st.bold, st.dim, st.italic, st.ul, st.inv, st.fg, st.bg = nil, nil, nil, nil, nil, nil, nil
    elseif n == 1 then st.bold = true
    elseif n == 2 then st.dim = true
    elseif n == 3 then st.italic = true
    elseif n == 4 then st.ul = true
    elseif n == 7 then st.inv = true
    elseif n == 22 then st.bold, st.dim = nil, nil
    elseif n == 23 then st.italic = nil
    elseif n == 24 then st.ul = nil
    elseif n == 27 then st.inv = nil
    elseif n == 38 or n == 48 then
      local v
      if p[i + 1] == "2" then v = table.concat({ p[i + 2] or "", p[i + 3] or "", p[i + 4] or "" }, ","); i = i + 4
      elseif p[i + 1] == "5" then v = "i" .. tostring(p[i + 2]); i = i + 2 end
      if n == 38 then st.fg = v else st.bg = v end
    elseif n == 39 then st.fg = nil
    elseif n == 49 then st.bg = nil
    elseif (n >= 30 and n <= 37) or (n >= 90 and n <= 97) then st.fg = "a" .. n
    elseif (n >= 40 and n <= 47) or (n >= 100 and n <= 107) then st.bg = "a" .. n
    end
    i = i + 1
  end
end

local function copy(st)
  return { bold = st.bold, dim = st.dim, italic = st.italic, ul = st.ul, inv = st.inv, fg = st.fg, bg = st.bg }
end

-- rows[i] = { {ch=, bold=, dim=, inv=, fg=, bg=, ...}, ... }
function vt.parse(s)
  local rows, row, st = {}, {}, {}
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    if c == 27 then
      local nx = s:sub(i + 1, i + 1)
      if nx == "[" then
        local j = i + 2
        while j <= n and not s:sub(j, j):match("[@-~]") do j = j + 1 end
        local params, final = s:sub(i + 2, j - 1), s:sub(j, j)
        if final == "m" then sgr(st, params)
        elseif final == "C" then
          for _ = 1, tonumber(params) or 1 do row[#row + 1] = { ch = " ", bg = st.bg, inv = st.inv } end
        end
        i = j + 1
      elseif nx == "]" then -- OSC, ended by BEL or ST
        local j = i + 2
        while j <= n do
          local b = s:byte(j)
          if b == 7 then break end
          if b == 27 and s:sub(j + 1, j + 1) == "\\" then j = j + 1; break end
          j = j + 1
        end
        i = j + 1
      else
        i = i + 2
      end
    elseif c == 10 then rows[#rows + 1] = row; row = {}; i = i + 1
    elseif c < 32 then i = i + 1
    else
      local len = c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4
      local cell = copy(st)
      cell.ch = s:sub(i, i + len - 1)
      row[#row + 1] = cell
      i = i + len
    end
  end
  rows[#rows + 1] = row
  return rows
end

-- The visible screen: the last HEIGHT rows. Rex ends the output without a
-- newline, so the last row is the screen's last row.
function vt.screen(s, height)
  local rows = vt.parse(s)
  local out = {}
  for i = math.max(1, #rows - height + 1), #rows do out[#out + 1] = rows[i] end
  return out
end

function vt.text(row, a, b)
  local t = {}
  for k = a or 1, b or #row do t[#t + 1] = row[k] and row[k].ch or "" end
  return table.concat(t)
end

-- The index of a row's first non-blank cell.
function vt.first(row)
  for i, c in ipairs(row) do if c.ch ~= " " then return i end end
end

-- A row that is mostly a horizontal rule.
function vt.rule(row)
  local n = 0
  for _, c in ipairs(row) do if c.ch == "─" then n = n + 1 end end
  return n >= 20 and n >= #row * 0.6
end

-- The text on rows A..B from column COL on, split into what ISDIM calls a
-- placeholder and the rest. Inverse cells are a drawn cursor and are skipped.
-- Runs of blanks collapse to one space.
function vt.collect(rows, a, b, col, isdim)
  local text, dim = {}, {}
  for r = a, b do
    for i = col, #rows[r] do
      local c = rows[r][i]
      if not c.inv then
        local t = isdim(c) and dim or text
        t[#t + 1] = c.ch
      end
    end
    text[#text + 1] = " "
    dim[#dim + 1] = " "
  end
  local function norm(t) return (table.concat(t):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end
  return { text = norm(text), dim = norm(dim), top = a, bottom = b }
end

return vt
