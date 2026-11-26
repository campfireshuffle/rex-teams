-- Run from the repo root with `luajit tests/lint.lua` or `lua5.1 tests/lint.lua`.
-- vendors.lua is the only script that names an agent CLI, so supporting a
-- new CLI, or a CLI changing its screen, touches one file.
local names = { "claude", "codex", "opencode", "anthropic", "openai", "gemini", "aider", "cursor-agent" }
local dir = "skills/rex-teams/scripts/"
local scripts = { "alarm.lua", "lib.lua", "mail.lua", "pane.lua", "postman.lua", "send.lua", "spawn.lua", "team.lua", "vt.lua", "report.md" }

local function read(path)
  local f = assert(io.open(path))
  local s = f:read("*a")
  f:close()
  return s
end

-- Every script in the folder is listed, so a new one is checked too.
local listed = {}
for _, name in ipairs(scripts) do listed[name] = true end
local p = io.popen("ls " .. dir)
for name in p:lines() do
  assert(listed[name] or name == "vendors.lua", dir .. name .. " isn't in tests/lint.lua's list")
end
p:close()

local found = {}
for _, name in ipairs(scripts) do
  local text = read(dir .. name):lower()
  for _, cli in ipairs(names) do
    if text:find(cli, 1, true) then found[#found + 1] = name .. " names " .. cli end
  end
  -- Pi's name is a common syllable, so look for it as a word.
  if text:find("%f[%w]pi%f[%W]") then found[#found + 1] = name .. " names pi" end
end
assert(read(dir .. "vendors.lua"):find("opencode", 1, true), "the check can't see names in vendors.lua")
if #found > 0 then
  print("not ok 1 - only vendors.lua names a CLI: " .. table.concat(found, "; "))
  os.exit(1)
end
print("ok 1 - only vendors.lua names a CLI")
print("Passed 1 lint trial.")
