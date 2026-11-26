-- Run from the repo root with `luajit tests/files.lua` or `lua5.1 tests/files.lua`.
-- send.lua file=: mocks rex.call and the `rex` command, and runs mkdir, cp
-- and rm for real in a scratch folder, so the stage can be checked on disk.
local real_dofile, real_getenv = dofile, os.getenv
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

local calls, pasted, execs, rex_cps, remote_root, cp_result

-- What the stage held when `rex cp` ran, relative to the stage folder.
local function tree(dir)
  local p = io.popen("cd " .. quote(dir) .. " && find . | LC_ALL=C sort")
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
    if method == "block.method" then
      assert(args.method == "list_dir")
      return list_dir(args.block_id, args.args.path)
    end
    if method == "block.event" then
      if args.event.type == "paste" then pasted[#pasted + 1] = { server = name, text = args.event.payload.text } end
      return {}
    end
    error("unexpected call: " .. method)
  end
  return s
end

-- The caller's terminal sits in SRC, like Rex's list_dir resolving a path.
local function local_dir(block, path)
  assert(block == "block:me-0000-aaaa", "list_dir must ask the caller's terminal")
  local p = path:sub(1, 1) == "/" and path or src .. "/" .. path
  p = p:gsub("/+$", "")
  if os.execute("test -d " .. quote(p)) == 0 then return { status = "ok", path = p } end
  if exists(p) then return { status = "not_dir", path = p } end
  return { status = "missing", path = p }
end

local function remote_dir(block, path)
  assert(path == "/tmp/rex-teams" and block == "block:far-0000-cccc", path)
  return { status = remote_root, path = path }
end

local function reset()
  calls, pasted, execs, rex_cps = {}, {}, {}, {}
  remote_root, cp_result = "ok", { ok = true, code = 0, stdout = "", stderr = "" }
  sh("rm -rf " .. quote(root))
  local servers = {
    [""] = server("local", {
      { id = "block:me-0000-aaaa", label = "Chief", session = "session:me" },
      { id = "block:peer-0000-bbbb", label = "Helper", session = "session:me" },
    }, local_dir),
    ws = server("ws", { { id = "block:far-0000-cccc", label = "Builder", session = "session:far" } }, remote_dir),
  }
  rex = {
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
        rex_cps[#rex_cps + 1] = { argv = argv, tree = tree(root .. "/outbox") }
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

local function run(args)
  rex.args = args
  local lib = real_dofile("skills/rex-teams/scripts/lib.lua")
  lib.root = root
  lib.me = function() return "session:me", "block:me-0000-aaaa" end
  dofile = function(path)
    if path:match("/lib%.lua$") then return lib end
    return real_dofile(path)
  end
  local ok, err = pcall(real_dofile, "skills/rex-teams/scripts/send.lua")
  dofile = real_dofile
  return ok, err
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
local function fails(args, want)
  local ok, err = run(args)
  assert(not ok and has(tostring(err), want), tostring(err))
  assert(#pasted == 0, "a failed send still pasted")
end
local function rexes()
  local n = 0
  for _, argv in ipairs(execs) do if argv[1] == "rex" then n = n + 1 end end
  return n
end
-- The message id in the one rex cp, and the stage it came from.
local function copied()
  assert(#rex_cps == 1, "want one rex cp, got " .. #rex_cps)
  local argv = rex_cps[1].argv
  local id = assert(argv[8]:match("/outbox/(%d+%-%a%a%a%a)/inbox$"), argv[8])
  return argv, id
end

check("same host: no copy, absolute paths, no delete note", function()
  assert(run({ block = "Helper", message = "see", file = { "a.md", src .. "/dir" } }))
  assert(#execs == 0, "same host ran " .. tostring(execs[1] and execs[1][1]))
  local want = "] see [files: " .. src .. "/a.md, " .. src .. "/dir]"
  assert(text():sub(-#want) == want, text())
  assert(not has(text(), "delete"))
end)
check("same host: a single file= string", function()
  assert(run({ block = "Helper", message = "see", file = "b.md" }))
  assert(has(text(), "] see [files: " .. src .. "/b.md]"), text())
end)
check("cross-host: one rex cp with host, session, -r, the stage and :/tmp/rex-teams/", function()
  assert(run({ host = "ws", block = "Builder", message = "see", file = "a.md" }))
  local argv, id = copied()
  local stage = root .. "/outbox/" .. id
  local want = { "rex", "-S", "ws", "cp", "-s", "session:far", "-r", stage .. "/inbox", ":/tmp/rex-teams/" }
  assert(#argv == #want, table.concat(argv, " "))
  for i, w in ipairs(want) do assert(argv[i] == w, i .. ": " .. tostring(argv[i])) end
  assert(rex_cps[1].tree == table.concat({ ".", "./" .. id, "./" .. id .. "/inbox", "./" .. id .. "/inbox/far-0000-cccc",
    "./" .. id .. "/inbox/far-0000-cccc/" .. id, "./" .. id .. "/inbox/far-0000-cccc/" .. id .. "/a.md" }, "\n"), rex_cps[1].tree)
  local folder = "/tmp/rex-teams/inbox/far-0000-cccc/" .. id
  assert(pasted[1].server == "ws")
  local suffix = "] see [files: " .. folder .. "/a.md; delete " .. folder .. " when done]"
  assert(text():sub(-#suffix) == suffix, text())
end)
check("cross-host: a list of files and a directory", function()
  assert(run({ host = "ws", block = "Builder", message = "see", file = { "a.md", "b.md", "dir/" } }))
  local _, id = copied()
  local stage_box = "./" .. id .. "/inbox/far-0000-cccc/" .. id
  for _, p in ipairs({ "/a.md", "/b.md", "/dir", "/dir/sub", "/dir/sub/c.txt" }) do
    assert(has(rex_cps[1].tree, stage_box .. p .. "\n") or rex_cps[1].tree:sub(-#(stage_box .. p)) == stage_box .. p, p .. " missing:\n" .. rex_cps[1].tree)
  end
  local folder = "/tmp/rex-teams/inbox/far-0000-cccc/" .. id
  assert(has(text(), "[files: " .. folder .. "/a.md, " .. folder .. "/b.md, " .. folder .. "/dir; delete " .. folder .. " when done]"), text())
end)
check("odd names: spaces, quotes and unicode arrive as one word each", function()
  assert(run({ host = "ws", block = "Builder", message = "see", file = odd }))
  local _, id = copied()
  assert(has(rex_cps[1].tree, "/" .. id .. "/" .. odd), rex_cps[1].tree)
  for _, argv in ipairs(execs) do
    if argv[1] == "cp" then assert(argv[#argv - 1] == src .. "/" .. odd, argv[#argv - 1]) end
  end
  assert(has(text(), "/" .. id .. "/" .. odd .. "; delete"), text())
end)
check("a missing local file: error, nothing copied or sent", function()
  for _, host in ipairs({ false, "ws" }) do
    reset()
    fails({ host = host or nil, block = host and "Builder" or "Helper", message = "see", file = { "a.md", "gone.md" } }, "gone.md")
    assert(rexes() == 0 and not exists(root .. "/outbox"))
  end
end)
check("rex cp exit 3 and 4: clear errors, nothing pasted", function()
  for code, want in pairs({ [3] = "has no rex cp", [4] = "can't reach" }) do
    reset()
    cp_result = { ok = false, code = code, stdout = "", stderr = "boom " .. code }
    fails({ host = "ws", block = "Builder", message = "see", file = "a.md" }, want)
    local _, err = run({ host = "ws", block = "Builder", message = "see", file = "a.md" })
    assert(has(err, "boom " .. code) and has(err, "exit " .. code), err)
  end
end)
check("/tmp/rex-teams missing on the receiver: created first", function()
  remote_root = "missing"
  assert(run({ host = "ws", block = "Builder", message = "see", file = "a.md" }))
  assert(#rex_cps == 2, "want two rex cp, got " .. #rex_cps)
  local first, second = rex_cps[1].argv, rex_cps[2].argv
  assert(first[3] == "ws" and first[6] == "session:far" and first[9] == ":/tmp/", table.concat(first, " "))
  assert(first[8]:match("/rex%-teams$"), first[8])
  assert(second[9] == ":/tmp/rex-teams/" and second[8]:match("/inbox$"), table.concat(second, " "))
  assert(#pasted == 1)
end)
check("the stage is removed on success and on failure", function()
  assert(run({ host = "ws", block = "Builder", message = "see", file = "a.md" }))
  local _, id = copied()
  assert(not exists(root .. "/outbox/" .. id), "stage left after success")
  reset()
  cp_result = { ok = false, code = 1, stdout = "", stderr = "nope" }
  fails({ host = "ws", block = "Builder", message = "see", file = "a.md" }, "nope")
  local _, id2 = copied()
  assert(not exists(root .. "/outbox/" .. id2), "stage left after failure")
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
sh("rm -rf " .. quote(tmp))
if failed > 0 then
  print("Failed " .. failed .. " of " .. count .. " file trials.")
  os.exit(1)
end
print("Passed " .. count .. " file trials.")
