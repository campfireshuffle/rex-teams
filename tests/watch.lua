-- Run with lua5.1 tests/watch.lua, or rex do tests/watch.lua from the repo root.
local original_rex, original_dofile = rex, dofile
local stop = {}
local passed = {}
local function scenario(name, setup, exercise, expected)
  local result, ready = os.tmpname(), os.tmpname()
  os.remove(result)
  os.remove(ready)
  local state = { exits = false, present = { child = true, parent = true }, messages = {}, timers = {}, handlers = {} }
  if setup then setup(state, result) end
  local function invoke(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and err ~= stop then error(name .. ": " .. tostring(err), 0) end
    return ok
  end
  rex = {
    args = { session = "session", child = "child", parent = "parent", result = result, ready = ready, task = "test" },
    stop = function() state.stopped = true; error(stop, 0) end,
    on = function(event, fn) state.handlers[event] = fn end,
    after = function(_, fn) state.timers[#state.timers + 1] = fn; return {} end,
  }
  dofile = function(path)
    assert(path:match("lib.lua$"))
    return {
      rule = "Don't rename the Rex session or your tab.",
      attach = function() end,
      write = function(path, text)
        local f = assert(io.open(path, "w")); f:write(text); f:close()
      end,
      call = function(method)
        if state.api_error then error("connection lost", 0) end
        if method == "session.list_blocks" then
          local blocks = {}
          for id, present in pairs(state.present) do if present then blocks[#blocks + 1] = { block_id = id } end end
          return { blocks = blocks }
        end
        assert(method == "block.method")
        return { last_exit = state.exits and { exit_code = 0 } or nil }
      end,
      paste_line = function(_, _, message)
        state.messages[#state.messages + 1] = message
        if state.send_error then error("uncertain write", 0) end
      end,
    }
  end
  invoke(original_dofile, "skills/rex-teams/scripts/watch.lua")
  assert(io.open(ready)):close()
  state.event = function(event, id, session)
    if not state.stopped then invoke(state.handlers[event], { session_id = session or "session", block_id = id }, { block_id = id }) end
  end
  state.fire = function()
    local timers = state.timers
    state.timers = {}
    for _, fn in ipairs(timers) do if not state.stopped then invoke(fn) end end
  end
  exercise(state, result)
  assert(#state.messages == expected, name .. ": expected " .. expected .. " notices, got " .. #state.messages)
  os.remove(result)
  os.remove(ready)
  passed[#passed + 1] = name
  print("ok " .. name)
end

scenario("immediate exit plus duplicate event", function(s) s.exits = true end, function(s)
  s.event("terminal.child_exited", "child")
  s.event("terminal.child_exited", "child")
  assert(#s.timers == 1)
  s.fire()
end, 1)
scenario("exit after subscription", nil, function(s)
  s.exits = true
  s.event("terminal.child_exited", "child")
  s.fire()
end, 1)
scenario("unrelated child and session", nil, function(s)
  s.event("terminal.child_exited", "other")
  s.event("terminal.child_exited", "child", "other-session")
  assert(#s.timers == 0)
end, 0)
scenario("manual closure beats pending exit", nil, function(s)
  s.exits = true
  s.event("terminal.child_exited", "child")
  s.event("block_closed", "child")
  s.fire()
end, 0)
scenario("closure found by snapshot", function(s) s.exits = true end, function(s)
  s.present.child = false
  s.fire()
end, 0)
scenario("parent gone", function(s) s.exits = true end, function(s)
  s.present.parent = false
  s.fire()
end, 0)
scenario("parent closure", nil, function(s)
  s.event("block_closed", "parent")
  assert(s.stopped)
end, 0)
for _, target in ipairs({ "child", "parent" }) do
  scenario(target .. " closed before subscription", function(s) s.present[target] = false end, function(s)
    assert(s.stopped)
  end, 0)
end
for _, status in ipairs({ "completed", "failed", "blocked" }) do
  scenario("follow-up exit after " .. status .. " report", function(s, path)
    local f = assert(io.open(path, "w")); f:write("STATUS: " .. status .. "\nReport\n"); f:close()
  end, function(s)
    assert(#s.timers == 0 and not s.stopped)
    s.exits = true
    s.event("terminal.child_exited", "child")
    s.fire()
    assert(s.messages[1]:find("may be absent or stale", 1, true))
  end, 1)
end
scenario("event without confirmed process exit", nil, function(s)
  s.event("terminal.child_exited", "child")
  s.fire()
end, 0)
scenario("connection failure is not a crash", function(s) s.exits = true end, function(s)
  s.api_error = true
  local ok, err = pcall(s.fire)
  assert(not ok and tostring(err):find("connection lost", 1, true))
end, 0)
scenario("ambiguous send is not retried", function(s) s.exits = true end, function(s)
  s.send_error = true
  local ok, err = pcall(s.fire)
  assert(not ok and tostring(err):find("uncertain write", 1, true))
  s.event("terminal.child_exited", "child")
  assert(#s.timers == 0)
end, 1)
rex, dofile = original_rex, original_dofile
assert(#passed == 15)
print(#passed .. " watchdog scenarios passed")
