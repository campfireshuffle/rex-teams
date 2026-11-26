-- rex do <skill>/scripts/alarm.lua in=1200 message="Check the deployment"
-- Use every=1800 to repeat. The target defaults to the calling agent.
--
-- An alarm is a block running `rex do <this script> --args <json>`, and its
-- arguments are all there is to it. The worker tells Rex that command
-- (OSC 7577), so a trust rule can start it again after Rex restarts.
-- Rex doesn't resume programs on Windows, so there the worker doesn't report.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
local script = lib.dir .. "alarm.lua"
local a = rex.args

local function b64(s)
  local abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local out = {}
  for i = 1, #s, 3 do
    local x, y, z = s:byte(i, i + 2)
    local n = x * 65536 + (y or 0) * 256 + (z or 0)
    local function digit(shift) local d = math.floor(n / shift) % 64 return abc:sub(d + 1, d + 1) end
    out[#out + 1] = digit(262144) .. digit(4096) .. (y and digit(64) or "=") .. (z and digit(1) or "=")
  end
  return table.concat(out)
end

-- Tell Rex how to start this worker again, or that it shouldn't (OSC 7577).
-- The owner is this `rex do`, the shell's parent. The token stays in the
-- shell's environment, never on a command line.
local function report(fields)
  if lib.windows or not os.getenv("OSC7577_TOKEN") then return end
  local r = assert(rex.exec({ "sh", "-c", 'body="pid=$PPID:time=$1:$2"; printf "%s:mac=" "$body"; '
    .. 'printf "%s:%s" "$body" "$OSC7577_TOKEN" | sha256sum | cut -c1-64', "sh", tostring(os.time()), fields }))
  local body = r.ok and r.stdout:match("^(pid=%d+:.*:mac=%x+)%s*$")
  assert(body and #body:match("mac=(%x+)$") == 64, "the OSC 7577 report failed: " .. tostring(r.stderr ~= "" and r.stderr or r.stdout))
  io.stdout:write("\27]7577;", body, "\27\\")
  io.stdout:flush()
end

if a.worker then
  lib.attach(a.session)
  local argv = {}
  for i, word in ipairs({ "rex", "do", script, "--args", rex.json.encode(a) }) do argv[i] = b64(word) end
  report("argv=" .. table.concat(argv, ","))
  local function fire(note)
    lib.paste_line(a.session, a.block, a.message .. note)
  end
  if a.at then
    -- Started after its time means Rex was down when it was due.
    local late = os.time() - a.at
    print("alarm: due at " .. os.date("%H:%M:%S", a.at))
    rex.after(math.max(0, -late), function()
      fire(late > 0 and (" [late by " .. late .. "s, Rex restarted]") or "")
      report("clear=1")
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

local seconds = assert(a["in"] or a.every, "use in=SECONDS or every=SECONDS")
assert(seconds > 0 and not (a["in"] and a.every), "use one positive interval")
local message = tostring(assert(a.message, "message is required"))
assert(not message:find("[\r\n]"), "the message must be one line")
if not lib.windows then
  local r = rex.exec({ "sh", "-c", "command -v sha256sum" })
  assert(r and r.ok, "alarm.lua needs sha256sum (macOS 15+ or coreutils)")
end

local from_session, from_block = lib.me()
local session, block = a.session or from_session, a.block or from_block
local header = session == from_session and block == from_block
  and "[alarm you set] "
  or lib.header(from_session, from_block)
local now = os.time()
local args = { worker = true, session = session, block = block, message = header .. message,
  at = a["in"] and now + a["in"], every = a.every, start = a.every and now }
lib.attach(session)
local alarm = lib.call("session.new_block", {
  session_id = session,
  label = "alarm: " .. message:sub(1, 40),
  flavor = "com.superlogical.terminal.shell",
  options = { command = { "rex", "do", script, "--args", rex.json.encode(args) } },
}).block_id
print("alarm: " .. alarm)
if lib.windows then return end

-- Rex says whether a rule trusts the worker once its report is in.
local function chosen(records)
  for _, r in ipairs(records or {}) do if r.chosen then return r end end
end
local function records()
  return lib.call("com.superlogical.terminal.program_resume_records", { session_id = session, block_id = alarm, args = {} }).records
end
local record = chosen(records())
if not record then
  local ev = rex.wait("terminal.program_resume_changed", function(e) return e.block_id == alarm and chosen(e.records) end, 5)
  record = chosen(ev and ev.records) or chosen(records())
end
if not record then
  print("alarm: Rex has no resume record for this alarm after 5s. Check with: rex block call -b " .. alarm .. " program_resume_records")
elseif not record.trusted then
  print("alarm: this alarm won't survive a Rex restart"
    .. (record.untrusted_reason == "no_rule" and "" or " (" .. tostring(record.untrusted_reason) .. ")")
    .. ". To keep alarms, add this to Rex's init.lua and run rex config reload: "
    .. ('rex.set("resume.trust.rex-teams-alarm", { command = { "rex", "do", %q }, flags = { ["--args"] = { "keep", values = 1 } } })'):format(script))
end
