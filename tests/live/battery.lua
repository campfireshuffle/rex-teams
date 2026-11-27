-- The live battery: real Rex, real agent CLIs. Not run by CI.
--
--   rex do tests/live/battery.lua [only=codex,pi] [host=LABEL]
--
-- It opens a scratch session, rex-teams-battery, with a stand-in sender (a
-- plain shell) and one pane per CLI, and checks each scenario the postman
-- handles. Receivers are told not to reply or run anything, and every
-- message names a sender that isn't an agent. With host=, it also sends a
-- message, and one with a file, to a Pi in a scratch session on that host.
-- It closes everything it opened, including any postman it started, and
-- prints a table. It exits non-zero if any scenario FAILs, it stops early,
-- or it can't close the postman it started.
--
-- It uses the postman in this checkout, so stop any other postman first
-- (a live block labelled "rex-teams postman" in the rex-teams session).
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
  { name = "shell" }, -- this host's shell
}
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

-- Scenarios ----------------------------------------------------------------------

local results, order = {}, {}
local function record(cli, scenario, ok, note)
  if not results[scenario] then
    results[scenario] = {}
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
-- Whether message ID shows on the screen within a few seconds: a CLI can
-- take a moment to draw what was pasted.
local function seen(block, id)
  return wait_for(function() return screen(block):find("msg " .. id, 1, true) ~= nil end, 5)
end
-- Whether TEXT shows on the screen, however it wraps. OpenCode draws a ┃
-- gutter on each wrapped line.
local function shows(block, text, host, s)
  return (screen(block, host, s):gsub("%s", ""):gsub("┃", "")):find((text:gsub("%s", "")), 1, true) ~= nil
end

local scenarios = {}
function scenarios.idle(c)
  local id = send(c.block, "Idle delivery.")
  local ok, took = delivered(c.block, id)
  return ok and seen(c.block, id), ("%.1fs"):format(took)
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
  return ok and working and shown, ("delivered %.1fs into the turn%s%s"):format(took, working and "" or ", turn over by then", shown and "" or ", id never shown")
end
function scenarios.file(c)
  local path = work .. "/note-" .. c.name .. ".md"
  local f = assert(io.open(path, "w"))
  f:write("a note\n")
  f:close()
  local id = run("send.lua", { block = c.block, message = "File attached." .. quiet, file = path })
  local ok, took = delivered(c.block, id)
  return ok and seen(c.block, id) and shows(c.block, path), ("%.1fs"):format(took)
end
function scenarios.shell(c)
  local id = send(c.block, "Shell paste.")
  local ok, took = delivered(c.block, id, 10)
  return ok and seen(c.block, id), ("%.1fs"):format(took)
end
function scenarios.alarm(c)
  local id = run("alarm.lua", { ["in"] = 5, message = "Alarm on time." .. quiet, block = c.block })
  local f = assert(io.open(outbox(id)))
  local at = rex.json.decode(f:read("*a")).at
  f:close()
  -- Timed to the paste: when the id shows on the receiver's screen.
  local ok = wait_for(function() return seen(c.block, id) end, 20)
  local late = now() - at
  return ok and late >= 0 and late < 3, ("pasted +%.1fs after its time"):format(late)
end

-- Run ---------------------------------------------------------------------------------

local live = dofile(scripts .. "postman.lua").live
local before = {}
for _, id in ipairs(live()) do before[id] = true end
local cleanup = {}
local ok, err = pcall(function()
  math.randomseed(os.time())
  for _, c in ipairs(clis) do
    c.block = pane(c.name, c.cmd)
  end
  for _, c in ipairs(clis) do
    if c.cmd and not wait_for(function() return idle(c.block) end, 40) then c.down = "never idle: " .. tostring(status(c.block)) end
  end
  for _, name in ipairs({ "idle", "busy", "alarm", "file", "shell" }) do
    for _, c in ipairs(clis) do
      if c.down then record(c.name, name, false, c.down) else
        if c.cmd then wait_for(function() return idle(c.block) end, 60) end
        local ok2, pass, note = true, nil, "not for this pane"
        if name == "file" or (c.name == "shell") == (name == "shell") then ok2, pass, note = pcall(scenarios[name], c) end
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
    local ok2, took = delivered(b, id, 60)
    record("pi@" .. a.host, "cross-host", ok2 and screen(b, a.host, far):find("msg " .. id, 1, true) ~= nil, ("%.1fs"):format(took))
    local path = work .. "/far-note.md"
    local f = assert(io.open(path, "w"))
    f:write("a note for another host\n")
    f:close()
    id = run("send.lua", { block = b, host = a.host, message = "Cross-host file." .. quiet, file = path })
    ok2, took = delivered(b, id, 90)
    local landed = "/tmp/rex-teams/inbox/" .. b:gsub("^block:", "") .. "/" .. id
    local there = method(b, "list_dir", { path = landed .. "/far-note.md", limit = 1 }, a.host, far).status
    record("pi@" .. a.host, "cross-host file=", ok2 and there == "not_dir" and shows(b, landed .. "/far-note.md", a.host, far),
      ("%.1fs, file %s"):format(took, there))

  end
end)
if not ok then print("battery stopped: " .. tostring(err)) end

-- Clean up: the scratch sessions, and the postman if this run started it.
call("session.destroy", { session_id = session })
local unclosed
for _, started in ipairs(live()) do if not before[started] then
  local closed, why = pcall(function()
    local found = call("target.resolve", { queries = { started }, kinds = { "block" } }).results[1]
    if found.status ~= "resolved" then error("Rex can't find it (" .. found.status .. ")", 0) end
    call("session.attach", { session_id = found.target.session_id })
    call("block.close", { session_id = found.target.session_id, block_id = found.target.block_id })
  end)
  if closed then print("closed the postman this run started: " .. started)
  else
    unclosed = "couldn't close the postman this run started, " .. started .. ": " .. tostring(why)
    print(unclosed)
  end
end end
if cleanup.far then pcall(call, "session.destroy", { session_id = cleanup.far }, a.host) end
print("")
local header = "| scenario |"
for _, c in ipairs(clis) do header = header .. " " .. c.name .. " |" end
print(header)
for _, name in ipairs(order) do
  if name:find("^cross%-host") then break end
  local row = "| " .. name .. " |"
  for _, c in ipairs(clis) do row = row .. " " .. (results[name][c.name] or "") .. " |" end
  print(row)
end
for _, name in ipairs({ "cross-host", "cross-host file=" }) do
  for k, v in pairs(results[name] or {}) do print("| " .. name .. " | " .. k .. ": " .. v .. " |") end
end

local failed = 0
for _, row in pairs(results) do
  for _, v in pairs(row) do if v:find("^FAIL") then failed = failed + 1 end end
end
if not ok or failed > 0 or unclosed then
  error(("battery failed: %d FAIL%s%s"):format(failed, ok and "" or ", stopped early", unclosed and ", postman left open" or ""), 0)
end
