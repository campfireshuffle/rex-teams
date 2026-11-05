-- Internal spawn watchdog. Observe the agent's process exit, not its
-- screen or OSC status. The retained child terminal covers exits before attach.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
local args = rex.args
local session, child, parent = args.session, args.child, args.parent
assert(session and child and parent and args.result and args.ready and args.task, "watch: missing spawn arguments")

local pending
local function inspect()
  local found = {}
  for _, block in ipairs(lib.call("session.list_blocks", { session_id = session }).blocks or {}) do
    found[block.block_id] = true
  end
  -- Closing a pane is cancellation, not a crash. Don't message a missing parent.
  if not found[child] or not found[parent] then return nil end
  return lib.call("block.method", { session_id = session, block_id = child, method = "process", args = {} })
end

local function reconcile()
  local process = inspect()
  if not process then rex.stop() end
  if not process.last_exit then return end

  -- No delivery retry: a failed terminal write may already have typed something.
  lib.paste_line(session, parent, "[watchdog " .. args.task .. "] " .. lib.rule .. " Subagent process exited. Check any outstanding work. Report path (may be absent or stale): "
    .. args.result .. ". Inspect its terminal: rex capture -s " .. session .. " -b " .. child
    .. ". This is an exit notice, not a crash diagnosis.")
  rex.stop()
end

local function check_later()
  if pending then return end
  -- Let a concurrent pane closure settle before inspecting the retained terminal.
  pending = rex.after(0.25, reconcile)
end

rex.on("terminal.child_exited", function(ctx)
  if ctx.session_id == session and ctx.block_id == child then check_later() end
end)
rex.on("block_closed", function(ctx, ev)
  if ctx.session_id == session and (ev.block_id == child or ev.block_id == parent) then rex.stop() end
end)

lib.attach(session)
-- Subscribe first, then inspect. An immediate exit is seen by either path;
-- both paths use the same timer so it can't produce two notices.
local process = inspect()
if process and process.last_exit then check_later() end
lib.write(args.ready, "ready\n")
if not process then rex.stop() end
