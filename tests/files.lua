-- Run from the repo root with `luajit tests/files.lua` or `lua5.1 tests/files.lua`.
-- send.lua file=: mocks rex.call and the `rex` command, and runs mkdir, cp
-- and rm for real in a scratch folder, so the stage can be checked on disk.
-- send.lua checks the files and queues the message; deliver() then runs the
-- postman's deliver and pane.lua, which copy them to another host at delivery.
local real_dofile, real_getenv = dofile, os.getenv
local json = real_dofile("tests/lib/json.lua")
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function sh(line) assert(os.execute(line) == 0, line) end
local function exists(path) return os.execute("test -e " .. quote(path)) == 0 end

local tmp = os.tmpname()
os.remove(tmp)
local src, root = tmp .. "/src", tmp .. "/root"
local odd = "sp ace it's \"q\" ü 名.txt"
sh("mkdir -p " .. quote(src .. "/dir/sub"))
for _, name in ipairs({ "a.md", "b.md", odd, "dir/sub/c.txt" }) do
  local f = assert(io.open(src .. "/" .. name, "w"))
  f:write(name)
  f:close()
end
-- Links to attach, and one inside dir that must stay a link.
sh("ln -s " .. quote(src .. "/a.md") .. " " .. quote(src .. "/link.md"))
sh("ln -s " .. quote(src .. "/dir") .. " " .. quote(src .. "/linkdir"))
sh("ln -s c.txt " .. quote(src .. "/dir/sub/inner"))
-- A file this user can't read, and a name with a line break.
local locked, broken = "locked.md", "line\nbreak.md"
for _, name in ipairs({ locked, broken }) do
  local f = assert(io.open(src .. "/" .. name, "w"))
  f:write(name)
  f:close()
end
sh("chmod 000 " .. quote(src .. "/" .. locked))

local calls, pasted, events, execs, rex_cps, remote_root, cp_result

-- What the stage held when `rex cp` ran, relative to the stage folder.
local function tree(dir)
  local p = io.popen("cd " .. quote(dir) .. " && find . | LC_ALL=C sort")
  local out = {}
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return table.concat(out, "\n")
end
local function links(dir)
  local p = io.popen("cd " .. quote(dir) .. " && find . -type l | LC_ALL=C sort")
  local out = {}
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return table.concat(out, "\n")
end

local function server(name, blocks, list_dir)
  local s = {}
  function s.call(method, args)
    calls[#calls + 1] = name .. " " .. method
    if method == "session.attach" then return {} end
    if method == "server.status" then return { host_id = "id-" .. name } end
    if method == "session.view" then
      local list = {}
      for _, b in ipairs(blocks) do list[#list + 1] = { block_id = b.id, label = "shell" } end
      return { windows = { { label = blocks[1].label, layers = { { blocks = list } } } } }
    end
    if method == "target.resolve" then
      for _, b in ipairs(blocks) do
        if args.queries[1] == b.id or args.queries[1] == b.label then
          return { results = { { status = "resolved", target = { session_id = b.session, block_id = b.id } } } }
        end
      end
      return { results = { { status = "not_found", reason = "" } } }
    end
    if method == "block.method" and args.method == "process" then return { foreground = { pid = 1 } } end
    if method == "block.method" then
      assert(args.method == "list_dir")
      return list_dir(args.block_id, args.args)
    end
    if method == "block.event" then
      events[#events + 1] = { server = name, session = args.session_id, block = args.block_id, type = args.event.type }
      if args.event.type == "paste" then pasted[#pasted + 1] = { server = name, text = args.event.payload.text } end
      return {}
    end
    error("unexpected call: " .. method)
  end
  return s
end

-- The caller's terminal sits in SRC, like Rex's list_dir resolving a path.
-- As in Rex, a file anywhere on the path makes it not_dir, and every answer
-- has entries.
local function local_dir(block, args)
  assert(block == "block:me-0000-aaaa", "list_dir must ask the caller's terminal")
  local path = args.path
  local p = path:sub(1, 1) == "/" and path or src .. "/" .. path
  p = p:gsub("/+$", "")
  if p == "" then p = "/" end
  if os.execute("test -d " .. quote(p)) == 0 then
    if not args.files then return { status = "ok", path = p, entries = {} } end
    local entries = {}
    local ls = io.popen("ls -A " .. quote(p))
    for name in ls:lines() do
      entries[#entries + 1] = { name = name }
    end
    ls:close()
    return { status = "ok", path = p, entries = entries, truncated = false }
  end
  local up = p
  while up ~= "" do
    if os.execute("test -d " .. quote(up)) == 0 then return { status = "missing", path = p, entries = {} } end
    if exists(up) then return { status = "not_dir", path = p, entries = {} } end
    up = up:match("^(.*)/[^/]*$")
  end
  return { status = "missing", path = p, entries = {} }
end

local function remote_dir(block, args)
  local path = args.path
  assert(path == "/tmp/rex-teams" and block == "block:far-0000-cccc", path)
  return { status = remote_root, path = path, entries = {} }
end

local function reset()
  calls, pasted, events, execs, rex_cps = {}, {}, {}, {}, {}
  remote_root, cp_result = "ok", { ok = true, code = 0, stdout = "", stderr = "" }
  sh("rm -rf " .. quote(root))
  local servers = {
    [""] = server("local", {
      { id = "block:me-0000-aaaa", label = "Chief", session = "session:me" },
      { id = "block:peer-0000-bbbb", label = "Helper", session = "session:me" },
      { id = "block:else-0000-dddd", label = "Other", session = "session:else" },
    }, local_dir),
    ws = server("ws", { { id = "block:far-0000-cccc", label = "Builder", session = "session:far" } }, remote_dir),
  }
  rex = {
    json = json,
    call = servers[""].call,
    server = function(label)
      if not servers[label] or label == "" then error('rex.server: no host named "' .. label .. '"', 0) end
      return servers[label]
    end,
    exec = function(argv, opts)
      execs[#execs + 1] = argv
      if argv[1] == "hostname" then return { ok = true, code = 0, stdout = "mac\n" } end
      if argv[1] == "rex" then
        assert(opts and opts.timeout == 600, "rex cp needs a 600 s timeout")
        rex_cps[#rex_cps + 1] = { argv = argv, tree = tree(root .. "/stage"), links = links(root .. "/stage") }
        return cp_result
      end
      assert(argv[1] == "mkdir" or argv[1] == "cp" or argv[1] == "rm", "unexpected exec: " .. argv[1])
      local words = {}
      for i, w in ipairs(argv) do words[i] = quote(w) end
      local code = os.execute(table.concat(words, " "))
      return { ok = code == 0, code = code, stdout = "", stderr = "" }
    end,
  }
end

local lib
local function load(windows)
  lib = real_dofile("skills/rex-teams/scripts/lib.lua")
  lib.root = root
  if windows then lib.windows = true end
  lib.me = function() return "session:me", "block:me-0000-aaaa" end
  dofile = function(path)
    if path:match("/lib%.lua$") then return lib end
    if path:match("/postman%.lua$") then return { ensure = function() end } end
    return real_dofile(path)
  end
end
local function run(args, windows)
  rex.args = args
  load(windows)
  local real_print = print
  print = function() end
  local ok, err = pcall(real_dofile, "skills/rex-teams/scripts/send.lua")
  dofile, print = real_dofile, real_print
  return ok, err
end

-- Deliver the queued message to a receiver that's there, as the postman
-- would. Returns the notice its sender gets instead, if any.
local function deliver()
  load()
  local P = real_dofile("skills/rex-teams/scripts/postman.lua")
  local p = io.popen("ls " .. quote(root .. "/outbox"))
  local name = assert(p:read("*l"), "nothing was queued")
  p:close()
  local f = assert(io.open(root .. "/outbox/" .. name))
  local msg = json.decode(f:read("*a"))
  f:close()
  P.deliver(msg, os.time())
  dofile = real_dofile
  p = io.popen("ls " .. quote(root .. "/outbox"))
  for file in p:lines() do
    f = assert(io.open(root .. "/outbox/" .. file))
    local m = json.decode(f:read("*a"))
    f:close()
    -- The other file is the notice.
    if file ~= name then p:close() return m.text end
  end
  p:close()
end

local count, failed = 0, 0
local function check(name, fn)
  reset()
  local ok, err = pcall(fn)
  dofile = real_dofile
  count = count + 1
  if not ok then failed = failed + 1 end
  print((ok and "ok " or "not ok ") .. count .. " - " .. name .. (ok and "" or ": " .. tostring(err)))
end
local function has(s, part) return s:find(part, 1, true) ~= nil end
local function text() return assert(pasted[1], "nothing was pasted").text end
local function fails(args, want, windows)
  local ok, err = run(args, windows)
  assert(not ok and has(tostring(err), want), tostring(err))
  assert(#pasted == 0, "a failed send still pasted")
end
-- A message whose files can't be copied: the sender is told why, and
-- nothing is pasted.
local function undelivered(args, want)
  assert(run(args))
  local notice = deliver()
  assert(notice and has(notice, want), tostring(notice))
  assert(#pasted == 0, "a failed copy still pasted")
  return notice
end
local function rexes()
  local n = 0
  for _, argv in ipairs(execs) do if argv[1] == "rex" then n = n + 1 end end
  return n
end
-- Every paste and key went to SERVER's SESSION and BLOCK: a paste, then Enter.
local function landed_in(server_name, session, block)
  assert(#events == 3, "want 3 events, got " .. #events)
  for i, e in ipairs(events) do
    assert(e.server == server_name and e.session == session and e.block == block,
      i .. ": " .. e.type .. " went to " .. e.server .. " " .. tostring(e.session) .. " " .. tostring(e.block))
  end
  assert(events[1].type == "paste" and events[2].type == "key" and events[3].type == "key")
end
-- The message id in the one rex cp, and the stage it came from.
local function copied()
  assert(#rex_cps == 1, "want one rex cp, got " .. #rex_cps)
  local argv = rex_cps[1].argv
  local id = assert(argv[8]:match("/stage/(%d+%-%a%a%a%a)/inbox$"), argv[8])
  return argv, id
end

check("same host: no copy, absolute paths, no remove note", function()
  assert(run({ block = "Helper", message = "see", file = { "a.md", src .. "/dir" } }))
  deliver()
  for _, argv in ipairs(execs) do assert(argv[1] == "mkdir", "same host ran " .. argv[1]) end
  local want = "] see [files: " .. src .. "/a.md, " .. src .. "/dir]"
  assert(text():sub(-#want) == want, text())
  assert(not has(text(), "remove"))
end)
check("same host: a single file= string", function()
  assert(run({ block = "Helper", message = "see", file = "b.md" }))
  deliver()
  assert(has(text(), "] see [files: " .. src .. "/b.md]"), text())
end)
check("cross-host: one rex cp with host, session, -r, the stage and :/tmp/rex-teams/", function()
  assert(run({ host = "ws", block = "Builder", message = "see", file = "a.md" }))
  deliver()
  local argv, id = copied()
  local stage = root .. "/stage/" .. id
  local want = { "rex", "-S", "ws", "cp", "-s", "session:far", "-r", stage .. "/inbox", ":/tmp/rex-teams/" }
  assert(#argv == #want, table.concat(argv, " "))
  for i, w in ipairs(want) do assert(argv[i] == w, i .. ": " .. tostring(argv[i])) end
  assert(rex_cps[1].tree == table.concat({ ".", "./" .. id, "./" .. id .. "/inbox", "./" .. id .. "/inbox/far-0000-cccc",
    "./" .. id .. "/inbox/far-0000-cccc/" .. id, "./" .. id .. "/inbox/far-0000-cccc/" .. id .. "/a.md" }, "\n"), rex_cps[1].tree)
  local folder = "/tmp/rex-teams/inbox/far-0000-cccc/" .. id
  landed_in("ws", "session:far", "block:far-0000-cccc")
  local suffix = "] see [files: " .. folder .. "/a.md; you can remove " .. folder .. " once you've read them]"
  assert(text():sub(-#suffix) == suffix, text())
end)
check("cross-host: a list of files and a directory", function()
  assert(run({ host = "ws", block = "Builder", message = "see", file = { "a.md", "b.md", "dir/" } }))
  deliver()
  local _, id = copied()
  local stage_box = "./" .. id .. "/inbox/far-0000-cccc/" .. id
  for _, p in ipairs({ "/a.md", "/b.md", "/dir", "/dir/sub", "/dir/sub/c.txt" }) do
    assert(has(rex_cps[1].tree, stage_box .. p .. "\n") or rex_cps[1].tree:sub(-#(stage_box .. p)) == stage_box .. p, p .. " missing:\n" .. rex_cps[1].tree)
  end
  local folder = "/tmp/rex-teams/inbox/far-0000-cccc/" .. id
  assert(has(text(), "[files: " .. folder .. "/a.md, " .. folder .. "/b.md, " .. folder .. "/dir; you can remove " .. folder .. " once you've read them]"), text())
end)
check("odd names: spaces, quotes and unicode arrive as one word each", function()
  assert(run({ host = "ws", block = "Builder", message = "see", file = odd }))
  deliver()
  local _, id = copied()
  assert(has(rex_cps[1].tree, "/" .. id .. "/" .. odd), rex_cps[1].tree)
  for _, argv in ipairs(execs) do
    if argv[1] == "cp" then assert(argv[#argv - 1] == src .. "/" .. odd, argv[#argv - 1]) end
  end
  assert(has(text(), "/" .. id .. "/" .. odd .. "; you can remove"), text())
end)
check("a missing local file: error, nothing copied or sent", function()
  for _, host in ipairs({ false, "ws" }) do
    reset()
    fails({ host = host or nil, block = host and "Builder" or "Helper", message = "see", file = { "a.md", "gone.md" } }, "gone.md")
    assert(rexes() == 0 and not exists(root .. "/outbox"))
  end
end)
check("a failed rex cp: the sender gets its exit code and stderr, nothing pasted", function()
  cp_result = { ok = false, code = 4, stdout = "", stderr = "boom" }
  local notice = undelivered({ host = "ws", block = "Builder", message = "see", file = "a.md" }, "wasn't sent")
  assert(has(notice, "failed (exit 4): boom"), notice)
end)
check("/tmp/rex-teams missing on the receiver: created first", function()
  remote_root = "missing"
  assert(run({ host = "ws", block = "Builder", message = "see", file = "a.md" }))
  deliver()
  assert(#rex_cps == 2, "want two rex cp, got " .. #rex_cps)
  local first, second = rex_cps[1].argv, rex_cps[2].argv
  assert(first[3] == "ws" and first[6] == "session:far" and first[9] == ":/tmp/", table.concat(first, " "))
  assert(first[8]:match("/rex%-teams$"), first[8])
  assert(second[9] == ":/tmp/rex-teams/" and second[8]:match("/inbox$"), table.concat(second, " "))
  assert(#pasted == 1)
end)
check("the stage is removed on success and on failure", function()
  assert(run({ host = "ws", block = "Builder", message = "see", file = "a.md" }))
  deliver()
  local _, id = copied()
  assert(not exists(root .. "/stage/" .. id), "stage left after success")
  reset()
  cp_result = { ok = false, code = 1, stdout = "", stderr = "nope" }
  undelivered({ host = "ws", block = "Builder", message = "see", file = "a.md" }, "nope")
  local _, id2 = copied()
  assert(not exists(root .. "/stage/" .. id2), "stage left after failure")
end)
check("messages with files go to the receiver's pane, here and in another session", function()
  for _, to in ipairs({ { "Helper", "session:me", "block:peer-0000-bbbb" }, { "Other", "session:else", "block:else-0000-dddd" } }) do
    reset()
    assert(run({ block = to[1], message = "see", file = "a.md" }))
    deliver()
    landed_in("local", to[2], to[3])
  end
end)
check("symlinks named in file= go as their targets; links inside a folder stay links", function()
  assert(run({ host = "ws", block = "Builder", message = "see", file = { "link.md", "linkdir" } }))
  deliver()
  local _, id = copied()
  local box = "./" .. id .. "/inbox/far-0000-cccc/" .. id
  assert(rex_cps[1].links == box .. "/linkdir/sub/inner", "staged links:\n" .. rex_cps[1].links)
  assert(has(rex_cps[1].tree, box .. "/link.md\n") and has(rex_cps[1].tree, box .. "/linkdir/sub/c.txt"), rex_cps[1].tree)
  assert(has(text(), "/" .. id .. "/link.md, "), text())
end)
check("a path through a file: error, nothing copied or sent", function()
  for _, host in ipairs({ false, "ws" }) do
    reset()
    fails({ host = host or nil, block = host and "Builder" or "Helper", message = "see", file = "a.md/nope" }, "a.md/nope: missing")
    assert(rexes() == 0 and not exists(root .. "/outbox"))
  end
end)
check("two files with one name: error, nothing copied or sent", function()
  fails({ host = "ws", block = "Builder", message = "see", file = { "a.md", "dir/../a.md" } }, "two files are named a.md")
  assert(rexes() == 0 and not exists(root .. "/outbox"))
end)
check("a Windows sender can't send files to another host", function()
  fails({ host = "ws", block = "Builder", message = "see", file = "a.md" }, "doesn't work from Windows yet", true)
  assert(rexes() == 0)
end)
check("Windows without TEMP: lib.lua stops with an error", function()
  local real_config = package.config
  package.config = "\\" .. real_config:sub(2)
  os.getenv = function(k) if k == "TEMP" then return nil end return real_getenv(k) end
  local ok, err = pcall(real_dofile, "skills/rex-teams/scripts/lib.lua")
  os.getenv = function(k) if k == "TEMP" then return "C:\\T" end return real_getenv(k) end
  local ok2, lib = pcall(real_dofile, "skills/rex-teams/scripts/lib.lua")
  package.config, os.getenv = real_config, real_getenv
  assert(not ok and has(tostring(err), "TEMP"), tostring(err))
  assert(ok2 and lib.root == "C:\\T\\rex-teams", tostring(lib))
end)
check("a file that can't be read: error, nothing copied or sent", function()
  for _, host in ipairs({ false, "ws" }) do
    reset()
    fails({ host = host or nil, block = host and "Builder" or "Helper", message = "see", file = { "a.md", locked } }, "locked.md: missing")
    assert(rexes() == 0 and not exists(root .. "/outbox"))
  end
end)
check("a file gone by delivery: the sender is told, no rex cp, nothing sent", function()
  sh("cp " .. quote(src .. "/a.md") .. " " .. quote(src .. "/later.md"))
  assert(run({ host = "ws", block = "Builder", message = "see", file = "later.md" }))
  sh("rm " .. quote(src .. "/later.md"))
  local notice = deliver()
  assert(notice and has(notice, "can't copy the files"), tostring(notice))
  assert(#pasted == 0 and rexes() == 0 and tree(root .. "/stage") == ".", "rex cp ran, a paste went or the stage was left")
end)
check("/tmp/rex-teams on the receiver not a folder or denied: the sender is told, no rex cp, nothing sent", function()
  for _, status in ipairs({ "not_dir", "denied" }) do
    reset()
    remote_root = status
    undelivered({ host = "ws", block = "Builder", message = "see", file = "a.md" }, "/tmp/rex-teams on ws: " .. status)
    assert(rexes() == 0 and tree(root .. "/stage") == ".", "rex cp ran or the stage was left")
  end
end)
check("a path with a line break: error, nothing copied or sent", function()
  for _, host in ipairs({ false, "ws" }) do
    reset()
    fails({ host = host or nil, block = host and "Builder" or "Helper", message = "see", file = broken }, "a line break")
    assert(rexes() == 0 and not exists(root .. "/outbox"))
  end
end)
check("file=/ to another host: a clear error, nothing copied or sent", function()
  fails({ host = "ws", block = "Builder", message = "see", file = "/" }, "file /: can't send the root folder")
  assert(rexes() == 0 and not exists(root .. "/outbox"))
end)
sh("chmod 600 " .. quote(src .. "/" .. locked))
sh("rm -rf " .. quote(tmp))
if failed > 0 then
  print("Failed " .. failed .. " of " .. count .. " file trials.")
  os.exit(1)
end
print("Passed " .. count .. " file trials.")
