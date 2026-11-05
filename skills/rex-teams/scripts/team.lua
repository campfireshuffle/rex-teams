-- List the agents in your Rex session, so you can message one by block ID.
--
--   rex do <skill>/scripts/team.lua [session=SESSION]
--
-- One line per terminal: its block ID, its tab, and its pane. Tabs starting
-- with ↳ are subagents. Teammates are the other labeled tabs and panes.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")

local my_session, my_block = lib.me()
for _, b in ipairs(lib.blocks(rex.args.session or my_session)) do
  print(b.id .. "  tab=" .. b.tab .. "  pane=" .. b.pane .. (b.id == my_block and "  (you)" or ""))
end
