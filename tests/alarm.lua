-- Run from the repo root with `lua5.1 tests/alarm.lua`.
-- An alarm is `rex do alarm.lua --args <json>`. rex.call, rex.exec, rex.after,
-- rex.wait and os.time are mocks. The one real command is the worker's
-- OSC 7577 shell, run with a fixed token.
local real_dofile, real_time, real_getenv, real_print = dofile, os.time, os.getenv, print
local script = "skills/rex-teams/scripts/alarm.lua"
local TOKEN = "fixed-test-token-0123456789"

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function run(argv, env)
  local line = "env"
  for k, v in pairs(env) do line = line .. " " .. k .. "=" .. sh_quote(v) end
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

-- JSON with sorted keys, like Rex's encoder. Each text maps back to its table.
local encoded = {}
local function encode(v)
  if type(v) == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return ("\\u%04x"):format(c:byte()) end) .. '"' end
  if type(v) ~= "table" then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = encode(k) .. ":" .. encode(v[k]) end
  local text = "{" .. table.concat(parts, ",") .. "}"
  encoded[text] = v
  return text
end

local state
local function reset()
  state = {
    now = 1795671000, env = { REX_BLOCK = "block:agent", OSC7577_TOKEN = TOKEN }, calls = {}, execs = {},
    timers = {}, out = {}, printed = {}, waited = nil, stopped = nil, sha256sum = true,
    blocks = { ["block:agent"] = "session:s" },
    records = { { chosen = true, trusted = true, rule = "rex-teams-alarm" } }, event = nil,
  }
end

os.time = function(t) if t then return real_time(t) end return state.now end
os.getenv = function(k) if state.env[k] ~= nil then return state.env[k] or nil end return real_getenv(k) end
io.stdout = { write = function(self, ...) for _, s in ipairs({ ... }) do state.out[#state.out + 1] = s end return self end,
  flush = function() end }
print = function(...) state.printed[#state.printed + 1] = table.concat({ ... }, "\t") end

rex = {
  args = {},
  json = { encode = encode },
  call = function(method, args)
    state.calls[#state.calls + 1] = { method = method, args = args }
    if method == "target.resolve" then
      local s = state.blocks[args.queries[1]]
      return { results = { { status = "resolved", target = { session_id = s, block_id = args.queries[1] } } } }
    end
    if method == "session.new_block" then state.blocks["block:alarm"] = args.session_id return { block_id = "block:alarm" } end
    if method == "com.superlogical.terminal.program_resume_records" then return { records = state.records } end
    if method == "block.method" and args.method == "format" then return { content = state.screen or "" } end
    return {}
  end,
  exec = function(argv, opts)
    state.execs[#state.execs + 1] = argv
    for _, a in ipairs(argv) do assert(not a:find(TOKEN, 1, true), "the token reached argv") end
    if argv[3] == "command -v sha256sum" then return { ok = state.sha256sum, code = state.sha256sum and 0 or 1, stdout = "", stderr = "" } end
    assert(argv[1] == "sh" and argv[3]:find("sha256sum", 1, true), "unexpected command " .. table.concat(argv, " "))
    return run(argv, { OSC7577_TOKEN = state.env.OSC7577_TOKEN })
  end,
  wait = function(event, filter, timeout)
    state.waited = { event = event, timeout = timeout }
    state.records = state.late_records or state.records
    if state.event and filter(state.event) then return state.event end
    return nil, "timeout"
  end,
  after = function(s, f) state.timers[#state.timers + 1] = { s = s, f = f } end,
  every = function() error("alarms schedule with rex.after from absolute times") end,
  stop = function(code) state.stopped = code end,
}
local lib = real_dofile("skills/rex-teams/scripts/lib.lua")
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
local function set(args) rex.args = args real_dofile(script) end
local function command() return assert(call("session.new_block"), "no alarm block").options.command end
local function worker()
  local json = command()[5]
  local args = assert(encoded[json], "unknown --args " .. tostring(json))
  state.env.REX_BLOCK, state.calls, state.out, state.printed = "block:alarm", {}, {}, {}
  set(args)
  return json
end

local n, failed = 0, 0
local mocks = { after = rex.after, call = rex.call }
local function trial(name, f)
  n = n + 1
  reset()
  local ok, err = pcall(f)
  rex.after, rex.call = mocks.after, mocks.call
  lib.windows = false
  if not ok then failed = failed + 1 end
  real_print((ok and "ok " or "not ok ") .. n .. " - " .. name .. (ok and "" or ": " .. tostring(err)))
end
local function fails(text, f)
  local ok, err = pcall(f)
  assert(not ok, "expected an error with " .. text)
  assert(tostring(err):find(text, 1, true), tostring(err))
end

trial("an alarm is rex do alarm.lua --args with its details", function()
  set({ ["in"] = 120, message = 'Check "CI" — ünïcode' })
  local c = command()
  assert(#c == 5 and c[1] == "rex" and c[2] == "do" and c[3] == lib.dir .. "alarm.lua" and c[4] == "--args", table.concat(c, " "))
  assert(c[5] == '{"at":1795671120,"block":"block:agent","message":"[alarm you set] Check \\u0022CI\\u0022 — ünïcode",'
    .. '"session":"session:s","worker":true}', c[5])
  assert(call("session.new_block").session_id == "session:s")
  assert(state.printed[1] == "alarm: block:alarm", tostring(state.printed[1]))
end)

trial("a recurring alarm stores its interval and start", function()
  set({ every = 60, message = "tick" })
  assert(command()[5] == '{"block":"block:agent","every":60,"message":"[alarm you set] tick","session":"session:s","start":1795671000,"worker":true}', command()[5])
end)

trial("a message with a newline is refused before anything exists", function()
  fails("one line", function() set({ ["in"] = 5, message = "a\nb" }) end)
  assert(#state.calls == 0)
end)

trial("fractional intervals are stored exactly", function()
  set({ every = 0.5, message = "fast" })
  assert(command()[5]:find('"every":0.5,', 1, true), command()[5])
  worker()
  assert(state.timers[1].s == 0.5, tostring(state.timers[1].s))
  reset()
  set({ ["in"] = 1.5, message = "soon" })
  assert(command()[5]:find('"at":1795671001.5,', 1, true), command()[5])
  worker()
  assert(state.timers[1].s == 1.5, tostring(state.timers[1].s))
end)

trial("the worker reports its exact command with OSC 7577", function()
  set({ ["in"] = 120, message = "Check CI" })
  local json = worker()
  local out = table.concat(state.out)
  local body, mac = out:match("^\27%]7577;(pid=%d+:time=1795671000:argv=[^:]+):mac=(%x+)\27\\$")
  assert(body, ("%q"):format(out))
  local want = run({ "sh", "-c", 'printf %s "$1" | sha256sum | cut -c1-64', "sh", body .. ":" .. TOKEN }, {}).stdout:gsub("%s", "")
  assert(mac == want, "wrong mac")
  local words = {}
  for _, w in ipairs({ "rex", "do", lib.dir .. "alarm.lua", "--args", json }) do
    words[#words + 1] = (run({ "sh", "-c", 'printf %s "$1" | base64 | tr -d "\\n"', "sh", w }, {}).stdout:gsub("%s", ""))
  end
  assert(body:match("argv=(.*)$") == table.concat(words, ","), body)
end)

trial("base64 pads one- and two-byte tails", function()
  local dir = lib.dir
  lib.dir = "/ab/"
  local ok, err = pcall(set, { worker = true, session = "s", block = "b", message = "m", at = state.now + 5 })
  lib.dir = dir
  assert(ok, err)
  local want = "argv=cmV4,ZG8=,L2FiL2FsYXJtLmx1YQ==,LS1hcmdz,"
  assert(table.concat(state.out):find(want, 1, true), table.concat(state.out))
end)

trial("a one-shot fires at its absolute time, not a fresh countdown", function()
  set({ ["in"] = 120, message = "Check CI" })
  state.now = state.now + 50
  worker()
  assert(state.timers[1].s == 70, tostring(state.timers[1].s))
end)

trial("a one-shot fires once, clears its record and closes its block", function()
  set({ ["in"] = 120, message = "Check CI" })
  worker()
  state.now, state.out = state.now + 120, {}
  state.timers[1].f()
  local paste = call("block.event")
  assert(paste.block_id == "block:agent" and paste.event.payload.text == "[alarm you set] Check CI", paste.event.payload.text)
  assert(count("block.event") == 3)
  assert(table.concat(state.out):match("^\27%]7577;pid=%d+:time=1795671120:clear=1:mac=%x+\27\\$"), table.concat(state.out))
  local close = call("block.close")
  assert(close and close.block_id == "block:alarm" and close.session_id == "session:s")
  assert(state.stopped == 0 and #state.timers == 1)
end)

trial("a one-shot that starts late fires at once with a note", function()
  set({ ["in"] = 20, message = "Check CI" })
  state.now = state.now + 39
  worker()
  assert(state.timers[1].s == 0)
  state.timers[1].f()
  assert(call("block.event").event.payload.text == "[alarm you set] Check CI [late by 19s, Rex restarted]",
    call("block.event").event.payload.text)
  reset()
  set({ ["in"] = 20, message = "Check CI" })
  state.now = state.now + 20
  worker()
  state.timers[1].f()
  assert(call("block.event").event.payload.text == "[alarm you set] Check CI", "on time is not late")
end)

trial("a recurring alarm keeps its phase and skips missed ticks", function()
  set({ every = 60, message = "tick" })
  state.now = state.now + 140 -- restarted after ticks at +60 and +120 passed
  worker()
  assert(state.timers[1].s == 40, tostring(state.timers[1].s))
  state.now = state.now + 40
  state.timers[1].f()
  assert(count("block.event") == 3, "missed ticks must not fire")
  assert(call("block.event").event.payload.text == "[alarm you set] tick")
  assert(state.timers[2].s == 60 and not call("block.close"))
  state.now = state.now + 61 -- a timer that runs a second late keeps the phase
  state.timers[2].f()
  assert(state.timers[3].s == 59, tostring(state.timers[3].s))
end)

-- Rex's clock is whole seconds, but its timers run on real time. Run the
-- alarm's timers on a real clock T, with os.time() = floor(T).
local function run_real(start, f)
  local t, queue, fired = start, {}, {}
  state.now = math.floor(t)
  rex.after = function(s, g) queue[#queue + 1] = { due = t + s, f = g } end
  local paste = rex.call
  rex.call = function(method, args)
    if method == "block.event" and args.event.type == "paste" then fired[#fired + 1] = { t = t, text = args.event.payload.text } end
    return paste(method, args)
  end
  f()
  local function step()
    table.sort(queue, function(x, y) return x.due < y.due end)
    local next = table.remove(queue, 1)
    if not next then return false end
    t = next.due
    state.now = math.floor(t)
    next.f()
    return true
  end
  return fired, step
end
local function at_real(t) state.now = math.floor(t) end

trial("fractional recurring alarms fire on their phase, never early or twice", function()
  for _, every in ipairs({ 0.3, 1.5, 2.5 }) do
    reset()
    at_real(1795671000.7)
    set({ every = every, message = "tick" })
    local start = 1795671000
    local fired, step = run_real(1795671000.9, worker)
    while #fired < 12 and step() do end
    assert(#fired == 12, every .. ": " .. #fired .. " ticks")
    for k, f in ipairs(fired) do
      local due = start + k * every
      assert(f.t >= due - 1e-9 and f.t < due + 1, ("every=%s tick %d at +%.2f, due +%.2f"):format(every, k, f.t - start, due - start))
    end
  end
end)

trial("a one-shot claims a restart only when it starts at least 1s late", function()
  -- in<1, with the worker starting just past a second boundary
  at_real(1795671000.95)
  set({ ["in"] = 0.5, message = "soon" })
  local fired, step = run_real(1795671001.05, worker)
  while step() do end
  assert(fired[1].text == "[alarm you set] soon", fired[1].text)
  -- a slow worker that starts just past a second boundary
  reset()
  at_real(1795671000.2)
  set({ ["in"] = 1.5, message = "soon" })
  fired, step = run_real(1795671002.05, worker)
  while step() do end
  assert(fired[1].text == "[alarm you set] soon", fired[1].text)
end)

trial("a one-shot never fires before its time", function()
  for _, wait in ipairs({ 5, 1.5, 0.5 }) do
    reset()
    at_real(1795671000.95)
    set({ ["in"] = wait, message = "x" })
    local at = 1795671000 + wait
    local fired, step = run_real(1795671001.05, worker)
    while step() do end
    assert(#fired == 1 and fired[1].t >= at, ("in=%s fired at +%.2f, due +%.2f"):format(wait, fired[1].t - 1795671000, wait))
  end
end)

trial("without OSC7577_TOKEN the worker stops and the setter says why", function()
  set({ ["in"] = 5, message = "x" })
  state.env.OSC7577_TOKEN = false
  fails("OSC7577_TOKEN isn't set", worker)
  assert(#state.timers == 0 and #state.out == 0, "the alarm armed without a report")
  reset()
  state.records = {}
  state.screen = "\nalarm worker failed: OSC7577_TOKEN isn't set, so Rex can't resume this alarm\n"
  set({ ["in"] = 5, message = "x" })
  assert(call("session.new_block").options.exit.on_completion == false, "a failed worker's block must stay")
  assert(call("block.method").args.unwrap, "read the screen unwrapped")
  assert(state.printed[2] == "alarm: alarm worker failed: OSC7577_TOKEN isn't set, so Rex can't resume this alarm", tostring(state.printed[2]))
end)

local function hint() return state.printed[2] or "" end
local rule = 'rex.set("resume.trust.rex-teams-alarm", { command = { "rex", "do", "' .. lib.dir
  .. 'alarm.lua" }, flags = { ["--args"] = { "keep", values = 1 } } })'

trial("a trusted alarm prints no hint", function()
  set({ ["in"] = 5, message = "x" })
  local asked = call("com.superlogical.terminal.program_resume_records")
  assert(asked.block_id == "block:alarm" and asked.session_id == "session:s")
  assert(#state.printed == 1 and not state.waited, table.concat(state.printed, "\n"))
end)

trial("no rule: one hint line with the rule", function()
  state.records = { { chosen = true, untrusted_reason = "no_rule" } }
  set({ ["in"] = 5, message = "x" })
  assert(#state.printed == 2 and hint():find("won't survive a Rex restart. ", 1, true), hint())
  assert(hint():find(rule, 1, true), hint())
end)

trial("another reason is named in the hint", function()
  state.records = { { chosen = true, untrusted_reason = "flags_differ" } }
  set({ ["in"] = 5, message = "x" })
  assert(hint():find("restart (flags_differ). ", 1, true) and hint():find(rule, 1, true), hint())
end)

trial("a record that arrives late is waited for, briefly", function()
  state.records = {}
  state.event = { block_id = "block:alarm", records = { { chosen = true, untrusted_reason = "no_rule" } } }
  set({ ["in"] = 5, message = "x" })
  assert(state.waited.event == "terminal.program_resume_changed" and state.waited.timeout <= 5)
  assert(hint():find(rule, 1, true), hint())
end)

trial("a record that lands just before the wait is read again", function()
  state.records, state.late_records = {}, { { chosen = true, trusted = true } }
  state.event = { block_id = "block:other", records = { { chosen = true, untrusted_reason = "no_rule" } } }
  set({ ["in"] = 5, message = "x" })
  assert(#state.printed == 1, table.concat(state.printed, "\n"))
end)

trial("no record at all says so", function()
  state.records = {}
  set({ ["in"] = 5, message = "x" })
  assert(hint():find("no resume record", 1, true), hint())
end)

trial("a missing sha256sum stops the setter before anything exists", function()
  state.sha256sum = false
  fails("alarm.lua needs sha256sum (macOS 15+ or coreutils)", function() set({ ["in"] = 5, message = "x" }) end)
  assert(#state.calls == 0)
end)

trial("on Windows an alarm is plain: no report, no hint, no POSIX tools", function()
  lib.windows = true
  set({ ["in"] = 5, message = "x" })
  assert(#state.printed == 1 and not call("com.superlogical.terminal.program_resume_records"))
  worker()
  state.timers[1].f()
  assert(#state.execs == 0, "ran " .. table.concat(state.execs[1] or {}, " "))
  assert(#state.out == 0 and call("block.event") and call("block.close"))
end)

print = real_print
if failed > 0 then print(failed .. " of " .. n .. " alarm trials failed.") os.exit(1) end
print("Passed " .. n .. " alarm trials.")
