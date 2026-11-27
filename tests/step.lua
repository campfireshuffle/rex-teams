-- Run from the repo root with `luajit tests/step.lua` or `lua5.1 tests/step.lua`.
-- postman.step is the delivery policy: one message, what its receiver's pane
-- shows, and the time in, one action out. No Rex calls are made.
local json = dofile("tests/lib/json.lua")
rex = { json = json, args = {} }
local real_dofile = dofile
local P = real_dofile("skills/rex-teams/scripts/postman.lua")
local step = P.step
local mailfile = real_dofile("skills/rex-teams/scripts/mail.lua").file

local function msg(o)
  local m = { id = "100-abcd", posted = 100, head = "[from Me", tail = ", who can't see this screen.] ", text = "hi",
    to = { session = "s:1", block = "b:to", name = "Reviewer" }, from = { session = "s:1", block = "b:me", name = "Me" } }
  for k, v in pairs(o or {}) do m[k] = v end
  return m
end
-- What pane.exists says about a receiver that's there.
local HERE = {}
local PASTED = "[from Me · msg 100-abcd, who can't see this screen.] hi"

local n, failed = 0, 0
local function trial(name, f)
  n = n + 1
  local ok, err = pcall(f)
  if not ok then failed = failed + 1 end
  print((ok and "ok " or "not ok ") .. n .. " - " .. name .. (ok and "" or ": " .. tostring(err)))
end
local function is(a, kind, extra)
  assert(a.kind == kind, "want " .. kind .. ", got " .. a.kind .. (a.why and " (" .. a.why .. ")" or "") .. (a.text and ": " .. a.text or ""))
  for k, v in pairs(extra or {}) do assert(a[k] == v, k .. " is " .. tostring(a[k]) .. ", want " .. tostring(v)) end
  return a
end
-- Paste M at time T on a receiver that's there.
local function put(m, t) return is(step(m, HERE, t or 100), "put") end

trial("a new message checks the receiver is there before anything else", function()
  is(step(msg(), nil, 100), "check")
end)
trial("a receiver that's there gets the header with the id, then the text, at once", function()
  is(step(msg(), HERE, 100), "put", { text = PASTED })
end)
trial("a paste and Enter that went through: done", function()
  local m = msg()
  put(m)
  m.d.sent = true
  is(step(m, nil, 100), "done")
end)
trial("a failed paste or Enter tells the sender once, with the error, and drops the message", function()
  local m = msg()
  put(m)
  m.d.error = "rex: block.event timed out"
  local a = is(step(m, nil, 101), "drop")
  assert(a.text == "Message 100-abcd to Reviewer may not have arrived: rex: block.event timed out. It isn't sent again.", a.text)
end)
trial("a paste with neither outcome, after a restart, is reported, never pasted again", function()
  local m = msg()
  put(m)
  local a = is(step(m, nil, 500), "drop")
  assert(a.text:find("may not have arrived: the postman stopped between its paste and its Enter", 1, true), a.text)
end)
trial("a failed paste to yourself, or a notice, drops it without a notice", function()
  for _, m in ipairs({ msg({ notice = true }), msg({ to = { session = "s:1", block = "b:me", name = "Me" } }) }) do
    put(m)
    m.d.error = "boom"
    local a = is(step(m, nil, 101), "drop")
    assert(a.text == nil, a.text)
  end
end)
trial("a failed tick of a recurring alarm drops that tick and waits for the next", function()
  local m = msg({ every = 60, start = 100 })
  is(step(m, HERE, 160), "put")
  m.d.error = "boom"
  local a = is(step(m, nil, 161), "drop", { at = 220 })
  assert(a.text and m.d == nil and m.k == 1)
  is(step(m, nil, 162), "wait", { at = 220 })
end)
trial("notices never cause notices", function()
  local g = msg({ notice = true })
  is(step(g, { gone = true }, 100), "save")
  assert(g.dead == "gone")
end)
trial("a receiver that's gone tells the sender once and keeps the file", function()
  local m = msg()
  local a = is(step(m, { gone = true }, 100), "notice")
  assert(a.text == "Message 100-abcd to Reviewer can't be delivered: that pane is gone. It's kept in " .. mailfile("100-abcd") .. ".", a.text)
  assert(m.dead == "gone")
  is(step(m, { gone = true }, 101), "wait")
end)
trial("files for another host are copied once, before the paste", function()
  local m = msg({ files = { "/a.md" } })
  is(step(m, HERE, 100), "attach")
  m.d.attached = true
  is(step(m, HERE, 100), "put")
end)
trial("a file copy that fails tells the sender and keeps the file", function()
  local m = msg({ files = { "/a.md" } })
  is(step(m, HERE, 100), "attach")
  m.d.attach_error = "rex cp to ws failed (exit 4, can't reach that host)"
  local a = is(step(m, HERE, 100), "notice")
  assert(a.text:find("Message 100-abcd to Reviewer wasn't sent: rex cp to ws failed (exit 4, can't reach that host). It's kept in ", 1, true), a.text)
  assert(m.dead == "files")
end)
trial("a pane Rex can't reach is held, never marked gone, and nobody is told", function()
  local m = msg()
  is(step(m, { error = "dial tcp: timeout" }, 100), "hold", { why = "Rex can't reach it (dial tcp: timeout)", at = 102 })
  assert(m.d.why == "Rex can't reach it (dial tcp: timeout)" and not m.dead)
  is(step(m, { error = "dial tcp: timeout" }, 5000), "hold")
  is(step(m, HERE, 5002), "put", { text = PASTED })
  assert(m.d.why == nil)
end)
trial("an alarm waits for its time, then goes like any message", function()
  local m = msg({ at = 160, head = "[alarm you set", tail = "] ", to = { session = "s:1", block = "b:me", name = "Me" } })
  is(step(m, nil, 100), "wait", { at = 160 })
  is(step(m, nil, 160), "check")
  is(step(m, HERE, 160), "put", { text = "[alarm you set · msg 100-abcd] hi" })
end)
trial("a one-shot found late at startup says so; one on time doesn't", function()
  local m = msg({ at = 120, late = 19 })
  local a = is(step(m, HERE, 139), "put")
  assert(a.text:find("hi %[late by 19s, Rex restarted%]$"), a.text)
  m = msg({ at = 120, late = 0 })
  a = is(step(m, HERE, 120), "put")
  assert(a.text:sub(-2) == "hi", a.text)
end)
local function sent(m, t)
  m.d.sent = true
  return step(m, nil, t)
end
trial("a recurring alarm keeps its phase, tags each tick, and stays queued", function()
  local m = msg({ every = 60, start = 100 })
  is(step(m, nil, 100), "wait", { at = 160 })
  is(step(m, HERE, 160), "put", { text = "[from Me · msg 100-abcd.1, who can't see this screen.] hi" })
  is(sent(m, 160), "save", { at = 220 })
  assert(m.d == nil and m.k == 1 and m.due == 220)
  is(step(m, nil, 219), "wait", { at = 220 })
  is(step(m, HERE, 220), "put", { text = "[from Me · msg 100-abcd.2, who can't see this screen.] hi" })
end)
trial("a recurring tick goes out however late, while no later tick is due", function()
  local m = msg({ every = 60, start = 100 })
  step(m, nil, 100)
  is(step(m, HERE, 219), "put", { text = "[from Me · msg 100-abcd.1, who can't see this screen.] hi" })
  assert(m.due == 220)
end)
trial("ticks that pile up, after a sleep or a restart, collapse into one, and the next stays on phase", function()
  local m = msg({ every = 60, start = 100 })
  step(m, nil, 100)
  is(step(m, HERE, 761), "put", { text = "[from Me · msg 100-abcd.11, who can't see this screen.] hi" })
  assert(m.k == 11 and m.due == 820)
  is(sent(m, 761), "save", { at = 820 })
  is(step(m, nil, 819), "wait", { at = 820 })
end)
trial("a held tick is overtaken by the next one due, which goes once Rex reaches the pane", function()
  local m = msg({ every = 60, start = 100 })
  step(m, nil, 100)
  is(step(m, { error = "timeout" }, 160), "hold")
  assert(m.d.tag == "100-abcd.1" and m.due == 220)
  is(step(m, { error = "timeout" }, 220), "hold")
  assert(m.d.tag == "100-abcd.2" and m.due == 280, tostring(m.due))
  is(step(m, HERE, 231), "put", { text = "[from Me · msg 100-abcd.2, who can't see this screen.] hi" })
end)
trial("last_tick is the last tick due, and 0 before the first", function()
  local m = { start = 1000, every = 60 }
  for _, row in ipairs({ { 1000, 0 }, { 1059, 0 }, { 1060, 1 }, { 1119, 1 }, { 1120, 2 }, { 1000 + 6000, 100 } }) do
    assert(P.last_tick(m, row[1]) == row[2], row[1] .. ": " .. P.last_tick(m, row[1]))
  end
  m = { start = 1000.7, every = 3.3 }
  for k = 1, 200 do
    local due = m.start + k * m.every
    assert(P.last_tick(m, due) == k and P.last_tick(m, due - 1e-6) == k - 1, k)
  end
end)

if failed > 0 then print(failed .. " of " .. n .. " step trials failed.") os.exit(1) end
print("Passed " .. n .. " step trials.")
