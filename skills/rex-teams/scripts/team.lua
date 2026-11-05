-- List the agents in your Rex session, so you can message one by block ID.
--
--   rex do <skill>/scripts/team.lua
--
-- Tabs starting with ↳ are subagents. Teammates are the other labeled tabs
-- and panes.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")

local session, me = lib.me()
for _, b in ipairs(lib.blocks(session)) do
  print(b.id .. "  tab=" .. b.tab .. "  pane=" .. b.pane .. (b.id == me and "  (you)" or ""))
end
