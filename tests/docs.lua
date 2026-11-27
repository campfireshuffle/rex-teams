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
local deliver = assert(arch:match("\n%*%*Deliver%*%*\n(.-)\n%*%*Notice%*%*"), "ARCHITECTURE.md has no Deliver section")
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

check("ARCHITECTURE Deliver says an unreachable host delays every delivery about 10 s per check", function()
  -- One postman serves every receiver in one loop, and a check of a host
  -- that's down blocks about 10 s (decision 006: no backoff). SKILL.md
  -- leaves this out (decision 009).
  assert(deliver:find("every delivery from this host", 1, true) and deliver:find("about 10 s", 1, true),
    "ARCHITECTURE Deliver doesn't say an unreachable host delays every delivery about 10 s")
end)

check("ARCHITECTURE Deliver says a failed recurring alarm keeps its file and drops only that tick", function()
  -- postman.lua finish() clears only pasted_at for a recurring alarm and saves it.
  assert(deliver:find("a recurring alarm keeps its file and drops only that tick", 1, true),
    "ARCHITECTURE Deliver says a failed recurring alarm's file is deleted")
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

check("ARCHITECTURE doesn't say mail.post checks all its input", function()
  -- send.lua and alarm.lua check host, at and every; post checks the rest.
  local row = assert(arch:match("\n| `mail%.lua` | ([^\n]*)"))
  assert(not row:find("bad input", 1, true) and not row:find("everything", 1, true),
    "ARCHITECTURE says mail.post checks all its input")
end)
check("README doesn't say the skill needs the screen", function()
  -- Decision 005: the postman pastes and presses Enter; nothing reads the screen.
  local needs = assert(read("README.md"):match("Rex already gives agents everything this skill needs: ([^.]*)%."))
  assert(not needs:find("screen", 1, true), "README says the skill needs the screen: " .. needs)
end)

check("ARCHITECTURE and mail.post say they start the postman, not wake it", function()
  -- ensure starts a postman that isn't running; a running one polls on its own.
  local mail = read("skills/rex-teams/scripts/mail.lua")
  for name, text in pairs({ ["ARCHITECTURE.md"] = arch, ["mail.lua"] = mail }) do
    assert(not text:lower():find("wake the postman", 1, true), name .. " says it wakes the postman")
  end
  assert(arch:find("start the postman if it isn't running", 1, true), "ARCHITECTURE.md doesn't say mail.post starts the postman")
  assert(mail:find("Start the postman if it isn't running", 1, true), "mail.lua's post comment doesn't say it starts the postman")
end)
if failed > 0 then os.exit(1) end
print("Passed " .. count .. " doc trials.")
