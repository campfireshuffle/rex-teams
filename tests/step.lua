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
local function look(o)
  local l = { status = "idle", known = true, app = "x", composer = { text = "" }, seen = false }
  for k, v in pairs(o or {}) do l[k] = v end
  return l
end
-- What a composer shows after msg()'s first paste.
local PASTED = "[from Me · msg 100-abcd, who can't see this screen.] hi"
local function ours(kind, o)
  return look({ composer = { text = kind == "token" and "[Pasted text #1]" or PASTED, ours = kind or "id" }, seen = o and o.seen })
end

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
-- Paste M at time T on an idle, empty receiver.
local function put(m, t) return is(step(m, look(), t or 100), "put") end

trial("a new message asks for a look before anything else", function()
  is(step(msg(), nil, 100), "look")
end)
trial("a ready receiver gets the header with the id, then the text", function()
  is(step(msg(), look(), 100), "put", { text = "[from Me · msg 100-abcd, who can't see this screen.] hi" })
end)
trial("a dim placeholder isn't a draft", function()
  is(step(msg(), look({ composer = { text = "" } }), 100), "put")
end)
for _, row in ipairs({
  { "blocked (permission)", { status = "blocked", kind = "permission" }, "it's asking for permission", false },
  { "blocked (no kind)", { status = "blocked" }, "it's waiting on a prompt", false },
  { "busy", { status = "working" }, "it's busy", false },
  { "a draft", { composer = { text = "half a thought" } }, "someone is typing there", true },
  { "no composer", { composer = false }, "its prompt box isn't showing", true },
  { "an unknown program", { known = false, app = "aider", composer = false }, "rex-teams can't read the prompt box of 'aider'", true },
  { "someone's paste token", { composer = { text = "[Pasted ~1 lines]", ours = "token" } }, "someone is typing there", true },
}) do
  trial("hold: " .. row[1], function()
    local l = look(row[2])
    if l.composer == false then l.composer = nil end
    local m = msg()
    local a = is(step(m, l, 100), "hold", { why = row[3] })
    assert((a.at ~= nil) == row[4], "a hold for " .. row[1] .. (row[4] and " looks again shortly" or " waits for a status change"))
    assert(m.d.why == row[3] and m.d.held_since == 100)
  end)
end
trial("blocked wins over a composer that looks free", function()
  is(step(msg(), look({ status = "blocked", kind = "question" }), 100), "hold", { why = "it's asking a question" })
end)
trial("a status that turns working after the paste confirms it", function()
  local m = msg()
  put(m)
  is(step(m, look({ status = "working", composer = { text = "" } }), 100), "done")
end)
trial("a working edge heard as an event confirms it, even if the pane is idle again", function()
  local m = msg()
  put(m)
  m.d.worked = true
  is(step(m, look(), 101), "done")
end)
trial("our text gone from the composer and the id above it confirms it", function()
  local m = msg()
  put(m)
  is(step(m, look({ seen = true }), 101), "done")
end)
trial("the id on screen doesn't confirm while ours is still in the composer", function()
  local m = msg()
  put(m)
  is(step(m, ours("id", { seen = true }), 102), "enter")
end)
trial("the id on screen doesn't confirm without a composer", function()
  local m = msg()
  put(m)
  local l = look({ seen = true })
  l.composer = nil
  assert(step(m, l, 101).kind ~= "done")
end)
trial("Enter is pressed again only while ours is in the composer, at most 3 times", function()
  local m = msg()
  put(m)
  is(step(m, ours(), 101), "wait", { at = 102 })
  is(step(m, ours(), 102), "enter")
  is(step(m, ours(), 103), "wait")
  is(step(m, ours(), 104), "enter")
  is(step(m, ours(), 106), "enter")
  local a = is(step(m, ours(), 108), "notice", { why = "unconfirmed" })
  assert(a.text:find("Couldn't confirm message 100-abcd reached Reviewer", 1, true), a.text)
  assert(m.dead == "unconfirmed")
  is(step(m, ours(), 200), "wait")
end)
trial("no Enter goes to a blocked receiver, even with ours in the composer", function()
  local m = msg()
  put(m)
  local blocked = ours()
  blocked.status, blocked.kind = "blocked", "permission"
  is(step(m, blocked, 102), "hold", { why = "it's asking for permission" })
  is(step(m, blocked, 110), "hold", { why = "it's asking for permission" })
  assert(m.d.enters == 0, "an Enter was counted while blocked")
  is(step(m, ours(), 111), "enter")
end)
trial("a blocked receiver holds a resend too, with ours gone from the composer", function()
  local m = msg()
  put(m)
  is(step(m, look({ status = "blocked", kind = "question" }), 110), "hold", { why = "it's asking a question" })
  assert(m.d.pastes == 1)
end)
trial("Enter isn't pressed again once a person has typed around our text", function()
  for _, text in ipairs({ PASTED .. " MY UNFINISHED DRAFT", "wait " .. PASTED }) do
    local m = msg()
    put(m)
    local l = look({ composer = { text = text, ours = "id" } })
    is(step(m, l, 102), "wait", { at = 110 })
    is(step(m, l, 110), "hold", { why = "someone is typing there" })
  end
end)
trial("our text wrapped across composer rows is still ours", function()
  local m = msg()
  put(m)
  is(step(m, look({ composer = { text = PASTED:gsub(" who ", "\nwho "), ours = "id" } }), 102), "enter")
end)
trial("a paste token right after our paste is ours", function()
  local m = msg()
  put(m)
  is(step(m, ours("token"), 102), "enter")
end)
trial("with evidence it was lost, it's pasted again after 10, 30 and 60 s, labelled resent", function()
  local m = msg()
  put(m, 100)
  is(step(m, look(), 105), "wait", { at = 110 })
  local a = is(step(m, look(), 110), "put")
  assert(a.text == "[from Me · msg 100-abcd · resent, who can't see this screen.] hi", a.text)
  is(step(m, look(), 139), "wait", { at = 140 })
  is(step(m, look(), 140), "put")
  is(step(m, look(), 199), "wait", { at = 200 })
  is(step(m, look(), 200), "put")
  is(step(m, look(), 259), "wait", { at = 260 })
  a = is(step(m, look(), 260), "notice", { why = "unconfirmed" })
  assert(a.text == "Couldn't confirm message 100-abcd reached Reviewer after 3 resends. It's kept in "
    .. mailfile("100-abcd") .. ".", a.text)
  assert(m.dead == "unconfirmed" and m.d.pastes == 4)
end)
trial("a resend waits for the receiver to be ready, like the first paste", function()
  local m = msg()
  put(m, 100)
  is(step(m, look({ composer = { text = "typing" } }), 110), "hold", { why = "someone is typing there" })
  is(step(m, look({ status = "working" }), 111), "done")
end)
trial("no resend without evidence: a missing composer or a busy receiver", function()
  local m = msg()
  put(m, 100)
  local l = look()
  l.composer = nil
  is(step(m, l, 200), "hold")
end)
trial("a message held 10 minutes tells its sender once", function()
  local m = msg()
  is(step(m, look({ composer = { text = "draft" } }), 100), "hold", { until_notice = 700 })
  is(step(m, look({ composer = { text = "draft" } }), 699), "hold")
  local a = is(step(m, look({ composer = { text = "draft" } }), 700), "notice", { why = "held" })
  assert(a.text == "Message 100-abcd to Reviewer has waited 10 minutes: someone is typing there. It goes out once that clears."
    .. " To drop it, delete " .. mailfile("100-abcd") .. ".", a.text)
  is(step(m, look({ composer = { text = "draft" } }), 2000), "hold")
  assert(not m.dead)
  is(step(m, look(), 2001), "put")
end)
trial("notices never cause notices", function()
  local m = msg({ notice = true })
  step(m, look({ status = "working" }), 100)
  is(step(m, look({ status = "working" }), 800), "save")
  local g = msg({ notice = true })
  is(step(g, { gone = true }, 100), "save")
  assert(g.dead == "gone")
end)
trial("an alarm you set yourself never tells you it's held", function()
  local m = msg({ to = { session = "s:1", block = "b:me", name = "Me" }, at = 100 })
  step(m, look({ status = "working" }), 100)
  is(step(m, look({ status = "working" }), 800), "save")
end)
trial("a receiver that's gone tells the sender once and keeps the file", function()
  local m = msg()
  local a = is(step(m, { gone = true }, 100), "notice", { why = "gone" })
  assert(a.text == "Message 100-abcd to Reviewer can't be delivered: that pane is gone. It's kept in " .. mailfile("100-abcd") .. ".", a.text)
  assert(m.dead == "gone")
  is(step(m, { gone = true }, 101), "wait")
end)
trial("files for another host are copied once, before the first paste", function()
  local m = msg({ files = { "/a.md" } })
  is(step(m, look(), 100), "attach")
  m.d.attached = true
  is(step(m, look(), 100), "put")
  is(step(m, look(), 110), "put")
end)
trial("a file copy that fails tells the sender and keeps the file", function()
  local m = msg({ files = { "/a.md" } })
  is(step(m, look(), 100), "attach")
  m.d.attach_error = "rex cp to ws failed (exit 4, can't reach that host)"
  local a = is(step(m, look(), 100), "notice", { why = "files" })
  assert(a.text:find("Message 100-abcd to Reviewer wasn't sent: rex cp to ws failed (exit 4, can't reach that host). It's kept in ", 1, true), a.text)
  assert(m.dead == "files")
end)
trial("a pane Rex can't reach is held, and the sender hears after 10 minutes", function()
  local m = msg()
  local a = is(step(m, { error = "dial tcp: timeout" }, 100), "hold", { why = "rex-teams can't reach it (dial tcp: timeout)" })
  assert(a.at == 102)
  is(step(m, { error = "dial tcp: timeout" }, 700), "notice", { why = "held" })
end)
trial("an alarm waits for its time, then goes like any message", function()
  local m = msg({ at = 160, head = "[alarm you set", tail = "] ", to = { session = "s:1", block = "b:me", name = "Me" } })
  is(step(m, nil, 100), "wait", { at = 160 })
  is(step(m, nil, 160), "look")
  is(step(m, look(), 160), "put", { text = "[alarm you set · msg 100-abcd] hi" })
end)
trial("a one-shot found late at startup says so; one on time doesn't", function()
  local m = msg({ at = 120, late = 19 })
  local a = is(step(m, look(), 139), "put")
  assert(a.text:sub(-28) == "hi [late by 19s, Rex restarted]" or a.text:find("hi %[late by 19s, Rex restarted%]$"), a.text)
  m = msg({ at = 120, late = 0 })
  a = is(step(m, look(), 120), "put")
  assert(a.text:sub(-2) == "hi", a.text)
end)
trial("a recurring alarm keeps its phase, tags each tick, and stays queued", function()
  local m = msg({ every = 60, start = 100 })
  is(step(m, nil, 100), "wait", { at = 160 })
  is(step(m, look(), 160), "put", { text = "[from Me · msg 100-abcd.1, who can't see this screen.] hi" })
  is(step(m, look({ status = "working" }), 161), "save", { at = 220 })
  assert(m.d == nil and m.k == 2 and m.due == 220)
  is(step(m, nil, 219), "wait", { at = 220 })
  is(step(m, look(), 220), "put", { text = "[from Me · msg 100-abcd.2, who can't see this screen.] hi" })
end)
trial("a recurring tick that comes 1s or more late is skipped", function()
  local m = msg({ every = 60, start = 100 })
  step(m, nil, 100)
  is(step(m, nil, 761), "save", { at = 820 })
  assert(not m.d and m.due == 820)
end)
trial("a recurring tick that comes while the last one is held is skipped", function()
  local m = msg({ every = 60, start = 100 })
  step(m, nil, 100)
  is(step(m, look({ status = "working" }), 160), "hold")
  is(step(m, look({ status = "working" }), 230), "hold")
  assert(m.d.tag == "100-abcd.1" and m.due == 280, tostring(m.due))
  is(step(m, look(), 231), "put", { text = "[from Me · msg 100-abcd.1, who can't see this screen.] hi" })
end)
trial("next_tick skips missed ticks and never goes back", function()
  local m = { start = 1000, every = 60 }
  assert(select(2, P.next_tick(m, 0, 1000)) == 1060)
  assert(select(2, P.next_tick(m, 0, 1140)) == 1180)
  assert(select(2, P.next_tick(m, 5, 1000)) == 1360)
  local k, due = P.next_tick(m, 1, 1121)
  assert(k == 3 and due == 1180, k .. " " .. due)
end)

if failed > 0 then print(failed .. " of " .. n .. " step trials failed.") os.exit(1) end
print("Passed " .. n .. " step trials.")
