-- Run from the repo root with `luajit tests/pane.lua` or `lua5.1 tests/pane.lua`.
-- pane.lua through a mock Rex: whether a pane exists, and the events put and
-- enter send. Nothing reads the screen.
local json = dofile("tests/lib/json.lua")

local calls, events, servers
-- A mock Rex server with BLOCKS, each { session, process? }. A block's
-- process is a live foreground program unless it says otherwise.
local function server(name, blocks)
  local s = {}
  function s.call(method, args)
    calls[#calls + 1] = name .. " " .. method .. " " .. (args.method or args.session_id or "")
    if method == "target.resolve" then
      local b = blocks[args.queries[1]]
      if not b then return { results = { { status = "not_found" } } } end
      return { results = { { status = "resolved", target = { session_id = b.session, block_id = args.queries[1] } } } }
    end
    if method == "session.attach" then return {} end
    if method == "block.method" and args.method == "process" then
      return blocks[args.block_id].process or { foreground = { pid = 1, name = "sh" } }
    end
    if method == "block.event" then
      events[#events + 1] = { server = name, session = args.session_id, block = args.block_id, event = args.event }
      return {}
    end
    error("unexpected call " .. method)
  end
  return s
end

local function reset(blocks, remote)
  calls, events = {}, {}
  servers = { [""] = server("local", blocks), ws = server("ws", remote or {}) }
  rex = { json = json, call = servers[""].call,
    server = function(label) if not servers[label] or label == "" then error('rex.server: no host named "' .. label .. '"', 0) end return servers[label] end }
end
reset({})
-- Keep pane.lua's own lib, so a trial can watch its file copies.
local real_dofile, plib = dofile, nil
dofile = function(path) local m = real_dofile(path) if path:match("lib%.lua$") then plib = m end return m end
local pane = dofile("skills/rex-teams/scripts/pane.lua")
dofile = real_dofile

local n, failed = 0, 0
local function trial(name, f)
  n = n + 1
  local ok, err = pcall(f)
  if not ok then failed = failed + 1 end
  print((ok and "ok " or "not ok ") .. n .. " - " .. name .. (ok and "" or ": " .. tostring(err)))
end

trial("exists: a pane there, or gone, without reading the screen", function()
  reset({ ["b:1"] = { session = "s:1" } })
  assert(pane.exists({ session = "s:1", block = "b:1" }) == true)
  assert(pane.exists({ session = "s:1", block = "b:gone" }) == false)
  for _, c in ipairs(calls) do assert(not c:find("format") and not c:find("capture"), c) end
end)
trial("exists: a pane whose program exited is gone; a shell whose last command failed isn't", function()
  reset({
    ["b:exited"] = { session = "s:1", process = { last_exit = { exit_code = 1 } } },
    ["b:quit"] = { session = "s:1", process = { last_exit = { exit_code = 0 } } },
    ["b:shell"] = { session = "s:1", process = { foreground = { pid = 2, name = "fish" } } },
  })
  assert(pane.exists({ session = "s:1", block = "b:exited" }) == false)
  assert(pane.exists({ session = "s:1", block = "b:quit" }) == false, "a program that exited cleanly counts as alive")
  assert(pane.exists({ session = "s:1", block = "b:shell" }) == true)
end)
trial("exists raises when Rex can't reach the host", function()
  reset({})
  local ok, err = pcall(pane.exists, { host = "down", session = "s:1", block = "b:1" })
  assert(not ok and tostring(err):find("no host named", 1, true), tostring(err))
end)
trial("put pastes, and enter presses and releases Enter, in the addressed pane", function()
  reset({ ["b:1"] = { session = "s:1" } })
  pane.put({ session = "s:1", block = "b:1" }, "hello")
  pane.enter({ session = "s:1", block = "b:1" })
  assert(#events == 3 and events[1].event.type == "paste" and events[1].event.payload.text == "hello")
  for i, action in ipairs({ "press", "release" }) do
    local k = events[i + 1].event.payload
    assert(events[i + 1].event.type == "key" and k.key == "enter" and k.text == "\r" and k.action == action)
  end
  for _, e in ipairs(events) do assert(e.server == "local" and e.session == "s:1" and e.block == "b:1") end
end)
trial("a pane whose tab moved to another session after the post gets the message there", function()
  local blocks = { ["b:1"] = { session = "s:1" } }
  reset(blocks)
  local addr = { session = "s:1", block = "b:1" }
  pane.put(addr, "before")
  blocks["b:1"].session = "s:2"
  calls, events = {}, {}
  pane.put(addr, "after")
  pane.enter(addr)
  assert(#events == 3, #events .. " events")
  for _, e in ipairs(events) do assert(e.session == "s:2", "an event went to " .. e.session) end
  assert(calls[1] == "local target.resolve " and calls[2] == "local session.attach s:2", "put didn't attach to s:2 first: " .. table.concat(calls, ", "))
  assert(pane.exists(addr))
end)
trial("another host's pane is checked and typed into through rex.server", function()
  reset({}, { ["b:far"] = { session = "s:far" } })
  local addr = { host = "ws", session = "s:far", block = "b:far" }
  assert(pane.exists(addr))
  pane.put(addr, "hi")
  pane.enter(addr)
  for _, c in ipairs(calls) do assert(c:find("^ws "), "a call went to this host: " .. c) end
  for _, e in ipairs(events) do assert(e.server == "ws" and e.block == "b:far") end
end)

trial("files for a pane whose tab moved go to the session it's in now", function()
  local far = { ["b:far"] = { session = "s:old" } }
  reset({}, far)
  local copies = {}
  local send_files = plib.send_files
  plib.send_files = function(host, session, block) copies[#copies + 1] = host .. " " .. session .. " " .. block end
  local addr = { host = "ws", session = "s:old", block = "b:far" }
  far["b:far"].session = "s:new"
  local ok, err = pcall(pane.attach, addr, { "/tmp/x" }, "1-abcd")
  plib.send_files = send_files
  assert(ok, tostring(err))
  assert(copies[1] == "ws s:new b:far", "files went to " .. tostring(copies[1]))
end)

if failed > 0 then print(failed .. " of " .. n .. " pane trials failed.") os.exit(1) end
print("Passed " .. n .. " pane trials.")
