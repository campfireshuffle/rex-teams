-- Paste a one-line message into another agent's Rex terminal and submit it.
--
--   rex do <skill>/scripts/send.lua [host=HOST] block=BLOCK message='MESSAGE'
--
-- BLOCK is the other agent's terminal: a full block ID, a short ID or a label,
-- as Rex reads it. HOST is a label from `rex hosts`; leave it out for this
-- host. session=SESSION narrows the search. team.lua prints this command,
-- filled in, for each agent.
-- The message arrives as
--   [from <your name>, who can't see this screen. <rule> Reply by running: <command>] MESSAGE
-- so the other agent knows who wrote and how to answer, even if it has never
-- heard of this skill. Without "can't see this screen", agents tend to answer
-- in their own pane, where nobody reads it.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
local a = rex.args
local usage = "usage: send.lua [host=HOST] block=BLOCK message='MESSAGE'"
local message = tostring(assert(a.message, usage))
-- A newline would submit half the message.
assert(not message:find("[\r\n]"), "the message must be one line; put longer text in a file and send its path")
local host = a.host and tostring(a.host)

local session, block = lib.target(host, tostring(assert(a.block, usage)), a.session and tostring(a.session))
local from_session, from_block = lib.me()
local header = lib.header(from_session, from_block, host)
lib.attach(session, host)
lib.paste_line(session, block, header .. message, host)
