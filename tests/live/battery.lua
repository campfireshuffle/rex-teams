-- The live battery: real Rex, real agent CLIs. Not run by CI.
--
--   rex do tests/live/battery.lua [only=codex,pi] [host=LABEL]
--
-- It opens a scratch session, rex-teams-battery, with a stand-in sender (a
-- plain shell) and one pane per CLI, and checks each scenario the postman
-- handles. Receivers are told not to reply or run anything, and every
-- message names a sender that isn't an agent. With host=, it also sends one
-- message to a Pi in a scratch session on that host. It closes everything
-- it opened, including any postman it started, and prints a table.
--
-- It uses the postman in this checkout, so stop any other postman first
-- (see /tmp/rex-teams/postman.json).
local repo = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "../../"
local scripts = repo .. "skills/rex-teams/scripts/"
local a = rex.args
local T = "com.superlogical.terminal"
local quiet = " Test only: don't reply, and don't run anything."

local clis = {
  { name = "claude-code", cmd = { "claude" } },
  { name = "codex", cmd = { "codex" } },
  { name = "opencode", cmd = { "opencode" } },
  { name = "pi", cmd = { "pi" } },
  { name = "shell" }, -- this host's shell: the postman doesn't read it
}
-- A CLI that can show a permission dialog, started so it does.
local dialogs = { codex = { "codex", "-a", "on-request", "-s", "read-only", "-c", "approvals_reviewer=user" } }
if a.only then
  local keep = {}
  for name in tostring(a.only):gmatch("[^,]+") do keep[name] = true end
  local out = {}
  for _, c in ipairs(clis) do if keep[c.name] then out[#out + 1] = c end end
  clis = out
end

local function call(method, args, host)
  local api = host and rex.server(host) or rex
  local r, err = api.call(method, args)
  if not r then error(method .. ": " .. tostring(err), 0) end
  return r
end
local function now()
  local r = rex.exec({ "perl", "-MTime::HiRes=time", "-e", "printf q(%.3f), time" })
  return tonumber(r.stdout)
end
local function exists(path)
  local f = io.open(path)
  if f then f:close() end
  return f ~= nil
end
local function outbox(id) return "/tmp/rex-teams/outbox/" .. id .. ".json" end

-- The scratch session ----------------------------------------------------------

local work = "/tmp/rex-teams-battery"
rex.exec({ "mkdir", "-p", work })
local session = call("session.create", { label = "rex-teams-battery" }).session_id
call("session.attach", { session_id = session })
local function pane(label, cmd)
  local r = call("session.new_window", { session_id = session, window_label = label, focus = false,
    layout = rex.layout.block({ flavor = T .. ".shell", options = { cwd = work, command = cmd, exit = { on_completion = false } } }) })
  return r.block_ids[1]
end
local sender = pane("battery sender")
local function method(block, name, args, host, s)
  return call("block.method", { session_id = s or session, block_id = block, method = name, args = args or {} }, host)
end
local function status(block, host, s)
  for _, r in ipairs(method(block, "program_status", {}, host, s).records or {}) do
    if not r.id then return r.state, r.kind end
  end
end
local function screen(block, host, s) return method(block, "format", { format = "text" }, host, s).content end
local function write(block, data) method(block, "write", { data = data }) end
local function paste(block, text)
  call("block.event", { session_id = session, block_id = block, event = { type = "paste", payload = { text = text } } })
end
local function enter(block)
  for _, action in ipairs({ "press", "release" }) do
    call("block.event", { session_id = session, block_id = block, event = { type = "key", payload = {
      key = "enter", mods = "", consumed_mods = "", text = "\r", unshifted_codepoint = 13, composing = false, action = action } } })
  end
end
local function wait_for(f, seconds)
  local deadline = now() + seconds
  while now() < deadline do
    if f() then return true end
    rex.sleep(0.25)
  end
  return f()
end
local function idle(block, host, s)
  local st = status(block, host, s)
  return st ~= nil and st ~= "working" and st ~= "blocked"
end

-- send.lua and alarm.lua as the stand-in sender.
local function run(script, args)
  local r = rex.exec({ "rex", "do", scripts .. script, "--args", rex.json.encode(args) }, { env = { REX_BLOCK = sender }, timeout = 60 })
  if not (r and r.ok) then error(script .. " failed: " .. tostring(r and (r.stderr .. r.stdout))) end
  local id = r.stdout:match("(%d+%-%a%a%a%a)")
  return assert(id, r.stdout), r.stdout
end
local function send(block, text, host) return run("send.lua", { block = block, message = text .. quiet, host = host }) end

-- A message as mail.post would queue it, already pasted and Entered, to
-- stand in for one whose Enter the CLI lost. BEFORE runs first, with the
-- text the postman pasted.
local function forge(block, text, before)
  local id = tostring(os.time()) .. "-" .. string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122), math.random(97, 122))
  local msg = { id = id, posted = os.time(), to = { session = session, block = block, name = "receiver" },
    from = { session = session, block = sender, name = "battery sender" },
    head = "[from battery sender", tail = ", who can't see this screen.] ", text = text .. quiet }
  local pasted = msg.head .. " · msg " .. id .. msg.tail .. msg.text
  msg.d = { tag = id, pasted_at = os.time(), known = true, text = pasted }
  before(pasted)
  rex.sleep(1)
  local f = assert(io.open(outbox(id) .. ".tmp", "w"))
  f:write(rex.json.encode(msg))
  f:close()
  assert(os.rename(outbox(id) .. ".tmp", outbox(id)))
  return id
end

-- Scenarios ----------------------------------------------------------------------

local results, order = {}, {}
local function record(cli, scenario, ok, note)
  if not results[scenario] or not results[scenario].listed then
    results[scenario] = results[scenario] or {}
    results[scenario].listed = true
    order[#order + 1] = scenario
  end
  results[scenario][cli] = (ok and "pass" or "FAIL") .. (note and note ~= "" and " (" .. note .. ")" or "")
  print(("%-12s %-22s %s"):format(cli, scenario, results[scenario][cli]))
end
local function delivered(block, id, seconds)
  local t0 = now()
  local ok = wait_for(function() return not exists(outbox(id)) end, seconds or 30)
  return ok, now() - t0
end
local function seen(block, id) return screen(block):find("msg " .. id, 1, true) ~= nil end
local function clear(block) write(block, string.rep("\127", 400)) rex.sleep(0.5) end

local scenarios = {}
function scenarios.idle(c)
  local id = send(c.block, "Idle delivery.")
  local ok, took = delivered(c.block, id)
  return ok and seen(c.block, id), ("%.1fs"):format(took)
end
function scenarios.draft(c)
  write(c.block, "a person's half-written draft")
  rex.sleep(1)
  local id = send(c.block, "Draft held.")
  rex.sleep(6)
  local held = exists(outbox(id)) and screen(c.block):find("half-written draft", 1, true) and not seen(c.block, id)
  clear(c.block)
  local ok = delivered(c.block, id)
  return held and ok and seen(c.block, id), held and "held 6s, then sent" or "not held"
end
function scenarios.busy(c)
  paste(c.block, "Run the shell command `sleep 15` and then reply with just OK.")
  enter(c.block)
  if not wait_for(function() return status(c.block) == "working" end, 10) then return false, "never got busy" end
  local id = send(c.block, "Busy steered.")
  local ok, took = delivered(c.block, id, 10)
  local working = status(c.block) == "working"
  -- The CLI takes it in: the id shows on its screen.
  local shown = wait_for(function() return seen(c.block, id) end, 90)
  return ok and working and shown, ("delivered %.1fs into the turn"):format(took)
end
function scenarios.lost_enter(c)
  -- What a lost Enter leaves: our text in the composer, unsent.
  local id = forge(c.block, "Lost Enter.", function(text) paste(c.block, text) end)
  local ok = delivered(c.block, id, 20)
  return ok and seen(c.block, id), ok and "Enter pressed once more" or "still queued"
end
function scenarios.shell(c)
  write(c.block, "a draft the postman doesn't read")
  rex.sleep(1)
  local id = send(c.block, "Shell paste.")
  local ok, took = delivered(c.block, id, 10)
  return ok and seen(c.block, id), ("%.1fs"):format(took)
end
function scenarios.alarm(c)
  local id = run("alarm.lua", { ["in"] = 5, message = "Alarm on time." .. quiet, block = c.block })
  local f = assert(io.open(outbox(id)))
  local at = rex.json.decode(f:read("*a")).at
  f:close()
  local ok = wait_for(function() return not exists(outbox(id)) end, 20)
  -- Delivered once the receiver starts on it, a moment after the paste.
  local late = now() - at
  return ok and late >= 0 and late < 3 and seen(c.block, id), ("+%.1fs after its time"):format(late)
end
function scenarios.dialog(c)
  if not c.dialog then return nil, "no dialog in this CLI" end
  paste(c.dialog, "Run the shell command: touch " .. work .. "/dialog.txt")
  enter(c.dialog)
  if not wait_for(function() return status(c.dialog) == "blocked" end, 40) then return false, "no dialog shown" end
  local id = send(c.dialog, "Dialog held.")
  rex.sleep(6)
  local held = exists(outbox(id)) and not seen(c.dialog, id)
  write(c.dialog, "\27") -- cancel the dialog
  local ok = delivered(c.dialog, id, 40)
  return held and ok, held and "held while its prompt box was covered" or "not held"
end

-- Run ---------------------------------------------------------------------------------

local function postman()
  local f = io.open("/tmp/rex-teams/postman.json")
  if not f then return nil end
  local s = rex.json.decode(f:read("*a"))
  f:close()
  return s
end
local before = postman()
local cleanup = {}
local ok, err = pcall(function()
  math.randomseed(os.time())
  for _, c in ipairs(clis) do
    c.block = pane(c.name, c.cmd)
    if dialogs[c.name] then c.dialog = pane(c.name .. " (dialog)", dialogs[c.name]) end
  end
  for _, c in ipairs(clis) do
    if c.cmd and not wait_for(function() return idle(c.block) end, 40) then c.down = "never idle: " .. tostring(status(c.block)) end
  end
  for _, name in ipairs({ "idle", "draft", "busy", "lost_enter", "dialog", "alarm", "shell" }) do
    for _, c in ipairs(clis) do
      if c.down then record(c.name, name, false, c.down) else
        if c.cmd then wait_for(function() return idle(c.block) end, 60) end
        local ok2, pass, note = true, nil, "not for this pane"
        if (c.name == "shell") == (name == "shell") then ok2, pass, note = pcall(scenarios[name], c) end
        if not ok2 then record(c.name, name, false, tostring(pass))
        elseif pass == nil then results[name] = results[name] or {} record(c.name, name, true, "n/a: " .. note)
        else record(c.name, name, pass, note) end
      end
    end
  end
  if a.host then
    local far = call("session.create", { label = "rex-teams-battery" }, a.host).session_id
    cleanup.far = far
    call("session.attach", { session_id = far }, a.host)
    local b = call("session.new_window", { session_id = far, window_label = "pi", focus = false,
      layout = rex.layout.block({ flavor = T .. ".shell", options = { command = { "pi" }, exit = { on_completion = false } } }) }, a.host).block_ids[1]
    wait_for(function() return idle(b, a.host, far) end, 60)
    local id = send(b, "Cross-host delivery.", a.host)
    local ok2 = delivered(b, id, 60)
    record("pi@" .. a.host, "cross-host", ok2 and screen(b, a.host, far):find("msg " .. id, 1, true) ~= nil)
  end
end)
if not ok then print("battery stopped: " .. tostring(err)) end

-- Clean up: the scratch sessions, and the postman if this run started it.
call("session.destroy", { session_id = session })
local after = postman()
if after and (not before or after.block ~= before.block) then
  pcall(call, "session.attach", { session_id = after.session })
  pcall(call, "block.close", { session_id = after.session, block_id = after.block })
  print("closed the postman this run started: " .. after.block)
end
if cleanup.far then pcall(call, "session.destroy", { session_id = cleanup.far }, a.host) end
print("")
local header = "| scenario |"
for _, c in ipairs(clis) do header = header .. " " .. c.name .. " |" end
print(header)
for _, name in ipairs(order) do
  local row = "| " .. name .. " |"
  for _, c in ipairs(clis) do row = row .. " " .. (results[name][c.name] or "") .. " |" end
  print(row)
end
if results["cross-host"] then for k, v in pairs(results["cross-host"]) do print("| cross-host | " .. k .. ": " .. v .. " |") end end
