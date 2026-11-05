-- List the agents in your Rex session, each with the command that messages it.
--
--   rex do <skill>/scripts/team.lua
--
-- Tabs starting with ↳ are subagents. Teammates are the other labeled tabs
-- and panes.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")

local session, me = lib.me()
for _, b in ipairs(lib.blocks(session)) do
  print(lib.name(b) .. "  " .. (b.id == me and "(you)" or lib.send_command(session, b.id, "<message>")))
end
