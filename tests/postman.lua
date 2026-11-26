-- Run from the repo root with `luajit tests/postman.lua` or `lua5.1 tests/postman.lua`.
-- The postman's worker, run against a mock Rex: its timers and events run on
-- a fake clock, the outbox is a real scratch folder, and pane.lua is replaced
-- by scripted receivers. The one real command is the OSC 7577 shell, run
-- with a fixed token.
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
    calls = {}, timers = {}, out = {}, printed = {}, stopped = nil, closed = {},
    receivers = {}, records = { { chosen = true, trusted = true } }, waited = nil,
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
    S.calls[#S.calls + 1] = { method = method, args = args }
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
      return { block_id = "block:new" }
    end
    if method == "com.superlogical.terminal.program_resume_records" then return { records = S.records } end
    if method == "block.method" then
      local b = S.blocks[args.block_id]
      if args.method == "process" then
        if S.process then return S.process(args.block_id) end
        return { foreground = b and b.pid and { pid = b.pid, name = "rex" } }
      end
      if args.method == "list_dir" then
        local entries = {}
        for _, name in ipairs(ls(args.args.path)) do entries[#entries + 1] = { name = name } end
        return { status = "ok", entries = entries }
      end
      if args.method == "format" then return { content = "Error: something broke\n" } end
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
  after = function(s, f)
    local timer = { due = S.t + s, f = f, live = true }
    function timer.cancel() timer.live = false end
    S.timers[#S.timers + 1] = timer
    return timer
  end,
  wait = function(event, filter, timeout)
    S.waited = { event = event, timeout = timeout }
    S.records = S.late_records or S.records
    if S.event and filter(S.event) then return S.event end
    return nil, "timeout"
  end,
  sleep = function() end,
  stop = function(code) S.stopped = code end,
}

-- Scripted receivers in place of pane.lua.
local fake = {}
-- A receiver shows its prompt box: what's pasted and not yet Entered, or a
-- draft. A shell's isn't read.
function fake.look(addr)
  local r = S.receivers[addr.block]
  if not r then return { gone = true } end
  r.looks = r.looks + 1
  if r.shell then return { app = "zsh", known = false } end
  return { app = "pi", known = true, composer = { text = r.pending or r.draft or "" } }
end
function fake.put(addr, text)
  local r = S.receivers[addr.block]
  r.puts[#r.puts + 1] = { t = S.t, text = text }
  r.pending = text
end
function fake.enter(addr)
  local r = S.receivers[addr.block]
  r.enters = r.enters + 1
  if r.pending and r.swallow > 0 then r.swallow = r.swallow - 1 return end
  if r.pending then
    r.delivered[#r.delivered + 1] = { t = S.t, text = r.pending }
    r.pending = nil
  end
end
function fake.attach() end
local function receiver(block, o)
  local r = { puts = {}, delivered = {}, enters = 0, looks = 0, swallow = 0 }
  for k, v in pairs(o or {}) do r[k] = v end
  S.receivers[block] = r
  S.blocks[block] = S.blocks[block] or { session = "s:1" }
  return r
end

local lib = real_dofile("skills/rex-teams/scripts/lib.lua")
lib.root = root
dofile = function(path)
  if path:match("/lib%.lua$") then return lib end
  if path:match("/pane%.lua$") then return fake end
  return real_dofile(path)
end
local P = real_dofile("skills/rex-teams/scripts/postman.lua")
local mail = real_dofile("skills/rex-teams/scripts/mail.lua")

-- Run the clock to T (real time, fractional), firing timers in order.
local function run_to(t)
  for _ = 1, 100000 do
    local next_i
    for i, timer in ipairs(S.timers) do
      if timer.live and (not next_i or timer.due < S.timers[next_i].due) then next_i = i end
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
local function start()
  print = function(...) S.printed[#S.printed + 1] = table.concat({ ... }, "\t") end
  local ok, err = pcall(P.run)
  print = real_print
  if not ok then error(err, 0) end
end
local function queue(o)
  local msg = { id = o.id or "1795671000-abcd", posted = o.posted or S.now, head = o.head or "[from Me", tail = o.tail or ", who…] ",
    text = o.text or "hi", to = { host = o.host, session = "s:1", block = o.to or "block:to", name = "Reviewer" },
    from = o.from or { session = "s:1", block = "block:me", name = "Me" }, at = o.at, every = o.every, start = o.every and (o.start or S.now),
    seq = o.seq or 0, files = o.files, dead = o.dead, d = o.d }
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

local n, failed = 0, 0
local function trial(name, f)
  n = n + 1
  reset()
  local ok, err = pcall(f)
  print = real_print
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
  receiver("block:to")
  fails("OSC7577_TOKEN isn't set", start)
  assert(#S.out == 0 and #S.timers == 0 and #S.receivers["block:to"].puts == 0)
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
  assert(s.block == "block:pm" and s.session == "s:home" and s.pid == 4242)
  assert(not io.open(root .. "/postman.lock"), "the lock was left")
end)
trial("a second postman sees the first, closes its own block and stops", function()
  S.blocks["block:first"] = { session = "s:home", pid = 99 }
  lib.write(root .. "/postman.json", json.encode({ block = "block:first", session = "s:home", pid = 99 }))
  start()
  assert(S.stopped == 0 and S.closed[1] == "block:pm" and #S.out == 0 and #S.timers == 0)
end)
trial("a postman.json whose process is gone is taken over", function()
  S.blocks["block:first"] = { session = "s:home", pid = 100 }
  lib.write(root .. "/postman.json", json.encode({ block = "block:first", session = "s:home", pid = 99 }))
  start()
  assert(not S.stopped and table.concat(S.out):find("^\27%]7577;"))
end)

-- Delivery --------------------------------------------------------------------

trial("a queued message is pasted, Entered, looked at once 2 s later, and removed", function()
  local r = receiver("block:to")
  queue({})
  start()
  run_to(S.t + 0.1)
  assert(#r.puts == 1 and r.puts[1].text == "[from Me · msg 1795671000-abcd, who…] hi", r.puts[1] and r.puts[1].text)
  assert(r.enters == 1 and #queued() == 1 and r.looks == 1)
  run_to(S.t + 2)
  assert(r.enters == 1 and r.looks == 2 and #queued() == 0, "still queued: " .. table.concat(queued(), " "))
end)
trial("a lost Enter is pressed once more, and only once", function()
  for _, lost in ipairs({ 1, 2 }) do
    reset()
    local r = receiver("block:to", { swallow = lost })
    queue({})
    start()
    run_to(S.t + 30)
    assert(#r.puts == 1 and r.enters == 2 and #r.delivered == 2 - lost and #queued() == 0, lost .. ": " .. r.enters)
  end
end)
trial("a busy receiver gets the message at once", function()
  local r = receiver("block:to", { status = "working" })
  local look = fake.look
  fake.look = function(addr) local l = look(addr) l.status = "working" return l end
  queue({})
  start()
  run_to(S.t + 0.1)
  fake.look = look
  assert(#r.puts == 1 and #r.delivered == 1)
end)
trial("a shell gets the message pasted and Entered, then it's done", function()
  local r = receiver("block:to", { shell = true })
  queue({})
  start()
  run_to(S.t + 0.1)
  assert(#r.puts == 1 and r.enters == 1 and r.looks == 1 and #queued() == 0)
end)
trial("a draft is held, then delivered once it's cleared", function()
  local r = receiver("block:to", { draft = "half a thought" })
  queue({})
  start()
  run_to(S.t + 30)
  assert(#r.puts == 0)
  r.draft = nil
  run_to(S.t + 5)
  assert(#r.puts == 1 and #queued() == 0)
end)
trial("messages to one receiver go one at a time, oldest first", function()
  local r = receiver("block:to")
  queue({ id = "1795671000-bbbb", posted = 1795671001 })
  queue({ id = "1795671000-aaaa", posted = 1795671000 })
  start()
  run_to(S.t + 0.1)
  assert(#r.puts == 1 and r.puts[1].text:find("aaaa", 1, true))
  run_to(S.t + 10)
  assert(#r.puts == 2 and r.puts[2].text:find("bbbb", 1, true) and #queued() == 0)
end)
trial("messages posted in one second go in the order they were posted", function()
  local r = receiver("block:to")
  queue({ id = "1795671000-zzzz", text = "first" })
  queue({ id = "1795671000-aaaa", text = "second", seq = 1 })
  start()
  run_to(S.t + 20)
  assert(#r.puts == 2 and r.puts[1].text:find("first$") and r.puts[2].text:find("second$"), r.puts[1] and r.puts[1].text)
end)
trial("a dead message doesn't hold up the ones behind it", function()
  local r = receiver("block:to")
  queue({ id = "1795671000-aaaa", dead = "files", d = { tag = "1795671000-aaaa", attach_error = "rex cp failed" } })
  queue({ id = "1795671000-bbbb", seq = 1 })
  start()
  run_to(S.t + 5)
  assert(#r.puts == 1 and r.puts[1].text:find("bbbb", 1, true) and #queued() == 1)
end)
trial("a broken file is set aside once and named, and the rest still go", function()
  local r = receiver("block:to")
  queue({ id = "1795671000-good" })
  local bad = queue({ id = "1795671000-badd", to = "block:other" })
  bad.head = nil
  mail.write(bad)
  start()
  run_to(S.t + 10)
  assert(#r.puts == 1 and #r.delivered == 1, "valid message pasted " .. #r.puts .. " times; " .. table.concat(S.printed, " | "))
  local file = root .. "/outbox/1795671000-badd.json"
  local said = 0
  for _, line in ipairs(S.printed) do
    if line == "postman: " .. file .. " has no head, so it can't be delivered; set aside as " .. file .. ".bad" then said = said + 1 end
  end
  assert(said == 1, table.concat(S.printed, " | "))
  assert(io.open(file .. ".bad") and not io.open(file), "not set aside")
end)
trial("a file with a field of the wrong type is set aside once, and the rest still go", function()
  local r = receiver("block:to")
  queue({ id = "1795671000-good" })
  local bad = queue({ id = "1795671000-badd", to = "block:other" })
  bad.to = false
  mail.write(bad)
  start()
  run_to(S.t + 10)
  assert(#r.puts == 1, "valid message pasted " .. #r.puts .. " times; " .. table.concat(S.printed, " | "))
  local file = root .. "/outbox/1795671000-badd.json"
  local said = 0
  for _, line in ipairs(S.printed) do
    if line:find(file .. " has a to that isn't a table", 1, true) then said = said + 1 end
  end
  assert(said == 1, table.concat(S.printed, " | "))
  assert(io.open(file .. ".bad") and not io.open(file), "not set aside")
end)
trial("serve follows the policy until it waits, however many steps that takes", function()
  local r = receiver("block:to")
  queue({})
  local step, looks = P.step, 0
  -- A policy that looks a dozen times before it pastes.
  P.step = function(msg, look, now)
    if looks < 12 then looks = looks + 1 return { kind = "look" } end
    return step(msg, look, now)
  end
  local ok, err = pcall(start)
  P.step = step
  assert(ok, err)
  assert(#r.puts == 1, "not pasted in the first pass")
end)
trial("the attempt is recorded before the paste", function()
  local r = receiver("block:to")
  queue({})
  local put = fake.put
  local on_disk
  fake.put = function(addr, text) on_disk = read_msg("1795671000-abcd") put(addr, text) end
  start()
  run_to(S.t + 0.1)
  fake.put = put
  assert(#r.puts == 1 and on_disk and on_disk.d and on_disk.d.pasted_at == 1795671000)
end)
trial("a draft typed while the files are copied holds the paste", function()
  local r = receiver("block:to")
  queue({ host = "ws", files = { "/w/a.md" } })
  fake.attach = function() r.draft = "a person typing" end
  start()
  run_to(S.t + 5)
  fake.attach = function() end
  assert(#r.puts == 0, "pasted onto a draft")
  r.draft = nil
  run_to(S.t + 5)
  assert(#r.puts == 1 and #queued() == 0)
end)
trial("a message deleted while its files are copied is never pasted", function()
  local r = receiver("block:to")
  queue({ host = "ws", files = { "/w/a.md" } })
  fake.attach = function() os.remove(root .. "/outbox/1795671000-abcd.json") end
  start()
  run_to(S.t + 30)
  fake.attach = function() end
  assert(#r.puts == 0 and #queued() == 0, #r.puts)
end)
trial("deleting a queued file drops the message", function()
  local r = receiver("block:to", { draft = "typing" })
  queue({})
  start()
  run_to(S.t + 5)
  os.remove(root .. "/outbox/1795671000-abcd.json")
  run_to(S.t + 3)
  r.draft = nil
  run_to(S.t + 3)
  assert(#r.puts == 0 and #queued() == 0)
end)
trial("a message held 10 minutes queues one notice to its sender", function()
  receiver("block:to", { draft = "typing" })
  local me = receiver("block:me", { draft = "busy" })
  queue({})
  start()
  run_to(S.t + 599)
  assert(#queued() == 1)
  run_to(S.t + 5)
  local names = queued()
  assert(#names == 2, table.concat(names, " "))
  local notice
  for _, name in ipairs(names) do
    local m = read_msg(name:match("^(.*)%.json$"))
    if m.notice then notice = m end
  end
  assert(notice and notice.to.block == "block:me" and notice.text:find("has waited 10 minutes: there\'s text in its prompt box", 1, true), notice and notice.text)
  run_to(S.t + 1200)
  assert(#queued() == 2, "a second notice")
  me.draft = nil
  run_to(S.t + 3)
  assert(#me.puts == 1 and me.puts[1].text:find("^%[rex%-teams postman · msg %d+%-%a%a%a%a%] Message 1795671000%-abcd to Reviewer"), me.puts[1] and me.puts[1].text)
end)
trial("a message queued behind a held one also tells its sender, once", function()
  local r = receiver("block:to", { draft = "typing" })
  receiver("block:me", { draft = "busy" })
  receiver("block:other", { draft = "busy" })
  queue({ id = "1795671000-aaaa" })
  run_to(S.t + 1)
  queue({ id = "1795671001-bbbb", text = "second", from = { session = "s:1", block = "block:other", name = "Other" } })
  start()
  local function notices()
    local by = {}
    for _, name in ipairs(queued()) do
      local m = read_msg(name:match("^(.*)%.json$"))
      if m.notice then by[m.to.block] = (by[m.to.block] or 0) + 1 end
    end
    return by
  end
  run_to(S.t + 598)
  assert(not notices()["block:other"], "too soon")
  run_to(S.t + 5)
  local by = notices()
  assert(by["block:me"] == 1 and by["block:other"] == 1, tostring(by["block:other"]))
  -- The first goes; the second is then held at the front, and says nothing more.
  r.draft = nil
  while #r.puts == 0 do run_to(S.t + 0.1) end
  r.draft = "typing again"
  run_to(S.t + 1300)
  assert(#r.puts == 1 and notices()["block:other"] == 1, "a second notice")
end)
trial("a receiver that's gone: one notice, and the file is kept", function()
  local me = receiver("block:me")
  queue({ to = "block:gone" })
  start()
  run_to(S.t + 5)
  assert(#me.puts == 1 and me.puts[1].text:find("can't be delivered: that pane is gone", 1, true))
  local m = read_msg("1795671000-abcd")
  assert(m and m.dead == "gone")
  run_to(S.t + 100)
  assert(#me.puts == 1)
end)
trial("a restart mid-delivery takes its one look rather than pasting again", function()
  for _, left in ipairs({ false, true }) do
    reset()
    local r = receiver("block:to")
    local msg = queue({})
    local text = "[from Me · msg 1795671000-abcd, who…] hi"
    if left then r.pending = text end
    msg.d = { tag = msg.id, pasted_at = S.now, known = true, text = text }
    mail.write(msg)
    start()
    run_to(S.t + 30)
    assert(#r.puts == 0 and #queued() == 0 and r.enters == (left and 1 or 0), tostring(left) .. ": " .. r.enters)
  end
end)

-- Alarms ------------------------------------------------------------------------

local function alarm(o)
  o.head, o.tail, o.to = "[alarm you set", "] ", "block:me"
  return queue(o)
end
trial("a one-shot fires at its absolute time, not a fresh countdown", function()
  local me = receiver("block:me")
  alarm({ at = S.now + 120 })
  run_to(S.t + 50)
  start()
  run_to(S.t + 69)
  assert(#me.puts == 0)
  run_to(S.t + 1)
  assert(#me.puts == 1 and me.puts[1].t == 1795671120 and me.puts[1].text == "[alarm you set · msg 1795671000-abcd] hi", me.puts[1] and me.puts[1].text)
end)
trial("a one-shot fires once and is removed", function()
  local me = receiver("block:me")
  alarm({ at = S.now + 5 })
  start()
  run_to(S.t + 100)
  assert(#me.puts == 1 and #queued() == 0)
end)
trial("a one-shot that starts late fires at once with a note; on time, without", function()
  local me = receiver("block:me")
  alarm({ at = S.now + 20 })
  run_to(S.t + 39)
  start()
  run_to(S.t + 0.1)
  assert(me.puts[1] and me.puts[1].text == "[alarm you set · msg 1795671000-abcd] hi [late by 19s, Rex restarted]", me.puts[1] and me.puts[1].text)
  reset()
  me = receiver("block:me")
  alarm({ at = S.now + 20 })
  run_to(S.t + 20)
  start()
  run_to(S.t + 0.1)
  assert(me.puts[1].text == "[alarm you set · msg 1795671000-abcd] hi", "on time is not late")
end)
trial("a recurring alarm keeps its phase, skips missed ticks, and stays queued", function()
  local me = receiver("block:me")
  alarm({ every = 60 })
  run_to(S.t + 140) -- restarted after ticks at +60 and +120 passed
  start()
  run_to(S.t + 39)
  assert(#me.puts == 0, "missed ticks must not fire")
  run_to(S.t + 1)
  assert(#me.puts == 1 and me.puts[1].t == 1795671180 and me.puts[1].text == "[alarm you set · msg 1795671000-abcd.3] hi", me.puts[1] and me.puts[1].text)
  run_to(S.t + 60)
  assert(#me.puts == 2 and me.puts[2].t == 1795671240 and #queued() == 1)
end)
trial("a recurring alarm skips the ticks it missed during a sleep", function()
  for _, wake in ipairs({ 660, 650 }) do
    reset()
    local me = receiver("block:me")
    alarm({ every = 60 })
    start()
    -- The whole machine sleeps: no timer runs until WAKE.
    S.t = S.t + wake
    S.now = math.floor(S.t)
    run_to(S.t + 0.5)
    assert(#me.puts <= 1, wake .. ": " .. #me.puts .. " pastes after the sleep")
    run_to(S.t + 60)
    assert(#me.puts >= 1, wake .. ": no tick after the sleep")
    for _, p in ipairs(me.puts) do
      assert((p.t - 1795671000) % 60 == 0 and p.t >= 1795671000 + wake, wake .. ": off phase at +" .. (p.t - 1795671000))
    end
  end
end)
trial("fractional recurring alarms fire on their phase, never early or twice", function()
  -- mail.post takes 3 s and up; the postman keeps phase below that too.
  for _, every in ipairs({ 2.5, 3.3, 10.5 }) do
    reset()
    local me = receiver("block:me")
    S.t, S.now = 1795671000.7, 1795671000
    alarm({ every = every, start = 1795671000 })
    S.t = 1795671000.9
    start()
    local k = 0
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
      if last and tick ~= last + 1 then error(("every=%s: ticks %d to %d skipped"):format(every, last + 1, tick - 1), 0) end
      last = tick
      k = k + 1
    end
  end
end)
trial("a recurring tick is pasted while slow looks of other receivers delay it", function()
  local me = receiver("block:me")
  for i = 1, 4 do
    receiver("block:o" .. i, { draft = "typing" })
    queue({ id = "1795671000-oo" .. string.char(96 + i) .. "a", to = "block:o" .. i })
  end
  alarm({ id = "1795671000-alrm", every = 5 })
  local look = fake.look
  fake.look = function(addr)
    if addr.block ~= "block:me" then S.t = S.t + 0.3 S.now = math.floor(S.t) end
    return look(addr)
  end
  start()
  for _ = 1, 600 do
    run_to(S.t + 0.1)
  end
  fake.look = look
  local due = math.floor((S.t - 1795671000) / 5)
  for i, p in ipairs(me.puts) do
    local tick = tonumber(p.text:match("%.(%d+)%]"))
    assert(tick == i, "tick " .. i .. " skipped, pasted " .. tick)
    assert(p.t >= 1795671000 + 5 * tick, "early")
  end
  assert(#me.puts >= due - 1, #me.puts .. " of " .. due .. " ticks")
end)
trial("the shortest interval loses no ticks; a shorter one is overtaken by its own look", function()
  -- A tick is pasted, then looked at 2 s on. The receiver's own pane takes
  -- half a second to read.
  local function skipped(every)
    reset()
    local me = receiver("block:me")
    alarm({ every = every })
    local look = fake.look
    fake.look = function(addr) S.t = S.t + 0.5 S.now = math.floor(S.t) return look(addr) end
    local ok, err = pcall(function()
      start()
      while #me.puts < 30 do run_to(S.t + 0.1) end
    end)
    fake.look = look
    assert(ok, err)
    local last, gaps = 0, 0
    for _, p in ipairs(me.puts) do
      local tick = tonumber(p.text:match("%.(%d+)%]"))
      assert(tick > last and p.t >= 1795671000 + tick * every, "tick " .. tick .. " twice or early")
      if tick > last + 1 then gaps = gaps + 1 end
      last = tick
    end
    return gaps
  end
  local gaps = skipped(3)
  assert(gaps == 0, "every=3: " .. gaps .. " gaps")
  assert(skipped(1.5) > 0, "every=1.5 lost nothing; the minimum could go lower")
end)
trial("a slow pass of other receivers never drops an alarm tick that nothing overtook", function()
  -- Four held receivers whose panes take 3 s each to read, so each pass
  -- takes longer than the alarm's interval.
  local me = receiver("block:me")
  for i = 1, 4 do
    receiver("block:o" .. i, { draft = "typing" })
    queue({ id = "1795671000-oo" .. string.char(96 + i) .. "a", to = "block:o" .. i })
  end
  alarm({ id = "1795671000-alrm", every = 10 })
  local look, step = fake.look, P.step
  fake.look = function(addr)
    if addr.block ~= "block:me" then S.t = S.t + 3 S.now = math.floor(S.t) end
    return look(addr)
  end
  -- Each time the postman turns to the alarm with no tick on its way, or
  -- takes the look that finishes one, the last tick due then must go out:
  -- only a later tick due too may take its place.
  local turns = {}
  P.step = function(msg, l, now, since)
    if msg.every and not (msg.d and msg.d.pasted_at and not l) then turns[#turns + 1] = { t = S.t, k = math.floor((now - msg.start) / 10) } end
    return step(msg, l, now, since)
  end
  local ok, err = pcall(function()
    start()
    for _ = 1, 600 do run_to(S.t + 0.1) end
  end)
  fake.look, P.step = look, step
  assert(ok, err)
  local pasted, last = {}, 0
  for _, p in ipairs(me.puts) do
    -- The held receivers' notices go to block:me too.
    local tick = tonumber(p.text:match("msg 1795671000%-alrm%.(%d+)%]"))
    if tick then
      assert(tick > last, "tick " .. tick .. " after " .. last)
      assert(p.t >= 1795671000 + 10 * tick, "tick " .. tick .. " early")
      pasted[tick], last = true, tick
    end
  end
  assert(last >= 10, "only up to tick " .. last)
  for _, turn in ipairs(turns) do
    if turn.k > 0 and turn.t < S.t - 30 then
      assert(pasted[turn.k], ("tick %d was the last due at +%.1f, and never went out"):format(turn.k, turn.t - 1795671000))
    end
  end
end)
trial("a recurring alarm held past its next tick sends the last tick due once it clears", function()
  local me = receiver("block:me", { draft = "typing" })
  alarm({ every = 10 })
  start()
  run_to(S.t + 35)
  assert(#me.puts == 0, "pasted onto a draft")
  me.draft = nil
  run_to(S.t + 3)
  assert(#me.puts == 1 and me.puts[1].text:find("msg 1795671000-abcd.3]", 1, true), me.puts[1] and me.puts[1].text)
  run_to(1795671045)
  assert(#me.puts == 2 and me.puts[2].t == 1795671040 and me.puts[2].text:find("msg 1795671000-abcd.4]", 1, true), me.puts[2] and me.puts[2].text)
end)
trial("a one-shot claims a restart only when it starts at least 1s late", function()
  local me = receiver("block:me")
  S.t, S.now = 1795671000.95, 1795671000
  alarm({ at = 1795671000.5 })
  S.t, S.now = 1795671001.05, 1795671001
  start()
  run_to(S.t + 2)
  assert(me.puts[1].text == "[alarm you set · msg 1795671000-abcd] hi", me.puts[1].text)
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

-- ensure and the trust hint ---------------------------------------------------------

local function ensure(hint)
  S.process = function(block)
    if block == "block:new" then
      if S.starts ~= false then lib.write(root .. "/postman.json", json.encode({ block = "block:new", session = "s:home", pid = 7 })) end
      return S.starts == false and { last_exit = { exit_code = 1 } } or { foreground = { pid = 7, name = "rex" } }
    end
    local b = S.blocks[block]
    return { foreground = b and b.pid and { pid = b.pid } }
  end
  S.blocks["block:new"] = { session = "s:home", pid = 7 }
  return P.ensure(hint)
end
local rule = 'rex.set("resume.trust.rex-teams", { command = { "rex", "do", rex.match.under("'
  .. lib.dir:gsub("/$", "") .. '") }, flags = { ["--args"] = { "keep", values = 1 } } })'

trial("ensure starts the postman in a rex-teams session when none runs", function()
  assert(ensure() == nil)
  local nb = assert(S.new_block, "no block started")
  local c = nb.options.command
  assert(S.created == "rex-teams" and nb.session_id == "s:home" and nb.label == "rex-teams postman")
  assert(#c == 5 and c[1] == "rex" and c[2] == "do" and c[3] == lib.dir .. "postman.lua" and c[4] == "--args" and c[5] == "{}", table.concat(c, " "))
  assert(nb.options.exit.on_completion == false, "a failed postman's block must stay")
end)
trial("ensure reuses the session labelled rex-teams", function()
  S.sessions = { { session_id = "s:theirs", label = "work" }, { session_id = "s:rt", label = "rex-teams" } }
  ensure()
  assert(S.new_block.session_id == "s:rt" and not S.created)
end)
trial("ensure leaves a running postman alone", function()
  S.blocks["block:first"] = { session = "s:home", pid = 99 }
  lib.write(root .. "/postman.json", json.encode({ block = "block:first", session = "s:home", pid = 99 }))
  assert(ensure() == nil and not S.new_block)
end)
trial("a postman that fails to start is an error with its last line, and its block is closed", function()
  S.starts = false
  fails("the postman didn't start: Error: something broke", ensure)
  assert(S.closed[1] == "block:new")
end)
trial("a trusted postman prints no hint", function()
  assert(ensure() == nil and not S.waited)
end)
trial("no rule: the hint gives the rule for the scripts folder", function()
  S.records = { { chosen = true, untrusted_reason = "no_rule" } }
  local hint = ensure()
  assert(hint == "postman: Rex won't start the postman again after a restart. Queued messages and alarms are kept, and go out once the next message starts it. To have Rex start it, add this to Rex's init.lua and run rex config reload: " .. rule, hint)
  -- SKILL.md tells agents what to do when they see this hint, by its opening.
  local f = assert(io.open("skills/rex-teams/SKILL.md"))
  local skill = f:read("*a")
  f:close()
  assert(skill:find("prints that Rex won't start the postman again after a restart", 1, true), "SKILL.md doesn't name the hint")
end)
trial("another reason is named in the hint", function()
  S.records = { { chosen = true, untrusted_reason = "flags_differ" } }
  local hint = ensure()
  assert(hint:find("restart (flags_differ). ", 1, true) and hint:find(rule, 1, true), hint)
end)
trial("a record that arrives late is waited for, briefly", function()
  S.records = {}
  S.event = { block_id = "block:new", records = { { chosen = true, untrusted_reason = "no_rule" } } }
  local hint = ensure()
  assert(S.waited.event == "terminal.program_resume_changed" and S.waited.timeout <= 5)
  assert(hint:find(rule, 1, true), hint)
end)
trial("a record that lands just before the wait is read again", function()
  S.records, S.late_records = {}, { { chosen = true, trusted = true } }
  S.event = { block_id = "block:other", records = { { chosen = true, untrusted_reason = "no_rule" } } }
  assert(ensure() == nil)
end)
trial("no record at all says so", function()
  S.records = {}
  assert(ensure():find("no resume record", 1, true))
end)
trial("with hint, a running postman that isn't trusted still gets the hint", function()
  S.blocks["block:first"] = { session = "s:home", pid = 99 }
  lib.write(root .. "/postman.json", json.encode({ block = "block:first", session = "s:home", pid = 99 }))
  S.records = { { chosen = true, untrusted_reason = "no_rule" } }
  assert(ensure(true):find(rule, 1, true) and not S.new_block)
  assert(ensure() == nil)
end)
trial("on Windows ensure gives no hint", function()
  lib.windows = true
  S.records = { { chosen = true, untrusted_reason = "no_rule" } }
  assert(ensure() == nil)
end)
trial("the trust rule checks out with rex config check's syntax", function()
  -- rex.match.under takes the scripts folder, without a trailing slash.
  assert(P.rule():find('rex.match.under("' .. lib.dir:sub(1, -2) .. '")', 1, true), P.rule())
end)

os.execute("rm -rf " .. quote(tmp))
dofile, os.time, os.getenv = real_dofile, real_time, real_getenv
if failed > 0 then print(failed .. " of " .. n .. " postman trials failed.") os.exit(1) end
print("Passed " .. n .. " postman trials.")
