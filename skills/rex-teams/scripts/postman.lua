-- One postman per Rex host delivers the queued messages in
-- /tmp/rex-teams/outbox/<id>.json, each of which also holds its delivery
-- state (msg.d). Every 2 s it reads the outbox and delivers what's due,
-- oldest first per receiver; deleting a file cancels it. postman.json names
-- the running postman, and OSC 7577 lets Rex start it again after a restart.
--
-- The save rule: save a message before each Rex call that acts on its
-- receiver, and write the sender's notice before removing the message or
-- marking it dead. Whatever raises leaves the file as it was on disk.
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")
local lib = dofile(dir .. "lib.lua")
local mail = dofile(dir .. "mail.lua")
local pane = dofile(dir .. "pane.lua")
local M = {}
M.script = dir .. "postman.lua"

M.poll = 2 -- seconds between passes

-- Delivery -------------------------------------------------------------

-- The last tick of a recurring alarm due at NOW, 0 before the first. Tick
-- k falls at start + k*every.
local function last_tick(msg, now)
  local k = math.max(0, math.floor((now - msg.start) / msg.every))
  -- The division can round down: 33 / 1.1 gives 29.999...
  if msg.start + (k + 1) * msg.every <= now then k = k + 1 end
  return k
end

local function next_tick(msg)
  return msg.start + ((msg.k or 0) + 1) * msg.every
end

-- Nil if MSG is due at NOW, else when it will be. A due message has msg.d,
-- with the tag its paste carries. The tick rule: a recurring alarm sends
-- its last due tick however late, ticks that pile up collapse into the
-- latest due one, and the schedule never drifts.
local function due(msg, now)
  if not msg.every then
    if msg.d then return nil end
    local at = msg.at or msg.posted
    if now < at then return at end
    msg.d = { tag = msg.id }
    if msg.late then msg.d.note = " [late by " .. msg.late .. "s, Rex restarted]" end
    return nil
  end
  -- A tick that's been pasted is finished as it is, never retagged.
  if msg.d and msg.d.pasted_at then return nil end
  local k = last_tick(msg, now)
  if k > (msg.k or 0) then
    msg.k = k
    msg.d = msg.d or {}
    msg.d.tag = msg.id .. "." .. k
  end
  if msg.d then return nil end
  return next_tick(msg)
end

-- Tell MSG's sender WHAT happened to it. The notice rule: never for a
-- message to yourself. A notice is to its sender too, so it never causes one.
local function tell(msg, what)
  if msg.to.host == nil and msg.to.block == msg.from.block then return end
  mail.notice(msg.from, "Message " .. msg.d.tag .. " to " .. msg.to.name .. " " .. what)
end

-- MSG can't go: its file is kept, marked dead, for its sender to read.
local function give_up(msg, why, what)
  tell(msg, what .. ". It's kept in " .. mail.file(msg.id) .. ".")
  msg.dead = why
  mail.write(msg, true)
end

-- MSG's paste is over, and is never tried again. ERR, if set, is why it
-- may not have arrived. A recurring alarm drops only this tick and returns
-- when its next is due.
local function finish(msg, err)
  if err then
    print("postman: " .. msg.id .. " may not have arrived: " .. err)
    tell(msg, "may not have arrived: " .. err .. ". It isn't sent again.")
  end
  if not msg.every then
    mail.remove(msg.id)
    return nil
  end
  msg.d = nil
  mail.write(msg, true)
  return next_tick(msg)
end

-- Deliver MSG as far as it can go at NOW, os.time(). Returns when to try
-- it again, or nil when it's over: delivered, given up on, or deleted by
-- its sender.
function M.deliver(msg, now)
  local wait = due(msg, now)
  if wait then return wait end
  local d = msg.d

  if d.pasted_at then return finish(msg, "the postman stopped between its paste and its Enter") end

  -- The receiver must be there. It's checked again after its files are
  -- copied, which can take a while.
  while true do
    local reached, there = pcall(pane.exists, msg.to)
    if not reached then
      -- Held, never given up on. Saved for team.lua to say why, and so a
      -- copy that's done isn't done again.
      d.why = "Rex can't reach it (" .. tostring(there) .. ")"
      mail.write(msg, true)
      return now + M.poll
    end
    if not there then
      give_up(msg, "gone", "can't be delivered: that pane is gone")
      return nil
    end
    if not msg.files or d.attached then break end
    if not mail.write(msg, true) then return nil end
    local copied, err = pcall(pane.attach, msg.to, msg.files, msg.id)
    if not copied then
      give_up(msg, "files", "wasn't sent: " .. tostring(err))
      return nil
    end
    d.attached = true
  end

  -- Saved first, so a postman that stops mid-paste never pastes it again.
  d.pasted_at = now
  if not mail.write(msg, true) then return nil end
  local text = msg.head .. " · msg " .. d.tag .. msg.tail .. msg.text .. (d.note or "")
  local ok, err = pcall(pane.put, msg.to, text)
  if ok then ok, err = pcall(pane.enter, msg.to) end
  if not ok then return finish(msg, tostring(err)) end
  return finish(msg)
end

-- Singleton ------------------------------------------------------------

local state_file = lib.path("postman.json")
local lock = lib.path("postman.lock")

local function read_state()
  local f = io.open(state_file)
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return rex.json.decode(text)
end

-- Whether STATE names a postman that is running: its block exists and its
-- foreground process is the one that claimed it.
function M.alive(state)
  if not (state and state.block and state.pid) then return false end
  local found = lib.call("target.resolve", { queries = { state.block }, kinds = { "block" } }).results[1]
  if found.status ~= "resolved" then return false end
  lib.attach(found.target.session_id)
  local p = lib.call("block.method", { session_id = found.target.session_id, block_id = state.block, method = "process", args = {} })
  return p.foreground ~= nil and p.foreground.pid == state.pid
end

-- Run F holding the lock, an atomic mkdir.
local function locked(f)
  for _ = 1, 50 do
    local r = rex.exec(lib.windows and { "cmd", "/c", "mkdir", lock } or { "mkdir", lock })
    if r and r.ok then
      local ok, err = pcall(f)
      rex.exec(lib.windows and { "cmd", "/c", "rmdir", lock } or { "rmdir", lock })
      if not ok then error(err, 0) end
      return err
    end
    rex.sleep(0.1)
  end
  error("another postman has held " .. lock .. " for 5s; if no postman is starting, remove it", 0)
end

-- The session that holds the postman's block, made if it's missing.
local function home()
  for _, s in ipairs(lib.call("session.list", {}).sessions) do
    if s.label == "rex-teams" then return s.session_id end
  end
  return lib.call("session.create", { label = "rex-teams" }).session_id
end

-- The trust rule that lets Rex start the postman again after a restart.
-- README.md quotes it.
function M.rule()
  return ('rex.set("resume.trust.rex-teams", { command = { "rex", "do", rex.match.under(%q) }, flags = { ["--args"] = { "keep", values = 1 } } })')
    :format((dir:gsub("[/\\]$", "")))
end

-- Make sure this host's postman is running, starting it if not. Raises if
-- it doesn't start. A postman claims postman.json only once it has
-- reported itself to Rex, so a live claim means a postman runs: this one,
-- or another that won the claim.
function M.ensure()
  if M.alive(read_state()) then return end
  local session = home()
  lib.attach(session)
  local block = lib.call("session.new_block", {
    session_id = session,
    label = "rex-teams postman",
    flavor = "com.superlogical.terminal.shell",
    -- A postman that stops leaves its block, and its error, in place.
    options = { command = { "rex", "do", M.script, "--args", "{}" }, exit = { on_completion = false } },
  }).block_id
  local hint = " See why with: rex capture -s " .. session .. " -b " .. block
  for _ = 1, 100 do
    if M.alive(read_state()) then return end
    -- A postman that lost the claim closes its own block, so this call can
    -- fail; the next check then finds the winner.
    local asked, p = pcall(lib.call, "block.method", { session_id = session, block_id = block, method = "process", args = {} })
    if asked and p.last_exit then error("the postman didn't start." .. hint, 0) end
    rex.sleep(0.05)
  end
  error("the postman didn't start within 5s." .. hint, 0)
end

-- OSC 7577 -------------------------------------------------------------

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

-- Tell Rex how to start the postman again (OSC 7577). The owner is this
-- `rex do`, the shell's parent. The token stays in the shell's environment,
-- never on a command line. Rex doesn't resume programs on Windows.
function M.report()
  if lib.windows then return end
  if not os.getenv("OSC7577_TOKEN") then error("postman failed: OSC7577_TOKEN isn't set, so Rex can't resume the postman", 0) end
  local argv = {}
  for i, word in ipairs({ "rex", "do", M.script, "--args", "{}" }) do argv[i] = b64(word) end
  local r = assert(rex.exec({ "sh", "-c", 'body="pid=$PPID:time=$1:$2"; printf "%s:mac=" "$body"; '
    .. 'printf "%s:%s" "$body" "$OSC7577_TOKEN" | sha256sum | cut -c1-64', "sh", tostring(os.time()), "argv=" .. table.concat(argv, ",") }))
  local body = r.ok and r.stdout:match("^(pid=%d+:.*:mac=%x+)%s*$")
  if not (body and #body:match("mac=(%x+)$") == 64) then
    error("postman failed: the OSC 7577 report failed: " .. tostring(r.stderr ~= "" and r.stderr or r.stdout), 0)
  end
  io.stdout:write("\27]7577;", body, "\27\\")
  io.stdout:flush()
end

-- The worker ---------------------------------------------------------------

function M.run()
  local me_session, me = lib.me()
  lib.attach(me_session)
  local pid = lib.call("block.method", { session_id = me_session, block_id = me, method = "process", args = {} }).foreground.pid
  -- Also makes the root folder, which holds the lock.
  lib.mkdir(lib.path("outbox"))
  local claimed = locked(function()
    local s = read_state()
    if s and s.block ~= me and M.alive(s) then return false end
    M.report()
    lib.write(state_file .. ".tmp", rex.json.encode({ block = me, pid = pid }))
    assert(os.rename(state_file .. ".tmp", state_file))
    return true
  end)
  if not claimed then
    print("postman: another postman is running")
    lib.call("block.close", { session_id = me_session, block_id = me })
    rex.stop(0)
    return
  end
  local started = os.time()
  print("postman: delivering " .. mail.dir())

  local said -- the error the last pass stopped on
  local function pass()
    -- The next pass comes when something is due, and at most M.poll from now.
    local next_at = os.time() + M.poll
    local ok, err = pcall(function()
      local queues = {}
      for _, msg in ipairs(mail.list()) do
        local key = (msg.to.host or "") .. " " .. msg.to.block
        queues[key] = queues[key] or {}
        table.insert(queues[key], msg)
      end
      for _, queue in pairs(queues) do
        for _, msg in ipairs(queue) do
          if not msg.dead then
            -- A one-shot already due when this postman started was due
            -- while Rex, or the postman, was down.
            if msg.at and not msg.d and msg.at <= started - 1 then msg.late = started - msg.at end
            local delivered, at = pcall(M.deliver, msg, os.time())
            if not delivered then
              -- Its file is as it was, so the next pass tries it again,
              -- before the rest of its queue.
              print("postman: " .. msg.id .. ": " .. tostring(at))
              break
            end
            if at then next_at = math.min(next_at, at) end
            -- A message that's due and isn't over holds the rest of its
            -- receiver's queue, so they arrive in order.
            if at and msg.d then break end
          end
        end
      end
    end)
    -- A file someone broke stops every pass until it's deleted: say so once.
    if ok then
      said = nil
    elseif err ~= said then
      print("postman: " .. tostring(err))
      said = err
    end
    rex.after(math.max(0, next_at - os.time()), pass)
  end

  pass()
end

if debug.getinfo(2) then return M end
M.run()
