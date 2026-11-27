-- Send a one-line message to another agent's Rex terminal.
--
--   rex do <skill>/scripts/send.lua [host=HOST] block=BLOCK message='MESSAGE' [file=PATH]
--
-- BLOCK is the other agent's terminal: a full block ID, a short ID or a label,
-- as Rex reads it. HOST is a label from `rex hosts`; leave it out for this
-- host. team.lua prints this command, filled in, for each agent.
--
-- It queues the message and returns; the postman types it in as it arrives,
-- and tells you if it can't. The message arrives as
--   [from <your name> · msg <id>, who can't see this screen. <rule> Reply by running: <command>] MESSAGE
-- so the other agent knows who wrote and how to answer, even if it has never
-- heard of this skill. Without "can't see this screen", agents tend to answer
-- in their own pane, where nobody reads it. Across hosts, the header names
-- this host and leaves the reply's host='<label>' for the reader to fill in.
--
-- file= attaches a file or folder; for several, pass
-- --args '{"block":…,"message":…,"file":["a","b"]}'. On this host the
-- message lists their paths. On another host they're copied into
-- /tmp/rex-teams/inbox/<block>/<id>/ there before the message goes, and the
-- message says the receiver can remove that folder once it has read them.
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")
local lib = dofile(dir .. "lib.lua")
local mail = dofile(dir .. "mail.lua")
local a = rex.args
lib.need(a.message ~= nil and a.block ~= nil, "usage: send.lua [host=HOST] block=BLOCK message='MESSAGE' [file=PATH]")
local id, name = mail.post({ to = tostring(a.block), host = a.host and tostring(a.host), text = tostring(a.message), files = a.file })
print("queued message " .. id .. " for " .. name)
