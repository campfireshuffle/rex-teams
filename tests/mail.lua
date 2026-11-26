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
    return { ensure = function(hint)
      ensured = ensured + 1
      queued_at_ensure = #outbox_files()
      if ensure_error then error(ensure_error, 0) end
      return hint and "the hint" or nil
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
  assert(msg.id == id and msg.text == "hi" and msg.to.block == "block:peer" and msg.to.session == "s:me" and msg.to.name == "Helper")
  assert(msg.from.block == "block:me" and msg.from.name == "Chief" and msg.to.host == nil)
  assert(msg.head == "[from Chief" and msg.tail:find("^, who can't see this screen%. Don't rename the Rex session or your tab%. Reply by running: rex do "), msg.tail)
  assert(msg.tail:find("block='block:me' message='<reply>'] $"), msg.tail)
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
  { "no text", { to = "Helper" }, "the message is required" },
  { "a blank address", { to = "  ", text = "hi" }, "say who the message is for" },
  { "an unknown block", { to = "Nobody", text = "hi" }, "block Nobody: not found" },
  { "an unknown host", { to = "Builder", host = "nope", text = "hi" }, 'no host named "nope"' },
  { "a missing file", { to = "Helper", text = "hi", files = { "a.md", "gone.md" } }, "file gone.md: missing" },
  { "a zero interval", { to = "Helper", text = "hi", every = 0 }, "every must be a positive number" },
  { "a negative time", { to = "Helper", text = "hi", at = -5 }, "at must be a positive number" },
  { "both at and every", { to = "Helper", text = "hi", at = 5, every = 5 }, "use at or every, not both" },
  { "two files with one name to another host", { to = "Builder", host = "ws", text = "hi", files = { "a.md", "x/a.md" } }, "two files are named a.md" },
}) do
  trial("refused before anything is queued: " .. row[1], function() fails(row[3], row[2]) end)
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
  assert(msg.to.host == "ws" and msg.to.session == "s:far" and msg.to.block == "block:far")
  assert(msg.head == "[from Chief on mac (Rex host id-mac)", msg.head)
end)
trial("an alarm to yourself is headed as one, with its time", function()
  mail.post({ to = "block:me", text = "check CI", at = 1795671120 })
  local msg = only()
  assert(msg.head == "[alarm you set" and msg.tail == "] " and msg.at == 1795671120 and not msg.every)
end)
trial("a recurring alarm stores its interval exactly, and starts now", function()
  local before = os.time()
  mail.post({ to = "Helper", text = "tick", every = 0.5 })
  local msg = only()
  assert(msg.every == 0.5 and msg.start >= before and msg.start <= os.time() and msg.head == "[from Chief")
end)
trial("hint=true asks the postman whether it's trusted", function()
  local _, _, hint = mail.post({ to = "Helper", text = "x", hint = true })
  assert(hint == "the hint")
  _, _, hint = mail.post({ to = "Helper", text = "x" })
  assert(hint == nil)
end)
trial("list reads the queue oldest first, and filters by receiver", function()
  local here = mail.list
  os.execute("mkdir -p " .. quote(root .. "/outbox"))
  mail.write({ id = "200-bbbb", posted = 200, to = { block = "block:peer" } })
  mail.write({ id = "100-aaaa", posted = 100, to = { block = "block:far", host = "ws" } })
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
