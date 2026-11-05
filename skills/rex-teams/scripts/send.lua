-- Type a one-line message into another agent's Rex terminal and submit it.
--
--   rex do <skill>/scripts/send.lua session=SESSION block=BLOCK message="MESSAGE"
--
-- SESSION is a session ID, such as $REX_SESSION. BLOCK is the block ID of the
-- other agent's terminal (block:...). Labels can be renamed or repeated, so
-- find the ID once with team.lua and send to that. The message arrives as
--   [from <your name>, who can't see this screen. Reply by running: <command>] MESSAGE
-- so the other agent knows who wrote and how to answer, even if it has never
-- heard of this skill. Without "can't see this screen", agents tend to answer
-- in their own pane, where nobody reads it.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
local args = rex.args

local session, block = args.session, args.block
-- Rex reads message=42 as a number and message=true as a boolean.
local message = args.message ~= nil and tostring(args.message) or nil
if not session or not block or not message then
  lib.fail('usage: rex do send.lua session=SESSION block=BLOCK message="MESSAGE"')
end
if not tostring(block):match("^block:") then
  lib.fail("send: block must be a block ID (block:...); list them with team.lua")
end
-- A newline would submit half the message.
if message:find("[\r\n]") then
  lib.fail("send: the message must be one line; put longer text in a file and send its path")
end

local my_session, my_block = lib.me()
local from = my_block
for _, b in ipairs(lib.blocks(my_session)) do
  if b.id == my_block then from = lib.name(b) or my_block end
end

local reply = lib.command("send.lua", "session=" .. my_session .. " block=" .. my_block .. ' message="<reply>"')
lib.type_line(session, block, "[from " .. from .. ", who can't see this screen. Reply by running: " .. reply .. "] " .. message)
