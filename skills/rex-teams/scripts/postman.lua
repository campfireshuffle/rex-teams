-- The postman delivers queued messages, one postman per Rex host. mail.lua
-- queues each message as /tmp/rex-teams/outbox/<id>.json, which also holds
-- its delivery state, and starts the postman if it isn't running, in a block
-- labelled "rex-teams postman". /tmp/rex-teams/postman.json names the one
-- that runs. Each pass reads the outbox again, so deleting a file cancels
-- its message. It tells Rex its command with OSC 7577, so a trust rule can
-- start it again after Rex restarts.
--
-- The save rule: a message is saved before each Rex call that acts on its
-- receiver, and its sender's notice is written before it's removed or
-- marked dead. Whatever raises leaves the file as it was, for the next pass.
--
-- Loaded with dofile, this file returns deliver, ensure and rule instead.
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")
local lib = dofile(dir .. "lib.lua")
local mail = dofile(dir .. "mail.lua")
local pane = dofile(dir .. "pane.lua")
local M = {}
M.script = dir .. "postman.lua"

M.poll = 2 -- seconds between checks of the outbox and of receivers Rex can't reach

-- The last tick of a recurring alarm due at NOW, 0 before the first. Tick
-- k falls at start + k*every. os.time() is whole seconds, so a tick may be
-- up to 1s late, never early.
local function last_tick(msg, now)
  local k = math.max(0, math.floor((now - msg.start) / msg.every))
  if msg.start + (k + 1) * msg.every <= now then k = k + 1 end
  if k > 0 and msg.start + k * msg.every > now then k = k - 1 end
  return k
end

-- Tell MSG's sender WHAT happened to it. Notices, and messages you sent
-- yourself, never cause notices; a notice's receiver has no name.
local function tell(msg, what)
  if msg.notice then return end
  if msg.to.host == nil and msg.to.block == msg.from.block then return end
  mail.notice(msg.from, "Message " .. msg.d.tag .. " to " .. msg.to.name .. " " .. what)
end

-- MSG can't go: its file is kept, marked dead, for its sender to read.
local function give_up(msg, why, what)
  tell(msg, what .. ". It's kept in " .. mail.file(msg.id) .. ".")
  msg.dead = why
  mail.write(msg, true)
end

-- MSG's paste is over and is never tried again. ERR, if set, is why it may
-- not have arrived. A recurring alarm drops only this tick: it keeps its
-- file and returns when its next tick is due.
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
  return msg.due
end

-- Deliver MSG as far as it can go at NOW, os.time(). Returns when to try it
-- again, or nil when nothing is left to do: it was delivered, given up on,
-- or deleted by its sender. MSG.d, its delivery state, is set once it's due.
function M.deliver(msg, now)
  -- Due. A recurring alarm sends its last due tick, however late; ticks
  -- that pile up collapse into the latest one, and the schedule never
  -- drifts.
  if msg.every and not (msg.d and msg.d.pasted_at) then
    local k = last_tick(msg, now)
    if k > (msg.k or 0) then
      msg.k = k
      msg.d = msg.d or {}
      msg.d.tag = msg.id .. "." .. k
    end
    msg.due = msg.start + ((msg.k or 0) + 1) * msg.every
    if not msg.d then return msg.due end
  elseif not msg.d then
    local due = msg.at or msg.posted
    if now < due then return due end
    msg.d = { tag = msg.id }
    if msg.late then msg.d.note = " [late by " .. msg.late .. "s, Rex restarted]" end
  end
  local d = msg.d

  -- A paste found on disk was cut short: the postman stopped before it
  -- could finish.
  if d.pasted_at then return finish(msg, "the postman stopped between its paste and its Enter") end

  -- The receiver must be there. It's checked again after copying files,
  -- which can take a while.
  repeat
    local ok, there = pcall(pane.exists, msg.to)
    if not ok then
      -- Held, never given up on. Saved, so later passes keep the rest of
      -- its receiver's queue behind it, and team.lua can say why.
      d.why = "Rex can't reach it (" .. tostring(there) .. ")"
      return now + M.poll
    end
    if not there then
      give_up(msg, "gone", "can't be delivered: that pane is gone")
      return nil
    end
    local copy = msg.files and not d.attached
    if copy then
      if not mail.write(msg, true) then return nil end
      local copied, err = pcall(pane.attach, msg.to, msg.files, msg.id)
      if not copied then
        give_up(msg, "files", "wasn't sent: " .. tostring(err))
        return nil
      end
      d.attached = true
    end
  until not copy

  -- Saved before the paste, so a restart never pastes it twice.
  d.why = nil
  d.pasted_at = now
  if not mail.write(msg, true) then return nil end
  local text = msg.head .. " · msg " .. d.tag .. msg.tail .. msg.text .. (d.note or "")
  local ok, err = pcall(pane.put, msg.to, text)
  if ok then ok, err = pcall(pane.enter, msg.to) end
  if ok then return finish(msg) end
  return finish(msg, tostring(err))
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

  -- When to try each message next, by id; one not here is due now.
  local wake, said = {}, nil
  local function pass()
    -- Sleep until the next thing is due, and at most until the next check
    -- of the outbox.
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
            local now = os.time()
            if (wake[msg.id] or 0) <= now then
              -- A one-shot already due when this postman started was due
              -- while Rex, or the postman, was down.
              if msg.at and not msg.d and msg.at <= started - 1 then msg.late = started - msg.at end
              local done, at = pcall(M.deliver, msg, now)
              if not done then
                -- Its file is as it was, so the next pass tries it again,
                -- before the rest of its queue.
                print("postman: " .. msg.id .. ": " .. tostring(at))
                break
              end
              wake[msg.id] = at
            end
            if wake[msg.id] then next_at = math.min(next_at, wake[msg.id]) end
            -- A message that has begun and isn't over holds the rest of its
            -- receiver's queue, so they arrive in order.
            if wake[msg.id] and msg.d then break end
          end
        end
      end
    end)
    -- A file someone broke stops every pass until it's deleted: say so once.
    if not ok and err ~= said then print("postman: " .. tostring(err)) end
    said = not ok and err or nil
    rex.after(math.max(0, next_at - os.time()), pass)
  end

  pass()
end

if debug.getinfo(2) then return M end
M.run()
