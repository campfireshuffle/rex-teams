-- Run from the repo root with `luajit tests/postman.lua` or `lua5.1 tests/postman.lua`.
-- The postman's worker, run against a mock Rex: its timers run on a fake
-- clock, the outbox is a real scratch folder, and pane.lua is replaced by
-- fake receivers whose checks follow a script, one entry per call. The one
-- real command is the OSC 7577 shell, run with a fixed token.
local real_dofile, real_time, real_getenv, real_print = dofile, os.time, os.getenv, print
local json = real_dofile("tests/lib/json.lua")
local TOKEN = "fixed-test-token-0123456789"
local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function run_sh(argv, env)
  local line = "env"
  for k, v in pairs(env) do line = line .. " " .. k .. "=" .. quote(v) end
  for _, a in ipairs(argv) do line = line .. " " .. quote(a) end
  local out = os.tmpname()
  local status = os.execute(line .. " >" .. out .. " 2>&1")
  local f = assert(io.open(out))
  local text = f:read("*a")
  f:close()
  os.remove(out)
  local ok = status == 0 or status == true
  return { ok = ok, code = ok and 0 or 1, stdout = text, stderr = ok and "" or text }
end
local tmp = os.tmpname()
os.remove(tmp)
local root = tmp .. "/rex-teams"

local S -- the mock world
local function reset()
  os.execute("rm -rf " .. quote(tmp))
  os.execute("mkdir -p " .. quote(root))
  S = {
    now = 1795671000, t = 1795671000, env = { REX_BLOCK = "block:pm", OSC7577_TOKEN = TOKEN },
    blocks = { ["block:pm"] = { session = "s:home", pid = 4242 }, ["block:me"] = { session = "s:1" }, ["block:to"] = { session = "s:1" } },
    timers = {}, out = {}, printed = {}, stopped = nil, closed = {}, receivers = {}, sleeps = 0,
  }
end

os.time = function(t) if t then return real_time(t) end return S.now end
os.getenv = function(k) if S.env[k] ~= nil then return S.env[k] or nil end return real_getenv(k) end
io.stdout = { write = function(self, ...) for _, s in ipairs({ ... }) do S.out[#S.out + 1] = s end return self end, flush = function() end }

local function ls(dir)
  local p = io.popen("ls " .. quote(dir) .. " 2>/dev/null")
  local out = {}
  for name in p:lines() do out[#out + 1] = name end
  p:close()
  return out
end

rex = {
  args = {}, json = json,
  call = function(method, args)
    if method == "target.resolve" then
      local b = S.blocks[args.queries[1]]
      if not b then return { results = { { status = "not_found" } } } end
      return { results = { { status = "resolved", target = { session_id = b.session, block_id = args.queries[1] } } } }
    end
    if method == "session.attach" then return {} end
    if method == "block.close" then S.closed[#S.closed + 1] = args.block_id S.blocks[args.block_id] = nil return {} end
    if method == "session.list" then return { sessions = S.sessions or {} } end
    if method == "session.create" then S.created = args.label return { session_id = "s:home" } end
    if method == "session.new_block" then
      S.new_block = args
      S.blocks["block:new"] = { session = "s:home", pid = 7 }
      return { block_id = "block:new" }
    end
    if method == "block.method" and args.method == "process" then
      local b = S.blocks[args.block_id]
      if not b then error("block not found (status=404 code=not_found)", 0) end
      return { foreground = b.pid and { pid = b.pid, name = "rex" }, last_exit = b.last_exit }
    end
    if method == "block.method" and args.method == "list_dir" then
      local entries = {}
      for _, name in ipairs(ls(args.args.path)) do entries[#entries + 1] = { name = name } end
      return { status = "ok", entries = entries }
    end
    error("unexpected call " .. method .. " " .. tostring(args.method))
  end,
  exec = function(argv)
    for _, a in ipairs(argv) do assert(not a:find(TOKEN, 1, true), "the token reached argv") end
    if argv[1] == "cmd" then table.remove(argv, 1) table.remove(argv, 1) end
    if argv[1] == "if" then argv = { "mkdir", "-p", argv[#argv] } end
    if argv[1] == "mkdir" or argv[1] == "rmdir" then
      local words = {}
      for i, w in ipairs(argv) do words[i] = quote(w) end
      local ok = os.execute(table.concat(words, " ") .. " 2>/dev/null")
      ok = ok == 0 or ok == true
      return { ok = ok, code = ok and 0 or 1, stdout = "", stderr = "" }
    end
    assert(argv[1] == "sh" and argv[3]:find("sha256sum", 1, true), "unexpected command " .. table.concat(argv, " "))
    return run_sh(argv, { OSC7577_TOKEN = S.env.OSC7577_TOKEN })
  end,
  after = function(s, f) S.timers[#S.timers + 1] = { due = S.t + s, f = f } end,
  sleep = function()
    S.sleeps = S.sleeps + 1
    if S.on_sleep then S.on_sleep(S.sleeps) end
  end,
  stop = function(code) S.stopped = code end,
}

-- Fake receivers in place of pane.lua. Each check takes the next entry of
-- the receiver's script, and the last entry stays: "up", "down" (raises,
-- as a Rex call to a host that's down does) or "gone".
local fake = {}
function fake.exists(addr)
  local r = S.receivers[addr.block]
  if not r then return false end
  local now = r.script[1]
  if #r.script > 1 then table.remove(r.script, 1) end
  r.checks[#r.checks + 1] = S.t
  if now == "down" then error("rex.server: dial tcp: timeout", 0) end
  return now == "up"
end
function fake.put(addr, text)
  local r = S.receivers[addr.block]
  r.puts[#r.puts + 1] = { t = S.t, text = text }
  r.pending = text
end
function fake.enter(addr)
  local r = S.receivers[addr.block]
  r.enters = r.enters + 1
  if r.pending then
    r.delivered[#r.delivered + 1] = { t = S.t, text = r.pending }
    r.pending = nil
  end
end
function fake.attach(addr) S.receivers[addr.block].copies = S.receivers[addr.block].copies + 1 end
local real_fake = {}
for k, v in pairs(fake) do real_fake[k] = v end
local function receiver(block, script)
  local r = { script = script or { "up" }, puts = {}, delivered = {}, enters = 0, checks = {}, copies = 0 }
  S.receivers[block] = r
  S.blocks[block] = S.blocks[block] or { session = "s:1" }
  return r
end

local lib = real_dofile("skills/rex-teams/scripts/lib.lua")
lib.root = root
local mail
dofile = function(path)
  if path:match("/lib%.lua$") then return lib end
  if path:match("/pane%.lua$") then return fake end
  if path:match("/mail%.lua$") and mail then return mail end
  return real_dofile(path)
end
mail = real_dofile("skills/rex-teams/scripts/mail.lua")
local real_mail = {}
for k, v in pairs(mail) do real_mail[k] = v end
local P = real_dofile("skills/rex-teams/scripts/postman.lua")
local real_P = {}
for k, v in pairs(P) do real_P[k] = v end

-- Run the clock to T (real time, fractional), firing timers in order.
local function run_to(t)
  for _ = 1, 100000 do
    local next_i
    for i, timer in ipairs(S.timers) do
      if not next_i or timer.due < S.timers[next_i].due then next_i = i end
    end
    if not next_i or S.timers[next_i].due > t then break end
    local timer = table.remove(S.timers, next_i)
    S.t = math.max(S.t, timer.due)
    S.now = math.floor(S.t)
    timer.f()
  end
  S.t = math.max(S.t, t)
  S.now = math.floor(S.t)
end
-- Start the postman; a restart first drops the old one's timers.
local function start()
  S.timers = {}
  P.run()
end
-- A message as mail.post queues it. Its from has no name.
local function queue(o)
  local msg = { id = o.id or "1795671000-abcd", posted = o.posted or S.now, head = o.head or "[from Me", tail = o.tail or ", who…] ",
    text = o.text or "hi", to = { host = o.host, session = "s:1", block = o.to or "block:to", name = o.name or "Reviewer" },
    from = o.from or { session = "s:1", block = "block:me" }, at = o.at, every = o.every, start = o.every and (o.start or S.now),
    seq = o.seq or 0, files = o.files }
  os.execute("mkdir -p " .. quote(root .. "/outbox"))
  mail.write(msg)
  return msg
end
local function queued() return ls(root .. "/outbox") end
local function read_msg(id)
  local f = io.open(root .. "/outbox/" .. id .. ".json")
  if not f then return nil end
  local m = json.decode(f:read("*a"))
  f:close()
  return m
end
local function texts(list)
  local out = {}
  for i, p in ipairs(list) do out[i] = p.text end
  return table.concat(out, " | ")
end

local n, failed = 0, 0
local function trial(name, f)
  n = n + 1
  reset()
  print = function(...) S.printed[#S.printed + 1] = table.concat({ ... }, "\t") end
  local ok, err = pcall(f)
  print = real_print
  for k, v in pairs(real_fake) do fake[k] = v end
  for k, v in pairs(real_mail) do mail[k] = v end
  for k, v in pairs(real_P) do P[k] = v end
  if not ok then failed = failed + 1 end
  lib.windows = false
  real_print((ok and "ok " or "not ok ") .. n .. " - " .. name .. (ok and "" or ": " .. tostring(err)))
end
local function fails(text, f)
  local ok, err = pcall(f)
  assert(not ok, "expected an error with " .. text)
  assert(tostring(err):find(text, 1, true), tostring(err))
end

-- OSC 7577 ------------------------------------------------------------------

trial("the postman reports its exact command with OSC 7577", function()
  start()
  local out = table.concat(S.out)
  local body, mac = out:match("^\27%]7577;(pid=%d+:time=1795671000:argv=[^:]+):mac=(%x+)\27\\$")
  assert(body, ("%q"):format(out))
  local want = run_sh({ "sh", "-c", 'printf %s "$1" | sha256sum | cut -c1-64', "sh", body .. ":" .. TOKEN }, {}).stdout:gsub("%s", "")
  assert(mac == want, "wrong mac")
  local words = {}
  for _, w in ipairs({ "rex", "do", lib.dir .. "postman.lua", "--args", "{}" }) do
    words[#words + 1] = (run_sh({ "sh", "-c", 'printf %s "$1" | base64 | tr -d "\\n"', "sh", w }, {}).stdout:gsub("%s", ""))
  end
  assert(body:match("argv=(.*)$") == table.concat(words, ","), body)
end)
trial("base64 pads one- and two-byte tails", function()
  local script = P.script
  P.script = "/ab/alarm.lua"
  local ok, err = pcall(P.report)
  P.script = script
  assert(ok, err)
  assert(table.concat(S.out):find("argv=cmV4,ZG8=,L2FiL2FsYXJtLmx1YQ==,LS1hcmdz,e30=:", 1, true), table.concat(S.out))
end)
trial("without OSC7577_TOKEN the postman stops before delivering anything", function()
  S.env.OSC7577_TOKEN = false
  queue({})
  local r = receiver("block:to")
  fails("OSC7577_TOKEN isn't set", start)
  assert(#S.out == 0 and #S.timers == 0 and #r.puts == 0)
end)
trial("on Windows the postman doesn't report", function()
  lib.windows = true
  start()
  assert(#S.out == 0)
end)

-- Singleton -------------------------------------------------------------------

trial("the postman claims postman.json with its block and pid", function()
  start()
  local f = assert(io.open(root .. "/postman.json"))
  local s = json.decode(f:read("*a"))
  f:close()
  assert(s.block == "block:pm" and s.pid == 4242 and s.session == nil)
  assert(not io.open(root .. "/postman.lock"), "the lock was left")
end)
trial("with no rex-teams folder yet, the first postman claims and delivers", function()
  os.execute("rm -rf " .. quote(root))
  start()
  local f = assert(io.open(root .. "/postman.json"), "not claimed")
  f:close()
  local r = receiver("block:to")
  queue({})
  run_to(S.t + 3)
  assert(#r.delivered == 1 and #queued() == 0)
end)
trial("two postmen starting at once: only one claims", function()
  S.blocks["block:pm2"] = { session = "s:home", pid = 4343 }
  local rename, second = os.rename, nil
  -- The second starts while the first is claiming.
  os.rename = function(a, b)
    if not second then
      second = true
      S.env.REX_BLOCK = "block:pm2"
      pcall(P.run)
      S.env.REX_BLOCK = "block:pm"
    end
    return rename(a, b)
  end
  local ok, err = pcall(P.run)
  os.rename = rename
  assert(ok, err)
  local delivering = 0
  for _, line in ipairs(S.printed) do
    if line:find("^postman: delivering") then delivering = delivering + 1 end
  end
  assert(second and delivering == 1, delivering .. " postmen claimed")
end)
trial("a second postman sees the first, closes its own block and stops", function()
  S.blocks["block:first"] = { session = "s:home", pid = 99 }
  lib.write(root .. "/postman.json", json.encode({ block = "block:first", pid = 99 }))
  start()
  assert(S.stopped == 0 and S.closed[1] == "block:pm" and #S.out == 0 and #S.timers == 0)
end)
trial("a postman.json whose process is gone is taken over", function()
  S.blocks["block:first"] = { session = "s:home", pid = 100 }
  lib.write(root .. "/postman.json", json.encode({ block = "block:first", pid = 99 }))
  start()
  assert(not S.stopped and table.concat(S.out):find("^\27%]7577;"))
end)

-- Delivery --------------------------------------------------------------------

trial("a queued message is pasted with its id, Entered and removed at once", function()
  local r = receiver("block:to")
  queue({})
  start()
  assert(texts(r.delivered) == "[from Me · msg 1795671000-abcd, who…] hi", texts(r.puts))
  assert(#r.puts == 1 and #queued() == 0)
end)
trial("messages to one receiver go in the order they were posted, all in one pass", function()
  local r = receiver("block:to")
  queue({ id = "1795671000-bbbb", posted = 1795671000, text = "second" })
  queue({ id = "1795671000-aaaa", posted = 1795670999, text = "first" })
  queue({ id = "1795671000-cccc", posted = 1795671000, seq = 1, text = "third" })
  start()
  assert(texts(r.delivered):gsub("%[[^]]*%] ", "") == "first | second | third", texts(r.delivered))
  assert(#queued() == 0)
end)
trial("a receiver Rex can't reach holds its queue in order, and nobody is told", function()
  local r = receiver("block:to", { "down" })
  local me = receiver("block:me")
  queue({ id = "1795671000-aaaa", text = "first" })
  queue({ id = "1795671000-bbbb", text = "second", seq = 1 })
  start()
  run_to(S.t + 1200)
  assert(#r.puts == 0 and #me.puts == 0 and #queued() == 2, #me.puts)
  r.script = { "up" }
  run_to(S.t + 3)
  assert(texts(r.delivered):gsub("%[[^]]*%] ", "") == "first | second", texts(r.delivered))
  assert(#queued() == 0)
end)
trial("a receiver that's down for one check, then up, still gets its messages in order", function()
  local r = receiver("block:to", { "down", "up" })
  queue({ id = "1795671000-aaaa", text = "first" })
  queue({ id = "1795671000-bbbb", text = "second", seq = 1 })
  start()
  run_to(S.t + 5)
  assert(texts(r.delivered):gsub("%[[^]]*%] ", "") == "first | second", texts(r.delivered))
end)
trial("an alarm waiting for its next tick, a one-shot not yet due, or a dead message doesn't hold up later messages", function()
  local me = receiver("block:me")
  queue({ id = "1795671000-alrm", head = "[alarm you set", tail = "] ", to = "block:me", every = 60 })
  queue({ id = "1795671000-late", head = "[alarm you set", tail = "] ", to = "block:me", at = S.now + 300, seq = 1 })
  start()
  run_to(S.t + 61)
  assert(texts(me.puts) == "[alarm you set · msg 1795671000-alrm.1] hi", texts(me.puts))
  queue({ id = "1795671061-mine", posted = S.now, to = "block:me", text = "for me" })
  receiver("block:gone")
  queue({ id = "1795671061-dead", posted = S.now, to = "block:gone" })
  S.receivers["block:gone"] = nil
  run_to(S.t + 3)
  queue({ id = "1795671064-next", posted = S.now, to = "block:gone", seq = 1, text = "next" })
  local r = receiver("block:gone")
  run_to(S.t + 3)
  assert(#me.delivered >= 2 and me.delivered[2].text:find("for me$"), texts(me.delivered))
  assert(texts(r.delivered):find("next$"), texts(r.delivered))
end)
trial("a file that isn't JSON stops delivery with one clear line until it's deleted", function()
  local r = receiver("block:to")
  queue({ id = "1795671000-good" })
  lib.write(root .. "/outbox/1795671000-badd.json", "nope")
  start()
  run_to(S.t + 10)
  local file = root .. "/outbox/1795671000-badd.json"
  local said = 0
  for _, line in ipairs(S.printed) do
    if line:find("postman: " .. file .. " isn't a message", 1, true) and line:find("; delete it$") then said = said + 1 end
  end
  assert(said == 1 and #r.puts == 0, table.concat(S.printed, " | "))
  os.remove(file)
  run_to(S.t + 3)
  assert(#r.puts == 1)
end)
trial("a postman that stops during a paste: the next one never pastes again, and tells the sender", function()
  local r = receiver("block:to")
  local me = receiver("block:me")
  queue({})
  local file, outbox = root .. "/outbox/1795671000-abcd.json", nil
  fake.put = function(addr, text)
    local f = assert(io.open(file))
    outbox = f:read("*a")
    f:close()
    return real_fake.put(addr, text)
  end
  start()
  fake.put = real_fake.put
  -- It stopped there: the outbox is as it was during the paste.
  lib.write(file, outbox)
  start()
  run_to(S.t + 30)
  assert(#r.puts == 1, "pasted " .. #r.puts .. " times")
  assert(texts(me.puts):find("Message 1795671000-abcd to Reviewer may not have arrived: the postman stopped between its paste and its Enter. It isn't sent again.", 1, true), texts(me.puts))
  assert(#queued() == 0)
end)
trial("a failed paste or Enter is reported to its sender once, and never pasted again", function()
  for _, fail in ipairs({ "put", "enter" }) do
    reset()
    local r = receiver("block:to")
    local me = receiver("block:me")
    queue({})
    fake[fail] = function(addr, text)
      if addr.block == "block:to" then
        if fail == "put" then r.puts[#r.puts + 1] = { t = S.t, text = text } end
        error("rex: block.event timed out", 0)
      end
      return real_fake[fail](addr, text)
    end
    start()
    run_to(S.t + 60)
    fake[fail] = real_fake[fail]
    assert(#r.puts == 1, fail .. ": pasted " .. #r.puts .. " times")
    assert(texts(me.puts) == "[rex-teams postman · msg " .. me.puts[1].text:match("msg (%S+)%]") .. "] Message 1795671000-abcd to Reviewer may not have arrived: rex: block.event timed out. It isn't sent again.", texts(me.puts))
    assert(#queued() == 0, fail .. ": still queued: " .. table.concat(queued(), " "))
  end
end)
trial("files for another host are copied once, and a failed copy is never pasted: its sender hears once, and the file is kept", function()
  local r = receiver("block:to")
  queue({ host = "ws", files = { "/w/a.md" } })
  start()
  assert(#r.delivered == 1 and r.copies == 1)

  reset()
  r = receiver("block:to")
  local me = receiver("block:me")
  queue({ host = "ws", files = { "/w/a.md" } })
  fake.attach = function() error("rex cp failed", 0) end
  start()
  run_to(S.t + 30)
  assert(#r.puts == 0, "pasted after a failed copy")
  assert(#me.puts == 1 and me.puts[1].text:find("Message 1795671000-abcd to Reviewer wasn't sent: rex cp failed. It's kept in " .. root .. "/outbox/1795671000-abcd.json.", 1, true), texts(me.puts))
  assert(read_msg("1795671000-abcd").dead == "files")
end)
trial("the receiver is checked again after the copy: gone keeps the message, unreachable holds it", function()
  local r = receiver("block:to", { "up", "gone" })
  local me = receiver("block:me")
  queue({ host = "ws", files = { "/w/a.md" } })
  start()
  run_to(S.t + 30)
  assert(#r.puts == 0 and #me.puts == 1 and me.puts[1].text:find("that pane is gone", 1, true), texts(me.puts))
  assert(read_msg("1795671000-abcd").dead == "gone", "not kept as gone")

  reset()
  r = receiver("block:to", { "up", "down", "down", "up" })
  me = receiver("block:me")
  queue({ host = "ws", files = { "/w/a.md" } })
  start()
  run_to(S.t + 3)
  assert(#r.puts == 0 and #me.puts == 0 and #queued() == 1, "pasted or dropped while unreachable")
  run_to(S.t + 3)
  assert(#r.delivered == 1 and r.copies == 1 and #queued() == 0, #r.delivered .. " delivered, " .. r.copies .. " copies")
end)
trial("deleting a message cancels it: held, while its receiver is checked, or while its files are copied", function()
  local r = receiver("block:to", { "down" })
  queue({})
  start()
  run_to(S.t + 5)
  os.remove(root .. "/outbox/1795671000-abcd.json")
  run_to(S.t + 3)
  r.script = { "up" }
  run_to(S.t + 3)
  assert(#r.puts == 0 and #queued() == 0)

  for _, when in ipairs({ "check", "copy" }) do
    reset()
    for k, v in pairs(real_fake) do fake[k] = v end
    r = receiver("block:to")
    queue({ host = "ws", files = { "/w/a.md" } })
    fake[when == "check" and "exists" or "attach"] = function(addr)
      os.remove(root .. "/outbox/1795671000-abcd.json")
      return real_fake[when == "check" and "exists" or "attach"](addr)
    end
    start()
    run_to(S.t + 30)
    assert(#r.puts == 0 and #queued() == 0, when .. ": pasted")
    assert(r.copies == (when == "check" and 0 or 1), when .. ": " .. r.copies .. " copies")
  end
end)
trial("a receiver that's gone: one notice, and the file is kept", function()
  local me = receiver("block:me")
  queue({ to = "block:gone" })
  start()
  run_to(S.t + 100)
  assert(#me.puts == 1 and me.puts[1].text:find("Message 1795671000-abcd to Reviewer can't be delivered: that pane is gone. It's kept in " .. root .. "/outbox/1795671000-abcd.json.", 1, true), texts(me.puts))
  assert(read_msg("1795671000-abcd").dead == "gone")
end)
trial("nothing tells you about your own messages, and notices cause no notices", function()
  local me = receiver("block:me")
  fake.put = function(addr, text)
    real_fake.put(addr, text)
    if addr.block == "block:me" then error("rex: block.event timed out", 0) end
  end
  queue({ id = "1795671000-self", to = "block:me", name = "Me" })
  mail.notice({ session = "s:1", block = "block:me" }, "x")
  mail.notice({ session = "s:1", block = "block:gone" }, "y")
  start()
  run_to(S.t + 10)
  fake.put = real_fake.put
  assert(#me.puts == 2 and not texts(me.puts):find("Message ", 1, true), texts(me.puts))
  local ids = queued()
  assert(#ids == 1, #ids .. " queued")
  local m = read_msg(ids[1]:gsub("%.json$", ""))
  assert(m.notice and m.dead == "gone", "dead=" .. tostring(m.dead))
  for _, line in ipairs(S.printed) do assert(not line:find("%.lua:%d+:"), line) end
  -- The next message to that sender still goes out.
  queue({ id = "1795671010-next", posted = S.now, to = "block:me", from = { session = "s:1", block = "block:other" } })
  run_to(S.t + 3)
  assert(#me.delivered == 1 and me.delivered[1].text:find("1795671010-next", 1, true), texts(me.delivered))
end)
trial("a postman that stops while telling a sender still tells them", function()
  for _, case in ipairs({ "paste", "gone", "files" }) do
    reset()
    local me = receiver("block:me")
    local r = receiver("block:to")
    if case == "gone" then queue({ to = "block:gone" }) else queue({ host = case == "files" and "ws" or nil, files = case == "files" and { "/w/a.md" } or nil }) end
    if case == "paste" then
      fake.put = function(addr, text)
        if addr.block == "block:to" then error("rex: block.event timed out", 0) end
        return real_fake.put(addr, text)
      end
    end
    fake.attach = function() error("rex cp failed", 0) end
    -- The postman stops as it writes the notice.
    mail.notice = function() error("postman stopped", 0) end
    start()
    mail.notice = real_mail.notice
    start()
    run_to(S.t + 30)
    assert(#me.puts >= 1, case .. ": the sender wasn't told")
    assert(#r.puts <= 1, case .. ": pasted twice")
    local m = read_msg("1795671000-abcd")
    if case == "paste" then assert(not m, "kept") else assert(m and m.dead == case, case .. ": not kept") end
  end
end)

-- Alarms ------------------------------------------------------------------------

local function alarm(o)
  o.head, o.tail, o.to = "[alarm you set", "] ", "block:me"
  return queue(o)
end
trial("a one-shot fires once at its absolute time, not a fresh countdown, and is removed", function()
  local me = receiver("block:me")
  alarm({ at = S.now + 120 })
  run_to(S.t + 50)
  start()
  run_to(S.t + 69)
  assert(#me.puts == 0)
  run_to(S.t + 100)
  assert(#me.puts == 1 and me.puts[1].t == 1795671120 and me.puts[1].text == "[alarm you set · msg 1795671000-abcd] hi", texts(me.puts))
  assert(#queued() == 0)
end)
trial("a one-shot that starts at least 1s late fires at once with a note; on time, without", function()
  local me = receiver("block:me")
  alarm({ at = S.now + 20 })
  run_to(S.t + 39)
  start()
  assert(texts(me.puts) == "[alarm you set · msg 1795671000-abcd] hi [late by 19s, Rex restarted]", texts(me.puts))
  for _, at in ipairs({ { 20, 20 }, { 0.5, 1.05 } }) do
    reset()
    me = receiver("block:me")
    S.t, S.now = 1795671000.95, 1795671000
    alarm({ at = 1795671000 + at[1] })
    S.t = 1795671000 + at[2]
    S.now = math.floor(S.t)
    start()
    run_to(S.t + 0.1)
    assert(texts(me.puts) == "[alarm you set · msg 1795671000-abcd] hi", "on time is not late: " .. texts(me.puts))
  end
end)
trial("a one-shot never fires before its time", function()
  for _, wait in ipairs({ 5, 1.5, 0.5 }) do
    reset()
    local me = receiver("block:me")
    S.t, S.now = 1795671000.95, 1795671000
    alarm({ at = 1795671000 + wait })
    start()
    run_to(S.t + 10)
    assert(#me.puts == 1 and me.puts[1].t >= 1795671000 + wait, ("at +%s fired at +%.2f"):format(wait, me.puts[1].t - 1795671000))
  end
end)
trial("a recurring alarm sends one catch-up tick after a restart, keeps its phase, and stays queued", function()
  local me = receiver("block:me")
  alarm({ every = 60 })
  run_to(S.t + 140) -- restarted after ticks at +60 and +120 passed
  start()
  assert(texts(me.puts) == "[alarm you set · msg 1795671000-abcd.2] hi", texts(me.puts))
  run_to(S.t + 39)
  assert(#me.puts == 1)
  run_to(S.t + 1)
  assert(#me.puts == 2 and me.puts[2].t == 1795671180 and me.puts[2].text:find("abcd.3]", 1, true) and #queued() == 1)
end)
trial("after a sleep, the ticks that piled up collapse into one catch-up tick", function()
  local me = receiver("block:me")
  alarm({ every = 60 })
  start()
  -- The whole machine sleeps: no timer runs until +650.
  S.t = S.t + 650
  S.now = math.floor(S.t)
  run_to(S.t + 0.5)
  assert(#me.puts == 1 and me.puts[1].text:find("abcd.10]", 1, true), texts(me.puts))
  run_to(1795671661)
  assert(#me.puts == 2 and me.puts[2].t == 1795671660 and me.puts[2].text:find("abcd.11]", 1, true))
end)
trial("fractional and short recurring alarms fire on their phase, never early or twice", function()
  for _, every in ipairs({ 0.5, 2.5, 3.3, 10.5 }) do
    reset()
    local me = receiver("block:me")
    S.t, S.now = 1795671000.7, 1795671000
    alarm({ every = every, start = 1795671000 })
    S.t = 1795671000.9
    start()
    for _ = 1, 4000 do
      run_to(S.t + 0.05)
      if #me.puts >= 12 then break end
    end
    assert(#me.puts >= 12, every .. ": " .. #me.puts .. " ticks")
    local last
    for _, p in ipairs(me.puts) do
      local tick = tonumber(p.text:match("%.(%d+)%]"))
      local due = 1795671000 + tick * every
      assert(p.t >= due - 1e-9 and p.t < due + 1, ("every=%s tick %d at +%.2f, due +%.2f"):format(every, tick, p.t - 1795671000, due - 1795671000))
      assert(not last or tick > last, "tick " .. tick .. " twice")
      -- Below a second, whole-second clocks collapse ticks; above, none is lost.
      if every >= 1 and last and tick ~= last + 1 then error(("every=%s: ticks %d to %d skipped"):format(every, last + 1, tick - 1), 0) end
      last = tick
    end
  end
end)
-- Four held receivers whose checks take STEP seconds each, and an alarm
-- every EVERY seconds to block:me.
local function slow_world(step, every)
  local me = receiver("block:me")
  for i = 1, 4 do
    receiver("block:o" .. i, { "down" })
    queue({ id = "1795671000-oo" .. string.char(96 + i) .. "a", to = "block:o" .. i })
  end
  alarm({ id = "1795671000-alrm", every = every })
  fake.exists = function(addr)
    if addr.block ~= "block:me" then S.t = S.t + step S.now = math.floor(S.t) end
    return real_fake.exists(addr)
  end
  return me
end
trial("a recurring tick is pasted while slow checks of other receivers delay it", function()
  local me = slow_world(0.3, 5)
  start()
  for _ = 1, 600 do run_to(S.t + 0.1) end
  local due = math.floor((S.t - 1795671000) / 5)
  for i, p in ipairs(me.puts) do
    local tick = tonumber(p.text:match("%.(%d+)%]"))
    assert(tick == i, "tick " .. i .. " skipped, pasted " .. tick)
    assert(p.t >= 1795671000 + 5 * tick, "early")
  end
  assert(#me.puts >= due - 1, #me.puts .. " of " .. due .. " ticks")
end)
trial("a slow pass of other receivers never drops an alarm tick that nothing overtook", function()
  -- Each pass takes longer than the alarm's interval.
  local me = slow_world(3, 10)
  -- Each time the postman turns to the alarm, the last tick due then must
  -- go out: only a later tick due too may take its place.
  local turns = {}
  P.deliver = function(msg, now)
    if msg.every then turns[#turns + 1] = { t = S.t, k = math.floor((now - msg.start) / 10) } end
    return real_P.deliver(msg, now)
  end
  start()
  for _ = 1, 600 do run_to(S.t + 0.1) end
  local pasted, last = {}, 0
  for _, p in ipairs(me.puts) do
    local tick = tonumber(p.text:match("msg 1795671000%-alrm%.(%d+)%]"))
    assert(tick > last, "tick " .. tick .. " after " .. last)
    assert(p.t >= 1795671000 + 10 * tick, "tick " .. tick .. " early")
    pasted[tick], last = true, tick
  end
  assert(last >= 10, "only up to tick " .. last)
  for _, turn in ipairs(turns) do
    if turn.k > 0 and turn.t < S.t - 30 then
      assert(pasted[turn.k], ("tick %d was the last due at +%.1f, and never went out"):format(turn.k, turn.t - 1795671000))
    end
  end
end)
trial("a held tick goes out however late, and one held past the next tick is overtaken by it", function()
  local me = receiver("block:me", { "down" })
  alarm({ every = 10 })
  start()
  run_to(S.t + 15)
  me.script = { "up" }
  run_to(S.t + 3)
  assert(texts(me.puts) == "[alarm you set · msg 1795671000-abcd.1] hi", texts(me.puts))
  me.script = { "down" }
  run_to(1795671045)
  me.script = { "up" }
  run_to(S.t + 3)
  assert(#me.puts == 2 and me.puts[2].text:find("msg 1795671000-abcd.4]", 1, true), texts(me.puts))
  run_to(1795671051)
  assert(#me.puts == 3 and me.puts[3].t == 1795671050 and me.puts[3].text:find("msg 1795671000-abcd.5]", 1, true), texts(me.puts))
end)
trial("a failed recurring tick drops only that tick: its sender hears once, even after a restart", function()
  local r = receiver("block:to")
  local me = receiver("block:me")
  queue({ every = 60 })
  fake.put = function(addr, text) if addr.block == "block:to" then error("rex: block.event timed out", 0) end return real_fake.put(addr, text) end
  start()
  run_to(S.t + 65)
  fake.put = real_fake.put
  assert(#me.puts == 1 and me.puts[1].text:find("Message 1795671000-abcd.1 to Reviewer may not have arrived", 1, true), texts(me.puts))
  start()
  run_to(S.t + 30)
  assert(#me.puts == 1, "the sender was told " .. #me.puts .. " times")
  run_to(1795671121)
  assert(#r.puts == 1 and r.puts[1].text:find("msg 1795671000-abcd.2,", 1, true), texts(r.puts))
end)
trial("a paste slower than its alarm's interval doesn't loop: each pass sends the tick due then, in order", function()
  local me = receiver("block:me")
  alarm({ every = 10 })
  fake.put = function(addr, text) S.t = S.t + 12 S.now = math.floor(S.t) return real_fake.put(addr, text) end
  start()
  run_to(1795671000 + 100)
  local last = 0
  for _, p in ipairs(me.delivered) do
    local k = tonumber(p.text:match("abcd%.(%d+)%]"))
    assert(k > last, "tick twice")
    -- Each paste carries the last tick due when it began.
    assert(math.floor((p.t - 12 - 1795671000) / 10) == k, "not the latest due tick: " .. k)
    last = k
  end
  assert(last >= 7)
end)

-- Faults ------------------------------------------------------------------------

-- Each Rex call and each write deliver makes raises once, on its first
-- call. Each message is still delivered or its sender told, and nothing is
-- pasted twice.
local faults = {
  { "pane.exists", fake, "exists" }, { "pane.attach", fake, "attach" }, { "pane.put", fake, "put" }, { "pane.enter", fake, "enter" },
  { "mail.write", mail, "write" }, { "mail.notice", mail, "notice" }, { "mail.remove", mail, "remove" },
}
-- Each case queues 1795671000-abcd, then a message behind it to the same
-- receiver (block:to for "gone").
local cases = {
  message = {},
  files = { host = "ws", files = { "/w/a.md" } },
  gone = { to = "block:gone" },
  alarm = { every = 30 },
}
local fired = {}
trial("a Rex call or a write that raises once loses, doubles and misorders nothing", function()
  for _, fault in ipairs(faults) do
    for case, o in pairs(cases) do
      reset()
      for k, v in pairs(real_fake) do fake[k] = v end
      local r = receiver("block:to")
      local me = receiver("block:me")
      queue(o)
      queue({ id = "1795671000-zzzz", host = o.host, seq = 1, text = "behind" })
      local real, raised = fault[2][fault[3]], false
      fault[2][fault[3]] = function(...)
        if not raised then
          raised = true
          fired[fault[1]] = true
          error("fault in " .. fault[1], 0)
        end
        return real(...)
      end
      local ok, err = pcall(function()
        start()
        run_to(S.t + 100)
      end)
      fault[2][fault[3]] = real
      local where = fault[1] .. ", " .. case .. ": "
      assert(ok, where .. tostring(err))
      local told = texts(me.delivered):find("Message 1795671000-abcd", 1, true) ~= nil
      local seen = {}
      for _, p in ipairs(r.puts) do
        local tag = p.text:match("msg (%S+),")
        assert(not seen[tag], where .. tag .. " pasted twice")
        seen[tag] = true
      end
      local abcd = {}
      for i, p in ipairs(r.delivered) do if p.text:find("msg 1795671000%-abcd") then abcd[#abcd + 1] = i end end
      if case == "gone" then
        assert(told and read_msg("1795671000-abcd").dead == "gone", where .. "not told, or not kept")
      elseif case == "alarm" then
        assert(#abcd + (told and 1 or 0) >= 3, where .. #abcd .. " ticks delivered, told " .. tostring(told))
      else
        assert(#abcd == 1 or told, where .. "neither delivered nor told")
      end
      -- The message behind arrives once, after the one ahead of it.
      local behind = select(2, texts(r.delivered):gsub("behind", ""))
      assert(behind == 1 or (behind == 0 and texts(me.delivered):find("Message 1795671000-zzzz", 1, true)), where .. "behind: " .. texts(r.delivered))
      if case == "message" or case == "files" then
        assert(#abcd == 0 or r.delivered[#r.delivered].text:find("behind$"), where .. "out of order: " .. texts(r.delivered))
      end
    end
  end
  for _, fault in ipairs(faults) do assert(fired[fault[1]], fault[1] .. " never raised") end
end)

-- ensure ------------------------------------------------------------------------

-- P.ensure while the postman it starts, block:new, does WHAT as it waits:
-- "claims", "fails" (exits), "hangs", or "loses" to another postman and
-- closes its own block.
local function ensure(what)
  S.on_sleep = function(i)
    if what == "claims" and i == 1 then lib.write(root .. "/postman.json", json.encode({ block = "block:new", pid = 7 })) end
    if what == "fails" and i == 1 then S.blocks["block:new"].last_exit = { exit_code = 1 } end
    if what == "loses" and i == 1 then
      -- The winner has claimed, but Rex doesn't show its process yet.
      S.blocks["block:other"] = { session = "s:home" }
      lib.write(root .. "/postman.json", json.encode({ block = "block:other", pid = 8 }))
      S.blocks["block:new"] = nil
    end
    if what == "loses" and i == 2 then S.blocks["block:other"].pid = 8 end
  end
  return P.ensure()
end

trial("ensure starts the postman in a rex-teams session, and returns once it claims", function()
  assert(ensure("claims") == nil)
  local nb = assert(S.new_block, "no block started")
  local c = nb.options.command
  assert(S.created == "rex-teams" and nb.session_id == "s:home" and nb.label == "rex-teams postman")
  assert(#c == 5 and c[1] == "rex" and c[2] == "do" and c[3] == lib.dir .. "postman.lua" and c[4] == "--args" and c[5] == "{}", table.concat(c, " "))
  assert(nb.options.exit.on_completion == false, "a failed postman's block must stay")
  assert(S.sleeps == 1, S.sleeps .. " sleeps")
end)
trial("ensure reuses the session labelled rex-teams", function()
  S.sessions = { { session_id = "s:theirs", label = "work" }, { session_id = "s:rt", label = "rex-teams" } }
  ensure("claims")
  assert(S.new_block.session_id == "s:rt" and not S.created)
end)
trial("ensure leaves a running postman alone", function()
  S.blocks["block:first"] = { session = "s:home", pid = 99 }
  lib.write(root .. "/postman.json", json.encode({ block = "block:first", pid = 99 }))
  assert(ensure("hangs") == nil and not S.new_block)
end)
trial("ensure returns when another postman wins the claim", function()
  assert(ensure("loses") == nil)
  assert(S.sleeps == 2, S.sleeps .. " sleeps")
end)
trial("a postman that fails to start is an error naming its block, which stays open", function()
  fails("the postman didn't start. See why with: rex capture -s s:home -b block:new", function() ensure("fails") end)
  assert(#S.closed == 0, "the failed postman's block was closed")
end)
trial("a postman that doesn't claim within 5s is an error naming its block", function()
  fails("the postman didn't start within 5s. See why with: rex capture -s s:home -b block:new", function() ensure("hangs") end)
  assert(S.sleeps == 100, S.sleeps .. " sleeps")
end)
trial("a postman that can't report never claims, so ensure raises", function()
  S.env.OSC7577_TOKEN = false
  local ran
  S.on_sleep = function(i)
    if i ~= 1 then return end
    S.env.REX_BLOCK = "block:new"
    ran = { pcall(P.run) }
    S.env.REX_BLOCK = "block:pm"
    S.blocks["block:new"].last_exit = { exit_code = 1 }
  end
  fails("the postman didn't start.", P.ensure)
  assert(ran[1] == false and tostring(ran[2]):find("OSC7577_TOKEN", 1, true), tostring(ran[2]))
  assert(not io.open(root .. "/postman.json"), "claimed without reporting")
end)

-- The trust rule ----------------------------------------------------------------

trial("README quotes the trust rule as postman.lua writes it", function()
  local f = assert(io.open("README.md"))
  local readme = f:read("*a")
  f:close()
  local generic = P.rule():gsub(lib.dir:sub(1, -2):gsub("%p", "%%%0"), "<skill>/scripts")
  assert(readme:find(generic, 1, true), "README.md doesn't quote: " .. generic)
end)
trial("the trust rule checks out with rex config check's syntax", function()
  -- rex.match.under takes the scripts folder, without a trailing slash.
  assert(P.rule():find('rex.match.under("' .. lib.dir:sub(1, -2) .. '")', 1, true), P.rule())
end)

os.execute("rm -rf " .. quote(tmp))
dofile, os.time, os.getenv = real_dofile, real_time, real_getenv
if failed > 0 then print(failed .. " of " .. n .. " postman trials failed.") os.exit(1) end
print("Passed " .. n .. " postman trials.")
