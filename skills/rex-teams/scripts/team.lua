-- List the agents in your Rex session, each with the command that messages it.
--
--   rex do <skill>/scripts/team.lua [host=HOST]
--
-- With host=, a label from `rex hosts`, it lists every session on that host.
-- Tabs prefixed with a possibly indented ↳ are subagents. Teammates are the other labeled tabs
-- and panes. An agent with messages still queued for it says how many, and why.
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")
local lib = dofile(dir .. "lib.lua")
local mail = dofile(dir .. "mail.lua")

local host = rex.args.host and tostring(rex.args.host)
local mine, me = lib.me()
local sessions = { { session_id = mine } }
if host then sessions = lib.call("session.list", {}, host).sessions end
local queued = {}
for _, msg in ipairs(mail.list()) do
  -- An alarm counts once it's due.
  if msg.to.host == host and not msg.notice and (msg.d or not (msg.at or msg.every)) then
    local q = queued[msg.to.block] or { n = 0, stopped = 0 }
    queued[msg.to.block] = q
    if msg.dead then q.stopped = q.stopped + 1 else
      q.n = q.n + 1
      q.why = q.why or (msg.d and msg.d.why)
    end
  end
end
for _, s in ipairs(sessions) do
  if host then print("session " .. (s.label or s.session_id) .. ":") end
  for _, b in ipairs(lib.blocks(s.session_id, host)) do
    print(lib.name(b) .. "  " .. (not host and b.id == me and "(you)" or lib.send_command(b.id, "<message>", host)))
    local q = queued[b.id]
    if q and q.n > 0 then
      print("  (" .. q.n .. (q.n == 1 and " message" or " messages") .. " waiting" .. (q.why and ": " .. q.why or "") .. ")")
    end
    if q and q.stopped > 0 then
      print("  (" .. q.stopped .. (q.stopped == 1 and " message" or " messages") .. " not delivered; its sender was told)")
    end
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
