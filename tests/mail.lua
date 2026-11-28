-- Run from the repo root with `luajit tests/mail.lua` or `lua5.1 tests/mail.lua`.
-- mail.post checks everything, resolves the address once, wakes the postman,
-- queues one file atomically, and never touches the receiver.
local json = dofile("tests/lib/json.lua")
local real_dofile = dofile
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local tmp = os.tmpname()
os.remove(tmp)
local root = tmp .. "/rex-teams"

local calls, ensured, renames, ensure_error
local blocks = {
  ["block:me"] = { session = "s:me", tab = "Chief" },
  ["block:peer"] = { session = "s:me", tab = "Helper" },
  ["block:far"] = { session = "s:far", tab = "Builder", host = "ws" },
}
local function server(name)
  local s = {}
  function s.call(method, args)
    calls[#calls + 1] = name .. " " .. method
    if method == "target.resolve" then
      local q = args.queries[1]
      for id, b in pairs(blocks) do
        if (b.host or "") == name:gsub("^local$", "") and (q == id or q == b.tab) then
          return { results = { { status = "resolved", target = { session_id = b.session, block_id = id } } } }
        end
      end
      return { results = { { status = "not_found", reason = "" } } }
    end
    if method == "session.attach" then return {} end
    if method == "server.status" then return { host_id = "id-mac" } end
    if method == "session.view" then
      local out = {}
      for id, b in pairs(blocks) do
        if b.session == args.session_id then out[#out + 1] = { label = b.tab, layers = { { blocks = { { block_id = id, label = "shell" } } } } } end
      end
      return { windows = out }
    end
    if method == "block.method" and args.method == "list_dir" then
      assert(args.block_id == "block:me", "files are found from the sender's terminal")
      local p = args.args.path
      if p == "gone.md" then return { status = "missing", path = "/w/gone.md" } end
      return { status = "ok", path = p:sub(1, 1) == "/" and p or "/w/" .. p, entries = {} }
    end
    error("unexpected call " .. name .. " " .. method)
  end
  return s
end
local servers
local function reset()
  calls, ensured, renames, ensure_error = {}, 0, 0, nil
  os.execute("rm -rf " .. quote(tmp))
  servers = { [""] = server("local"), ws = server("ws") }
  rex = {
    json = json,
    call = servers[""].call,
    server = function(label) if not servers[label] or label == "" then error('rex.server: no host named "' .. label .. '"', 0) end return servers[label] end,
    exec = function(argv)
      calls[#calls + 1] = "exec " .. argv[1]
      if argv[1] == "hostname" then return { ok = true, code = 0, stdout = "mac\n" } end
      assert(argv[1] == "mkdir")
      local ok = os.execute("mkdir -p " .. quote(argv[3]))
      return { ok = ok == 0 or ok == true, code = 0, stdout = "", stderr = "" }
    end,
  }
end
reset()
local lib = real_dofile("skills/rex-teams/scripts/lib.lua")
lib.root = root
local real_getenv = os.getenv
os.getenv = function(k) if k == "REX_BLOCK" then return "block:me" end return real_getenv(k) end
local real_rename = os.rename
os.rename = function(a, b)
  renames = renames + 1
  assert(a == b .. ".tmp", "not written to a temp file first: " .. a)
  return real_rename(a, b)
end
local function outbox_files()
  local p = io.popen("ls " .. quote(root .. "/outbox") .. " 2>/dev/null")
  local names = {}
  for name in p:lines() do names[#names + 1] = name end
  p:close()
  return names
end
local queued_at_ensure
dofile = function(path)
  if path:match("/lib%.lua$") then return lib end
  if path:match("/postman%.lua$") then
    return { ensure = function()
      ensured = ensured + 1
      queued_at_ensure = #outbox_files()
      if ensure_error then error(ensure_error, 0) end
    end }
  end
  return real_dofile(path)
end
local mail = real_dofile("skills/rex-teams/scripts/mail.lua")

local n, failed = 0, 0
local function trial(name, f)
  n = n + 1
  reset()
  local ok, err = pcall(f)
  if not ok then failed = failed + 1 end
  print((ok and "ok " or "not ok ") .. n .. " - " .. name .. (ok and "" or ": " .. tostring(err)))
end
local function fails(text, o)
  local ok, err = pcall(mail.post, o)
  assert(not ok and tostring(err):find(text, 1, true), tostring(err))
  local f = io.open(root .. "/outbox")
  local files = 0
  if f then
    f:close()
    local p = io.popen("ls " .. quote(root .. "/outbox"))
    for _ in p:lines() do files = files + 1 end
    p:close()
  end
  assert(files == 0 and ensured == 0, "a refused message was queued")
end
local function only()
  local p = io.popen("ls " .. quote(root .. "/outbox"))
  local names = {}
  for name in p:lines() do names[#names + 1] = name end
  p:close()
  assert(#names == 1, "want one queued file, got " .. #names .. ": " .. table.concat(names, " "))
  local f = assert(io.open(root .. "/outbox/" .. names[1]))
  local msg = json.decode(f:read("*a"))
  f:close()
  assert(names[1] == msg.id .. ".json")
  return msg
end

trial("the postman is woken, then the message is queued as one file, atomically", function()
  local id, name = mail.post({ to = "Helper", text = "hi" })
  assert(id:match("^%d+%-%a%a%a%a$") and name == "Helper", id .. " " .. name)
  local msg = only()
  assert(msg.id == id and msg.text == "hi" and msg.to.block == "block:peer" and msg.to.name == "Helper")
  assert(msg.from.block == "block:me" and msg.to.host == nil)
  -- The postman looks the session up at delivery, so none is saved.
  assert(msg.to.session == nil and msg.from.session == nil, "a session was saved")
  assert(msg.head:find("[from Chief · msg " .. id .. ", who can't see this screen. Reply by running: rex do ", 1, true) == 1, msg.head)
  assert(msg.head:find("block='block:me' message='<reply>'] $"), msg.head)
  assert(renames == 1 and ensured == 1 and queued_at_ensure == 0, "queued before the postman was woken")
end)
trial("when the postman doesn't start, post raises and nothing is queued, so sending again doesn't double it", function()
  ensure_error = "the postman didn't start: boom"
  local ok, err = pcall(mail.post, { to = "Helper", text = "hi" })
  assert(not ok and err == "the postman didn't start: boom", tostring(err))
  local names = outbox_files()
  assert(#names == 0, "a message whose post raised was queued: " .. table.concat(names, " "))
  ensure_error = nil
  mail.post({ to = "Helper", text = "hi" })
  assert(only().text == "hi")
end)
trial("post never types into the receiver", function()
  mail.post({ to = "Helper", text = "hi" })
  for _, c in ipairs(calls) do assert(not c:find("block.event"), c) end
end)
trial("the address is resolved once, at post", function()
  mail.post({ to = "Helper", text = "hi" })
  local n = 0
  for _, c in ipairs(calls) do if c == "local target.resolve" then n = n + 1 end end
  assert(n == 2, "want one lookup for the receiver and one for the sender, got " .. n)
end)
for _, row in ipairs({
  { "two lines", { to = "Helper", text = "a\nb" }, "the message must be one line" },
  { "an empty message", { to = "Helper", text = "" }, "the message is empty; say something" },
  { "a blank message", { to = "Helper", text = "   " }, "the message is empty; say something" },
  { "a blank address", { to = "  ", text = "hi" }, "say who the message is for" },
  { "an unknown block", { to = "Nobody", text = "hi" }, "block Nobody: not found" },
  { "an unknown host", { to = "Builder", host = "nope", text = "hi" }, 'no host named "nope"' },
  { "a missing file", { to = "Helper", text = "hi", files = { "a.md", "gone.md" } }, "file gone.md: missing" },
  { "two files with one name to another host", { to = "Builder", host = "ws", text = "hi", files = { "a.md", "x/a.md" } }, "two files are named a.md" },
}) do
  trial("refused before anything is queued: " .. row[1], function()
    fails(row[3], row[2])
    -- A plain sentence, without the script's file and line.
    local _, err = pcall(mail.post, row[2])
    assert(not tostring(err):find("%.lua:%d"), err)
  end)
end
trial("an unknown host fails with no calls on this host", function()
  fails('no host named "nope"', { to = "Builder", host = "nope", text = "hi" })
  assert(#calls == 0, table.concat(calls, ", "))
end)
trial("files on this host are named where they are, and not copied", function()
  mail.post({ to = "Helper", text = "see", files = { "a.md", "/abs/b" } })
  local msg = only()
  assert(msg.text == "see [files: /w/a.md, /abs/b]" and msg.files == nil, msg.text)
end)
trial("files for another host are named where they'll land, and copied at delivery", function()
  local id = mail.post({ to = "Builder", host = "ws", text = "see", files = "a.md" })
  local msg = only()
  local folder = "/tmp/rex-teams/inbox/far/" .. id
  assert(msg.text == "see [files: " .. folder .. "/a.md; you can remove " .. folder .. " once you've read them]", msg.text)
  assert(msg.files[1] == "/w/a.md" and #msg.files == 1)
  assert(msg.to.host == "ws" and msg.to.block == "block:far")
  assert(msg.head:find("[from Chief on mac (Rex host id-mac) · msg " .. id .. ", who can't see this screen.", 1, true) == 1, msg.head)
end)
trial("an alarm to yourself is headed as one, with its time", function()
  mail.post({ to = "block:me", text = "check CI", at = 1795671120 })
  local msg = only()
  assert(msg.head == "[alarm you set · msg " .. msg.id .. "] " and msg.at == 1795671120 and not msg.every, msg.head)
end)
trial("a recurring alarm stores its interval exactly, and starts now", function()
  local before = os.time()
  mail.post({ to = "Helper", text = "tick", every = 10.5 })
  local msg = only()
  assert(msg.every == 10.5 and msg.start >= before and msg.start <= os.time() and msg.head:find("[from Chief · msg ", 1, true) == 1)
end)
trial("any positive interval is taken, however short", function()
  mail.post({ to = "Helper", text = "tick", every = 0.5 })
  assert(only().every == 0.5)
end)
trial("list reads the queue oldest first, and filters by receiver", function()
  local here = mail.list
  os.execute("mkdir -p " .. quote(root .. "/outbox"))
  local function full(m)
    m.seq, m.from, m.head, m.text = 0, { block = "block:me" }, "[from Chief · msg " .. m.id .. "] ", "hi"
    m.to.name = "Peer"
    return m
  end
  mail.write(full({ id = "200-bbbb", posted = 200, to = { block = "block:peer" } }))
  mail.write(full({ id = "100-aaaa", posted = 100, to = { block = "block:far", host = "ws" } }))
  rex.call = function(method, args)
    if method == "block.method" and args.method == "list_dir" then
      return { status = "ok", entries = { { name = "200-bbbb.json" }, { name = "100-aaaa.json" }, { name = "100-aaaa.json.tmp" }, { name = "x" } } }
    end
    return servers[""].call(method, args)
  end
  local all = here()
  assert(#all == 2 and all[1].id == "100-aaaa" and all[2].id == "200-bbbb")
  local one = here({ block = "block:far", host = "ws" })
  assert(#one == 1 and one[1].id == "100-aaaa")
  -- A file that isn't JSON was edited by hand: one clear error names it.
  lib.write(root .. "/outbox/100-aaaa.json", "nope")
  local ok, err = pcall(here)
  assert(not ok and err:find("^" .. (root .. "/outbox/100-aaaa.json"):gsub("%p", "%%%0") .. " isn't a message .*; delete it$"), tostring(err))
end)
trial("notices to one sender in one second are listed in the order they were written", function()
  os.execute("mkdir -p " .. quote(root .. "/outbox"))
  rex.call = function(method, args)
    if method == "block.method" and args.method == "list_dir" then
      local entries = {}
      for _, name in ipairs(outbox_files()) do entries[#entries + 1] = { name = name } end
      return { status = "ok", entries = entries }
    end
    return servers[""].call(method, args)
  end
  local real_time = os.time
  os.time = function() return 1000 end
  local ok, err = pcall(function()
    local sender = { block = "block:me" }
    for i = 1, 20 do mail.notice(sender, "n" .. i) end
    local got = mail.list({ block = "block:me" })
    assert(#got == 20, #got)
    assert(got[1].notice == nil and got[1].head == "[rex-teams postman · msg " .. got[1].id .. "] ", "a notice carries a notice field")
    for i, msg in ipairs(got) do assert(msg.text == "n" .. i, "notice " .. i .. " is " .. msg.text) end
  end)
  os.time = real_time
  assert(ok, err)
end)
trial("posts in one second to a receiver on another host are numbered in the order sent", function()
  os.execute("mkdir -p " .. quote(root .. "/outbox"))
  rex.call = function(method, args)
    if method == "block.method" and args.method == "list_dir" and args.args.path == root .. "/outbox" then
      local entries = {}
      for _, name in ipairs(outbox_files()) do entries[#entries + 1] = { name = name } end
      return { status = "ok", entries = entries }
    end
    return servers[""].call(method, args)
  end
  local real_time = os.time
  os.time = function() return 1000 end
  local ok, err = pcall(function()
    for i = 1, 3 do mail.post({ to = "Builder", host = "ws", text = "part " .. i }) end
    local got = mail.list({ block = "block:far", host = "ws" })
    assert(#got == 3, #got)
    for i, msg in ipairs(got) do assert(msg.seq == i - 1 and msg.text == "part " .. i, "part " .. i .. " is " .. msg.text .. ", seq " .. msg.seq) end
  end)
  os.time = real_time
  assert(ok, err)
end)
trial("a post never replaces a queued file, even when the time and letters repeat", function()
  local real_time, real_random = os.time, math.random
  -- Two posts in one second draw the same four letters, then other ones.
  local letters = { 97, 97, 97, 97, 97, 97, 97, 97, 98, 98, 98, 98 }
  os.time = function() return 1000 end
  math.random = function() return table.remove(letters, 1) or 99 end
  local ok, err = pcall(function()
    local a = mail.post({ to = "Helper", text = "first" })
    local b = mail.post({ to = "Helper", text = "second" })
    assert(a ~= b, "both posts got " .. a)
    local names = outbox_files()
    assert(#names == 2, "want two queued files, got " .. table.concat(names, " "))
  end)
  os.time, math.random = real_time, real_random
  assert(ok, err)
end)
trial("a write of a file someone deleted doesn't bring it back", function()
  os.execute("mkdir -p " .. quote(root .. "/outbox"))
  assert(mail.write({ id = "300-cccc" }, true) == false)
  assert(not io.open(root .. "/outbox/300-cccc.json"))
end)

os.execute("rm -rf " .. quote(tmp))
dofile, os.getenv, os.rename = real_dofile, real_getenv, real_rename
if failed > 0 then print(failed .. " of " .. n .. " mail trials failed.") os.exit(1) end
print("Passed " .. n .. " mail trials.")
