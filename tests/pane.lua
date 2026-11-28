-- Run from the repo root with `luajit tests/pane.lua` or `lua5.1 tests/pane.lua`.
-- pane.lua through a mock Rex: whether a pane exists, the events type sends,
-- and where attach copies files. Nothing reads the screen.
local json = dofile("tests/lib/json.lua")

local calls, events, servers
-- A mock Rex server with BLOCKS, each { session, process? }. A block's
-- process is a live foreground program unless it says otherwise. Like Rex,
-- it refuses a call on a session this script hasn't attached to, and an
-- event whose kind is in FAIL ("paste" or "key") fails, as Rex's can.
local fail
local function server(name, blocks)
  local s, attached = {}, {}
  function s.call(method, args)
    calls[#calls + 1] = name .. " " .. method .. " " .. (args.method or args.session_id or "")
    if method == "target.resolve" then
      local b = blocks[args.queries[1]]
      if not b then return { results = { { status = "not_found" } } } end
      return { results = { { status = "resolved", target = { session_id = b.session, block_id = args.queries[1] } } } }
    end
    if method == "session.attach" then attached[args.session_id] = true return {} end
    if args.session_id and not attached[args.session_id] then
      error(method .. ": stream is not attached to " .. args.session_id .. " (status=409 code=conflict)", 0)
    end
    if method == "block.method" and args.method == "process" then
      return blocks[args.block_id].process or { foreground = { pid = 1, name = "sh" } }
    end
    if method == "block.method" and args.method == "list_dir" then return { status = "ok" } end
    if method == "block.event" then
      if fail == args.event.type then return nil, "block.event: timed out" end
      events[#events + 1] = { server = name, session = args.session_id, block = args.block_id, event = args.event }
      return {}
    end
    error("unexpected call " .. method)
  end
  return s
end

local function reset(blocks, remote)
  calls, events, fail = {}, {}, nil
  servers = { [""] = server("local", blocks), ws = server("ws", remote or {}) }
  rex = { json = json, call = servers[""].call,
    server = function(label) if not servers[label] or label == "" then error('rex.server: no host named "' .. label .. '"', 0) end return servers[label] end }
end
reset({})
local pane = dofile("skills/rex-teams/scripts/pane.lua")

local n, failed = 0, 0
local function trial(name, f)
  n = n + 1
  local ok, err = pcall(f)
  if not ok then failed = failed + 1 end
  print((ok and "ok " or "not ok ") .. n .. " - " .. name .. (ok and "" or ": " .. tostring(err)))
end

trial("exists: a pane there, or gone, without reading the screen", function()
  reset({ ["b:1"] = { session = "s:1" } })
  assert(pane.exists({ block = "b:1" }) == true)
  assert(pane.exists({ block = "b:gone" }) == false)
  for _, c in ipairs(calls) do assert(not c:find("format") and not c:find("capture"), c) end
end)
trial("exists: a pane whose program exited is gone; a shell whose last command failed isn't", function()
  reset({
    ["b:exited"] = { session = "s:1", process = { last_exit = { exit_code = 1 } } },
    ["b:quit"] = { session = "s:1", process = { last_exit = { exit_code = 0 } } },
    ["b:shell"] = { session = "s:1", process = { foreground = { pid = 2, name = "fish" } } },
  })
  assert(pane.exists({ block = "b:exited" }) == false)
  assert(pane.exists({ block = "b:quit" }) == false, "a program that exited cleanly counts as alive")
  assert(pane.exists({ block = "b:shell" }) == true)
end)
trial("exists raises when Rex can't reach the host", function()
  reset({})
  local ok, err = pcall(pane.exists, { host = "down", block = "b:1" })
  assert(not ok and tostring(err):find("no host named", 1, true), tostring(err))
end)
trial("type pastes, then presses and releases Enter, in the addressed pane, after one resolve and attach", function()
  reset({ ["b:1"] = { session = "s:1" } })
  pane.type({ block = "b:1" }, "hello")
  local setup = {}
  for _, c in ipairs(calls) do if not c:find("block.event") then setup[#setup + 1] = c end end
  assert(table.concat(setup, ", ") == "local target.resolve , local session.attach s:1", table.concat(calls, ", "))
  assert(#events == 3 and events[1].event.type == "paste" and events[1].event.payload.text == "hello")
  for i, action in ipairs({ "press", "release" }) do
    local k = events[i + 1].event.payload
    -- Enter with no modifiers: Shift+Enter would add a line instead.
    assert(events[i + 1].event.type == "key" and k.key == "enter" and k.mods == "" and k.text == "\r" and k.action == action)
  end
  for _, e in ipairs(events) do assert(e.server == "local" and e.session == "s:1" and e.block == "b:1") end
end)
trial("type raises when the paste or the Enter fails, so the postman tells the sender", function()
  for _, kind in ipairs({ "paste", "key" }) do
    reset({ ["b:1"] = { session = "s:1" } })
    fail = kind
    local ok, err = pcall(pane.type, { block = "b:1" }, "hello")
    assert(not ok and tostring(err):find("block.event: timed out", 1, true), kind .. ": " .. tostring(err))
  end
end)
trial("a pane whose tab moved to another session after the post gets the message there", function()
  local blocks = { ["b:1"] = { session = "s:1" } }
  reset(blocks)
  local addr = { block = "b:1" }
  pane.type(addr, "before")
  blocks["b:1"].session = "s:2"
  calls, events = {}, {}
  pane.type(addr, "after")
  assert(#events == 3, #events .. " events")
  for _, e in ipairs(events) do assert(e.session == "s:2", "an event went to " .. e.session) end
  assert(calls[1] == "local target.resolve " and calls[2] == "local session.attach s:2", "type didn't attach to s:2 first: " .. table.concat(calls, ", "))
  assert(pane.exists(addr))
end)
trial("another host's pane is checked and typed into through rex.server", function()
  reset({}, { ["b:far"] = { session = "s:far" } })
  local addr = { host = "ws", block = "b:far" }
  assert(pane.exists(addr))
  pane.type(addr, "hi")
  for _, c in ipairs(calls) do assert(c:find("^ws "), "a call went to this host: " .. c) end
  for _, e in ipairs(events) do assert(e.server == "ws" and e.block == "b:far") end
end)

trial("files for a pane whose tab moved go to the session it's in now", function()
  local far = { ["b:far"] = { session = "s:old" } }
  reset({}, far)
  local copies = {}
  rex.exec = function(argv)
    if argv[1] == "rex" then copies[#copies + 1] = table.concat(argv, " ", 2, 6) end
    return { ok = true }
  end
  local addr = { host = "ws", block = "b:far" }
  far["b:far"].session = "s:new"
  local ok, err = pcall(pane.attach, addr, { "/tmp/x" }, "1-abcd")
  assert(ok, tostring(err))
  assert(#copies == 1 and copies[1] == "-S ws cp -s s:new", "files went to " .. table.concat(copies, "; "))
  assert(calls[#calls] == "ws block.method list_dir", "the receiver's inbox wasn't checked in s:new: " .. table.concat(calls, ", "))
end)

if failed > 0 then print(failed .. " of " .. n .. " pane trials failed.") os.exit(1) end
print("Passed " .. n .. " pane trials.")
