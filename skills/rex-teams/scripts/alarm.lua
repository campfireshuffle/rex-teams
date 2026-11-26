-- rex do <skill>/scripts/alarm.lua in=1200 message="Check the deployment"
-- Use every=1800 to repeat. The target defaults to the calling agent.
--
-- An alarm is a file in the alarms folder that sets ALARM and runs this
-- script. Its block runs `rex do <file>`, and the worker tells Rex how to
-- start it again (OSC 7577), so a trust rule can resume it after Rex restarts.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
local dir = lib.path("alarms")
local rule = ('rex.set("resume.trust.rex-teams-alarm", { command = { "rex", "do", rex.match.under("%s") } })'):format(dir)

local function exec(argv, opts)
  local r, err = rex.exec(argv, opts)
  assert(r and r.ok, table.concat(argv, " ") .. " failed: " .. tostring(r and (r.stderr ~= "" and r.stderr or r.stdout) or err))
  return r.stdout
end

local function b64(s)
  local abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local function digit(shift) local d = math.floor(n / shift) % 64 return abc:sub(d + 1, d + 1) end
    out[#out + 1] = digit(262144) .. digit(4096) .. (b and digit(64) or "=") .. (c and digit(1) or "=")
  end
  return table.concat(out)
end

-- Tell Rex how to start this worker again, or that it shouldn't (OSC 7577).
-- The token stays in the hashing shell's environment, never on a command line.
local function report(fields)
  if not os.getenv("OSC7577_TOKEN") then return end
  -- The owner is this `rex do`, the parent of the shell.
  local pid = assert(exec({ "sh", "-c", "echo $PPID" }, { env = { OSC7577_TOKEN = false } }):match("%d+"))
  local body = ("pid=%s:time=%d:%s"):format(pid, os.time(), fields)
  local mac = exec({ "sh", "-c", 'printf "%s:%s" "$BODY" "$OSC7577_TOKEN" | sha256sum | cut -c1-64' },
    { env = { BODY = body } }):gsub("%s", "")
  assert(mac:match("^%x+$") and #mac == 64, "sha256sum printed " .. mac)
  io.stdout:write("\27]7577;", body, ":mac=", mac, "\27\\")
  io.stdout:flush()
end

if ALARM then
  local a = ALARM
  lib.attach(a.session)
  report("argv=" .. b64("rex") .. "," .. b64("do") .. "," .. b64(a.file))
  local function fire(note)
    lib.paste_line(a.session, a.block, a.message .. note)
  end
  local now = os.time()
  if a.at then
    -- Started after its time means Rex was down when it was due.
    local late = now - a.at
    print("alarm: due at " .. os.date("%H:%M:%S", a.at))
    rex.after(math.max(0, -late), function()
      fire(late > 0 and (" [late by " .. late .. "s, Rex restarted]") or "")
      report("clear=1")
      os.remove(a.file)
      -- Rex resumes the worker under a shell, which would stay in the pane.
      local session, block = lib.me()
      lib.call("block.close", { session_id = session, block_id = block })
      rex.stop(0)
    end)
  else
    -- Ticks fall at start + k*every. Ticks missed while Rex was down are skipped.
    local function next_tick()
      local wait = a.every - (os.time() - a.start) % a.every
      print("alarm: next at " .. os.date("%H:%M:%S", os.time() + wait))
      rex.after(wait, function() fire("") next_tick() end)
    end
    next_tick()
  end
  return
end

local a = rex.args
local seconds = assert(a["in"] or a.every, "use in=SECONDS or every=SECONDS")
assert(seconds > 0 and not (a["in"] and a.every), "use one positive interval")
local message = tostring(assert(a.message, "message is required"))
assert(not message:find("[\r\n]"), "the message must be one line")

local from_session, from_block = lib.me()
local session, block = a.session or from_session, a.block or from_block
local header = session == from_session and block == from_block
  and "[alarm you set] "
  or lib.header(from_session, from_block)

-- Rex resumes any file in the folder as the user, so it must be the user's alone.
-- The root may be the user's own link to another folder, so check it and its target.
lib.mkdir(dir)
local uid = exec({ "id", "-u" }):match("%d+")
for _, path in ipairs({ lib.root, lib.root .. lib.sep, dir }) do
  local kind, owner = exec({ "ls", "-ldn", path }):match("^(.)%S*%s+%d+%s+(%d+)")
  assert(owner == uid and (kind == "d" or path == lib.root),
    path .. " belongs to someone else or isn't a folder, so alarms can't be kept there")
end
exec({ "chmod", "700", dir })

-- Files are named by Rex host, so another Rex server's alarms are left alone.
local host = assert(lib.call("server.status", {}).host_id, "Rex didn't report this host's host_id")
for name in exec({ "ls", dir }):gmatch("[^\n]+") do
  if name:sub(1, #host + 1) == host .. "-" and name:match("%.lua$") then
    local path = dir .. lib.sep .. name
    local id = lib.read(path):match('^ALARM = { alarm_block = "([^"]+)"')
    local found = id and lib.call("target.resolve", { queries = { id }, kinds = { "block" } }).results[1]
    if found and found.status == "not_found" then
      assert(os.remove(path))
    else
      assert(not found or found.status == "resolved", "Rex can't tell whether alarm " .. id .. " exists (" .. tostring(found and found.status) .. ")")
    end
  end
end

-- Only a trust rule lets Rex start the worker again after a restart.
local config = rex.exec({ "rex", "config", "check", "--json" })
assert(config and config.ok, "rex config check failed, so I can't tell whether alarms survive a restart: "
  .. tostring(config and config.stderr))
local trusted
for _, r in ipairs(rex.json.decode(config.stdout).resume_rules) do
  local c = r.rule and r.rule.command or {}
  local under = type(c[3]) == "table" and c[3].match == "under" and c[3].dir:gsub("/+$", "")
  if #c == 3 and c[1] == "rex" and c[2] == "do" and under and (dir == under or dir:sub(1, #under + 1) == under .. "/") then
    trusted = true
  end
end

local function save(path, alarm)
  local fields = {}
  if alarm.alarm_block then fields[1] = ("alarm_block = %q"):format(alarm.alarm_block) end
  for _, k in ipairs({ "session", "block", "message", "file" }) do fields[#fields + 1] = ("%s = %q"):format(k, alarm[k]) end
  fields[#fields + 1] = alarm.at and ("at = %d"):format(alarm.at) or ("every = %d, start = %d"):format(alarm.every, alarm.start)
  -- Write a private copy, then rename it, so a worker never reads half a file.
  lib.write(alarm.tmp, ("ALARM = { %s }\nreturn dofile(%q)\n"):format(table.concat(fields, ", "), lib.dir .. "alarm.lua"))
  exec({ "chmod", "600", alarm.tmp })
  assert(os.rename(alarm.tmp, path))
end

local now = os.time()
local tmp = exec({ "mktemp", dir .. lib.sep .. host .. "-XXXXXXXXXX" }):gsub("%s+$", "")
local alarm = { session = session, block = block, message = header .. message, file = tmp .. ".lua", tmp = tmp,
  at = a["in"] and now + seconds, every = a.every, start = a.every and now }
save(alarm.file, alarm)

lib.attach(session)
local ok, created = pcall(lib.call, "session.new_block", {
  session_id = session,
  label = "alarm: " .. message:sub(1, 40),
  flavor = "com.superlogical.terminal.shell",
  options = { command = { "rex", "do", alarm.file } },
})
if not ok then
  os.remove(alarm.file)
  error(created, 0)
end
-- The block ID lets a later alarm remove this file once the block is closed.
alarm.alarm_block = created.block_id
save(alarm.file, alarm)
print("alarm: " .. created.block_id)
if not trusted then
  print("alarm: this alarm won't survive a Rex restart. To keep alarms, add this line to Rex's init.lua: " .. rule)
end
