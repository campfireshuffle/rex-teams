-- List the agents in your Rex session, each with the command that messages it.
--
--   rex do <skill>/scripts/team.lua [host=HOST]
--
-- With host=, a label from `rex hosts`, it lists every session on that host.
-- Tabs prefixed with a possibly indented ↳ are subagents. Teammates are the other labeled tabs
-- and panes.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")

local host = rex.args.host and tostring(rex.args.host)
local mine, me = lib.me()
local sessions = { { session_id = mine } }
if host then sessions = lib.call("session.list", {}, host).sessions end
for _, s in ipairs(sessions) do
  if host then print("session " .. (s.label or s.session_id) .. ":") end
  for _, b in ipairs(lib.blocks(s.session_id, host)) do
    print(lib.name(b) .. "  " .. (not host and b.id == me and "(you)" or lib.send_command(b.id, "<message>", host)))
    -- Git runs here, so only this host's checkouts can be read.
    local process = not host and rex.call("block.method", { session_id = s.session_id, block_id = b.id, method = "process", args = {} })
    local cwd = process and process.foreground and process.foreground.cwd
    local worktree = cwd and lib.worktree(cwd)
    if worktree then
      print("  branch: " .. worktree.branch)
      print("  worktree: " .. worktree.path)
    end
  end
end
