-- Run from the repo root with `lua5.1 tests/worktrees.lua` or `rex do tests/worktrees.lua`.
-- Rex calls are mocked; Git fixtures are real and never touch the user's checkout.
local native_exec = rex and rex.exec
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function read(path)
  local f = assert(io.open(path))
  local value = f:read("*a")
  f:close()
  return value
end
local function exec(argv, opts)
  if native_exec then return native_exec(argv, opts) end
  local words = { "env" }
  for key, value in pairs(opts and opts.env or {}) do
    assert(value == false)
    words[#words + 1] = "-u"
    words[#words + 1] = quote(key)
  end
  for _, word in ipairs(argv) do words[#words + 1] = quote(word) end
  local out, err = os.tmpname(), os.tmpname()
  local status = os.execute(table.concat(words, " ") .. " >" .. quote(out) .. " 2>" .. quote(err))
  local result = { ok = status == 0, code = status / 256, stdout = read(out), stderr = read(err) }
  os.remove(out)
  os.remove(err)
  return result
end
local function command(...)
  local r = assert(exec({...}))
  assert(r.ok, r.stderr)
  return r.stdout:gsub("[\r\n]+$", "")
end
local root = command("mktemp", "-d", "/tmp/rex-teams-trials.XXXXXX")
local repo, linked = root .. "/main repo", root .. "/linked tree"
local function git(cwd, ...)
  return command("git", "-C", cwd, ...)
end
command("git", "init", "-q", "-b", "main", repo)
git(repo, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-q", "--allow-empty", "-m", "fixture")
git(repo, "worktree", "add", "-q", "-b", "agents/fix-auth", linked)
command("mkdir", "-p", linked .. "/nested folder")
local canonical = git(linked, "rev-parse", "--show-toplevel")

rex = { exec = exec }
local lib = dofile("skills/rex-teams/scripts/lib.lua")
lib.root = root .. "/state"
lib.me = function() return "session:test", "block:parent" end
local count = 0
local function check(name, fn)
  fn()
  count = count + 1
  print("ok " .. count .. " - " .. name)
end
check("main checkout and non-repository have no worktree marker", function()
  assert(not lib.worktree(repo))
  assert(not lib.worktree(root))
end)
check("linked root and nested cwd with spaces", function()
  for _, path in ipairs({ linked, linked .. "/nested folder" }) do
    local w = assert(lib.worktree(path))
    assert(w.path == canonical and w.branch == "agents/fix-auth")
  end
end)
check("worktree probes explicitly clear inherited Git selectors", function()
  local probes = {}
  rex.exec = function(argv, opts)
    local env = opts and opts.env or {}
    for _, key in ipairs({ "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR" }) do
      assert(env[key] == false, "worktree probe must remove " .. key)
    end
    probes[argv[4]] = true
    return exec(argv, opts)
  end
  local w = assert(lib.worktree(linked .. "/nested folder"))
  rex.exec = exec
  assert(w.path == canonical and w.branch == "agents/fix-auth")
  assert(probes["rev-parse"] and probes["symbolic-ref"])
end)
check("separate git-dir is not a linked worktree", function()
  local separate = root .. "/separate"
  command("git", "init", "-q", "--separate-git-dir", root .. "/git data", separate)
  assert(not lib.worktree(separate))
end)
check("submodule is not a linked worktree", function()
  git(repo, "-c", "protocol.file.allow=always", "submodule", "add", "-q", repo, "module")
  assert(not lib.worktree(repo .. "/module"))
end)
check("detached linked worktree is identified", function()
  git(linked, "checkout", "-q", "--detach")
  assert(lib.worktree(linked).branch == "detached HEAD")
  git(linked, "checkout", "-q", "agents/fix-auth")
end)
check("missing Git and failed probes do not claim isolation", function()
  rex.exec = function() return nil, "Git missing" end
  assert(not lib.worktree(linked))
  rex.exec = function() return { ok = false, code = 128 } end
  assert(not lib.worktree(linked))
  rex.exec = exec
end)
check("branch lookup failure is not called detached HEAD", function()
  rex.exec = function(argv, opts)
    if argv[4] == "symbolic-ref" then return { ok = false, code = 128 } end
    return exec(argv, opts)
  end
  assert(lib.worktree(linked).branch == "unknown")
  rex.exec = exec
end)

local marker = "\226\128\139"
local windows, processes, created, moves = {}, {}, {}, {}
rex.layout = { block = function(value) return value end }
rex.call = function(method, args)
  if method == "session.attach" then return {} end
  if method == "session.view" then return { windows = windows } end
  if method == "block.method" then
    if args.method == "list_dir" then return { status = "ok", path = args.args.path } end
    if args.method == "process" then return processes[args.block_id] end
  end
  if method == "session.new_window" then
    created[#created + 1] = args
    return { window_id = "window:child", block_ids = { "block:child" } }
  end
  if method == "session.move_window" then moves[#moves + 1] = args; return {} end
  error("unexpected Rex call: " .. method)
end
local function window(id, label, block)
  return { window_id = id, label = label, layers = {{ blocks = {{ block_id = block, label = "shell" }} }} }
end
local real_dofile = dofile
local function run(script)
  local output, real_print = {}, print
  print = function(line) output[#output + 1] = line end
  dofile = function(path)
    if path:match("/lib%.lua$") then return lib end
    return real_dofile(path)
  end
  local ok, err = pcall(real_dofile, "skills/rex-teams/scripts/" .. script)
  print, dofile = real_print, real_dofile
  assert(ok, err)
  return table.concat(output, "\n")
end
lib.mkdir(lib.root)
lib.write(root .. "/task.md", "Mock task: inspect the checkout without editing it.")
local function spawn(cwd)
  rex.args = { name = "fix-auth", cwd = cwd, task = root .. "/task.md", command = "mock-agent {prompt}" }
  return run("spawn.lua")
end
windows = { window("window:parent", "Parent", "block:parent"), window("window:other", "Other", "block:other") }
check("spawn marks linked worktree and prints branch/path", function()
  local output = spawn(linked .. "/nested folder")
  local args = created[#created]
  assert(args.window_label == marker .. "↳ fix-auth (w)")
  assert(args.focus == false and args.layout.options.cwd == linked .. "/nested folder")
  assert(output:find("branch: agents/fix-auth", 1, true))
  assert(output:find("worktree: " .. canonical, 1, true))
  assert(not output:find("task: fix-auth (w)", 1, true))
  assert(moves[#moves].before_window_id == "window:other")
  local prompt = read(output:match("folder: ([^\n]+)") .. "/prompt.md")
  assert(prompt:find("Work in `" .. linked .. "/nested folder`.", 1, true))
  assert(prompt:find("Branch at launch: agents/fix-auth", 1, true))
  assert(prompt:find("don't remove the worktree", 1, true))
  assert(prompt:find("STATUS: completed", 1, true))
  assert(prompt:find("You can't start subagents.", 1, true))
  assert(not prompt:match("{%w+}"))
end)
check("ordinary checkout spawn leaves tab and output uncluttered", function()
  local output = spawn(repo)
  assert(created[#created].window_label == marker .. "↳ fix-auth")
  assert(not output:find("branch:", 1, true))
end)
check("Git unavailable does not prevent spawning", function()
  rex.exec = function(argv, opts)
    if argv[1] == "git" then return nil, "not found" end
    return exec(argv, opts)
  end
  spawn(linked)
  assert(created[#created].window_label == marker .. "↳ fix-auth")
  rex.exec = exec
end)
check("nested marked parents preserve indent and sibling ordering", function()
  windows = {
    window("window:parent", marker .. "↳ parent (w)", "block:parent"),
    window("window:sibling", marker .. "    ↳ sibling (w)", "block:sibling"),
    window("window:other", "Other", "block:other"),
  }
  lib.write(lib.path("depth", "parent"), "1\n")
  spawn(linked)
  assert(created[#created].window_label == marker .. "    ↳ fix-auth (w)")
  assert(moves[#moves].before_window_id == "window:other")
end)
check("team reads current branch and skips unavailable/nonterminal processes", function()
  windows = {
    window("window:child", marker .. "↳ fix-auth (w)", "block:child"),
    window("window:other", "Other", "block:other"),
  }
  processes["block:child"] = { foreground = { cwd = linked .. "/nested folder" } }
  git(linked, "checkout", "-q", "-b", "agents/renamed")
  local output = run("team.lua")
  assert(output:find("branch: agents/renamed", 1, true))
  assert(output:find("worktree: " .. canonical, 1, true))
  assert(output:find("block=block:child", 1, true))
  assert(output:find("Other", 1, true))
  assert(lib.header("session:test", "block:child"):find("fix-auth (w)", 1, true))
end)
check("team does not use stale cwd from the launch label", function()
  processes["block:child"] = { foreground = { cwd = repo } }
  assert(not run("team.lua"):find("worktree:", 1, true))
  processes["block:child"] = { foreground = {} }
  assert(not run("team.lua"):find("worktree:", 1, true))
end)
command("rm", "-rf", root)
print("Passed " .. count .. " mock trials with real Git fixtures.")
