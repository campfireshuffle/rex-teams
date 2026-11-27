-- The postman's one adapter over Rex's terminal calls: whether a receiver's
-- pane is there, the copy of its files from another host, and the paste and
-- Enter that deliver to it. Nothing here reads the screen.
--
-- An address is { host?, block }; host is a label from `rex hosts`, or nil
-- for this host. A tab can move to another session after a message is
-- posted, so each call asks Rex for the block's session now and attaches to
-- it.
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")
local lib = dofile(dir .. "lib.lua")
local pane = {}

-- The block's session now, attached, and its full ID. A script must attach
-- to a session before it acts on it.
local function attach(addr)
  local session, block = lib.target(addr.host, addr.block)
  lib.attach(session, addr.host)
  return session, block
end

-- Whether the pane still exists with its program running. Rex keeps a pane
-- open after its program exits, with the exit in last_exit; that counts as
-- gone. Raises when Rex can't reach its host.
function pane.exists(addr)
  local found = lib.call("target.resolve", { queries = { addr.block }, kinds = { "block" } }, addr.host).results[1]
  if found.status ~= "resolved" then return false end
  local session, block = found.target.session_id, found.target.block_id
  lib.attach(session, addr.host)
  return lib.call("block.method", { session_id = session, block_id = block, method = "process", args = {} }, addr.host).last_exit == nil
end

-- Type TEXT, one line, into the pane: paste it, then press Enter. A paste
-- event lets the program tell the text from the Enter that submits it.
function pane.type(addr, text)
  local session, block = attach(addr)
  lib.call("block.event", { session_id = session, block_id = block, event = { type = "paste", payload = { text = text } } }, addr.host)
  for _, action in ipairs({ "press", "release" }) do
    lib.call("block.event", { session_id = session, block_id = block, event = { type = "key", payload = {
      key = "enter", mods = "", consumed_mods = "", text = "\r", unshifted_codepoint = 13, composing = false, action = action,
    } } }, addr.host)
  end
end

local function rex_cp(host, session, from, to)
  local r, err = rex.exec({ "rex", "-S", host, "cp", "-s", session, "-r", from, to }, { timeout = 600 })
  if not r then error("rex cp to " .. host .. ": " .. tostring(err), 0) end
  if not r.ok then
    error("rex cp to " .. host .. " failed (exit " .. tostring(r.code) .. "): " .. (r.stderr or ""):gsub("%s+$", ""), 0)
  end
end

-- Copy FILES, absolute paths here, into the inbox of a receiver on another
-- host for message ID, with one rex cp, where lib.inbox says. The
-- receiver's /tmp/rex-teams may be a symlink, and rex cp merges into a
-- symlinked folder only when it's named as the destination, so the stage
-- holds inbox/<block>/<id>/ and goes to /tmp/rex-teams/ itself.
function pane.attach(addr, files, id)
  local session, block = attach(addr)
  local host = addr.host
  local uuid = block:gsub("^block:", "")
  local stage = lib.path("stage", id)
  local ok, err = pcall(function()
    local box = table.concat({ stage, "inbox", uuid, id }, "/")
    lib.mkdir(box)
    -- -H copies a link named here as its target; links inside a folder
    -- stay links, as rex cp copies them.
    local argv = { "cp", "-RH" }
    for _, file in ipairs(files) do argv[#argv + 1] = file end
    argv[#argv + 1] = box
    local r = rex.exec(argv)
    if not (r and r.ok) then error("can't copy the files to " .. box .. ": " .. (r and r.stderr or ""), 0) end
    local root = lib.call("block.method", { session_id = session, block_id = block, method = "list_dir", args = { path = "/tmp/rex-teams", limit = 1 } }, host).status
    if root == "missing" then
      -- Without this, rex cp would copy inbox to a missing /tmp/rex-teams
      -- by renaming it rex-teams, so make /tmp/rex-teams first.
      lib.mkdir(stage .. "/rex-teams")
      rex_cp(host, session, stage .. "/rex-teams", ":/tmp/")
    end
    rex_cp(host, session, stage .. "/inbox", ":/tmp/rex-teams/")
  end)
  rex.exec({ "rm", "-rf", stage })
  if not ok then error(err, 0) end
end

return pane
