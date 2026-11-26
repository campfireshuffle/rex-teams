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

-- How long a message waits after a paste before it's pasted again, when
-- there's evidence the paste was lost.
M.resend = { 10, 30, 60 }
M.enters = 3 -- Enters pressed again while our text sits in the composer
M.enter_gap = 2 -- seconds between those Enters
M.held_notice = 600 -- a held message tells its sender once, after this long
M.poll = 2 -- seconds between checks of the outbox and of held receivers

-- The tick of a recurring alarm due next, after tick K, at or after NOW.
-- Tick k falls at start + k*every. os.time() is whole seconds, so a tick
-- may be up to 1s late, never early. Ticks missed while Rex was down or the
-- machine slept are skipped.
function M.next_tick(msg, k, now)
  k = math.max(k + 1, math.floor((now - 1 - msg.start) / msg.every) + 1)
  return k, msg.start + k * msg.every
end

local function self_addressed(msg)
  return msg.to.host == nil and msg.to.block == msg.from.block
end

-- Why a receiver can't take a message now, or nil when it can: it isn't
-- blocked or working, its composer is showing, and holds nothing.
function M.why(look)
  if look.error then return "rex-teams can't reach it (" .. look.error .. ")" end
  if look.status == "blocked" then
    return look.kind == "permission" and "it's asking for permission"
      or look.kind == "question" and "it's asking a question"
      or look.kind == "auth" and "it's asking to sign in"
      or "it's waiting on a prompt"
  end
  if look.status == "working" then return "it's busy" end
  if not look.known then
    return "rex-teams can't read the prompt box of " .. (look.app and ("'" .. look.app .. "'") or "that program")
  end
  if not look.composer then return "its prompt box isn't showing" end
  if look.composer.text ~= "" then return "someone is typing there" end
end

local function notice(msg, why, text)
  if msg.notice or self_addressed(msg) then return { kind = "save" } end
  return { kind = "notice", why = why, text = text }
end

local function give_up(msg, why, text)
  msg.dead = why
  local a = notice(msg, why, text)
  return a
end

-- Hold message MSG, in delivery state D, because of WHY, and tell its
-- sender once if it's held for long.
local function hold(msg, d, look, why, now)
  d.held_since, d.why = d.held_since or now, why
  if not d.noticed and now - d.held_since >= M.held_notice then
    d.noticed = true
    return notice(msg, "held", "Message " .. msg.id .. " to " .. msg.to.name .. " has waited "
      .. math.floor((now - d.held_since) / 60) .. " minutes: " .. why .. ". It goes out once that clears. To drop it, delete "
      .. mail.file(msg.id) .. ".")
  end
  -- A busy or blocked receiver reports when it's done; the rest are
  -- checked again shortly.
  local event = look.status == "working" or look.status == "blocked"
  return { kind = "hold", why = why, at = not event and now + M.poll or nil,
    until_notice = not d.noticed and d.held_since + M.held_notice or nil }
end

-- A composer's text without its blanks, which wrapping adds.
local function squash(text) return (text:gsub("%s", "")) end

-- The delivery policy. STEP looks at one message and what its receiver's
-- pane shows, updates the message's delivery state, and says what to do:
--   wait   nothing until AT (or a status change, if AT is nil)
--   look   call again with the receiver's pane.look
--   hold   the receiver can't take it (WHY); look again at AT or on a status change
--   attach copy the files into the receiver's inbox, then step again
--   put    paste TEXT, then press Enter
--   enter  press Enter again
--   done   delivered: remove the message
--   save   keep the message with its new state
--   notice tell the sender TEXT, then keep the message
-- NOW is os.time(). LOOK is nil until step asks for it.
function M.step(msg, look, now)
  if msg.dead then return { kind = "wait" } end
  local d = msg.d
  if not d then
    if msg.every then
      if not msg.k then msg.k, msg.due = M.next_tick(msg, 0, now) end
      if now < msg.due then return { kind = "wait", at = msg.due } end
      local k = msg.k
      local late = now - msg.due >= 1
      msg.k, msg.due = M.next_tick(msg, k, now)
      -- A tick that comes 1s or more late was missed; skip it.
      if late then return { kind = "save", at = msg.due } end
      msg.d = { tag = msg.id .. "." .. k, started = now }
    else
      local due = msg.at or msg.posted
      if now < due then return { kind = "wait", at = due } end
      msg.d = { tag = msg.id, started = now, note = msg.late and msg.late >= 1
        and (" [late by " .. msg.late .. "s, Rex restarted]") or nil }
    end
    d = msg.d
  elseif msg.every and now >= msg.due then
    -- The next tick came while this one was still on its way: skip it.
    msg.k, msg.due = M.next_tick(msg, msg.k, now)
  end
  if not look then return { kind = "look" } end
  if look.gone then
    return give_up(msg, "gone", "Message " .. msg.id .. " to " .. msg.to.name
      .. " can't be delivered: that pane is gone. It's kept in " .. mail.file(msg.id) .. ".")
  end
  if d.attach_error then
    return give_up(msg, "files", "Message " .. msg.id .. " to " .. msg.to.name .. " wasn't sent: " .. d.attach_error
      .. ". It's kept in " .. mail.file(msg.id) .. ".")
  end
  -- Our paste is in the composer when it shows exactly our text, or just
  -- the one stand-in a long paste becomes. Anything a person typed around
  -- it makes it theirs.
  local c = look.composer
  local ours = c ~= nil and d.pasted_at ~= nil
    and (c.ours == "token" or (c.ours == "id" and squash(c.text) == squash(d.text)))

  if d.pasted_at then
    -- Delivered when the receiver starts working, or when our text has
    -- left its composer and its id is on the screen above it.
    if d.worked or look.status == "working" or (c and not ours and look.seen) then
      if not msg.every then return { kind = "done" } end
      msg.d = nil
      return { kind = "save", at = msg.due }
    end
    -- Nothing goes to a blocked receiver, not even an Enter.
    if look.status == "blocked" then return hold(msg, d, look, M.why(look), now) end
    if ours then
      if now - d.last < M.enter_gap then return { kind = "wait", at = d.last + M.enter_gap } end
      if (d.enters or 0) < M.enters then
        d.enters, d.last, d.held_since, d.why = (d.enters or 0) + 1, now, nil, nil
        return { kind = "enter" }
      end
      return give_up(msg, "unconfirmed", "Couldn't confirm message " .. msg.id .. " reached " .. msg.to.name
        .. ": it's still in their prompt box after " .. M.enters .. " more Enters. It's kept in " .. mail.file(msg.id) .. ".")
    end
    local wait = M.resend[d.pastes] or M.resend[#M.resend]
    if now - d.pasted_at < wait then return { kind = "wait", at = d.pasted_at + wait } end
    if d.pastes > #M.resend then
      return give_up(msg, "unconfirmed", "Couldn't confirm message " .. msg.id .. " reached " .. msg.to.name
        .. " after " .. #M.resend .. " resends. It's kept in " .. mail.file(msg.id) .. ".")
    end
  end

  -- Paste only when the receiver is ready. Otherwise hold, and tell the
  -- sender once if it's held for long.
  local why = M.why(look)
  if why then return hold(msg, d, look, why, now) end
  if msg.files and #msg.files > 0 and not d.attached then return { kind = "attach" } end
  d.held_since, d.why = nil, nil
  local resent = d.pasted_at ~= nil
  d.pastes, d.pasted_at, d.last, d.enters, d.worked = (d.pastes or 0) + 1, now, now, 0, nil
  d.text = msg.head .. " · msg " .. d.tag .. (resent and " · resent" or "") .. msg.tail .. msg.text .. (d.note or "")
  return { kind = "put", text = d.text }
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

-- Rex says whether a rule trusts a block's resume report once it's in.
local function resume_hint(session, block)
  local function chosen(records)
    for _, r in ipairs(records or {}) do if r.chosen then return r end end
  end
  local function records()
    return lib.call("com.superlogical.terminal.program_resume_records", { session_id = session, block_id = block, args = {} }).records
  end
  local record = chosen(records())
  if not record then
    local ev = rex.wait("terminal.program_resume_changed", function(e) return e.block_id == block and chosen(e.records) end, 5)
    record = chosen(ev and ev.records) or chosen(records())
  end
  if not record then
    return "postman: Rex has no resume record for the postman after 5s. See why with: rex capture -b " .. block
  elseif not record.trusted then
    return "postman: queued messages and alarms won't survive a Rex restart"
      .. (record.untrusted_reason == "no_rule" and "" or " (" .. tostring(record.untrusted_reason) .. ")")
      .. ". To keep them, add this to Rex's init.lua and run rex config reload: " .. M.rule()
  end
end

function M.rule()
  return ('rex.set("resume.trust.rex-teams", { command = { "rex", "do", rex.match.under(%q) }, flags = { ["--args"] = { "keep", values = 1 } } })')
    :format((dir:gsub("[/\\]$", "")))
end

-- Make sure this host's postman is running, starting it if not. Returns the
-- trust-rule hint when it starts one that Rex wouldn't resume, or with HINT
-- whenever the running one isn't trusted, and nil otherwise.
function M.ensure(hint)
  local running = read_state()
  if M.alive(running) then
    if hint and not lib.windows then return resume_hint(running.session, running.block) end
    return nil
  end
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
    if s and s.block ~= block and M.alive(s) then return nil end
    local p = lib.call("block.method", { session_id = session, block_id = block, method = "process", args = {} })
    if p.last_exit then
      local screen = lib.call("block.method", { session_id = session, block_id = block, method = "format", args = { format = "text", trim = true } })
      lib.call("block.close", { session_id = session, block_id = block })
      error("the postman didn't start: " .. (screen.content:gsub("%s+$", ""):match("([^\n]*)$") or ""), 0)
    end
    rex.sleep(0.05)
  end
  local s = read_state()
  if not (s and s.block == block) then error("the postman didn't start within 5s. See why with: rex capture -b " .. block, 0) end
  if lib.windows then return nil end
  return resume_hint(session, block)
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

  -- Messages by id, as last read or written. A file that vanished was
  -- dropped by its sender.
  local msgs, wake = {}, {}
  local function key(msg) return (msg.to.host or "") .. " " .. msg.to.block end

  local function load()
    local seen = {}
    for _, msg in ipairs(mail.list()) do
      seen[msg.id] = true
      if not msgs[msg.id] then
        -- A one-shot already late when this postman starts was due while
        -- Rex, or this postman, was down.
        if msg.at and not msg.d and msg.at <= started - 1 then msg.late = started - msg.at end
        -- pane.look attaches to the receiver's session, which also brings
        -- its status events here.
        msgs[msg.id] = msg
        wake[msg.id] = 0
      end
    end
    for id in pairs(msgs) do
      if not seen[id] then msgs[id], wake[id] = nil, nil end
    end
  end

  -- Each receiver's messages, oldest first. Only the first goes at a time.
  local function queues()
    local by = {}
    for _, msg in pairs(msgs) do
      local k = key(msg)
      by[k] = by[k] or {}
      table.insert(by[k], msg)
    end
    for _, list in pairs(by) do
      table.sort(list, function(a, b) if a.posted ~= b.posted then return a.posted < b.posted end return a.id < b.id end)
    end
    return by
  end

  local function save(msg)
    if not mail.write(msg, true) then msgs[msg.id], wake[msg.id] = nil, nil end
  end

  local function serve(msg)
    local now = os.time()
    local look
    for _ = 1, 4 do
      local a = M.step(msg, look, now)
      if a.kind == "look" then
        -- A pane Rex can't reach is held like a busy one, and its sender
        -- hears about it after a while.
        local ok, l = pcall(pane.look, msg.to, msg.d.tag)
        look = ok and l or { error = tostring(l) }
      elseif a.kind == "attach" then
        local ok, err = pcall(pane.attach, msg.to, msg.files, msg.id)
        if ok then msg.d.attached = true else msg.d.attach_error = tostring(err) end
        save(msg)
      else
        if a.kind == "put" then
          save(msg) -- record the attempt before the paste, so a restart confirms rather than pastes again
          pane.put(msg.to, a.text)
          pane.enter(msg.to)
          wake[msg.id] = now + 1
        elseif a.kind == "enter" then
          save(msg)
          pane.enter(msg.to)
          wake[msg.id] = now + M.enter_gap
        elseif a.kind == "done" then
          mail.remove(msg.id)
          msgs[msg.id], wake[msg.id] = nil, nil
        elseif a.kind == "notice" then
          save(msg)
          mail.notice(msg.from, a.text)
          wake[msg.id] = msg.dead and math.huge or now + M.poll
          load()
        else
          -- Record why it's held, for team.lua, when that changes.
          if a.kind == "save" or (a.kind == "hold" and msg.d.saved_why ~= a.why) then
            if a.kind == "hold" then msg.d.saved_why = a.why end
            save(msg)
          end
          if msgs[msg.id] then
            -- Another host sends no status events here, so check it shortly.
            local at = math.min(a.at or math.huge, a.until_notice or math.huge, msg.to.host and now + M.poll or math.huge)
            if msg.every and msg.due and not msg.dead then at = math.min(at, msg.due) end
            wake[msg.id] = at
          end
        end
        return
      end
    end
  end

  local timer
  local function pass()
    -- Sleep until the next thing is due, and at most until the next check
    -- of the outbox. Messages queued behind another wait for it.
    local next_at = os.time() + M.poll
    local ok, err = pcall(function()
      load()
      local now = os.time()
      for _, list in pairs(queues()) do
        -- The first message not yet dead goes first; alarms not yet due
        -- don't hold up the messages behind them.
        for _, msg in ipairs(list) do
          if not msg.dead then
            if (wake[msg.id] or 0) <= now then
              local ok2, err2 = pcall(serve, msg)
              if not ok2 then
                print("postman: " .. msg.id .. ": " .. tostring(err2))
                wake[msg.id] = now + M.poll
              end
            end
            if msgs[msg.id] then next_at = math.min(next_at, wake[msg.id] or 0) end
            -- Removed means delivered: the next one may go at once.
            if not msgs[msg.id] then next_at = now end
            if msgs[msg.id] and msg.d then break end
          end
        end
      end
    end)
    if not ok then print("postman: " .. tostring(err)) end
    if timer then timer:cancel() end
    timer = rex.after(math.max(0, next_at - os.time()), pass)
  end

  -- A receiver's status changed: a paste that made it work is delivered,
  -- and a receiver that stopped working may take what's held for it.
  rex.on("terminal.program_status_changed", function(ctx, ev)
    local record = ev.record or {}
    if record.id then return end
    local any = false
    for id, msg in pairs(msgs) do
      if not msg.to.host and msg.to.block == ev.block_id then
        any = true
        wake[id] = 0
        if msg.d and msg.d.pasted_at and record.state == "working" then msg.d.worked = true end
      end
    end
    if any then pass() end
  end)
  rex.on("block_closed", function(ctx, ev)
    for id, msg in pairs(msgs) do
      if not msg.to.host and msg.to.block == ev.block_id then wake[id] = 0 end
    end
  end)
  pass()
end

if debug.getinfo(2) then return M end
M.run()
