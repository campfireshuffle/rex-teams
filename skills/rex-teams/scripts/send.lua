-- Paste a one-line message into another agent's Rex terminal and submit it.
--
--   rex do <skill>/scripts/send.lua [host=HOST] block=BLOCK message='MESSAGE' [file=PATH]
--
-- BLOCK is the other agent's terminal: a full block ID, a short ID or a label,
-- as Rex reads it. HOST is a label from `rex hosts`; leave it out for this
-- host. team.lua prints this command, filled in, for each agent.
-- The message arrives as
--   [from <your name>, who can't see this screen. <rule> Reply by running: <command>] MESSAGE
-- so the other agent knows who wrote and how to answer, even if it has never
-- heard of this skill. Without "can't see this screen", agents tend to answer
-- in their own pane, where nobody reads it. Across hosts, the header names
-- this host and leaves the reply's host='<label>' for the reader to fill in.
--
-- file= attaches a file or folder; for several, pass
-- --args '{"block":…,"message":…,"file":["a","b"]}'. On this host the
-- message lists their paths. On another host they're copied into
-- /tmp/rex-teams/inbox/<block>/<id>/ there first, and the message says the
-- receiver can remove that folder once it has read them. If the copy fails,
-- nothing is sent.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
local a = rex.args
local usage = "usage: send.lua [host=HOST] block=BLOCK message='MESSAGE' [file=PATH]"
local message = tostring(assert(a.message, usage))
-- A newline would submit half the message.
assert(not message:find("[\r\n]"), "the message must be one line; put longer text in a file and attach it with file=")
local target = a.block and tostring(a.block)
-- Rex resolves an empty query to some terminal.
assert(target and target:match("%S"), usage)
local host = a.host and tostring(a.host)
local files = type(a.file) == "table" and a.file or { a.file }
for _, file in ipairs(files) do
  assert(type(file) == "string" and file ~= "", "file must be a path or a list of paths")
end

local session, block = lib.target(host, target)
local from_session, from_block = lib.me()
lib.attach(from_session)
local paths = lib.locate(from_session, from_block, files)
local header = lib.header(from_session, from_block, host ~= nil)
lib.attach(session, host)
if #paths > 0 and host then
  local landed, folder = lib.send_files(host, session, block, paths)
  message = message .. " [files: " .. table.concat(landed, ", ") .. "; you can remove " .. folder .. " once you've read them]"
elseif #paths > 0 then
  message = message .. " [files: " .. table.concat(paths, ", ") .. "]"
end
lib.paste_line(session, block, header .. message, host)
