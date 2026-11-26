-- Run from the repo root with `luajit tests/alarm.lua` or `lua5.1 tests/alarm.lua`.
-- alarm.lua queues a message with a time; tests/postman.lua checks when the
-- postman delivers it. rex.call, rex.exec and os.time are mocks, and the
-- outbox is a scratch folder.
local real_dofile, real_time, real_getenv, real_print = dofile, os.time, os.getenv, print
local json = real_dofile("tests/lib/json.lua")
local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local tmp = os.tmpname()
os.remove(tmp)
local root = tmp .. "/rex-teams"

local S
local function reset()
  os.execute("rm -rf " .. quote(tmp))
  S = { now = 1795671000, calls = {}, printed = {}, sha256sum = true, ensured = {}, hint = nil }
end
os.time = function(t) if t then return real_time(t) end return S.now end
os.getenv = function(k) if k == "REX_BLOCK" then return "block:agent" end return real_getenv(k) end
local tabs = { ["block:agent"] = "Agent", ["block:other"] = "Marketer" }
rex = {
  args = {}, json = json,
  call = function(method, args)
    S.calls[#S.calls + 1] = method
    if method == "target.resolve" then
      local q = args.queries[1]
      for id, tab in pairs(tabs) do
        if q == id or q == tab then return { results = { { status = "resolved", target = { session_id = "session:s", block_id = id } } } } end
      end
      return { results = { { status = "not_found", reason = "" } } }
    end
    if method == "session.attach" then return {} end
    if method == "session.view" then
      local w = {}
      for id, tab in pairs(tabs) do w[#w + 1] = { label = tab, layers = { { blocks = { { block_id = id, label = "shell" } } } } } end
      return { windows = w }
    end
    if method == "block.method" and args.method == "list_dir" then
      local entries = {}
      local p = io.popen("ls " .. quote(args.args.path) .. " 2>/dev/null")
      for name in p:lines() do entries[#entries + 1] = { name = name } end
      p:close()
      return { status = "ok", entries = entries }
    end
    error("unexpected call " .. method)
  end,
  exec = function(argv)
    if argv[3] == "command -v sha256sum" then return { ok = S.sha256sum, code = S.sha256sum and 0 or 1, stdout = "", stderr = "" } end
    if argv[1] == "mkdir" or argv[1] == "cmd" then
      os.execute("mkdir -p " .. quote(argv[#argv]))
      return { ok = true, code = 0, stdout = "", stderr = "" }
    end
    error("unexpected command " .. table.concat(argv, " "))
  end,
}
local lib = real_dofile("skills/rex-teams/scripts/lib.lua")
lib.root = root
dofile = function(path)
  if path:match("/lib%.lua$") then return lib end
  if path:match("/postman%.lua$") then
    return { ensure = function(hint) S.ensured[#S.ensured + 1] = hint or false return S.hint end }
  end
  return real_dofile(path)
end

local function set(args)
  rex.args = args
  print = function(...) S.printed[#S.printed + 1] = table.concat({ ... }, "\t") end
  local ok, err = pcall(real_dofile, "skills/rex-teams/scripts/alarm.lua")
  print = real_print
  if not ok then error(err, 0) end
end
local function queued()
  local p = io.popen("ls " .. quote(root .. "/outbox") .. " 2>/dev/null")
  local out = {}
  for name in p:lines() do
    local f = assert(io.open(root .. "/outbox/" .. name))
    out[#out + 1] = json.decode(f:read("*a"))
    f:close()
  end
  p:close()
  return out
end

local n, failed = 0, 0
local function trial(name, f)
  n = n + 1
  reset()
  local ok, err = pcall(f)
  print = real_print
  lib.windows = false
  if not ok then failed = failed + 1 end
  real_print((ok and "ok " or "not ok ") .. n .. " - " .. name .. (ok and "" or ": " .. tostring(err)))
end
local function fails(text, f)
  local ok, err = pcall(f)
  assert(not ok, "expected an error with " .. text)
  assert(tostring(err):find(text, 1, true), tostring(err))
  assert(#queued() == 0, "a refused alarm was queued")
end

trial("an alarm is a queued message to you, at an absolute time", function()
  set({ ["in"] = 120, message = 'Check "CI" — ünïcode' })
  local q = queued()
  assert(#q == 1, #q)
  local m = q[1]
  assert(m.at == 1795671120 and not m.every and m.text == 'Check "CI" — ünïcode')
  assert(m.head == "[alarm you set" and m.tail == "] " and m.to.block == "block:agent" and m.to.session == "session:s")
  assert(S.printed[1] == "alarm: " .. m.id .. " for Agent. Cancel it with: rm " .. quote(root .. "/outbox/" .. m.id .. ".json"), S.printed[1])
  assert(S.ensured[1] == true, "alarm.lua asks for the trust hint")
end)
trial("a recurring alarm stores its interval and start", function()
  set({ every = 60, message = "tick" })
  local m = queued()[1]
  assert(m.every == 60 and m.start == 1795671000 and not m.at)
end)
trial("fractional intervals are stored exactly", function()
  set({ every = 0.5, message = "fast" })
  assert(queued()[1].every == 0.5)
  reset()
  set({ ["in"] = 1.5, message = "soon" })
  assert(queued()[1].at == 1795671001.5, queued()[1].at)
end)
trial("an alarm for another agent has the normal header", function()
  set({ ["in"] = 60, message = "Check in", block = "Marketer" })
  local m = queued()[1]
  assert(m.to.block == "block:other" and m.head == "[from Agent" and m.tail:find("Reply by running: ", 1, true))
  assert(S.printed[1]:find(" for Marketer. ", 1, true), S.printed[1])
end)
trial("the trust hint is printed when the postman isn't trusted", function()
  S.hint = "postman: Rex won't start the postman again after a restart. …"
  set({ ["in"] = 5, message = "x" })
  assert(S.printed[2] == S.hint, tostring(S.printed[2]))
end)
trial("a message with a newline is refused before anything exists", function()
  fails("one line", function() set({ ["in"] = 5, message = "a\nb" }) end)
  assert(#S.calls == 0)
end)
trial("a bad interval is refused before anything exists", function()
  for _, args in ipairs({ { message = "x" }, { ["in"] = 0, message = "x" }, { ["in"] = -5, message = "x" },
    { ["in"] = 5, every = 5, message = "x" }, { ["in"] = "soon", message = "x" } }) do
    reset()
    local ok = pcall(set, args)
    assert(not ok and #queued() == 0 and #S.calls == 0)
  end
end)
trial("a missing sha256sum stops the setter before anything exists", function()
  S.sha256sum = false
  fails("alarm.lua needs sha256sum (macOS 15+ or coreutils)", function() set({ ["in"] = 5, message = "x" }) end)
  assert(#S.calls == 0)
end)
trial("on Windows the setter needs no POSIX tools", function()
  lib.windows = true
  S.sha256sum = false
  set({ ["in"] = 5, message = "x" })
  assert(#queued() == 1)
end)
trial("list=true shows your alarms and how to cancel each", function()
  set({ ["in"] = 120, message = "Check CI" })
  set({ every = 60, message = "tick", block = "Marketer" })
  S.printed = {}
  set({ list = true })
  local all = table.concat(S.printed, "\n")
  assert(all:find("at 03:", 1, true) or all:find("  at ", 1, true), all)
  assert(all:find("  to Agent: Check CI", 1, true) and all:find("every 60s  to Marketer: tick", 1, true), all)
  assert(all:find("  cancel: rm " .. root .. "/outbox/", 1, true), all)
end)

os.execute("rm -rf " .. quote(tmp))
dofile, os.time, os.getenv = real_dofile, real_time, real_getenv
if failed > 0 then print(failed .. " of " .. n .. " alarm trials failed.") os.exit(1) end
print("Passed " .. n .. " alarm trials.")
