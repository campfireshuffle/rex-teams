-- Run from the repo root with `luajit tests/pane.lua` or `lua5.1 tests/pane.lua`.
-- pane.look on screens recorded from the real CLIs, through a mock Rex that
-- serves each fixture's status and vt screen; and the events put and enter send.
local json = dofile("tests/lib/json.lua")
local function read(path)
  local f = assert(io.open(path))
  local s = f:read("*a")
  f:close()
  return s
end

local calls, events, servers
-- A mock Rex server whose block FIXTURE shows a recorded screen.
local function server(name, blocks)
  local s = {}
  function s.call(method, args)
    calls[#calls + 1] = name .. " " .. method .. (args.method and " " .. args.method or "")
    if method == "target.resolve" then
      local b = blocks[args.queries[1]]
      if not b then return { results = { { status = "not_found" } } } end
      return { results = { { status = "resolved", target = { session_id = b.session, block_id = args.queries[1] } } } }
    end
    if method == "session.attach" then return {} end
    if method == "block.event" then
      events[#events + 1] = { server = name, session = args.session_id, block = args.block_id, event = args.event }
      return {}
    end
    assert(method == "block.method", "unexpected call " .. method)
    local b = assert(blocks[args.block_id], "no block " .. args.block_id)
    assert(args.session_id == b.session, "wrong session")
    if args.method == "program_status" then return { records = b.records } end
    if args.method == "process" then return { foreground = b.process and { name = b.process } } end
    if args.method == "size" then return { rows = b.rows or 24 } end
    if args.method == "format" then
      assert(args.args.format == "vt" and args.args.max_bytes > 0)
      if b.big then
        return { content = b.vt:sub(1, 100), id = 7, total = #b.vt }
      end
      return { content = b.vt }
    end
    if args.method == "blob_read" then
      assert(args.args.id == 7)
      local part = b.vt:sub(args.args.offset + 1, args.args.offset + 5000)
      return { id = 7, data = part, total = #b.vt, eof = args.args.offset + #part >= #b.vt }
    end
    error("unexpected method " .. args.method)
  end
  return s
end

local function fixture(name)
  local meta = json.decode(read("tests/fixtures/screens/" .. name .. ".json"))
  return { session = "s:1", vt = read("tests/fixtures/screens/" .. name .. ".vt"), records = meta.records, rows = meta.rows, process = meta.process }
end

local function reset(blocks, remote)
  calls, events = {}, {}
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
local function look(name)
  local b = fixture(name)
  reset({ ["b:1"] = b })
  return pane.look({ session = "s:1", block = "b:1" })
end

for _, app in ipairs({ "claude-code", "codex", "opencode", "pi" }) do
  trial(app .. ": empty and known", function()
    local l = look("empty@" .. app)
    assert(l.known and l.app == app, tostring(l.app))
    assert(l.composer and l.composer.text == "" and not l.composer.token)
  end)
  trial(app .. ": a draft is text in the box", function()
    local l = look("draft@" .. app)
    assert(l.composer.text == "hello there draft" and not l.composer.token)
  end)
  trial(app .. ": a long paste's stand-in is a token", function()
    assert(look("ours-token@" .. app).composer.token)
  end)
end
trial("a dialog: text in the box", function()
  local l = look("dialog@codex")
  assert(l.composer and l.composer.text ~= "" and not l.composer.token)
end)

-- #40: the CLI loses the Enter after our paste. The one look 2 s later
-- finds our text still in its box (ours-text, or ours-token for a long
-- paste) and presses Enter once more; a box that's empty again gets none.
local P = dofile("skills/rex-teams/scripts/postman.lua")
local function deliver(app, screen)
  local m = { id = "1795671000-abcd", posted = 100, head = "[from Sender",
    tail = ", who can't see this screen. Don't rename the Rex session or your tab. Reply by running: rex do '/x/send.lua' block='block:me' message='<reply>'] ",
    text = "Test only: do not reply or run anything.",
    to = { session = "s:1", block = "b:1", name = "R" }, from = { session = "s:1", block = "b:me", name = "Me" } }
  assert(P.step(m, look("empty@" .. app), 100).kind == "put")
  assert(P.step(m, nil, 102).kind == "look")
  local kinds = { P.step(m, look(screen .. "@" .. app), 102).kind }
  if kinds[1] == "enter" then kinds[2] = P.step(m, nil, 103).kind end
  return table.concat(kinds, " ")
end
for _, app in ipairs({ "claude-code", "codex", "opencode", "pi" }) do
  trial(app .. ": a lost Enter leaves our text in the box: one more Enter, then done", function()
    for _, screen in ipairs({ "ours-text", "ours-token" }) do
      local got = deliver(app, screen)
      assert(got == "enter done", screen .. ": " .. got)
    end
  end)
  trial(app .. ": our text gone at the look: done, no second Enter", function()
    for _, screen in ipairs({ "empty", "delivered" }) do
      local got = deliver(app, screen)
      assert(got == "done", screen .. ": " .. got)
    end
  end)
end
trial("a pane that's gone reads as gone and nothing else is asked", function()
  reset({})
  local l = pane.look({ session = "s:1", block = "b:gone" })
  assert(l.gone and #calls == 1, table.concat(calls, ", "))
end)
trial("a program Rex has no status for, or an unknown one, isn't read", function()
  reset({ ["b:1"] = { session = "s:1", records = {}, process = "bash", vt = "" } })
  local l = pane.look({ session = "s:1", block = "b:1" })
  assert(not l.known and l.app == "bash" and l.composer == nil)
  for _, c in ipairs(calls) do assert(not c:find("format"), "read the screen of an unknown program") end
  reset({ ["b:1"] = { session = "s:1", records = { { app = "aider", state = "idle" } }, vt = "" } })
  l = pane.look({ session = "s:1", block = "b:1" })
  assert(not l.known and l.app == "aider")
end)
trial("a CLI without an app is found by its process name", function()
  local b = fixture("empty@codex")
  b.records = { { state = "idle" } }
  b.process = "codex"
  reset({ ["b:1"] = b })
  local l = pane.look({ session = "s:1", block = "b:1" })
  assert(l.known and l.app == "codex" and l.composer.text == "")
end)
trial("the app comes from the root status record, not a child's", function()
  local b = fixture("empty@opencode")
  b.records = { { app = "aider", id = "task/1", state = "working" }, { app = "opencode", state = "idle" } }
  reset({ ["b:1"] = b })
  assert(pane.look({ session = "s:1", block = "b:1" }).app == "opencode")
end)
trial("a long scrollback is read from its tail", function()
  local b = fixture("draft@pi")
  b.vt = string.rep("old line\r\n", 20000) .. b.vt
  b.big = true
  reset({ ["b:1"] = b })
  assert(pane.look({ session = "s:1", block = "b:1" }).composer.text == "hello there draft")
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
trial("another host's pane is looked at and typed into through rex.server", function()
  reset({}, { ["b:far"] = fixture("empty@pi") })
  servers.ws.call = server("ws", { ["b:far"] = (function() local f = fixture("empty@pi") f.session = "s:far" return f end)() }).call
  local addr = { host = "ws", session = "s:far", block = "b:far" }
  local l = pane.look(addr)
  pane.put(addr, "hi")
  pane.enter(addr)
  assert(l.known and l.composer.text == "")
  for _, c in ipairs(calls) do assert(c:find("^ws "), "a call went to this host: " .. c) end
  for _, e in ipairs(events) do assert(e.server == "ws" and e.block == "b:far") end
end)
trial("attach on this host copies nothing", function()
  reset({})
  pane.attach({ session = "s:1", block = "b:1" }, { "/a.md" }, "1-abcd")
  assert(#calls == 0)
end)

if failed > 0 then print(failed .. " of " .. n .. " pane trials failed.") os.exit(1) end
print("Passed " .. n .. " pane trials.")
