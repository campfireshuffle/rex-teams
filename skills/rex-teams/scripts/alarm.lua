-- Set an alarm: a message to an agent, at a time or repeating.
--
--   rex do <skill>/scripts/alarm.lua in=SECONDS message='MESSAGE' [block=BLOCK]
--   rex do <skill>/scripts/alarm.lua every=SECONDS message='MESSAGE' [block=BLOCK]
--   rex do <skill>/scripts/alarm.lua list=true
--
-- The target defaults to the calling agent. An alarm is a queued message
-- with a time; the postman delivers it, as it does every message, once the
-- agent's prompt box is free. A recurring alarm skips the ticks it misses.
-- Cancel one by deleting its file, which it prints.
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")
local lib = dofile(dir .. "lib.lua")
local mail = dofile(dir .. "mail.lua")
local a = rex.args

if a.list then
  local _, me = lib.me()
  for _, msg in ipairs(mail.list()) do
    if (msg.at or msg.every) and msg.from.block == me then
      print(msg.id .. "  " .. (msg.every and ("every " .. msg.every .. "s") or ("at " .. os.date("%H:%M:%S", msg.at)))
        .. "  to " .. msg.to.name .. ": " .. msg.text .. (msg.dead and "  (stopped: " .. msg.dead .. ")" or ""))
      print("  cancel: rm " .. mail.file(msg.id))
    end
  end
  return
end

local seconds = assert(a["in"] or a.every, "use in=SECONDS or every=SECONDS")
assert(type(seconds) == "number" and seconds > 0 and not (a["in"] and a.every), "use one positive interval")
local message = tostring(assert(a.message, "message is required"))
assert(not message:find("[\r\n]"), "the message must be one line")
-- The postman reports itself to Rex with sha256sum.
if not lib.windows then
  local r = rex.exec({ "sh", "-c", "command -v sha256sum" })
  assert(r and r.ok, "alarm.lua needs sha256sum (macOS 15+ or coreutils)")
end
local _, me = lib.me()
local id, name, hint = mail.post({ to = a.block and tostring(a.block) or me, text = message,
  at = a["in"] and os.time() + a["in"], every = a.every, hint = true })
print("alarm: " .. id .. " for " .. name .. ". Cancel it with: rm " .. lib.quote(mail.file(id)))
if hint then print(hint) end
