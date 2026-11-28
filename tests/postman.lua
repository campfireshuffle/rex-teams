-- Run from the repo root with `luajit tests/postman.lua` or `lua5.1 tests/postman.lua`.
-- The postman's worker, run against a mock Rex: its timers run on a fake
-- clock, the outbox is a real scratch folder, and pane.lua is replaced by
-- fake receivers whose checks follow a script, one entry per call. The one
-- real command is the OSC 7577 shell, run with a fixed token.
local real_dofile, real_time, real_getenv, real_print = dofile, os.time, os.getenv, print
local json = real_dofile("tests/lib/json.lua")
local TOKEN = "fixed-test-token-0123456789" -- ggignore: a test value, not a secret
local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
-- With PIDFILE, the shell that runs ARGV writes its pid there: the pid
-- of ARGV's parent, as `rex do` is in Rex.
local function run_sh(argv, env, pidfile)
  local line = "env"
  for k, v in pairs(env) do line = line .. " " .. k .. "=" .. quote(v) end
  for _, a in ipairs(argv) do line = line .. " " .. quote(a) end
  local out = os.tmpname()
  line = line .. " >" .. out .. " 2>&1"
  if pidfile then line = "echo $$ >" .. quote(pidfile) .. "; " .. line .. "; exit $?" end
  local status = os.execute(line)
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
local fake, real_fake, mail, real_mail, P, real_P = {}, {}, nil, {}, nil, {}
local function reset()
  for k, v in pairs(real_fake) do fake[k] = v end
  for k, v in pairs(real_mail) do mail[k] = v end
  for k, v in pairs(real_P) do P[k] = v end
  os.execute("rm -rf " .. quote(tmp))
  os.execute("mkdir -p " .. quote(root))
  S = {
    now = 1795671000, t = 1795671000, env = { REX_BLOCK = "block:pm", OSC7577_TOKEN = TOKEN },
    sessions = {},
    blocks = { ["block:pm"] = { session = "s:home", pid = 4242 }, ["block:me"] = { session = "s:1" }, ["block:to"] = { session = "s:1" } },
    timers = {}, out = {}, printed = {}, stopped = nil, closed = {}, receivers = {}, sleeps = 0, slept = 0, attached = {}, made = 0,
  }
end

os.time = function(t) if t then return real_time(t) end return S.now end
os.getenv = function(k) if S.env[k] ~= nil then return S.env[k] or nil end return real_getenv(k) end
io.stdout = { write = function(self, ...) for _, s in ipairs({ ... }) do S.out[#S.out + 1] = s end return self end, flush = function() end }

-- Listing a folder takes a fork, and the passes list the outbox thousands
-- of times. Every file in the scratch folder is written by this process,
-- so remember every path written, and list the ones that exist now.
local real_open, real_rename = io.open, os.rename
local written = {}
io.open = function(path, mode)
  if mode and mode:find("^w") then written[path] = true end
  return real_open(path, mode)
end
os.rename = function(from, to)
  written[to] = true
  return real_rename(from, to)
end
local function ls(dir)
  local out = {}
  for path in pairs(written) do
    local name = path:sub(#dir + 2)
    local f = path:sub(1, #dir + 1) == dir .. "/" and not name:find("/") and real_open(path)
    if f then
      f:close()
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

rex = {
  args = {}, json = json,
  call = function(method, args)
    -- As in Rex, a script acts on a session only once it has attached to it.
    if method == "session.attach" then S.attached[args.session_id] = true return {} end
    if args.session_id and not S.attached[args.session_id] then
      error("stream is not attached to session " .. args.session_id .. " (status=409 code=conflict)", 0)
    end
    if method == "target.resolve" then
      local b = S.blocks[args.queries[1]]
      if not b then return { results = { { status = "not_found" } } } end
      return { results = { { status = "resolved", target = { session_id = b.session, block_id = args.queries[1] } } } }
    end
    if method == "block.close" then S.closed[#S.closed + 1] = args.block_id S.blocks[args.block_id] = nil return {} end
    if method == "session.list" then
      return { sessions = S.sessions }
    end
    if method == "session.create" then
      S.created = args.label
      table.insert(S.sessions, { session_id = "s:home", label = args.label })
      return { session_id = "s:home" }
    end
    if method == "session.list_blocks" then
      local blocks = {}
      for id, b in pairs(S.blocks) do
        if b.session == args.session_id then blocks[#blocks + 1] = { block_id = id, label = b.label } end
      end
      return { blocks = blocks }
    end
    if method == "session.view" then
      -- Each block is a tab of its own, labelled with its name.
      local windows = {}
      for id, b in pairs(S.blocks) do
        if b.session == args.session_id then
          windows[#windows + 1] = { label = b.name or id, layers = { { blocks = { { block_id = id, label = "shell" } } } } }
        end
      end
      return { windows = windows }
    end
    if method == "session.new_block" then
      S.new_block = args
      -- Its process takes a moment to start. Later blocks sort after it.
      local id = "block:new" .. (S.made > 0 and S.made or "")
      S.made = S.made + 1
      S.blocks[id] = { session = args.session_id, label = args.label }
      return { block_id = id }
    end
    if method == "session.set_block_label" then S.blocks[args.block_id].label = args.label return {} end
    if method == "block.method" and args.method == "process" then
      local b = S.blocks[args.block_id]
      if not b then error("block not found (status=404 code=not_found)", 0) end
      return { foreground = b.pid and { pid = b.pid, name = b.fg or "rex" }, last_exit = b.last_exit }
    end
    if method == "block.method" and args.method == "list_dir" then
      -- Like Rex, it lists at most LIMIT entries and says if there were more.
      local entries, names = {}, ls(args.args.path)
      for i = 1, math.min(#names, args.args.limit or math.huge) do entries[i] = { name = names[i] } end
      return { status = "ok", entries = entries, truncated = #entries < #names }
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
    return run_sh(argv, { OSC7577_TOKEN = S.env.OSC7577_TOKEN }, tmp .. "/parent.pid")
  end,
  after = function(s, f) S.timers[#S.timers + 1] = { due = S.t + s, f = f } end,
  sleep = function(seconds)
    S.sleeps = S.sleeps + 1
    S.slept = S.slept + seconds
    if S.on_sleep then S.on_sleep(S.sleeps) end
  end,
  stop = function(code) S.stopped = code end,
}

-- Fake receivers in place of pane.lua. Each check takes the next entry of
-- the receiver's script, and the last entry stays: "up", "down" (raises,
-- as a Rex call to a host that's down does), "gone" or "exited".
function fake.exists(addr)
  local r = S.receivers[addr.block]
  if not r then return false, "that pane is gone" end
  local now = r.script[1]
  if #r.script > 1 then table.remove(r.script, 1) end
  r.checks[#r.checks + 1] = S.t
  if now == "down" then error("rex.server: dial tcp: timeout", 0) end
  if now == "gone" then return false, "that pane is gone" end
  if now == "exited" then return false, "its program has exited" end
  return true
end
-- A paste of a recurring alarm records the tick it carries, msg.k, which
-- the postman saves before the paste.
function fake.put(addr, text)
  local r = S.receivers[addr.block]
  local f = real_open(root .. "/outbox/" .. (text:match("msg (%d+%-%a+)") or "") .. ".json")
  local k = f and json.decode(f:read("*a")).k
  if f then f:close() end
  r.puts[#r.puts + 1] = { t = S.t, text = text, k = k }
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
-- pane.type is a paste, then an Enter, so a trial can fail either one.
function fake.type(addr, text)
  fake.put(addr, text)
  fake.enter(addr)
end
function fake.attach(addr) S.receivers[addr.block].copies = S.receivers[addr.block].copies + 1 end
for k, v in pairs(fake) do real_fake[k] = v end
local function receiver(block, script)
  local r = { script = script or { "up" }, puts = {}, delivered = {}, enters = 0, checks = {}, copies = 0 }
  S.receivers[block] = r
  S.blocks[block] = S.blocks[block] or { session = "s:1" }
  return r
end

local lib = real_dofile("skills/rex-teams/scripts/lib.lua")
lib.root = root
dofile = function(path)
  if path:match("/lib%.lua$") then return lib end
  if path:match("/pane%.lua$") then return fake end
  if path:match("/mail%.lua$") and mail then return mail end
  return real_dofile(path)
end
mail = real_dofile("skills/rex-teams/scripts/mail.lua")
for k, v in pairs(mail) do real_mail[k] = v end
P = real_dofile("skills/rex-teams/scripts/postman.lua")
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
-- Start the postman; a restart is a new process, so it drops the old one's
-- timers and attachments.
local function start()
  S.timers, S.attached = {}, {}
  P.run()
end
-- A message as mail.post queues it. Its from has no name.
local function queue(o)
  local id = o.id or "1795671000-abcd"
  local msg = { id = id, posted = o.posted or S.now, head = o.alarm and "[alarm you set · msg " .. id .. "] " or "[from Me · msg " .. id .. ", who…] ",
    text = o.text or "hi", to = { host = o.host, block = o.to or "block:to", name = o.name or "Reviewer" },
    from = o.from or { block = "block:me" }, at = o.at, every = o.every, start = o.every and (o.start or S.now),
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
  -- The owner is the shell's parent, not the shell, which exits at once.
  local pid = lib.read(tmp .. "/parent.pid"):match("%d+")
  assert(body:match("^pid=(%d+):") == pid, body .. ", parent " .. pid)
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

-- A postman block in the rex-teams session, s:home.
local function postman(block, o)
  S.sessions = { { session_id = "s:home", label = "rex-teams" } }
  S.blocks[block] = { session = "s:home", label = "rex-teams postman", pid = 99, fg = o and o.fg, last_exit = o and o.last_exit }
end
local function delivering()
  local n = 0
  for _, line in ipairs(S.printed) do
    if line:find("^postman: delivering") then n = n + 1 end
  end
  return n
end

trial("with no rex-teams folder yet, the first postman delivers", function()
  os.execute("rm -rf " .. quote(root))
  postman("block:pm")
  start()
  local r = receiver("block:to")
  queue({})
  run_to(S.t + 3)
  assert(delivering() == 1 and #r.delivered == 1 and #queued() == 0)
end)
trial("two postmen starting at once: the older delivers, the newer closes its block", function()
  postman("block:pm")
  postman("block:pm2")
  S.blocks["block:pm"].pid = 4242
  S.env.REX_BLOCK = "block:pm2"
  start()
  assert(S.stopped == 0 and S.closed[1] == "block:pm2" and #S.out == 0 and #S.timers == 0, "the newer one stayed")
  S.stopped, S.env.REX_BLOCK = nil, "block:pm"
  start()
  assert(not S.stopped and delivering() == 1)
end)
trial("an older postman block that isn't live doesn't count", function()
  -- Stopped, a shell after a Rex restart, or labelled, or kept, elsewhere.
  for _, case in ipairs({ "exited", "shell", "label", "session" }) do
    reset()
    postman("block:a-old", { last_exit = case == "exited" and { exit_code = 1 } or nil, fg = case == "shell" and "fish" or nil })
    if case == "label" then S.blocks["block:a-old"].label = "notes" end
    if case == "session" then S.sessions[1].label = "work" end
    start()
    assert(not S.stopped and delivering() == 1, case .. ": quit")
  end
end)
trial("every rex-teams session counts, since labels can repeat", function()
  postman("block:pm")
  table.insert(S.sessions, { session_id = "s:dup", label = "rex-teams" })
  S.blocks["block:a-old"] = { session = "s:dup", label = "rex-teams postman", pid = 5 }
  start()
  assert(S.stopped == 0 and S.closed[1] == "block:pm")
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
trial("a receiver Rex can't reach holds its queue, and nobody is told; when it's back they arrive in order", function()
  local r = receiver("block:to", { "down" })
  local me = receiver("block:me")
  queue({ id = "1795671000-aaaa", text = "first" })
  queue({ id = "1795671000-bbbb", text = "second", seq = 1 })
  start()
  run_to(S.t + 1200)
  assert(#r.puts == 0 and #me.puts == 0 and #queued() == 2, #me.puts)
  -- Back between its two checks in one pass: the second may not pass the first.
  r.script = { "down", "up" }
  run_to(S.t + 5)
  assert(texts(r.delivered):gsub("%[[^]]*%] ", "") == "first | second", texts(r.delivered))
  assert(#queued() == 0)
end)
trial("an alarm waiting for its next tick, a one-shot not yet due, or a message to a gone pane doesn't hold up later messages", function()
  local me = receiver("block:me")
  queue({ id = "1795671000-alrm", alarm = true, to = "block:me", every = 60 })
  queue({ id = "1795671000-late", alarm = true, to = "block:me", at = S.now + 300, seq = 1 })
  start()
  run_to(S.t + 61)
  assert(texts(me.puts) == "[alarm you set · msg 1795671000-alrm] hi" and me.puts[1].k == 1, texts(me.puts))
  queue({ id = "1795671061-mine", posted = S.now, to = "block:me", text = "for me" })
  receiver("block:gone")
  queue({ id = "1795671061-gone", posted = S.now, to = "block:gone" })
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
  assert(texts(me.puts):find("Message 1795671000-abcd to Reviewer may not have arrived: the postman stopped between its paste and its Enter. It isn't sent again. It said: hi", 1, true), texts(me.puts))
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
    assert(texts(me.puts) == "[rex-teams postman · msg " .. me.puts[1].text:match("msg (%S+)%]") .. "] Message 1795671000-abcd to Reviewer may not have arrived: rex: block.event timed out. It isn't sent again. It said: hi", texts(me.puts))
    assert(#queued() == 0, fail .. ": still queued: " .. table.concat(queued(), " "))
  end
end)
trial("files for another host are copied once, and a failed copy is never pasted: its sender hears once, with its text, and the file is deleted", function()
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
  assert(#me.puts == 1 and me.puts[1].text:find("Message 1795671000-abcd to Reviewer wasn't sent: rex cp failed. It said: hi", 1, true), texts(me.puts))
  assert(#queued() == 0)
end)
trial("the receiver is checked once, before its files are copied: unreachable holds it with no copy", function()
  local r = receiver("block:to", { "down", "up" })
  local me = receiver("block:me")
  queue({ host = "ws", files = { "/w/a.md" } })
  start()
  run_to(S.t + 1)
  assert(r.copies == 0 and #r.puts == 0 and #queued() == 1, "copied or pasted while unreachable")
  run_to(S.t + 3)
  assert(#r.delivered == 1 and r.copies == 1 and #queued() == 0, #r.delivered .. " delivered, " .. r.copies .. " copies")
  assert(#r.checks == 2 and #me.puts == 0, #r.checks .. " checks")

  -- A pane that goes during the copy isn't checked again: the paste goes
  -- ahead, and in Rex it raises and tells the sender.
  reset()
  r = receiver("block:to", { "up", "gone" })
  queue({ host = "ws", files = { "/w/a.md" } })
  start()
  run_to(S.t + 30)
  assert(#r.checks == 1 and r.copies == 1 and #r.delivered == 1, #r.checks .. " checks")
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
    r = receiver("block:to")
    queue({ host = "ws", files = { "/w/a.md" } })
    fake[when == "check" and "exists" or "attach"] = function(addr)
      os.remove(root .. "/outbox/1795671000-abcd.json")
      return real_fake[when == "check" and "exists" or "attach"](addr)
    end
    start()
    run_to(S.t + 30)
    assert(#r.puts == 0 and #queued() == 0, when .. ": pasted")
    -- The save before the paste is what sees the deletion, after the copy.
    assert(r.copies == 1, when .. ": " .. r.copies .. " copies")
  end
end)
trial("a receiver that's gone: one notice with the text, and the file is deleted", function()
  local me = receiver("block:me")
  queue({ to = "block:gone" })
  start()
  run_to(S.t + 100)
  assert(#me.puts == 1 and me.puts[1].text:find("Message 1795671000-abcd to Reviewer can't be delivered: that pane is gone. It said: hi", 1, true), texts(me.puts))
  assert(#queued() == 0)
end)
trial("a receiver whose program exited: the notice says so", function()
  local me = receiver("block:me")
  receiver("block:to", { "exited" })
  queue({})
  start()
  run_to(S.t + 100)
  assert(#me.puts == 1 and me.puts[1].text:find("Message 1795671000-abcd to Reviewer can't be delivered: its program has exited. It said: hi", 1, true), texts(me.puts))
  assert(#queued() == 0)
end)
trial("nothing tells you about your own messages, and notices cause no notices", function()
  local me = receiver("block:me")
  fake.put = function(addr, text)
    real_fake.put(addr, text)
    if addr.block == "block:me" then error("rex: block.event timed out", 0) end
  end
  queue({ id = "1795671000-self", to = "block:me", name = "Me" })
  -- mail.notice lists the outbox through the postman's own pane.
  lib.attach("s:home")
  mail.notice({ block = "block:me" }, "x")
  mail.notice({ block = "block:gone" }, "y")
  start()
  run_to(S.t + 10)
  fake.put = real_fake.put
  assert(#me.puts == 2 and not texts(me.puts):find("Message ", 1, true), texts(me.puts))
  assert(#queued() == 0, #queued() .. " queued")
  for _, line in ipairs(S.printed) do assert(not line:find("%.lua:%d+:"), line) end
  -- The next message to that sender still goes out.
  queue({ id = "1795671010-next", posted = S.now, to = "block:me", from = { block = "block:other" } })
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
    assert(not m, case .. ": kept")
  end
end)

-- Alarms ------------------------------------------------------------------------

local function alarm(o)
  o.alarm, o.to = true, "block:me"
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
  assert(texts(me.puts) == "[alarm you set · msg 1795671000-abcd] hi" and me.puts[1].k == 2, texts(me.puts))
  run_to(S.t + 39)
  assert(#me.puts == 1)
  run_to(S.t + 1)
  assert(#me.puts == 2 and me.puts[2].t == 1795671180 and me.puts[2].k == 3 and #queued() == 1)
end)
trial("after a sleep, the ticks that piled up collapse into one catch-up tick", function()
  local me = receiver("block:me")
  alarm({ every = 60 })
  start()
  -- The whole machine sleeps: no timer runs until +650.
  S.t = S.t + 650
  S.now = math.floor(S.t)
  run_to(S.t + 0.5)
  assert(#me.puts == 1 and me.puts[1].k == 10, texts(me.puts))
  run_to(1795671661)
  assert(#me.puts == 2 and me.puts[2].t == 1795671660 and me.puts[2].k == 11)
end)
trial("fractional recurring alarms fire on their phase, at most a beat late, never early, twice or skipped", function()
  for _, every in ipairs({ 10, 10.5, 13.3 }) do
    reset()
    local me = receiver("block:me")
    S.t, S.now = 1795671000.7, 1795671000
    alarm({ every = every, start = 1795671000 })
    S.t = 1795671000.9
    start()
    for _ = 1, 4000 do
      run_to(S.t + 0.05)
      if #me.puts >= 12 and S.t > 1795671040 then break end
    end
    assert(#me.puts >= 12, every .. ": " .. #me.puts .. " ticks")
    local last
    for _, p in ipairs(me.puts) do
      local tick = p.k
      local due = 1795671000 + tick * every
      -- A beat late, plus up to a second for whole-second clocks.
      assert(p.t >= due - 1e-9 and p.t < due + P.poll + 1, ("every=%s tick %d at +%.2f, due +%.2f"):format(every, tick, p.t - 1795671000, due - 1795671000))
      assert(not last or tick > last, "tick " .. tick .. " twice")
      if last and tick ~= last + 1 then error(("every=%s: ticks %d to %d skipped"):format(every, last + 1, tick - 1), 0) end
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
  -- Behind them, so the slow checks come first in each pass.
  alarm({ id = "1795671000-alrm", every = every, seq = 1 })
  fake.exists = function(addr)
    if addr.block ~= "block:me" then S.t = S.t + step S.now = math.floor(S.t) end
    return real_fake.exists(addr)
  end
  return me
end
trial("slow checks of other receivers never drop an alarm tick that nothing overtook", function()
  -- Checks faster than the alarm, then passes slower than it.
  for _, world in ipairs({ { 0.3, 5 }, { 3, 10 } }) do
    reset()
    local every = world[2]
    local me = slow_world(world[1], every)
    -- Each time the postman turns to the alarm, the last tick due then must
    -- go out: only a later tick due too may take its place.
    local turns = {}
    P.deliver = function(msg, now)
      -- The last tick due now by the clock, not by NOW, which a pass
      -- could have read before its slow checks.
      if msg.every then turns[#turns + 1] = { t = S.t, k = math.floor((S.now - msg.start) / every) } end
      return real_P.deliver(msg, now)
    end
    start()
    for _ = 1, 600 do run_to(S.t + 0.1) end
    local pasted, last = {}, 0
    for _, p in ipairs(me.puts) do
      local tick = p.k
      assert(tick > last, "tick " .. tick .. " after " .. last)
      assert(p.t >= 1795671000 + every * tick, "tick " .. tick .. " early")
      assert(tick == math.floor((math.floor(p.t) - 1795671000) / every), ("every=%d: tick %d pasted at +%.1f"):format(every, tick, p.t - 1795671000))
      pasted[tick], last = true, tick
    end
    assert(last >= 5, "only up to tick " .. last)
    for _, turn in ipairs(turns) do
      if turn.k > 0 and turn.t < S.t - 30 then
        assert(pasted[turn.k], ("every=%d: tick %d was the last due at +%.1f, and never went out"):format(every, turn.k, turn.t - 1795671000))
      end
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
  assert(texts(me.puts) == "[alarm you set · msg 1795671000-abcd] hi" and me.puts[1].k == 1, texts(me.puts))
  me.script = { "down" }
  run_to(1795671045)
  me.script = { "up" }
  run_to(S.t + 3)
  assert(#me.puts == 2 and me.puts[2].k == 4, texts(me.puts))
  run_to(1795671051)
  assert(#me.puts == 3 and me.puts[3].t == 1795671050 and me.puts[3].k == 5, texts(me.puts))
end)
trial("a tick cut short by a stop is reported, and the tick due by the restart still goes out", function()
  local r = receiver("block:to")
  local me = receiver("block:me")
  queue({ every = 10 })
  local file, outbox = root .. "/outbox/1795671000-abcd.json", nil
  fake.put = function(addr, text)
    local f = assert(io.open(file))
    outbox = f:read("*a")
    f:close()
    return real_fake.put(addr, text)
  end
  start()
  run_to(S.t + 11)
  fake.put = real_fake.put
  -- It stopped during tick 1's paste, and starts again after tick 2 is due.
  lib.write(file, outbox)
  S.t, S.now = 1795671025, 1795671025
  start()
  run_to(S.t + P.poll)
  assert(texts(me.puts):find("Message 1795671000-abcd to Reviewer may not have arrived: the postman stopped", 1, true), texts(me.puts))
  assert(#r.puts == 2 and r.puts[1].k == 1 and r.puts[2].k == 2, texts(r.puts))
end)
trial("a failed recurring tick drops only that tick: its sender hears once, even after a restart", function()
  local r = receiver("block:to")
  local me = receiver("block:me")
  queue({ every = 60 })
  fake.put = function(addr, text) if addr.block == "block:to" then error("rex: block.event timed out", 0) end return real_fake.put(addr, text) end
  start()
  run_to(S.t + 65)
  fake.put = real_fake.put
  assert(#me.puts == 1 and me.puts[1].text:find("Message 1795671000-abcd to Reviewer may not have arrived", 1, true), texts(me.puts))
  start()
  run_to(S.t + 30)
  assert(#me.puts == 1, "the sender was told " .. #me.puts .. " times")
  run_to(1795671121)
  assert(#r.puts == 1 and r.puts[1].k == 2, texts(r.puts))
end)
trial("a paste slower than its alarm's interval doesn't loop: each pass sends the tick due then, in order", function()
  local me = receiver("block:me")
  alarm({ every = 10 })
  fake.put = function(addr, text) S.t = S.t + 12 S.now = math.floor(S.t) return real_fake.put(addr, text) end
  start()
  run_to(1795671000 + 100)
  local last = 0
  for _, p in ipairs(me.puts) do
    local k = p.k
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
  { "pane.exists", fake, "exists" }, { "pane.attach", fake, "attach" }, { "pane.type (paste)", fake, "put" }, { "pane.type (Enter)", fake, "enter" },
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
        local tag = p.text:match("msg (%S+),") .. "." .. tostring(p.k)
        assert(not seen[tag], where .. tag .. " pasted twice")
        seen[tag] = true
      end
      local abcd = {}
      for i, p in ipairs(r.delivered) do if p.text:find("msg 1795671000%-abcd") then abcd[#abcd + 1] = i end end
      if case == "gone" then
        assert(told and not read_msg("1795671000-abcd"), where .. "not told, or kept")
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
-- "starts" (reports and takes its label), "fails" (exits), "hangs", or
-- "loses" to an older postman and closes its own block.
local function ensure(what)
  S.on_sleep = function(i)
    if what == "starts" and i == 1 then S.blocks["block:new"].pid, S.blocks["block:new"].label = 7, "rex-teams postman" end
    if what == "fails" and i == 1 then S.blocks["block:new"].last_exit = { exit_code = 1 } end
    if what == "loses" and i == 1 then
      -- The older one runs, but Rex doesn't show its process yet.
      S.blocks["block:a-old"] = { session = "s:home", label = "rex-teams postman" }
      S.blocks["block:new"] = nil
    end
    if what == "loses" and i == 2 then S.blocks["block:a-old"].pid = 8 end
  end
  return P.ensure()
end

trial("ensure starts the postman in a rex-teams session, and returns once it runs", function()
  assert(ensure("starts") == nil)
  local nb = assert(S.new_block, "no block started")
  local c = nb.options.command
  -- It takes its label once it has reported.
  assert(S.created == "rex-teams" and nb.session_id == "s:home" and nb.label == nil)
  assert(#c == 5 and c[1] == "rex" and c[2] == "do" and c[3] == lib.dir .. "postman.lua" and c[4] == "--args" and c[5] == "{}", table.concat(c, " "))
  assert(nb.options.exit.on_completion == false, "a failed postman's block must stay")
  assert(S.sleeps == 1, S.sleeps .. " sleeps")
end)
trial("ensure reuses the session labelled rex-teams", function()
  S.sessions = { { session_id = "s:theirs", label = "work" }, { session_id = "s:rt", label = "rex-teams" } }
  ensure("starts")
  assert(S.new_block.session_id == "s:rt" and not S.created)
end)
trial("ensure leaves a running postman alone", function()
  postman("block:first")
  assert(ensure("hangs") == nil and not S.new_block)
end)
trial("ensure starts a postman when the only postman block isn't live", function()
  postman("block:first", { fg = "fish" })
  assert(ensure("starts") == nil and S.new_block)
end)
trial("ensure returns when an older postman wins", function()
  assert(ensure("loses") == nil)
  assert(S.sleeps == 2, S.sleeps .. " sleeps")
end)
trial("a postman that fails to start is an error naming its block, which stays open", function()
  fails("the postman didn't start. See why with: rex capture -s s:home -b block:new", function() ensure("fails") end)
  assert(#S.closed == 0, "the failed postman's block was closed")
end)
trial("a postman that doesn't run within 5s is an error naming its block", function()
  fails("the postman didn't start within 5s. See why with: rex capture -s s:home -b block:new", function() ensure("hangs") end)
  -- The limit is the time waited, not the number of checks.
  assert(math.abs(S.slept - 5) < 1e-6, "waited " .. S.slept .. " seconds")
end)
local function locked()
  local status = os.execute("test -d " .. quote(root .. "/postman.lock"))
  return status == 0 or status == true
end
-- Run the postman in BLOCK, as Rex does once its process is up.
local function run_in(block)
  S.blocks[block].pid = 7
  local prev = S.env.REX_BLOCK
  S.env.REX_BLOCK = block
  local ok, err = pcall(P.run)
  S.env.REX_BLOCK, S.stopped = prev, nil
  if not ok then S.blocks[block].last_exit = { exit_code = 1 } end
  return ok, err
end
trial("a postman that fails before it reports never counts: the send raises and queues nothing", function()
  receiver("block:to")
  S.on_sleep = function(i)
    -- Its process is up at the first check; its report fails before the second.
    if i == 1 then S.blocks["block:new"].pid = 7 end
    if i == 2 then
      S.env.OSC7577_TOKEN = false
      assert(not run_in("block:new"))
    end
  end
  S.env.REX_BLOCK = "block:me"
  lib.attach("s:home")
  fails("the postman didn't start. See why with: rex capture -s s:home -b block:new", function() mail.post({ to = "block:to", text = "lost?" }) end)
  assert(#queued() == 0, "queued: " .. table.concat(queued(), " "))
  assert(not locked(), "the lock is still held")
end)
trial("a postman counts as live only once it has reported (decision 010 Q2)", function()
  -- Rex shows a label at once, and a waiting sender checks every 50 ms, so
  -- a postman labelled before its report would count while it reports.
  local real_exec, during = rex.exec, nil
  rex.exec = function(argv)
    if argv[1] == "sh" then during = #P.live() end
    return real_exec(argv)
  end
  S.on_sleep = function(i) if i == 1 then assert(run_in("block:new")) end end
  P.ensure()
  rex.exec = real_exec
  assert(during == 0, "live during its report: " .. tostring(during))
  assert(#P.live() == 1)
end)
trial("the first send after a reboot, with no /tmp/rex-teams, starts a postman", function()
  os.execute("rm -rf " .. quote(root))
  S.on_sleep = function(i)
    assert(i < 1000, "ensure is stuck on the lock")
    if S.blocks["block:new"] and not S.blocks["block:new"].pid then assert(run_in("block:new")) end
  end
  P.ensure()
  assert(#P.live() == 1 and S.made == 1 and not locked())
end)
-- SENDERS call ensure at once, each in its own coroutine, taking turns.
-- After each round of turns, the postmen in the blocks made so far start:
-- the newest first, then the rest oldest first, as round 5 saw in Rex.
-- Without LOCK, every sender gets the lock. Returns the senders' errors.
local function race(senders, lock)
  local real_exec, real_sleep = rex.exec, rex.sleep
  if not lock then
    rex.exec = function(argv)
      if argv[#argv] == root .. "/postman.lock" then return { ok = true, code = 0, stdout = "", stderr = "" } end
      return real_exec(argv)
    end
  end
  rex.sleep = function(seconds) S.slept = S.slept + seconds coroutine.yield() end
  local threads, errs, up = {}, {}, {}
  local done, err = pcall(function()
    for i = 1, senders do threads[i] = coroutine.create(P.ensure) end
    for _ = 1, 1000 do
      local waiting = false
      for _, co in ipairs(threads) do
        if coroutine.status(co) ~= "dead" then
          local ok, err = coroutine.resume(co)
          if not ok then errs[#errs + 1] = err end
          waiting = waiting or coroutine.status(co) ~= "dead"
        end
      end
      local made = {}
      for id in pairs(S.blocks) do if id:find("^block:new") and not up[id] then made[#made + 1] = id up[id] = true end end
      table.sort(made)
      if #made > 1 then table.insert(made, 1, table.remove(made)) end
      for _, id in ipairs(made) do assert(run_in(id)) end
      if not waiting then break end
    end
  end)
  rex.exec, rex.sleep = real_exec, real_sleep
  assert(done, err)
  return errs
end
trial("six first sends at once start one postman, which holds the lock only while it starts", function()
  local errs = race(6, false)
  assert(#errs == 0, table.concat(errs, "; "))
  assert(#P.live() == 2 and delivering() == 2, "without the lock: " .. #P.live() .. " postmen, not the 2 round 5 saw")
  reset()
  errs = race(6, true)
  assert(#errs == 0, table.concat(errs, "; "))
  assert(S.made == 1 and #P.live() == 1 and delivering() == 1, "with the lock: " .. S.made .. " blocks, " .. #P.live() .. " postmen")
  assert(not locked(), "the lock is still held")
end)
trial("a lock left by a killed sender is broken after 30 s, and a postman starts", function()
  os.execute("mkdir -p " .. quote(root .. "/postman.lock"))
  S.on_sleep = function()
    if S.blocks["block:new"] and not S.blocks["block:new"].pid then assert(run_in("block:new")) end
  end
  P.ensure()
  assert(#P.live() == 1 and S.made == 1 and not locked())
  assert(S.slept >= 30 and S.slept < 31, "waited " .. S.slept .. " s")
  assert(table.concat(S.printed, " | "):find("postman: breaking a lock held for 30s: " .. root .. "/postman.lock", 1, true), table.concat(S.printed, " | "))
end)

-- Ten end-to-end trials ------------------------------------------------------------
-- The likeliest real uses, driven through mail.post as send.lua and
-- alarm.lua call it, the postman's singleton and its 2 s beat.

-- block:me posts O through mail.post. mail.list lists the outbox through
-- the pane it first ran in, the postman's, so that session is attached.
local function post(o)
  local prev = S.env.REX_BLOCK
  S.env.REX_BLOCK = "block:me"
  lib.attach("s:home")
  local ok, id, name = pcall(mail.post, o)
  S.env.REX_BLOCK = prev
  assert(ok, id)
  return id, name
end
-- The postman ensure starts, block:new, runs once its process is up.
local function starts_on_ensure()
  S.on_sleep = function(i)
    if i ~= 1 then return end
    S.blocks["block:new"].pid = 7
    local prev = S.env.REX_BLOCK
    S.env.REX_BLOCK = "block:new"
    P.run()
    S.env.REX_BLOCK = prev
  end
end
local function people()
  local r, me = receiver("block:to"), receiver("block:me")
  S.blocks["block:to"].name, S.blocks["block:me"].name = "Reviewer", "Me"
  return r, me
end
local function reply(block) return "Reply by running: " .. lib.send_command(block, "<reply>") .. "] " end

trial("E1 the first send on a fresh machine starts the postman, which delivers it with its header", function()
  local r = people()
  starts_on_ensure()
  local id, name = post({ to = "block:to", text = "review PR 12" })
  assert(name == "Reviewer" and S.created == "rex-teams" and S.blocks["block:new"].label == "rex-teams postman")
  run_to(S.t + P.poll)
  assert(texts(r.delivered) == "[from Me · msg " .. id .. ", who can't see this screen. " .. reply("block:me") .. "review PR 12", texts(r.delivered))
  assert(#queued() == 0 and not S.stopped)
end)
trial("E2 later sends find the running postman, start no other, and arrive within a beat", function()
  local r = people()
  postman("block:pm")
  start()
  for i = 1, 3 do
    local t = S.t
    post({ to = "block:to", text = "note " .. i })
    run_to(S.t + P.poll)
    assert(#r.delivered == i and r.delivered[i].t - t <= P.poll, "note " .. i)
    run_to(S.t + 30)
  end
  assert(not S.new_block and #S.closed == 0, "another postman started")
end)
trial("E3 messages sent in one second to one receiver arrive in the order sent", function()
  local r = people()
  postman("block:pm")
  start()
  for i = 1, 5 do post({ to = "block:to", text = "part " .. i }) end
  run_to(S.t + P.poll)
  assert(texts(r.delivered):gsub("%[[^]]*%] ", "") == "part 1 | part 2 | part 3 | part 4 | part 5", texts(r.delivered))
end)
trial("E4 an alarm in 60 s arrives within a beat of its time, headed as yours, and its file goes", function()
  local _, me = people()
  postman("block:pm")
  start()
  local id = post({ to = "block:me", text = "check CI", at = S.now + 60 })
  run_to(S.t + 59)
  assert(#me.puts == 0, "early")
  run_to(S.t + P.poll + 1)
  assert(#me.puts == 1 and me.puts[1].text == "[alarm you set · msg " .. id .. "] check CI", texts(me.puts))
  assert(me.puts[1].t >= 1795671060 and me.puts[1].t < 1795671060 + P.poll, me.puts[1].t)
  assert(#queued() == 0)
end)
trial("E5 an alarm every 10 min ticks on time for an hour, then deleting its file cancels it", function()
  local _, me = people()
  postman("block:pm")
  start()
  local id = post({ to = "block:me", text = "standup", every = 600 })
  run_to(S.t + 3601)
  assert(#me.puts == 6, #me.puts .. " ticks")
  for k, p in ipairs(me.puts) do
    local due = 1795671000 + 600 * k
    assert(p.k == k and p.t >= due and p.t < due + P.poll, ("tick %d at +%.1f"):format(k, p.t - due))
  end
  os.remove(mail.file(id))
  run_to(S.t + 1800)
  assert(#me.puts == 6 and #queued() == 0)
end)
trial("E6 a receiver that closed its pane: one notice with the text, and nothing is left queued", function()
  local _, me = people()
  postman("block:pm")
  start()
  local id = post({ to = "block:to", text = "are you there?" })
  S.receivers["block:to"] = nil
  run_to(S.t + 60)
  assert(#me.puts == 1 and me.puts[1].text:find("Message " .. id .. " to Reviewer can't be delivered: that pane is gone. It said: are you there?", 1, true), texts(me.puts))
  assert(#queued() == 0)
end)
trial("E7 after a Rex restart the resumed postman delivers what waited, once, past old postman shells", function()
  local r = people()
  -- Before the restart, Rex was down with a message queued; old postmen
  -- that had stopped are shells now, and older.
  postman("block:a-pm")
  S.blocks["block:0-old"] = { session = "s:home", label = "rex-teams postman", pid = 5, fg = "fish" }
  S.blocks["block:1-old"] = { session = "s:home", label = "rex-teams postman", last_exit = { exit_code = 1 } }
  queue({ text = "while you were out" })
  S.env.REX_BLOCK = "block:a-pm"
  start()
  run_to(S.t + 10)
  assert(not S.stopped and #r.delivered == 1 and texts(r.delivered):find("while you were out$"), texts(r.delivered))
  post({ to = "block:to", text = "and now" })
  run_to(S.t + P.poll)
  assert(#r.delivered == 2 and not S.new_block, "a send after the restart started another postman")
end)
trial("E8 two postmen started at once: the newer quits before reporting, and each message is pasted once", function()
  local r = people()
  postman("block:p1")
  postman("block:p2")
  S.blocks["block:p1"].pid, S.blocks["block:p2"].pid = 11, 12
  queue({ text = "once" })
  S.env.REX_BLOCK = "block:p2"
  start()
  assert(S.stopped == 0 and S.closed[1] == "block:p2" and #S.out == 0)
  S.env.REX_BLOCK = "block:p1"
  S.stopped = nil
  P.run()
  post({ to = "block:to", text = "twice?" })
  run_to(S.t + 30)
  assert(texts(r.delivered):gsub("%[[^]]*%] ", "") == "once | twice?", texts(r.delivered))
  local reports = select(2, table.concat(S.out):gsub("\27%]7577;", ""))
  assert(reports == 1, reports .. " OSC reports")
end)
trial("E9 a postman killed mid-paste: the next one never pastes it again, and the sender hears", function()
  local r, me = people()
  postman("block:pm")
  local id = post({ to = "block:to", text = "deploy" })
  local file, outbox = mail.file(id), nil
  fake.put = function(addr, text)
    local f = assert(real_open(file))
    outbox = f:read("*a")
    f:close()
    return real_fake.put(addr, text)
  end
  start()
  fake.put = real_fake.put
  lib.write(file, outbox) -- killed there: the file is as it was during the paste
  start()
  run_to(S.t + 30)
  assert(#r.puts == 1, "pasted " .. #r.puts .. " times")
  assert(#me.puts == 1 and me.puts[1].text:find("Message " .. id .. " to Reviewer may not have arrived: the postman stopped between its paste and its Enter", 1, true), texts(me.puts))
  assert(#queued() == 0)
end)
trial("E10 a receiver Rex can't reach holds only its own queue: the others arrive, and its messages follow in order", function()
  local r = people()
  local far = receiver("block:far", { "down" })
  S.blocks["block:far"].name = "Far"
  postman("block:pm")
  start()
  post({ to = "block:far", text = "far 1" })
  post({ to = "block:to", text = "near" })
  post({ to = "block:far", text = "far 2" })
  run_to(S.t + P.poll)
  assert(#r.delivered == 1 and #far.puts == 0)
  run_to(S.t + 300)
  assert(#far.puts == 0 and #S.receivers["block:me"].puts == 0, "pasted, or the sender was told")
  far.script = { "up" }
  run_to(S.t + P.poll)
  assert(texts(far.delivered):gsub("%[[^]]*%] ", "") == "far 1 | far 2", texts(far.delivered))
end)

-- The trust rule ----------------------------------------------------------------

trial("README quotes the trust rule that lets Rex resume the postman's command", function()
  local f = assert(io.open("README.md"))
  local readme = f:read("*a")
  f:close()
  -- The postman reports `rex do <skill>/scripts/postman.lua --args {}`.
  -- rex.match.under takes the scripts folder, without a trailing slash.
  assert(P.script == lib.dir .. "postman.lua", P.script)
  local rule = 'rex.set("resume.trust.rex-teams", { command = { "rex", "do", rex.match.under("<skill>/scripts") }, '
    .. 'flags = { ["--args"] = { "keep", values = 1 } } })'
  assert(readme:find(rule, 1, true), "README.md doesn't quote: " .. rule)
end)

os.execute("rm -rf " .. quote(tmp))
dofile, os.time, os.getenv, io.open, os.rename = real_dofile, real_time, real_getenv, real_open, real_rename
if failed > 0 then print(failed .. " of " .. n .. " postman trials failed.") os.exit(1) end
print("Passed " .. n .. " postman trials.")
