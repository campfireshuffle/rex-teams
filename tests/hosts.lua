-- Run from the repo root with `luajit tests/hosts.lua` or `lua5.1 tests/hosts.lua`.
-- Mocks rex.call, rex.server, target.resolve and hosts.list to check send.lua and team.lua
-- on this host and on another one.
local real_dofile = dofile
local servers, calls, pasted, printed

-- A mock Rex server: its sessions, blocks and known hosts.
local function server(name, host_id, hosts, sessions)
  local s = { name = name, host_id = host_id, hosts = hosts, sessions = sessions }
  function s.call(method, args)
    calls[#calls + 1] = name .. " " .. method
    if method == "session.attach" or method == "block.method" then return {} end
    if method == "server.status" then return { host_id = s.host_id } end
    if method == "hosts.list" then return { hosts = s.hosts } end
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

local function reset(remote_hosts)
  calls, pasted, printed = {}, {}, {}
  servers = {
    [""] = server("local", "id-mac", { { host_id = "id-ws", label = "ws" } }, {
      ["session:me"] = { label = "mine", tab = "Chief", blocks = {
        { id = "block:me-000000-aaaaaa", label = "Chief" },
        { id = "block:peer-00000-bbbbbb", label = "Helper" },
      } },
    }),
    ws = server("ws", "id-ws", remote_hosts, {
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
  reset({})
  assert(run("send.lua", { session = "session:me", block = "block:peer-00000-bbbbbb", message = "hi" }))
  local p = assert(pasted[1])
  assert(p.server == "local" and p.block == "block:peer-00000-bbbbbb" and p.session == "session:me")
  assert(has(p.text, "[from Chief, who can't see this screen."))
  assert(has(p.text, "block='block:me-000000-aaaaaa' message='<reply>'] hi"))
  assert(not has(p.text, "session=") and not has(p.text, "host="))
  none_on("ws")
end)
check("send by short ID and by label", function()
  reset({})
  assert(run("send.lua", { block = "bbbbbb", message = "hi" }))
  assert(pasted[1].block == "block:peer-00000-bbbbbb")
  reset({})
  assert(run("send.lua", { block = "Helper", message = "hi" }))
  assert(pasted[1].block == "block:peer-00000-bbbbbb" and pasted[1].session == "session:me")
end)
check("an ambiguous label fails with the candidates", function()
  reset({})
  local ok, err = run("send.lua", { host = "ws", block = "Twin", message = "hi" })
  assert(not ok and has(err, "block:twin1-0000-dddddd") and has(err, "block:twin2-0000-eeeeee"), tostring(err))
  assert(#pasted == 0)
end)
check("session= narrows a label that repeats across sessions", function()
  reset({})
  assert(run("send.lua", { host = "ws", session = "session:far", block = "Scout", message = "hi" }))
  local p = assert(pasted[1])
  assert(p.session == "session:far" and p.block == "block:scout-0000-ffffff", p.block)
end)
check("an unknown host fails without touching this host", function()
  reset({})
  local ok, err = run("send.lua", { host = "nope", block = "Helper", message = "hi" })
  assert(not ok and has(err, 'no host named "nope"'), tostring(err))
  assert(#calls == 0 and #pasted == 0)
end)
check("a cross-host message carries a reply command with host=", function()
  reset({ { host_id = "id-mac", label = "mac" } })
  assert(run("send.lua", { host = "ws", block = "cccccc", message = "hi" }))
  local p = assert(pasted[1])
  assert(p.server == "ws" and p.block == "block:far-00000-cccccc" and p.session == "session:far")
  assert(has(p.text, " host='mac' block='block:me-000000-aaaaaa' message='<reply>'] hi"), p.text)
  for _, c in ipairs(calls) do assert(c ~= "local block.event", "pasted on this host") end
end)
check("without a route back the header says no reply is possible", function()
  reset({})
  assert(run("send.lua", { host = "ws", block = "Builder", message = "hi" }))
  local p = assert(pasted[1])
  assert(has(p.text, "can't reply through Rex") and not has(p.text, "rex do"), p.text)
end)
check("team.lua host= lists remote agents with host= in their commands", function()
  reset({})
  assert(run("team.lua", { host = "ws" }))
  local all = table.concat(printed, "\n")
  assert(has(all, "Builder  rex do "), all)
  assert(has(all, " host='ws' block='block:far-00000-cccccc' message='<message>'"), all)
  assert(not has(all, "(you)") and not has(all, "session="), all)
  none_on("local")
end)
check("team.lua on this host is unchanged apart from session=", function()
  reset({})
  assert(run("team.lua", {}))
  local all = table.concat(printed, "\n")
  assert(has(all, "Chief  (you)"), all)
  assert(has(all, "block='block:peer-00000-bbbbbb' message='<message>'"), all)
  assert(not has(all, "host=") and not has(all, "session="), all)
end)
print("Passed " .. count .. " host trials.")
