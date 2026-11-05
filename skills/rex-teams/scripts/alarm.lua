-- Run in a background Rex tab; session/block identify the agent to wake,
-- not the alarm's own pane. seconds is the delay or recurring interval.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
local args = rex.args
assert(type(args.seconds) == "number" and args.seconds > 0, "seconds must be positive")
assert(args.session and args.block, "session and block are required")
assert(args.recurring == nil or type(args.recurring) == "boolean", "recurring must be true or false")
assert(type(args.message) == "string" and not args.message:find("[\r\n]"), "message must be one line")
lib.attach(args.session)
rex.on("block_closed", function(ctx, ev)
  if ctx.session_id == args.session and ev.block_id == args.block then rex.stop() end
end)
-- Check after subscribing so target closure during startup isn't missed.
local exists = false
for _, block in ipairs(lib.call("session.list_blocks", { session_id = args.session }).blocks or {}) do
  if block.block_id == args.block then exists = true end
end
if not exists then rex.stop() end
local schedule = args.recurring and rex.every or rex.after
schedule(args.seconds, function()
  lib.paste_line(args.session, args.block, "[alarm] " .. lib.rule .. " " .. args.message)
  if not args.recurring then rex.stop() end
end)
print("Alarm armed")
