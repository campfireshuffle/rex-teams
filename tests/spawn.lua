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
rex.call = function(method, args)
  if method == "session.attach" then return {} end
  if method == "session.view" then return { windows = {} } end
  if method == "block.method" then return { status = "ok", path = "/checkout" } end
  if method == "session.new_window" then
    launches = launches + 1
    local kickoff = args.layout.options.command[2]
    local path = assert(kickoff:match("Read (.-) and follow it%."))
    local prompt = lib.read(path)
    assert(prompt_closed, "prompt must be closed before launch")
    assert(prompt:find("Complete mock task.\nFinal task instruction.", 1, true))
    assert(prompt:find("Work in `/checkout`.", 1, true))
    assert(prompt:find("STATUS: completed", 1, true))
    assert(prompt:find("You can't start subagents.", 1, true))
    assert(prompt:find("send.lua' block='block:parent' message=", 1, true))
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
  rex.args = { name = "test", cwd = "/checkout", task = "task.md", command = "mock-agent {prompt}" }
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
dofile = real_dofile
assert(os.remove(root .. "-prompt.md"))
assert(os.remove(root .. "-child"))
print("Passed 5 spawn publication trials.")
