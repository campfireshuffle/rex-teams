-- The postman delivers queued messages, one postman per Rex host.
--
--   rex do <skill>/scripts/postman.lua --args '{}'
--
-- mail.lua queues each message as /tmp/rex-teams/outbox/<id>.json and starts
-- the postman if it isn't running, in a detached block labelled
-- "rex-teams postman" in a session labelled "rex-teams". Nobody needs to
-- start it by hand. It tells Rex its command with OSC 7577, so a trust rule
-- can start it again after Rex restarts.
--
-- Loaded with dofile, this file returns its functions instead of running:
-- step, the delivery policy, and ensure, which mail.lua calls.
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")
local lib = dofile(dir .. "lib.lua")
local mail = dofile(dir .. "mail.lua")
local M = {}
M.script = dir .. "postman.lua"

M.poll = 2 -- seconds between checks of the outbox and of receivers Rex can't reach

-- The last tick of a recurring alarm due at NOW, 0 before the first. Tick
-- k falls at start + k*every. os.time() is whole seconds, so a tick may be
-- up to 1s late, never early.
function M.last_tick(msg, now)
  local k = math.max(0, math.floor((now - msg.start) / msg.every))
  if msg.start + (k + 1) * msg.every <= now then k = k + 1 end
  if k > 0 and msg.start + k * msg.every > now then k = k - 1 end
  return k
end

-- Notices, and messages you sent yourself, never cause notices.
local function notice(msg, text)
  local self = msg.to.host == nil and msg.to.block == msg.from.block
  if not (msg.notice or self) then return text end
end

local function give_up(msg, why, text)
  msg.dead = why
  text = notice(msg, text)
  return text and { kind = "notice", text = text } or { kind = "save" }
end

-- A paste or Enter that failed, or may not have finished, is never tried
-- again: its sender hears once, with ERR. A recurring alarm drops this tick
-- and waits for its next.
local function lost(msg, err)
  local text = notice(msg, "Message " .. msg.d.tag .. " to " .. msg.to.name .. " may not have arrived: " .. err
    .. ". It isn't sent again.")
  if msg.every then msg.d = nil end
  return { kind = "drop", text = text, err = err, at = msg.due }
end

-- The delivery policy. STEP looks at one message and whether its receiver
-- is there, updates the message's delivery state, and says what to do:
--   wait   nothing until AT
--   check  call again with what pane.exists says: {} when it's there,
--          { gone = true }, or { error = why } when Rex can't reach it
--   hold   Rex can't reach the receiver (WHY); check again at AT
--   attach copy the files into the receiver's inbox, then step again
--   put    paste TEXT and press Enter, set d.sent or d.error, then step again
--   done   delivered: remove the message
--   drop   the paste failed: tell the sender TEXT, if set, and remove the
--          message, or keep a recurring alarm until AT
--   save   keep the message with its new state, until AT
--   notice tell the sender TEXT, then keep the message
-- NOW is os.time(). CHECK is nil until step asks for it.
--
-- A recurring alarm sends its last due tick, however late; ticks that pile
-- up collapse into the latest one, and the schedule never drifts.
function M.step(msg, check, now)
  if msg.dead then return { kind = "wait" } end
  if msg.every and not (msg.d and msg.d.pasted_at) then
    local k = M.last_tick(msg, now)
    if k > (msg.k or 0) then
      msg.k = k
      msg.d = msg.d or {}
      msg.d.tag = msg.id .. "." .. k
    end
    msg.due = msg.start + ((msg.k or 0) + 1) * msg.every
    if not msg.d then return { kind = "wait", at = msg.due } end
  elseif not msg.d then
    local due = msg.at or msg.posted
    if now < due then return { kind = "wait", at = due } end
    msg.d = { tag = msg.id, note = msg.late and msg.late >= 1
      and (" [late by " .. msg.late .. "s, Rex restarted]") or nil }
  end
  local d = msg.d

  if d.pasted_at then
    if d.sent then
      if not msg.every then return { kind = "done" } end
      msg.d = nil
      return { kind = "save", at = msg.due }
    end
    return lost(msg, d.error or "the postman stopped between its paste and its Enter")
  end

  if not check then return { kind = "check" } end
  if check.gone then
    return give_up(msg, "gone", "Message " .. msg.id .. " to " .. msg.to.name
      .. " can't be delivered: that pane is gone. It's kept in " .. mail.file(msg.id) .. ".")
  end
  if d.attach_error then
    return give_up(msg, "files", "Message " .. msg.id .. " to " .. msg.to.name .. " wasn't sent: " .. d.attach_error
      .. ". It's kept in " .. mail.file(msg.id) .. ".")
  end
  if check.error then
    d.why = "Rex can't reach it (" .. check.error .. ")"
    return { kind = "hold", why = d.why, at = now + M.poll }
  end
  if msg.files and #msg.files > 0 and not d.attached then return { kind = "attach" } end
  d.why, d.pasted_at = nil, now
  return { kind = "put", text = msg.head .. " · msg " .. d.tag .. msg.tail .. msg.text .. (d.note or "") }
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
  if not (state and state.block and state.session and state.pid) then return false end
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
-- it doesn't start.
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
  -- Wait for it to claim the outbox, or say why it couldn't.
  for _ = 1, 100 do
    local s = read_state()
    if s and s.block == block then break end
    if s and s.block ~= block and M.alive(s) then return end
    local p = lib.call("block.method", { session_id = session, block_id = block, method = "process", args = {} })
    if p.last_exit then error("the postman didn't start. See why with: rex capture -b " .. block, 0) end
    rex.sleep(0.05)
  end
  local s = read_state()
  if not (s and s.block == block) then error("the postman didn't start within 5s. See why with: rex capture -b " .. block, 0) end
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
  local pane = dofile(dir .. "pane.lua")
  local me_session, me = lib.me()
  lib.attach(me_session)
  local pid = lib.call("block.method", { session_id = me_session, block_id = me, method = "process", args = {} }).foreground.pid
  local claimed = locked(function()
    local s = read_state()
    if s and s.block ~= me and M.alive(s) then return false end
    lib.mkdir(lib.path("outbox"))
    lib.write(state_file .. ".tmp", rex.json.encode({ block = me, session = me_session, pid = pid }))
    assert(os.rename(state_file .. ".tmp", state_file))
    return true
  end)
  if not claimed then
    print("postman: another postman is running")
    lib.call("block.close", { session_id = me_session, block_id = me })
    rex.stop(0)
    return
  end
  M.report()
  local started = os.time()
  print("postman: delivering " .. mail.dir())

  -- Messages by id, as last read or written, and when each is next due. A
  -- file that vanished was dropped by its sender.
  local msgs, wake = {}, {}
  local function forget(id) msgs[id], wake[id] = nil, nil end

  local function load()
    local seen = {}
    for _, msg in ipairs(mail.list()) do
      seen[msg.id] = true
      if not msgs[msg.id] then
        -- A one-shot already late when this postman starts was due while
        -- Rex, or this postman, was down.
        if msg.at and not msg.d and msg.at <= started - 1 then msg.late = started - msg.at end
        msgs[msg.id], wake[msg.id] = msg, 0
      end
    end
    for id in pairs(msgs) do
      if not seen[id] then forget(id) end
    end
  end

  -- Each receiver's messages, in the order they were posted.
  local function queues()
    local by = {}
    for _, msg in pairs(msgs) do
      local k = (msg.to.host or "") .. " " .. msg.to.block
      by[k] = by[k] or {}
      table.insert(by[k], msg)
    end
    for _, list in pairs(by) do table.sort(list, mail.before) end
    return by
  end

  -- Save MSG; false when the sender deleted its file, which drops it.
  local function save(msg)
    if mail.write(msg, true) then return true end
    forget(msg.id)
    return false
  end

  local function tell(msg, text)
    mail.notice(msg.from, text)
    load()
  end

  -- Do what step says, until it says to wait.
  local function serve(msg)
    local check
    while true do
      local a = M.step(msg, check, os.time())
      if a.kind == "check" then
        local ok, there = pcall(pane.exists, msg.to)
        check = not ok and { error = tostring(there) } or { gone = not there }
      elseif a.kind == "attach" then
        local ok, err = pcall(pane.attach, msg.to, msg.files, msg.id)
        if ok then msg.d.attached = true else msg.d.attach_error = tostring(err) end
        if not save(msg) then return end
        check = nil
      elseif a.kind == "put" then
        -- Saved before the paste, so a restart never pastes twice; and the
        -- sender may have deleted the file meanwhile.
        if not save(msg) then return end
        local ok, err = pcall(pane.put, msg.to, a.text)
        if ok then ok, err = pcall(pane.enter, msg.to) end
        if ok then msg.d.sent = true else msg.d.error = tostring(err) end
      elseif a.kind == "done" then
        mail.remove(msg.id)
        forget(msg.id)
        return
      elseif a.kind == "drop" then
        print("postman: " .. msg.id .. " may not have arrived: " .. a.err)
        if msg.every then save(msg) else mail.remove(msg.id) end
        if a.text then tell(msg, a.text) end
        if not msg.every then forget(msg.id) return end
        if msgs[msg.id] then wake[msg.id] = a.at end
        return
      elseif a.kind == "notice" then
        if save(msg) then tell(msg, a.text) end
        return
      else
        if a.kind ~= "wait" and not save(msg) then return end
        wake[msg.id] = a.at or math.huge
        -- A recurring alarm's next tick may be due already: it goes now.
        if a.kind ~= "save" or not a.at or a.at > os.time() then return end
        check = nil
      end
    end
  end

  local timer, said
  local function pass()
    -- Sleep until the next thing is due, and at most until the next check
    -- of the outbox.
    local next_at = os.time() + M.poll
    local ok, err = pcall(function()
      load()
      for _, list in pairs(queues()) do
        for _, msg in ipairs(list) do
          if not msg.dead and msgs[msg.id] then
            local now = os.time()
            if wake[msg.id] <= now then
              local ok2, err2 = pcall(serve, msg)
              if not ok2 then
                print("postman: " .. msg.id .. ": " .. tostring(err2))
                wake[msg.id] = now + M.poll
              end
            end
            if msgs[msg.id] then next_at = math.min(next_at, wake[msg.id]) end
            -- One that's due but can't go yet holds the rest of its
            -- receiver's queue, so they arrive in order.
            if msgs[msg.id] and msg.d then break end
          end
        end
      end
    end)
    -- A file someone broke stops every pass until it's deleted: say so once.
    if not ok and err ~= said then print("postman: " .. tostring(err)) end
    said = not ok and err or nil
    if timer then timer:cancel() end
    timer = rex.after(math.max(0, next_at - os.time()), pass)
  end

  pass()
end

if debug.getinfo(2) then return M end
M.run()
