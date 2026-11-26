-- Run from the repo root with `lua5.1 tests/alarm.lua`.
-- Alarms are files that Rex can resume. rex.call, rex.after and os.time are
-- mocks. rex.exec runs the real command with a fixed OSC7577_TOKEN, except
-- the calls a test answers itself.
local real_dofile, real_time, real_getenv = dofile, os.time, os.getenv
local script = "skills/rex-teams/scripts/alarm.lua"
local TOKEN = "fixed-test-token-0123456789"

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function run(argv, env)
  local words = {}
  for k, v in pairs(env) do words[#words + 1] = v and (k .. "=" .. sh_quote(v)) or ("-u " .. k) end
  local line = "env " .. table.concat(words, " ")
  for _, a in ipairs(argv) do line = line .. " " .. sh_quote(a) end
  local out = os.tmpname()
  local status = os.execute(line .. " >" .. out .. " 2>&1")
  local f = assert(io.open(out))
  local text = f:read("*a")
  f:close()
  os.remove(out)
  local ok = status == 0 or status == true
  return { ok = ok, code = ok and 0 or 1, stdout = text, stderr = ok and "" or text }
end

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. sh_quote(root)) == 0 or true)

local state
local function reset()
  state = {
    now = 1795671000, env = { REX_BLOCK = "block:agent", OSC7577_TOKEN = TOKEN }, calls = {}, execs = {},
    timers = {}, out = {}, printed = {}, stopped = nil, blocks = { ["block:agent"] = "session:s" },
    config = { ok = true, json = "rule" }, uid = nil, fake_pid = "4242",
  }
  os.execute("rm -rf " .. sh_quote(root) .. " && mkdir -p " .. sh_quote(root))
end

local rules = {
  rule = { resume_rules = {
    { name = "claude", rule = { command = { "claude", "--resume", { match = "uuid" } } } },
    { name = "rex-teams-alarm", rule = { command = { "rex", "do", { match = "under", dir = root } } } },
  } },
  norule = { resume_rules = {
    { name = "claude", rule = { command = { "claude", "--resume", { match = "uuid" } } } },
    { name = "other", rule = { command = { "rex", "do", { match = "under", dir = "/elsewhere" } } } },
  } },
}

os.time = function(t) if t then return real_time(t) end return state.now end
os.getenv = function(k) if state.env[k] ~= nil then return state.env[k] or nil end return real_getenv(k) end
io.stdout = { write = function(self, ...) for _, s in ipairs({ ... }) do state.out[#state.out + 1] = s end return self end,
  flush = function() end }
local real_print = print
print = function(...) state.printed[#state.printed + 1] = table.concat({ ... }, "\t") end

rex = {
  args = {},
  json = { decode = function(s) return assert(rules[s], "unexpected json " .. s) end },
  call = function(method, args)
    state.calls[#state.calls + 1] = { method = method, args = args }
    if method == "target.resolve" then
      local s = state.blocks[args.queries[1]]
      if s then return { results = { { status = "resolved", target = { session_id = s, block_id = args.queries[1] } } } } end
      return { results = { { status = "not_found" } } }
    end
    if method == "server.status" then return { host_id = "host-1" } end
    if method == "session.new_block" then state.blocks["block:alarm"] = args.session_id return { block_id = "block:alarm" } end
    if method == "block.close" then state.blocks[args.block_id] = nil return {} end
    return {}
  end,
  exec = function(argv, opts)
    state.execs[#state.execs + 1] = argv
    for _, a in ipairs(argv) do assert(not a:find(TOKEN, 1, true), "the token reached argv") end
    if argv[1] == "rex" and argv[2] == "config" then
      return { ok = state.config.ok, code = state.config.ok and 0 or 1, stdout = state.config.json, stderr = "init.lua:3: boom" }
    end
    if argv[1] == "sh" and argv[3] == "echo $PPID" then return { ok = true, code = 0, stdout = state.fake_pid .. "\n" } end
    if argv[1] == "id" and state.uid then return { ok = true, code = 0, stdout = state.uid .. "\n" } end
    local env = { OSC7577_TOKEN = state.env.OSC7577_TOKEN or false }
    for k, v in pairs(opts and opts.env or {}) do env[k] = v end
    return run(argv, env)
  end,
  after = function(s, f) state.timers[#state.timers + 1] = { s = s, f = f } end,
  every = function() error("alarms schedule with rex.after from absolute times") end,
  stop = function(code) state.stopped = code end,
}
local lib = real_dofile("skills/rex-teams/scripts/lib.lua")
lib.root = root
dofile = function(path)
  if path:match("/lib%.lua$") then return lib end
  return real_dofile(path)
end

local function call(method)
  for _, c in ipairs(state.calls) do if c.method == method then return c.args end end
end
local function count(method)
  local n = 0
  for _, c in ipairs(state.calls) do if c.method == method then n = n + 1 end end
  return n
end
local function ls(path) return run({ "ls", "-ldn", path }, {}).stdout end
local function exists(path) local f = io.open(path) if f then f:close() end return f ~= nil end
local function read(path) local f = assert(io.open(path)) local t = f:read("*a") f:close() return t end
local function set(args) rex.args = args ALARM = nil real_dofile(script) end
local function alarm_file() return assert(call("session.new_block"), "no alarm block").options.command[3] end
local function worker(file) state.env.REX_BLOCK = "block:alarm" ALARM = nil real_dofile(file) end

local n, failed = 0, 0
local function trial(name, f)
  n = n + 1
  reset()
  local ok, err = pcall(f)
  if not ok then failed = failed + 1 end
  real_print((ok and "ok " or "not ok ") .. n .. " - " .. name .. (ok and "" or ": " .. tostring(err)))
end
local function fails(text, f)
  local ok, err = pcall(f)
  assert(not ok, "expected an error with " .. text)
  assert(tostring(err):find(text, 1, true), tostring(err))
end

trial("a new alarm is a private file that its block runs with rex do", function()
  set({ ["in"] = 120, message = "Check CI" })
  local file = alarm_file()
  local opts = call("session.new_block")
  assert(opts.session_id == "session:s")
  assert(#opts.options.command == 3 and opts.options.command[1] == "rex" and opts.options.command[2] == "do")
  assert(file:find(root .. "/alarms/host-1-", 1, true) == 1 and file:match("%.lua$"), file)
  assert(ls(root .. "/alarms"):match("^drwx%-%-%-%-%-%-%S? "), ls(root .. "/alarms"))
  assert(ls(file):match("^%-rw%-%-%-%-%-%-%-%S? "), ls(file))
  local text = read(file)
  assert(text:find('ALARM = { alarm_block = "block:alarm", session = "session:s", block = "block:agent", '
    .. 'message = "[alarm you set] Check CI", file = "' .. file .. '", at = 1795671120 }', 1, true), text)
  assert(text:find('return dofile("' .. lib.dir .. 'alarm.lua")', 1, true), text)
  assert(state.printed[1] == "alarm: block:alarm", tostring(state.printed[1]))
end)

trial("a recurring alarm stores its interval and start", function()
  set({ every = 60, message = "tick" })
  assert(read(alarm_file()):find("every = 60, start = 1795671000 }", 1, true))
end)

trial("an alarms folder that belongs to someone else stops the setter", function()
  state.uid = "99999"
  fails("belongs to someone else", function() set({ ["in"] = 5, message = "x" }) end)
  assert(not call("session.new_block"))
end)

trial("the root may be the user's own link to a folder, but alarms must be a folder", function()
  os.execute("rm -rf " .. sh_quote(root) .. " " .. sh_quote(root .. "-real") .. " && mkdir " .. sh_quote(root .. "-real")
    .. " && ln -s " .. sh_quote(root .. "-real") .. " " .. sh_quote(root))
  set({ ["in"] = 5, message = "x" })
  assert(call("session.new_block"))
  os.execute("rm -rf " .. sh_quote(root .. "-real/alarms") .. " && mkdir " .. sh_quote(root .. "-elsewhere")
    .. " && ln -s " .. sh_quote(root .. "-elsewhere") .. " " .. sh_quote(root .. "-real/alarms"))
  state.calls = {}
  fails("isn't a folder", function() set({ ["in"] = 5, message = "x" }) end)
  assert(not call("session.new_block"))
  os.execute("rm -rf " .. sh_quote(root) .. " " .. sh_quote(root .. "-real") .. " " .. sh_quote(root .. "-elsewhere"))
end)

trial("the worker reports how to restart itself with OSC 7577", function()
  set({ ["in"] = 120, message = "Check CI" })
  local file = alarm_file()
  state.out = {}
  worker(file)
  local function b64(s) return (run({ "sh", "-c", 'printf %s "$1" | base64', "sh", s }, {}).stdout:gsub("%s", "")) end
  local body = "pid=4242:time=1795671000:argv=" .. b64("rex") .. "," .. b64("do") .. "," .. b64(file)
  local mac = run({ "sh", "-c", 'printf %s "$1" | sha256sum | cut -c1-64', "sh", body .. ":" .. TOKEN }, {}).stdout:gsub("%s", "")
  local want = "\27]7577;" .. body .. ":mac=" .. mac .. "\27\\"
  assert(table.concat(state.out) == want, ("%q"):format(table.concat(state.out)))
end)

trial("base64 pads one- and two-byte tails", function()
  state.out = {}
  ALARM = { session = "session:s", block = "block:agent", message = "m", file = "/a/bc", at = state.now + 5 }
  real_dofile(script)
  assert(table.concat(state.out):find("argv=cmV4,ZG8=,L2EvYmM=:", 1, true), table.concat(state.out))
end)

trial("a one-shot fires at its absolute time, not a fresh countdown", function()
  set({ ["in"] = 120, message = "Check CI" })
  local file = alarm_file()
  state.now = state.now + 50
  worker(file)
  assert(state.timers[1].s == 70, tostring(state.timers[1].s))
end)

trial("a one-shot fires once, then deletes its file and closes its block", function()
  set({ ["in"] = 120, message = "Check CI" })
  local file = alarm_file()
  worker(file)
  state.now, state.out = state.now + 120, {}
  state.timers[1].f()
  local paste = call("block.event")
  assert(paste.block_id == "block:agent" and paste.event.payload.text == "[alarm you set] Check CI", paste.event.payload.text)
  assert(count("block.event") == 3)
  assert(table.concat(state.out):find("\27]7577;pid=4242:time=1795671120:clear=1:mac=", 1, true), table.concat(state.out))
  assert(not exists(file), "file left behind")
  local close = call("block.close")
  assert(close and close.block_id == "block:alarm" and close.session_id == "session:s")
  assert(state.stopped == 0)
  assert(#state.timers == 1)
end)

trial("a one-shot that wakes up late fires at once with a note", function()
  set({ ["in"] = 20, message = "Check CI" })
  local file = alarm_file()
  state.now = state.now + 39
  worker(file)
  assert(state.timers[1].s == 0)
  state.timers[1].f()
  assert(call("block.event").event.payload.text == "[alarm you set] Check CI [late by 19s, Rex restarted]",
    call("block.event").event.payload.text)
end)

trial("a recurring alarm keeps its phase and skips missed ticks", function()
  set({ every = 60, message = "tick" })
  local file = alarm_file()
  state.now = state.now + 140 -- restarted after ticks at +60 and +120 passed
  worker(file)
  assert(state.timers[1].s == 40, tostring(state.timers[1].s))
  state.now = state.now + 40
  state.timers[1].f()
  assert(count("block.event") == 3, "missed ticks must not fire")
  assert(call("block.event").event.payload.text == "[alarm you set] tick")
  assert(state.timers[2].s == 60 and exists(file) and not call("block.close"))
  state.now = state.now + 61 -- a timer that runs a second late keeps the phase
  state.timers[2].f()
  assert(state.timers[3].s == 59, tostring(state.timers[3].s))
end)

trial("the trust rule present: no hint", function()
  set({ ["in"] = 5, message = "x" })
  assert(#state.printed == 1, table.concat(state.printed, "\n"))
  local checked
  for _, argv in ipairs(state.execs) do
    if table.concat(argv, " ") == "rex config check --json" then checked = true end
  end
  assert(checked, "the setter didn't run rex config check --json")
end)

trial("the trust rule absent: one hint line after the alarm line", function()
  state.config.json = "norule"
  set({ ["in"] = 5, message = "x" })
  assert(#state.printed == 2 and state.printed[1] == "alarm: block:alarm", table.concat(state.printed, "\n"))
  assert(state.printed[2]:find("won't survive a Rex restart", 1, true), state.printed[2])
  assert(state.printed[2]:find('rex.set("resume.trust.rex-teams-alarm", { command = { "rex", "do", rex.match.under("'
    .. root .. '/alarms") } })', 1, true), state.printed[2])
  for _, argv in ipairs(state.execs) do assert(argv[3] ~= "reload", "the setter changed config") end
end)

trial("rex config check failing is an error, before any alarm exists", function()
  state.config.ok = false
  fails("init.lua:3: boom", function() set({ ["in"] = 5, message = "x" }) end)
  assert(not call("session.new_block"))
end)

trial("setting an alarm removes files whose block is gone", function()
  set({ ["in"] = 5, message = "old" })
  local gone = alarm_file()
  state.calls = {}
  set({ ["in"] = 5, message = "live" })
  local live = alarm_file()
  local other = root .. "/alarms/host-2-abc.lua"
  local f = assert(io.open(other, "w")) f:write('ALARM = { alarm_block = "block:elsewhere" }') f:close()
  state.blocks["block:alarm"] = nil -- the user closed the first alarm (same mock ID, so re-add the live one)
  state.blocks["block:alarm-live"] = "session:s"
  f = assert(io.open(live, "w")) f:write((read(gone):gsub('"block:alarm"', '"block:alarm-live"'))) f:close()
  state.calls = {}
  set({ ["in"] = 5, message = "new" })
  assert(not exists(gone), "a gone alarm's file stayed")
  assert(exists(live), "a live alarm's file was removed")
  assert(exists(other), "another Rex host's file was removed")
end)

print = real_print
if failed > 0 then print(failed .. " of " .. n .. " alarm trials failed.") os.exit(1) end
print("Passed " .. n .. " alarm trials.")
