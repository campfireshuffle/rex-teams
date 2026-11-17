-- Run from the repo root with `luajit tests/hosts.lua` or `lua5.1 tests/hosts.lua`.
-- Mocks rex.call, rex.server, target.resolve, `hostname` and `rex hosts --json` to check
-- send.lua and team.lua on this host and on another one.
local real_dofile = dofile
local servers, calls, pasted, printed, known

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
        if not (args.scope and args.scope.session ~= id) then
          for _, b in ipairs(sess.blocks) do
            if q == b.id or q == b.id:sub(-6) or q == b.label then
              found[#found + 1] = { kind = "block", session_id = id, block_id = b.id, label = b.label, where = "window 1" }
            end
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

-- HOSTS is what `rex hosts --json` lists on this host.
local function reset(hosts)
  calls, pasted, printed = {}, {}, {}
  known = hosts or { { host = { label = "ws", host_id = "id-ws" } } }
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
        { id = "block:scout-0000-ffffff", label = "Scout" },
      } },
      ["session:near"] = { label = "near", tab = "Scout", blocks = {
        { id = "block:scout-0000-999999", label = "Scout" },
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
      if line == "hostname" then return { ok = true, code = 0, stdout = "mac-host\r\n" } end
      if line == "rex hosts --json" then return { ok = true, code = 0, stdout = "<hosts>" } end
      error("unexpected exec: " .. line)
    end,
    json = { decode = function(text)
      assert(text == "<hosts>")
      return { home = { this_machine = true }, hosts = known }
    end },
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

check("local send by full ID with the old session= still works", function()
  reset()
  assert(run("send.lua", { session = "session:me", block = "block:peer-00000-bbbbbb", message = "hi" }))
  local p = assert(pasted[1])
  assert(p.server == "local" and p.block == "block:peer-00000-bbbbbb" and p.session == "session:me")
  assert(has(p.text, "[from Chief, who can't see this screen."))
  assert(has(p.text, "block='block:me-000000-aaaaaa' message='<reply>'] hi"))
  assert(not has(p.text, "session=") and not has(p.text, "host="))
  none_on("ws")
end)
check("send by short ID and by label", function()
  reset()
  assert(run("send.lua", { block = "bbbbbb", message = "hi" }))
  assert(pasted[1].block == "block:peer-00000-bbbbbb")
  reset()
  assert(run("send.lua", { block = "Helper", message = "hi" }))
  assert(pasted[1].block == "block:peer-00000-bbbbbb" and pasted[1].session == "session:me")
end)
check("an ambiguous label fails with the candidates", function()
  reset()
  local ok, err = run("send.lua", { host = "ws", block = "Twin", message = "hi" })
  assert(not ok and has(err, "block:twin1-0000-dddddd") and has(err, "block:twin2-0000-eeeeee"), tostring(err))
  assert(#pasted == 0)
end)
check("session= narrows a label that repeats across sessions", function()
  reset()
  assert(run("send.lua", { host = "ws", session = "session:far", block = "Scout", message = "hi" }))
  local p = assert(pasted[1])
  assert(p.session == "session:far" and p.block == "block:scout-0000-ffffff", p.block)
end)
local function pastes_only_on(name)
  for _, p in ipairs(pasted) do assert(p.server == name, "pasted on " .. p.server) end
end
local function refused(args, script)
  local ok, err = run(script or "send.lua", args)
  assert(not ok and has(err, "no host " .. args.host .. " in your rex hosts; your Rex can't reach it. Tell your user instead of retrying."), tostring(err))
  assert(#pasted == 0)
  none_on("ws")
end
check("an unknown host fails without touching another host", function()
  reset()
  refused({ host = "nope", block = "Helper", message = "hi" })
end)
check("host= omitted stays on this host", function()
  reset()
  assert(run("send.lua", { block = "Helper", message = "hi" }))
  assert(pasted[1].server == "local")
  none_on("ws")
  for _, c in ipairs(calls) do assert(not c:find("^exec "), "unexpected " .. c) end
end)
check("host= a label reaches that host", function()
  reset()
  assert(run("send.lua", { host = "ws", block = "cccccc", message = "hi" }))
  local p = assert(pasted[1])
  assert(p.server == "ws" and p.block == "block:far-00000-cccccc" and p.session == "session:far")
  pastes_only_on("ws")
end)
check("host= our own host_id stays on this host with no remote calls", function()
  reset()
  assert(run("send.lua", { host = "id-mac", block = "Helper", message = "hi" }))
  assert(pasted[1].server == "local" and not has(pasted[1].text, "host="), pasted[1].text)
  none_on("ws")
end)
check("host= a known host_id reaches its label once the host confirms it", function()
  reset()
  assert(run("send.lua", { host = "id-ws", block = "cccccc", message = "hi" }))
  assert(pasted[1].server == "ws" and pasted[1].block == "block:far-00000-cccccc")
  local confirmed
  for i, c in ipairs(calls) do
    if c == "ws server.status" then confirmed = i end
    if c == "ws block.event" then assert(confirmed and confirmed < i, "pasted before confirming") end
  end
  assert(confirmed, "never asked ws for its host_id")
end)
check("host= an unknown host_id fails with no paste anywhere", function()
  reset()
  refused({ host = "7c6a4922-c7e7-483a-95d4-89cabc146085", block = "Helper", message = "hi" })
end)
check("host= a hostname is refused, ours or another's", function()
  reset()
  refused({ host = "mac-host", block = "Helper", message = "hi" })
  reset()
  refused({ host = "ws-uswest2-1-f08a", block = "Helper", message = "hi" })
end)
check("host= a label whose host_id is ours stays on this host", function()
  reset({ { host = { label = "self", host_id = "id-mac" } }, { host = { label = "ws", host_id = "id-ws" } } })
  assert(run("send.lua", { host = "self", block = "Helper", message = "hi" }))
  assert(pasted[1].server == "local")
  none_on("ws")
end)
check("host= a host_id whose label now reports another host_id fails with no paste", function()
  reset({ { host = { label = "ws", host_id = "id-old" } } })
  local ok, err = run("send.lua", { host = "id-old", block = "cccccc", message = "hi" })
  assert(not ok and has(err, "host ws no longer has host_id id-old"), tostring(err))
  assert(#pasted == 0)
end)
check("entries without a host_id still match by label", function()
  reset({ { host = { label = "bare" } }, { host = { label = "ws" } } })
  assert(run("send.lua", { host = "ws", block = "cccccc", message = "hi" }))
  assert(pasted[1].server == "ws")
  reset({ { host = { label = "ws" } } })
  refused({ host = "id-ws", block = "cccccc", message = "hi" })
end)
check("a cross-host header names this host and replies by host_id", function()
  reset()
  assert(run("send.lua", { host = "ws", block = "cccccc", message = "hi" }))
  local text = assert(pasted[1]).text
  assert(has(text, "[from Chief on mac-host, who can't see this screen. "), text)
  assert(has(text, " Reply by running, with your rex-teams skill's path filled in: rex do <rex-teams skill>/scripts/send.lua host='id-mac' block='block:me-000000-aaaaaa' message='<reply>'] hi"), text)
  reset()
  assert(run("send.lua", { block = "Helper", message = "hi" }))
  text = pasted[1].text
  assert(has(text, "[from Chief, who can't see this screen. ") and not has(text, "host=") and not has(text, "<rex-teams skill>"), text)
end)
check("a cross-host header without a host_id names the host and gives no reply", function()
  reset()
  servers[""].host_id = nil
  assert(run("send.lua", { host = "ws", block = "cccccc", message = "hi" }))
  local text = pasted[1].text
  assert(has(text, "[from Chief on mac-host, who can't see this screen. ") and not has(text, "Reply by running"), text)
end)
check("an empty or blank block= is refused before anything runs", function()
  for _, block in ipairs({ "", "  ", "\t" }) do
    reset()
    local ok = run("send.lua", { host = "ws", block = block, message = "hi" })
    assert(not ok and #calls == 0, block)
  end
end)
check("team.lua host=<host_id> lists the same as host=<label>", function()
  reset()
  assert(run("team.lua", { host = "ws" }))
  local by_label = table.concat(printed, "\n")
  reset()
  assert(run("team.lua", { host = "id-ws" }))
  assert(table.concat(printed, "\n") == by_label, table.concat(printed, "\n"))
end)
check("team.lua refuses an unknown host", function()
  reset()
  local ok, err = run("team.lua", { host = "nope" })
  assert(not ok and has(err, "no host nope"), tostring(err))
  assert(#printed == 0)
end)
check("team.lua host= lists remote agents with host= in their commands", function()
  reset()
  assert(run("team.lua", { host = "ws" }))
  local all = table.concat(printed, "\n")
  assert(has(all, "Builder  rex do "), all)
  assert(has(all, " host='ws' block='block:far-00000-cccccc' message='<message>'"), all)
  assert(not has(all, "(you)") and not has(all, "session="), all)
  for _, c in ipairs(calls) do assert(c == "local server.status" or not c:find("^local "), "unexpected call " .. c) end
end)
check("team.lua host= names an unlabeled session by its ID", function()
  reset()
  servers.ws.sessions["session:bare"] = { tab = "Lone", blocks = { { id = "block:lone-00000-111111", label = "Lone" } } }
  local ok, err = run("team.lua", { host = "ws" })
  assert(ok, tostring(err))
  local all = table.concat(printed, "\n")
  assert(has(all, "session session:bare:"), all)
end)
check("team.lua on this host is unchanged apart from session=", function()
  reset()
  assert(run("team.lua", {}))
  local all = table.concat(printed, "\n")
  assert(has(all, "Chief  (you)"), all)
  assert(has(all, "block='block:peer-00000-bbbbbb' message='<message>'"), all)
  assert(not has(all, "host=") and not has(all, "session="), all)
end)
print("Passed " .. count .. " host trials.")
