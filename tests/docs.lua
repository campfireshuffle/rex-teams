-- Run from the repo root with `luajit tests/docs.lua` or `lua5.1 tests/docs.lua`.
-- SKILL.md claims checked against the scripts it describes.
local function read(path)
  local f = assert(io.open(path))
  local s = f:read("*a")
  f:close()
  return s
end
local skill = read("skills/rex-teams/SKILL.md")
local arch = read("ARCHITECTURE.md")
local count, failed = 0, 0
local function check(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if ok then print("ok " .. count .. " - " .. name) else
    failed = failed + 1
    print("not ok " .. count .. " - " .. name .. ": " .. tostring(err))
  end
end

check("SKILL.md quotes the kickoff as spawn.lua writes it", function()
  local expr = assert(read("skills/rex-teams/scripts/spawn.lua"):match("\nlocal kickoff = ([^\n]+)"), "spawn.lua has no kickoff line")
  local build = assert(loadstring("return " .. expr))
  setfenv(build, { prompt = "<task folder>/prompt.md" })
  local kickoff = build()
  assert(skill:find("`" .. kickoff .. "`", 1, true), "SKILL.md doesn't quote the kickoff: " .. kickoff)
end)

check("SKILL.md mentions -s only if one of its commands uses it", function()
  if not skill:find("`-s`", 1, true) then return end
  for block in skill:gmatch("```sh\n(.-)```") do
    if block:find("%s%-s%s") then return end
  end
  error("SKILL.md describes -s, but none of its commands uses it")
end)

check("every function ARCHITECTURE names for a script is defined in that script", function()
  -- Round 2's redo renamed the delivery policy to deliver(), and the doc kept the old name.
  -- Names come from the Components diagram, `postman.lua (deliver, ensure, run)`,
  -- and from each script's row in the File table, `name(` in code spans.
  local named = {}
  for script, list in arch:gmatch("(%w+)%.lua %(([^)]*)%)") do
    for name in list:gmatch("[%w_]+") do table.insert(named, { script, name }) end
  end
  for script, row in arch:gmatch("\n| `(%w+)%.lua` | ([^\n]*)") do
    for span in row:gmatch("`([^`]*)`") do
      for name in span:gmatch("([%w_.]+)%(") do table.insert(named, { script, name:match("[%w_]+$") }) end
    end
  end
  assert(#named > 0, "ARCHITECTURE.md names no script functions")
  for _, pair in ipairs(named) do
    local script, name = pair[1], pair[2]
    local code = read("skills/rex-teams/scripts/" .. script .. ".lua")
    assert(code:find("function [%w_]+%." .. name .. "%(") or code:find("local function " .. name .. "%("),
      "ARCHITECTURE.md names " .. name .. "() for " .. script .. ".lua, which doesn't define it")
  end
end)

if failed > 0 then os.exit(1) end
print("Passed " .. count .. " doc trials.")
