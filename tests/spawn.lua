-- Run from the repo root with `luajit tests/spawn.lua` or `lua5.1 tests/spawn.lua`.
-- The mock child reads its assignment inside session.new_window, before it returns.
local real_dofile, real_open = dofile, io.open
local root = os.tmpname()
os.remove(root)
rex = { layout = { block = function(value) return value end } }
local lib = real_dofile("skills/rex-teams/scripts/lib.lua")
lib.root = root
lib.me = function() return "session:parent", "block:parent" end
lib.mkdir = function() end
lib.worktree = function() end
lib.read = function(path)
  if path == "task.md" then return "Complete mock task.\nFinal task instruction." end
  local f = assert(real_open(path))
  local value = f:read("*a")
  assert(f:close())
  return value
end
lib.path = function(...)
  local parts = {...}
  return root .. "-" .. parts[#parts]
end
local launches, prompt_closed, close_path = 0, false
local nesting, depth_arg = "You can't start subagents."
rex.call = function(method, args)
  if method == "session.attach" then return {} end
  if method == "session.view" then return { windows = {} } end
  if method == "block.method" then return { status = "ok", path = "/checkout" } end
  if method == "session.new_window" then
    launches = launches + 1
    local kickoff = args.layout.options.command[2]
    -- A subagent acts on its kickoff before it reads any skill, so the rule must be there.
    assert(kickoff:find("Don't rename the Rex session or your tab, even when Rex asks you to name your session.", 1, true), "the kickoff must carry the don't-rename rule: " .. kickoff)
    local path = assert(kickoff:match("Read (.-) and follow it%."))
    local prompt = lib.read(path)
    assert(prompt_closed, "prompt must be closed before launch")
    assert(prompt:find("Complete mock task.\nFinal task instruction.", 1, true))
    assert(prompt:find("Work in `/checkout`.", 1, true))
    assert(prompt:find("STATUS: completed", 1, true))
    assert(prompt:find(nesting, 1, true), "the prompt must say: " .. nesting)
    assert(prompt:find("send.lua' block='block:parent' message=", 1, true))
    assert(not prompt:find("session=", 1, true))
    close_path = assert(prompt:match("run the close command in ([^ ]+close%.md)"), "notice must point to parent-owned close instructions")
    assert(not prompt:find("CHILD_BLOCK", 1, true))
    assert(not prompt:find("REX_BLOCK", 1, true))
    assert(not real_open(close_path), "window metadata must be written after new_window returns")
    assert(prompt:find("Don't notify the parent with progress updates.", 1, true))
    assert(not prompt:match("{%w+}"))
    return { window_id = "window:child", block_ids = { "block:child" } }
  end
  error("unexpected call: " .. method)
end
dofile = function(path)
  if path:match("/lib%.lua$") then return lib end
  return real_dofile(path)
end
local function run(failure)
  os.remove(root .. "-prompt.md")
  prompt_closed = false
  io.open = function(path, mode)
    if failure == "close.md" and path == root .. "-close.md" and mode == "w" then return nil, "injected close.md failure" end
    if path ~= root .. "-prompt.md" or mode ~= "w" then return real_open(path, mode) end
    if failure == "open" then return nil, "injected open failure" end
    local file = assert(real_open(path, mode))
    return {
      write = function(_, value)
        if failure == "write" then
          file:write(value:sub(1, 5))
          file:close()
          return nil, "injected write failure"
        end
        return file:write(value)
      end,
      close = function()
        assert(file:close())
        if failure == "close" then return nil, "injected close failure" end
        prompt_closed = true
        return true
      end,
    }
  end
  rex.args = { name = "test", cwd = "/checkout", task = "task.md", command = "mock-agent {prompt}", depth = depth_arg }
  local saved_print = print
  print = function() end
  local ok, err = pcall(real_dofile, "skills/rex-teams/scripts/spawn.lua")
  print, io.open = saved_print, real_open
  return ok, err
end
local ok, err = run()
assert(ok, err)
assert(launches == 1)
assert(lib.read(close_path) == "rex window close -s session:parent window:child\n")
print("ok 1 - child reads complete closed assignment at launch")
for i, failure in ipairs({ "open", "write", "close" }) do
  local before = launches
  local succeeded, message = run(failure)
  assert(not succeeded and tostring(message):find("injected " .. failure .. " failure", 1, true), tostring(message))
  assert(launches == before, failure .. " failure must prevent launch")
  print("ok " .. (i + 1) .. " - prompt " .. failure .. " failure prevents launch")
end
assert(os.remove(close_path))
os.remove(root .. "-child")
local succeeded, message = run("close.md")
assert(not succeeded and tostring(message):find("injected close.md failure", 1, true), tostring(message))
local depth = assert(real_open(root .. "-child"), "depth file must exist once the child launched")
assert(depth:close())
print("ok 5 - close.md failure leaves the depth file in place")
assert(os.remove(root .. "-child"))

-- A subagent's own depth file limits how deep its subagents may go.
local function child_depth()
  local f = assert(real_open(root .. "-child"), "the child's depth file is missing")
  local value = f:read("*l")
  assert(f:close())
  return value
end
local function allow(levels)
  local f = assert(real_open(root .. "-parent", "w"))
  assert(f:write(levels .. "\n"))
  assert(f:close())
end
allow(2)
depth_arg, nesting = 5, "up to 1 level(s) below you"
ok, err = run()
assert(ok, err)
assert(child_depth() == "1", "a parent allowed 2 levels gives its child at most 1, not " .. child_depth())
assert(os.remove(root .. "-child"))
assert(os.remove(root .. "-close.md"))
print("ok 6 - a subagent's subagents get at most one level less than it was allowed")
allow(0)
depth_arg, nesting = nil, "You can't start subagents."
local before = launches
succeeded, message = run()
assert(not succeeded, "a subagent allowed no levels started one")
assert(tostring(message):find("didn't allow you to start subagents", 1, true), tostring(message))
assert(launches == before, "a subagent allowed no levels must not launch one")
assert(not real_open(root .. "-child"), "no depth file without a launch")
print("ok 7 - a subagent allowed no levels can't start one")
assert(os.remove(root .. "-parent"))
assert(not real_open(root .. "-prompt.md"), "no prompt without a launch")
print("Passed 7 spawn publication trials.")

-- Ten mock trials: the common ways a parent uses spawn, against a fake
-- session. Each returns what spawn printed and the calls it made.
local function spawn(args, opts)
  opts = opts or {}
  local calls, out = {}, {}
  lib.worktree = function() return opts.worktree end
  rex.call = function(method, call)
    calls[#calls + 1] = { method = method, args = call }
    if method == "session.attach" then return {} end
    if method == "session.view" then return { windows = opts.windows or {} } end
    if method == "block.method" then return { status = "ok", path = "/checkout" } end
    if method == "session.new_window" then return { window_id = "window:new", block_ids = { "block:new" } } end
    if method == "session.move_window" then return {} end
    error("unexpected call: " .. method)
  end
  rex.args = args
  local saved_print = print
  print = function(line) out[#out + 1] = line end
  local ok, err = pcall(real_dofile, "skills/rex-teams/scripts/spawn.lua")
  print = saved_print
  assert(ok, err)
  for _, name in ipairs({ "-prompt.md", "-close.md", "-new" }) do os.remove(root .. name) end
  local by = {}
  for _, c in ipairs(calls) do by[c.method] = c.args end
  return table.concat(out, "\n") .. "\n", by
end
local base = { name = "docs", cwd = "/checkout", task = "task.md", command = "claude {prompt}" }
local function with(extra)
  local t = {}
  for k, v in pairs(base) do t[k] = v end
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end
local trials = 0
local function trial(name, fn)
  trials = trials + 1
  fn()
  print("ok " .. trials .. " - " .. name)
end

trial("the task id is <name>-<lib.id()>, and the folder is named after it", function()
  local out = spawn(base)
  local id = assert(out:match("task: (%S+)\n"), out)
  assert(id:match("^docs%-%d+%-%l%l%l%l$"), "task id isn't <name>-<lib.id()>: " .. id)
  assert(out:find("folder: " .. root .. "-" .. id .. "\n", 1, true), out)
end)
trial("two spawns with the same name get different task ids", function()
  local a = spawn(base):match("task: (%S+)")
  local b = spawn(base):match("task: (%S+)")
  assert(a ~= b, "both got " .. a)
end)
trial("spawn prints no tab: line, and message it: targets the new block", function()
  local out = spawn(base)
  assert(not out:find("tab:", 1, true), out)
  assert(out:find("message it: " .. lib.send_command("block:new", "MESSAGE") .. "\n", 1, true), out)
end)
trial("{prompt} puts the kickoff where the CLI takes it", function()
  local _, by = spawn(with({ command = "codex -i {prompt} --yolo" }))
  local argv = by["session.new_window"].layout.options.command
  assert(argv[1] == "codex" and argv[2] == "-i" and argv[3]:find("^You are a subagent%.") and argv[4] == "--yolo", table.concat(argv, " | "))
end)
trial("without {prompt}, the kickoff goes last", function()
  local _, by = spawn(with({ command = "pi --model x" }))
  local argv = by["session.new_window"].layout.options.command
  assert(#argv == 4 and argv[4]:find("^You are a subagent%."), table.concat(argv, " | "))
end)
trial("the tab opens in the background, labelled with the name, in the resolved cwd", function()
  local _, by = spawn(base)
  local w = by["session.new_window"]
  assert(w.focus == false and w.window_label == "\226\128\139↳ docs", w.window_label)
  assert(w.layout.options.cwd == "/checkout")
end)
trial("a worktree adds (w) and prints its branch and path", function()
  local out, by = spawn(base, { worktree = { path = "/wt", branch = "feat/x" } })
  assert(by["session.new_window"].window_label:find("↳ docs (w)", 1, true))
  assert(out:find("branch: feat/x\n", 1, true) and out:find("worktree: /wt\n", 1, true), out)
end)
trial("the tab moves after the parent and the subagents already under it", function()
  local windows = {
    { window_id = "window:parent", label = "pm", layers = { { blocks = { { block_id = "block:parent" } } } } },
    { window_id = "window:kid", label = "\226\128\139↳ kid", layers = { { blocks = {} } } },
    { window_id = "window:other", label = "eng", layers = { { blocks = {} } } },
  }
  local _, by = spawn(base, { windows = windows })
  assert(by["session.move_window"] and by["session.move_window"].before_window_id == "window:other")
end)
trial("a subagent's subagent is indented one level more", function()
  local windows = {
    { window_id = "window:parent", label = "\226\128\139↳ lead", layers = { { blocks = { { block_id = "block:parent" } } } } },
  }
  local _, by = spawn(base, { windows = windows })
  assert(by["session.new_window"].window_label == "\226\128\139    ↳ docs", by["session.new_window"].window_label)
  assert(not by["session.move_window"], "a last tab has nothing to move before")
end)
trial("close.md closes exactly the new tab", function()
  local written = {}
  local saved = lib.write
  lib.write = function(path, value) written[path] = value return saved(path, value) end
  spawn(base)
  lib.write = saved
  assert(written[root .. "-close.md"] == "rex window close -s session:parent window:new\n", tostring(written[root .. "-close.md"]))
end)
dofile = real_dofile
print("Passed " .. trials .. " spawn mock trials.")
