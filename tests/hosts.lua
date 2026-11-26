-- Run from the repo root with `luajit tests/hosts.lua` or `lua5.1 tests/hosts.lua`.
-- Mocks rex.call, rex.server, target.resolve and `hostname` to check
-- send.lua and team.lua on this host and on another one.
local real_dofile = dofile
local servers, calls, pasted, printed, hostname

-- A mock Rex server: its sessions and blocks.
local function server(name, host_id, sessions)
  local s = { name = name, host_id = host_id, sessions = sessions }
  function s.call(method, args)
    calls[#calls + 1] = name .. " " .. method
    if method == "session.attach" or method == "block.method" then return {} end
    if method == "server.status" then return { host_id = s.host_id } end
    if method == "session.list" then
      local out = {}
      for id, sess in pairs(s.sessions) do out[#out + 1] = { session_id = id, label = sess.label } end
      return { sessions = out }
    end
    if method == "session.view" then
      local blocks = {}
      for _, b in ipairs(s.sessions[args.session_id].blocks) do blocks[#blocks + 1] = { block_id = b.id, label = "shell" } end
      return { windows = { { label = s.sessions[args.session_id].tab, layers = { { blocks = blocks } } } } }
    end
    if method == "target.resolve" then
      local q, found = args.queries[1], {}
      for id, sess in pairs(s.sessions) do
        assert(args.scope == nil, "unexpected scope")
        for _, b in ipairs(sess.blocks) do
          if q == b.id or q == b.id:sub(-6) or q == b.label then
            found[#found + 1] = { kind = "block", session_id = id, block_id = b.id, label = b.label, where = "window 1" }
          end
        end
      end
      if #found == 1 then return { results = { { query = q, status = "resolved", target = found[1] } } } end
      if #found == 0 then return { results = { { query = q, status = "not_found", reason = "" } } } end
      return { results = { { query = q, status = "ambiguous", candidates = found } } }
    end
    if method == "block.event" then
      if args.event.type == "paste" then pasted[#pasted + 1] = { server = name, session = args.session_id, block = args.block_id, text = args.event.payload.text } end
      return {}
    end
    error("unexpected call: " .. method)
  end
  return s
end

local function reset()
  calls, pasted, printed = {}, {}, {}
  hostname = { ok = true, code = 0, stdout = "mac-host\r\n" }
  servers = {
    [""] = server("local", "id-mac", {
      ["session:me"] = { label = "mine", tab = "Chief", blocks = {
        { id = "block:me-000000-aaaaaa", label = "Chief" },
        { id = "block:peer-00000-bbbbbb", label = "Helper" },
      } },
    }),
    ws = server("ws", "id-ws", {
      ["session:far"] = { label = "far", tab = "Builder", blocks = {
        { id = "block:far-00000-cccccc", label = "Builder" },
        { id = "block:twin1-0000-dddddd", label = "Twin" },
        { id = "block:twin2-0000-eeeeee", label = "Twin" },
      } },
    }),
  }
  rex = {
    call = servers[""].call,
    server = function(label)
      if not servers[label] or label == "" then error('rex.server: no host named "' .. label .. '"', 0) end
      return servers[label]
    end,
    exec = function(argv)
      local line = table.concat(argv, " ")
      calls[#calls + 1] = "exec " .. line
      if line == "hostname" then return hostname end
      error("unexpected exec: " .. line)
    end,
  }
end

local function run(script, args)
  rex.args = args
  local lib = real_dofile("skills/rex-teams/scripts/lib.lua")
  lib.me = function() return "session:me", "block:me-000000-aaaaaa" end
  lib.worktree = function() end
  dofile = function(path)
    if path:match("/lib%.lua$") then return lib end
    return real_dofile(path)
  end
  local real_print = print
  print = function(line) printed[#printed + 1] = line end
  local ok, err = pcall(real_dofile, "skills/rex-teams/scripts/" .. script)
  print, dofile = real_print, real_dofile
  return ok, err
end

local count = 0
local function check(name, fn)
  fn()
  count = count + 1
  print("ok " .. count .. " - " .. name)
end
local function has(s, part) return s:find(part, 1, true) ~= nil end
local function none_on(name)
  for _, c in ipairs(calls) do assert(not c:find("^" .. name .. " "), "unexpected call " .. c) end
end
local function fails(script, args, text)
  local ok, err = run(script, args)
  assert(not ok and has(tostring(err), text), tostring(err))
  assert(#pasted == 0)
end

check("a local send by full ID, short ID or label, with no session= anywhere", function()
  for _, block in ipairs({ "block:peer-00000-bbbbbb", "bbbbbb", "Helper" }) do
    reset()
    assert(run("send.lua", { block = block, message = "hi" }))
    local p = assert(pasted[1])
    assert(p.server == "local" and p.block == "block:peer-00000-bbbbbb" and p.session == "session:me")
    assert(has(p.text, "[from Chief, who can't see this screen. Don't rename the Rex session or your tab. Reply by running: rex do "), p.text)
    assert(has(p.text, "block='block:me-000000-aaaaaa' message='<reply>'] hi"), p.text)
    assert(not has(p.text, "session=") and not has(p.text, "host="), p.text)
    none_on("ws")
  end
end)
check("host= a label reaches that host", function()
  reset()
  assert(run("send.lua", { host = "ws", block = "cccccc", message = "hi" }))
  local p = assert(pasted[1])
  assert(p.server == "ws" and p.block == "block:far-00000-cccccc" and p.session == "session:far")
end)
check("an unknown label fails with zero calls on this host", function()
  reset()
  fails("send.lua", { host = "nope", block = "Helper", message = "hi" }, 'no host named "nope"')
  assert(#calls == 0, table.concat(calls, ", "))
end)
check("an ambiguous label fails with the candidates", function()
  reset()
  fails("send.lua", { host = "ws", block = "Twin", message = "hi" }, "block:twin1-0000-dddddd")
  assert(has(select(2, run("send.lua", { host = "ws", block = "Twin", message = "hi" })), "block:twin2-0000-eeeeee"))
end)
check("an empty or blank block= is refused before anything runs", function()
  for _, block in ipairs({ "", "  ", "\t" }) do
    reset()
    local ok = run("send.lua", { host = "ws", block = block, message = "hi" })
    assert(not ok and #calls == 0, block)
  end
end)
check("a cross-host header names this host and asks for the receiver's label", function()
  reset()
  assert(run("send.lua", { host = "ws", block = "cccccc", message = "hi" }))
  local text = assert(pasted[1]).text
  local want = "[from Chief on mac-host (Rex host id-mac), who can't see this screen. Don't rename the Rex session or your tab."
    .. " To reply, run this with your rex-teams skill's path and your rex hosts label for that host filled in:"
    .. " rex do <rex-teams skill>/scripts/send.lua host='<label>' block='block:me-000000-aaaaaa' message='<reply>'] hi"
  assert(text == want, text)
end)
check("a cross-host send fails if hostname fails", function()
  for _, result in ipairs({ false, { ok = false, code = 1, stdout = "", stderr = "boom" }, { ok = true, code = 0, stdout = " \n" } }) do
    reset()
    hostname = result or nil
    fails("send.lua", { host = "ws", block = "cccccc", message = "hi" }, "hostname")
  end
end)
check("a cross-host send fails if Rex has no host_id", function()
  reset()
  servers[""].host_id = nil
  fails("send.lua", { host = "ws", block = "cccccc", message = "hi" }, "host_id")
end)
check("team.lua host= lists remote agents with host= in their commands", function()
  reset()
  assert(run("team.lua", { host = "ws" }))
  local all = table.concat(printed, "\n")
  assert(has(all, "session far:"), all)
  assert(has(all, "Builder  rex do "), all)
  assert(has(all, " host='ws' block='block:far-00000-cccccc' message='<message>'"), all)
  assert(not has(all, "(you)") and not has(all, "session="), all)
  none_on("local")
end)
check("team.lua host= names an unlabeled session by its ID", function()
  reset()
  servers.ws.sessions["session:bare"] = { tab = "Lone", blocks = { { id = "block:lone-00000-111111", label = "Lone" } } }
  assert(run("team.lua", { host = "ws" }))
  assert(has(table.concat(printed, "\n"), "session session:bare:"))
end)
check("team.lua refuses an unknown label", function()
  reset()
  local ok, err = run("team.lua", { host = "nope" })
  assert(not ok and has(tostring(err), 'no host named "nope"'), tostring(err))
  assert(#printed == 0 and #calls == 0, table.concat(calls, ", "))
end)
check("team.lua on this host prints commands without host= or session=", function()
  reset()
  assert(run("team.lua", {}))
  local all = table.concat(printed, "\n")
  assert(has(all, "Chief  (you)"), all)
  assert(has(all, "block='block:peer-00000-bbbbbb' message='<message>'"), all)
  assert(not has(all, "host=") and not has(all, "session="), all)
end)
print("Passed " .. count .. " host trials.")
