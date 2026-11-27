-- Run from the repo root with `luajit tests/checks/removal.lua [BASE]`. BASE is
-- a git revision; it defaults to where this branch left main. It needs git
-- history, so it's a pre-merge check, not a CI test (CI runs tests/*.lua on
-- a shallow checkout).
-- A name that the scripts' code had at BASE and has no longer must not be
-- mentioned by the docs, the tests or the scripts' comments. Every
-- fix-induced defect in loop 2 was a removal that a reader or a doc still
-- used (step, serve, notice). Prose removals, like "team.lua shows counts",
-- aren't names; the gate greps the release notes for those.
local function sh(cmd)
  local p = assert(io.popen(cmd .. " 2>/dev/null"))
  local out = p:read("*a")
  p:close()
  return out
end
local function read(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local base = arg[1] or sh("git merge-base HEAD main"):match("%x+")
assert(base and sh("git cat-file -t " .. base):match("commit"), "no base revision: pass one, e.g. luajit tests/checks/removal.lua main")

-- Words that stay in use under another meaning. Each one says why.
local allowed = {
  load = true, -- the tests' own load() helpers and Lua's load, not the old script function
}

-- Lua with strings and comments taken out, so only code names count.
local function code(src)
  return (src:gsub("%-%-%[%[.-%]%]", ""):gsub('"[^"\n]*"', ""):gsub("'[^'\n]*'", ""):gsub("%-%-[^\n]*", ""))
end
local function comments(src)
  local out = {}
  for c in src:gsub('"[^"\n]*"', ""):gsub("'[^'\n]*'", ""):gmatch("%-%-([^\n]*)") do out[#out + 1] = c end
  return table.concat(out, "\n")
end
-- Functions, and the fields of our own tables: a message (msg, d, to,
-- from) and the modules. Fields of Rex's replies aren't ours to remove.
local owners = { msg = true, d = true, to = true, from = true, M = true, lib = true, mail = true, pane = true, postman = true }
local function names(src)
  local found = {}
  src = code(src)
  local function add(n, kind) found[n] = found[n] or {} found[n][kind] = true end
  for n in src:gmatch("function [%w_]+[.:]([%w_]+)%(") do add(n, "fn") end
  for n in src:gmatch("local function ([%w_]+)%(") do add(n, "fn") end
  for owner, n in src:gmatch("%f[%w_]([%w_]+)%.([%a_][%w_]*)") do
    if owners[owner] then add(n, "field") end
  end
  return found
end
local function words(src)
  local found = {}
  for n in code(src):gmatch("[%a_][%w_]*") do found[n] = true end
  return found
end

local dir = "skills/rex-teams/scripts/"
local was, scripts_then = {}, {}
for path in sh("git ls-tree --name-only " .. base .. " " .. dir):gmatch("[^\n]+") do
  if path:match("%.lua$") then
    scripts_then[path:match("[^/]+$")] = true
    for n, kind in pairs(names(sh("git show " .. base .. ":" .. path))) do
      was[n] = was[n] or {}
      for k in pairs(kind) do was[n][k] = true end
    end
  end
end
local now, readers = {}, {}
for name in sh("ls " .. dir):gmatch("[^\n]+") do
  if name:match("%.lua$") then
    local src = assert(read(dir .. name))
    for n in pairs(words(src)) do now[n] = true end
    readers[#readers + 1] = { dir .. name .. " (comments)", comments(src) }
    scripts_then[name] = nil
  end
end

local gone = {}
for n, kind in pairs(was) do
  if #n >= 3 and not now[n] and not allowed[n] then gone[#gone + 1] = { name = n, kind = kind } end
end
table.sort(gone, function(a, b) return a.name < b.name end)
-- A whole script that went is a removed name too: vt.lua, say.
local gone_files = {}
for name in pairs(scripts_then) do gone_files[#gone_files + 1] = name end
table.sort(gone_files)

for _, path in ipairs({ "README.md", "ARCHITECTURE.md", "skills/rex-teams/SKILL.md", dir .. "report.md" }) do
  readers[#readers + 1] = { path, assert(read(path), path) }
end
for name in sh("ls tests"):gmatch("[^\n]+") do
  if name:match("%.lua$") then readers[#readers + 1] = { "tests/" .. name, read("tests/" .. name), lua = true } end
end
readers[#readers + 1] = { "tests/live/battery.lua", read("tests/live/battery.lua"), lua = true }

-- A mention is the name used as code: name( for a function, .name for a
-- field (a Rex reply's .records isn't alarm.lua's old records()), or
-- `name` in a doc.
local function mentions(text, gone)
  local n = gone.name
  local lines = {}
  local i = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    i = i + 1
    if gone.kind.fn and line:find("%f[%w_]" .. n .. "%(") or gone.kind.field and line:find("[%w_%]%)]%." .. n .. "%f[^%w_]")
      or line:find("`" .. n .. "[`(]") then
      lines[#lines + 1] = i
    end
  end
  return lines
end

local hits = {}
for _, r in ipairs(readers) do
  if r[2] then
    -- In a test, a string like "block:gone" is data, not a name.
    local text = r.lua and r[2]:gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''") or r[2]
    for _, n in ipairs(gone) do
      local lines = mentions(text, n)
      if #lines > 0 then hits[#hits + 1] = r[1] .. ":" .. table.concat(lines, ",") .. " names " .. n.name .. ", which the scripts no longer have" end
    end
    for _, f in ipairs(gone_files) do
      if r[2]:find(f, 1, true) then hits[#hits + 1] = r[1] .. " names " .. f .. ", which is gone" end
    end
  end
end
for _, h in ipairs(hits) do print("not ok - " .. h) end
if #hits > 0 then os.exit(1) end
print("Passed: no doc, test or comment names any of the " .. #gone .. " names removed since " .. base:sub(1, 7) .. ".")
