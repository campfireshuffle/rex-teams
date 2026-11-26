-- Run from the repo root with `luajit tests/docs.lua` or `lua5.1 tests/docs.lua`.
-- SKILL.md claims checked against the scripts it describes.
local function read(path)
  local f = assert(io.open(path))
  local s = f:read("*a")
  f:close()
  return s
end
local skill = read("skills/rex-teams/SKILL.md")
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
  rex = { json = dofile("tests/lib/json.lua"), args = {} }
  local lib = dofile("skills/rex-teams/scripts/lib.lua")
  local expr = assert(read("skills/rex-teams/scripts/spawn.lua"):match("\nlocal kickoff = ([^\n]+)"), "spawn.lua has no kickoff line")
  local build = assert(loadstring("return " .. expr))
  setfenv(build, { lib = lib, prompt = "<task folder>/prompt.md" })
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

check("SKILL.md doesn't say team.lua counts only your messages", function()
  -- team.lua counts the messages from every sender; see tests/hosts.lua.
  local teammates = assert(skill:match("\n## Teammates\n(.-)\n## "))
  assert(not teammates:find("your messages", 1, true), "SKILL.md says team.lua counts only your messages")
end)
if failed > 0 then os.exit(1) end
print("Passed " .. count .. " doc trials.")
