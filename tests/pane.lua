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
local function look(name, tag)
  local b = fixture(name)
  reset({ ["b:1"] = b })
  return pane.look({ session = "s:1", block = "b:1" }, tag or "1795671000-abcd")
end

for _, app in ipairs({ "claude-code", "codex", "opencode", "pi" }) do
  trial(app .. ": empty, idle, known, nothing seen", function()
    local l = look("empty@" .. app)
    assert(l.status == "idle" and l.known and l.app == app, tostring(l.status) .. " " .. tostring(l.app))
    assert(l.composer and l.composer.text == "" and l.composer.ours == nil and l.seen == false)
  end)
  trial(app .. ": a draft isn't ours", function()
    local l = look("draft@" .. app)
    assert(l.composer.text == "hello there draft" and l.composer.ours == nil)
  end)
  trial(app .. ": our unsent paste is ours, by its id or as one token", function()
    local l = look("ours-text@" .. app)
    assert(l.composer.ours == (app == "opencode" and "token" or "id"), tostring(l.composer.ours))
    assert(l.seen == false, "the composer's own text must not count as seen")
    l = look("ours-token@" .. app, "1795671000-wxyz")
    assert(l.composer.ours == "token" and not l.seen, tostring(l.composer.ours))
  end)
  trial(app .. ": a delivered message is seen above the composer", function()
    local l = look("delivered@" .. app, "1795671000-dlvr")
    assert(l.seen == true and l.composer.text == "" and l.composer.ours == nil)
    assert(look("delivered@" .. app, "1795671000-dlv").seen == false, "a prefix of the id isn't the id")
    assert(look("delivered@" .. app, "1795671000-abcd").seen == false)
  end)
end
trial("a dialog: blocked, with text that isn't ours", function()
  local l = look("dialog@codex")
  assert(l.status == "blocked" and l.kind == "permission")
  assert(l.composer and l.composer.text ~= "" and l.composer.ours == nil)
end)
trial("an id that wraps between msg and the id is still seen", function()
  local rows = { {}, {}, {} }
  local function row(s) local r = {} for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do r[#r + 1] = { ch = ch } end return r end
  rows = { row("  [from Someone With A Long Name · msg"), row("  1795671000-abcd, who can't see"), row("❯ ") }
  local entry = { composer = function() return { text = "", dim = "", top = 3, bottom = 3 } end, tokens = {} }
  local c, seen = pane.read(entry, rows, "1795671000-abcd")
  assert(c and seen, "not seen across the wrap")
end)
trial("a pane that's gone reads as gone and nothing else is asked", function()
  reset({})
  local l = pane.look({ session = "s:1", block = "b:gone" }, "x")
  assert(l.gone and #calls == 1, table.concat(calls, ", "))
end)
trial("a program Rex has no status for, or an unknown one, isn't read", function()
  reset({ ["b:1"] = { session = "s:1", records = {}, process = "bash", vt = "" } })
  local l = pane.look({ session = "s:1", block = "b:1" }, "x")
  assert(not l.known and l.app == "bash" and l.status == nil and l.composer == nil)
  for _, c in ipairs(calls) do assert(not c:find("format"), "read the screen of an unknown program") end
  reset({ ["b:1"] = { session = "s:1", records = { { app = "aider", state = "idle" } }, vt = "" } })
  l = pane.look({ session = "s:1", block = "b:1" }, "x")
  assert(not l.known and l.app == "aider")
end)
trial("a CLI without an app is found by its process name", function()
  local b = fixture("empty@codex")
  b.records = { { state = "idle" } }
  b.process = "codex"
  reset({ ["b:1"] = b })
  local l = pane.look({ session = "s:1", block = "b:1" }, "x")
  assert(l.known and l.app == "codex" and l.composer.text == "")
end)
trial("the root status record is used, not a child's", function()
  local b = fixture("empty@opencode")
  b.records = { { app = "opencode", id = "task/1", state = "working" }, { app = "opencode", state = "idle" } }
  reset({ ["b:1"] = b })
  assert(pane.look({ session = "s:1", block = "b:1" }, "x").status == "idle")
end)
trial("a long scrollback is read from its tail", function()
  local b = fixture("delivered@pi")
  b.vt = string.rep("old line\r\n", 20000) .. b.vt
  b.big = true
  reset({ ["b:1"] = b })
  local l = pane.look({ session = "s:1", block = "b:1" }, "1795671000-dlvr")
  assert(l.seen and l.composer.text == "")
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
  local l = pane.look(addr, "x")
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
