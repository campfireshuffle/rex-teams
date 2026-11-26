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
local function box(text, token) return look({ composer = { text = text, token = token } }) end

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
  is(step(msg(), look(), 100), "put", { text = PASTED })
end)
trial("a dim placeholder isn't a draft", function()
  is(step(msg(), look({ composer = { text = "" } }), 100), "put")
end)
trial("a busy receiver with an empty prompt box gets it at once", function()
  is(step(msg(), look({ status = "working" }), 100), "put", { text = PASTED })
end)
trial("the prompt box alone decides: a blocked status with an empty box doesn't hold", function()
  is(step(msg(), look({ status = "blocked", kind = "permission" }), 100), "put")
end)
trial("an unknown program, a shell too, gets it at once, and it's done without a look", function()
  for _, app in ipairs({ "aider", "zsh" }) do
    local m = msg()
    is(step(m, look({ known = false, app = app, composer = false }), 100), "put", { text = PASTED })
    is(step(m, nil, 100), "done")
  end
end)
for _, row in ipairs({
  { "a draft", { composer = { text = "half a thought" } }, "there's text in its prompt box" },
  { "a dialog in place of the prompt box", { composer = false }, "its prompt box isn't showing" },
  { "someone's paste token", { composer = { text = "[Pasted ~1 lines]", token = true } }, "there's text in its prompt box" },
}) do
  trial("hold: " .. row[1], function()
    local l = look(row[2])
    if l.composer == false then l.composer = nil end
    local m = msg()
    is(step(m, l, 100), "hold", { why = row[3], at = 100 + P.poll })
    assert(m.d.why == row[3] and m.d.held_since == 100)
  end)
end
trial("after the paste, one look at the prompt box, 2 s later", function()
  local m = msg()
  put(m)
  is(step(m, nil, 101), "wait", { at = 102 })
  is(step(m, nil, 102), "look")
end)
trial("our text gone at the look: done, with no second Enter", function()
  local m = msg()
  put(m)
  is(step(m, box(""), 102), "done")
end)
trial("our text still in the box at the look: Enter once more, then done", function()
  for _, l in ipairs({ box(PASTED), box(PASTED:gsub(" who ", "\nwho ")), box("[Pasted text #1]", true) }) do
    local m = msg()
    put(m)
    is(step(m, l, 102), "enter")
    is(step(m, nil, 103), "done")
  end
end)
trial("a person's text around ours isn't ours: no Enter submits their draft", function()
  for _, text in ipairs({ PASTED .. " MY UNFINISHED DRAFT", "wait " .. PASTED }) do
    local m = msg()
    put(m)
    is(step(m, box(text), 102), "done")
  end
end)
trial("a pane gone or unreachable at the look: done", function()
  for _, l in ipairs({ { gone = true }, { error = "dial tcp: timeout" } }) do
    local m = msg()
    put(m)
    is(step(m, l, 102), "done")
  end
end)
trial("a message held 10 minutes tells its sender once", function()
  local m = msg()
  is(step(m, look({ composer = { text = "draft" } }), 100), "hold")
  is(step(m, look({ composer = { text = "draft" } }), 699), "hold")
  local a = is(step(m, look({ composer = { text = "draft" } }), 700), "notice", { why = "held" })
  assert(a.text == "Message 100-abcd to Reviewer has waited 10 minutes: there's text in its prompt box. It goes out once that clears."
    .. " To drop it, delete " .. mailfile("100-abcd") .. ".", a.text)
  is(step(m, look({ composer = { text = "draft" } }), 2000), "hold")
  assert(not m.dead)
  is(step(m, look(), 2001), "put")
end)
trial("notices never cause notices", function()
  local m = msg({ notice = true })
  step(m, look({ composer = { text = "draft" } }), 100)
  is(step(m, look({ composer = { text = "draft" } }), 800), "hold")
  local g = msg({ notice = true })
  is(step(g, { gone = true }, 100), "save")
  assert(g.dead == "gone")
end)
trial("an alarm you set yourself never tells you it's held", function()
  local m = msg({ to = { session = "s:1", block = "b:me", name = "Me" }, at = 100 })
  step(m, look({ composer = { text = "draft" } }), 100)
  is(step(m, look({ composer = { text = "draft" } }), 800), "hold")
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
  is(step(m, nil, 161), "wait", { at = 162 })
  is(step(m, look(), 162), "save", { at = 220 })
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
  is(step(m, look({ composer = { text = "draft" } }), 160), "hold")
  is(step(m, look({ composer = { text = "draft" } }), 220), "hold")
  assert(m.due == 220, "overtaken on time, not 1s late")
  is(step(m, look({ composer = { text = "draft" } }), 230), "hold")
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
