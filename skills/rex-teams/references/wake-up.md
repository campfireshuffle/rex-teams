# Wake an agent later

Use Rex's timers, not an agent sleeping in a tool call. No scheduler installation
is needed. This recipe runs in its own background tab and uses the same terminal
input as `send.lua`; it does not protect drafts or approval prompts.

Write this to a temporary `wake.lua` on the Rex host. Replace `<skill>` with the
absolute path to this skill:

```lua
local lib = dofile("<skill>/scripts/lib.lua")
local args = rex.args
assert(type(args.seconds) == "number" and args.seconds > 0, "seconds must be positive")
assert(args.session and args.block, "session and block are required")
assert(type(args.message) == "string" and not args.message:find("[\r\n]"), "message must be one line")
lib.call("session.attach", { session_id = args.session })
rex.on("block_closed", function(ctx, ev)
  if ctx.session_id == args.session and ev.block_id == args.block then rex.stop() end
end)
local exists = false
for _, block in ipairs(lib.call("session.list_blocks", { session_id = args.session }).blocks or {}) do
  if block.block_id == args.block then exists = true end
end
if not exists then rex.stop() end
rex.after(args.seconds, function()
  lib.type_line(args.session, args.block, "[scheduled wake-up] " .. args.message)
  rex.stop()
end)
print("Wake-up armed")
```

Start it in a background tab, supplying the **target agent's** session and block
IDs. Use your current IDs to wake yourself:

```sh
rex run -s <session ID> --label wake-up --focus=false --json -- rex do -s <session ID> --fail-fast /absolute/path/wake.lua session=<session ID> block=<target block ID> seconds=1200 message="Check the deployment"
```

Save the returned timer block ID. Capture that block once to confirm it printed
`Wake-up armed`, then **end your turn**. Don't wait for the timer or poll it.
The timer sends the message after 20 minutes and its tab closes on success.
If the timer fails, inspect its terminal instead of blindly scheduling another.

Cancel it with `rex block close -s <session ID> <timer block ID>`. The ordinary
`rex block ls` command lists timer panes along with other panes.

For a recurring wake-up, replace `rex.after` with `rex.every` and remove the
`rex.stop()` inside the timer callback. Keep the stop in the closure handler.
Cancel the timer when the work is finished. Recurring messages can accumulate if
the harness queues them while busy; this recipe does not track consumption.

The server, session, target, and timer process must stay alive. There is no
restart recovery, calendar scheduling, or machine wake-from-sleep. The Lua file
and skill must exist on the host running the timer. Don't change this shared
file while an active timer is starting.
