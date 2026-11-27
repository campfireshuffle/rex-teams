-- One postman per Rex host delivers the queued messages in
-- /tmp/rex-teams/outbox/<id>.json, each of which also holds its delivery
-- state (msg.d). Every 2 s it reads the outbox and delivers what's due,
-- oldest first per receiver; deleting a file cancels it. The oldest live
-- block labelled "rex-teams postman" is the postman, and OSC 7577 lets Rex
-- start it again after a restart.
--
-- The save rule: save a message before its paste, and write the sender's
-- notice before removing the message. Whatever raises
-- leaves the file as it was on disk.
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

-- Whether MSG is due at NOW. A due message has msg.d, with the tag its
-- paste carries. The tick rule: a recurring alarm sends its last due tick
-- however late, ticks that pile up collapse into the latest due one, and
-- the schedule never drifts.
local function due(msg, now)
  if not msg.every then
    if now < (msg.at or msg.posted) then return false end
    msg.d = msg.d or { tag = msg.id }
    return true
  end
  -- A tick that's been pasted is finished as it is, never retagged.
  if msg.d and msg.d.pasted_at then return true end
  local k = last_tick(msg, now)
  if k > (msg.k or 0) then
    msg.k = k
    msg.d = msg.d or {}
    msg.d.tag = msg.id .. "." .. k
  end
  return msg.d ~= nil
end

-- Tell MSG's sender WHAT happened to it. The notice rule: never for a
-- message to yourself. A notice is to its sender too, so it never causes one.
local function tell(msg, what)
  if msg.to.host == nil and msg.to.block == msg.from.block then return end
  mail.notice(msg.from, "Message " .. msg.d.tag .. " to " .. msg.to.name .. " " .. what)
end

-- MSG can't go: its sender hears WHAT, with its text, and it's deleted.
local function give_up(msg, what)
  tell(msg, what .. ". It said: " .. msg.text)
  mail.remove(msg.id)
end

-- MSG's paste is over, and is never tried again. ERR, if set, is why it
-- may not have arrived. A recurring alarm drops only this tick.
local function finish(msg, err)
  if err then
    print("postman: " .. msg.id .. " may not have arrived: " .. err)
    tell(msg, "may not have arrived: " .. err .. ". It isn't sent again.")
  end
  if not msg.every then return mail.remove(msg.id) end
  msg.d = nil
  mail.write(msg, true)
end

-- Deliver MSG as far as it can go at NOW, os.time(). Returns true if MSG
-- is due and held, so the rest of its receiver's queue waits.
function M.deliver(msg, now)
  if not due(msg, now) then return end
  local d = msg.d

  if d.pasted_at then return finish(msg, "the postman stopped between its paste and its Enter") end

  local reached, there = pcall(pane.exists, msg.to)
  if not reached then return true end -- held, never given up on
  if not there then return give_up(msg, "can't be delivered: that pane is gone") end
  if msg.files then
    local copied, err = pcall(pane.attach, msg.to, msg.files, msg.id)
    if not copied then return give_up(msg, "wasn't sent: " .. tostring(err)) end
  end

  -- Saved first, so a postman that stops mid-paste never pastes it again,
  -- and a message its sender deleted isn't pasted.
  d.pasted_at = now
  if not mail.write(msg, true) then return end
  local text = msg.head .. " · msg " .. d.tag .. msg.tail .. msg.text
  local ok, err = pcall(pane.type, msg.to, text)
  if ok then return finish(msg) end
  finish(msg, tostring(err))
end

-- Singleton ------------------------------------------------------------

-- The live postmen's block IDs, oldest first. Rex is the record: a postman
-- is a block labelled "rex-teams postman" in a session labelled
-- "rex-teams", and it's live while it runs `rex`. After a Rex restart, a
-- postman that had stopped comes back as a live shell. Labels can repeat,
-- so every rex-teams session counts.
function M.live()
  local out = {}
  for _, s in ipairs(lib.call("session.list", {}).sessions) do
    if s.label == "rex-teams" then
      lib.attach(s.session_id)
      for _, b in ipairs(lib.call("session.list_blocks", { session_id = s.session_id }).blocks) do
        if b.label == "rex-teams postman" then
          -- A block can close while it's listed.
          local ok, p = pcall(lib.call, "block.method", { session_id = s.session_id, block_id = b.block_id, method = "process", args = {} })
          if ok and not p.last_exit and p.foreground and p.foreground.name == "rex" then out[#out + 1] = b.block_id end
        end
      end
    end
  end
  -- Block IDs are time-ordered.
  table.sort(out)
  return out
end

-- The session that holds the postman's block, made if it's missing.
local function home()
  for _, s in ipairs(lib.call("session.list", {}).sessions) do
    if s.label == "rex-teams" then return s.session_id end
  end
  return lib.call("session.create", { label = "rex-teams" }).session_id
end

-- Make sure this host's postman is running, starting it if not. Raises if
-- it doesn't start.
function M.ensure()
  if M.live()[1] then return end
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
    if M.live()[1] then return end
    -- A postman that finds an older one closes its own block, so this call
    -- can fail; the next check then finds the older one.
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
  if not body then
    error("postman failed: the OSC 7577 report failed: " .. tostring(r.stderr ~= "" and r.stderr or r.stdout), 0)
  end
  io.stdout:write("\27]7577;", body, "\27\\")
  io.stdout:flush()
end

-- The worker ---------------------------------------------------------------

function M.run()
  local me_session, me = lib.me()
  lib.attach(me_session)
  local function quit(why)
    print("postman: " .. why)
    lib.call("block.close", { session_id = me_session, block_id = me })
    rex.stop(0)
  end
  -- The oldest live postman delivers; a newer one quits before it reports.
  -- A lookup that raises doesn't stop this one, which may be the only one.
  local looked, live = pcall(M.live)
  if looked and live[1] and live[1] < me then return quit("an older postman is running") end
  M.report()
  lib.mkdir(lib.path("outbox"))
  print("postman: delivering " .. mail.dir())

  local said -- the error the last pass stopped on
  local function pass()
    local ok, err = pcall(function()
      -- A receiver is held once a message to it is due and isn't over, so
      -- its messages arrive in order.
      local held = {}
      for _, msg in ipairs(mail.list()) do
        local key = (msg.to.host or "") .. " " .. msg.to.block
        if not held[key] then
          local done, holds = pcall(M.deliver, msg, os.time())
          -- Its file is as it was, so the next pass tries it again, before
          -- the rest of its queue.
          if not done then print("postman: " .. msg.id .. ": " .. tostring(holds)) end
          held[key] = not done or holds
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
    rex.after(M.poll, pass)
  end

  pass()
end

if debug.getinfo(2) then return M end
M.run()
