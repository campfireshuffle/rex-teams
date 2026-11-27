-- Set an alarm: a message to an agent, at a time or repeating.
--
--   rex do <skill>/scripts/alarm.lua in=SECONDS message='MESSAGE' [block=BLOCK]
--   rex do <skill>/scripts/alarm.lua every=SECONDS message='MESSAGE' [block=BLOCK]
--   rex do <skill>/scripts/alarm.lua list=true
--
-- The target defaults to the calling agent. An alarm is a queued message
-- with a time; the postman delivers it as it does every message. A due tick
-- goes out however late; ticks that pile up, while Rex was down or the
-- machine slept, collapse into the latest one, and the schedule never
-- drifts. Cancel one by deleting its file, which it prints.
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

local need = lib.need
local seconds = a["in"] or a.every
need(seconds ~= nil and not (a["in"] and a.every), "use in=SECONDS or every=SECONDS")
need(type(seconds) == "number" and seconds > 0, (a.every and "every" or "in") .. " must be a positive number of seconds")
need(a.message ~= nil, "message is required")
local _, me = lib.me()
local id, name = mail.post({ to = a.block and tostring(a.block) or me, text = tostring(a.message),
  at = a["in"] and os.time() + a["in"], every = a.every })
print("alarm: " .. id .. " for " .. name .. ". Cancel it with: rm " .. lib.quote(mail.file(id)))
