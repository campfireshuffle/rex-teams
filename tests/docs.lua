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

check("SKILL.md doesn't say team.lua counts only your messages", function()
  -- team.lua counts the messages from every sender; see tests/hosts.lua.
  local teammates = assert(skill:match("\n## Teammates\n(.-)\n## "))
  assert(not teammates:find("your messages", 1, true), "SKILL.md says team.lua counts only your messages")
end)
check("SKILL.md and ARCHITECTURE Deliver say an unreachable host delays every delivery about 10 s per check", function()
  -- One postman serves every receiver in one loop, and a check of a host
  -- that's down blocks about 10 s (decision 006: no backoff).
  local why = skill:match("[^\n]*Rex can't reach the receiver's host[^\n]*")
  assert(why and why:find("every delivery from this host", 1, true) and why:find("about 10 s", 1, true),
    "SKILL.md doesn't say an unreachable host delays every delivery about 10 s")
  assert(deliver:find("every delivery from this host", 1, true) and deliver:find("about 10 s", 1, true),
    "ARCHITECTURE Deliver doesn't say an unreachable host delays every delivery about 10 s")
end)

check("ARCHITECTURE Deliver says a failed recurring alarm keeps its file and drops only that tick", function()
  -- postman.lua lost() clears only msg.d for a recurring alarm, and serve saves it.
  assert(deliver:find("a recurring alarm keeps its file and drops only that tick", 1, true),
    "ARCHITECTURE Deliver says a failed recurring alarm's file is deleted")
end)

check("ARCHITECTURE names exactly the fields postman.lua writes to postman.json", function()
  local fields = assert(read("skills/rex-teams/scripts/postman.lua"):match("rex%.json%.encode%(({[^}]*})%)"), "postman.lua writes no state")
  local row = assert(arch:match("\n| `/tmp/rex%-teams/postman%.json` | ([^\n]*)"), "ARCHITECTURE.md has no postman.json row")
  for _, word in ipairs({ "block", "session", "pid" }) do
    local written = fields:find("%f[%w]" .. word .. " =") ~= nil
    assert(written == (row:find("%f[%w]" .. word .. "%f[%W]") ~= nil),
      "the postman.json row and postman.lua disagree about " .. word)
  end
end)

check("ARCHITECTURE doesn't say mail.post checks all its input", function()
  -- send.lua and alarm.lua check host, at and every; post checks the rest.
  local row = assert(arch:match("\n| `mail%.lua` | ([^\n]*)"))
  assert(not row:find("bad input", 1, true) and not row:find("everything", 1, true),
    "ARCHITECTURE says mail.post checks all its input")
end)
if failed > 0 then os.exit(1) end
print("Passed " .. count .. " doc trials.")
