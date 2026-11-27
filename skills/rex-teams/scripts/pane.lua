-- The postman's one adapter over Rex's terminal calls: whether a receiver's
-- pane is there, and the paste and Enter that deliver to it. Nothing here
-- reads the screen.
--
-- An address is { host?, session, block }; host is a label from `rex hosts`,
-- or nil for this host. A tab can move to another session after a message
-- is posted, so each call asks Rex for the block's session now and attaches
-- to it, and never uses the saved session.
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

-- Paste TEXT, one line, into the pane. A paste event lets the program tell
-- the text from the Enter that submits it.
function pane.put(addr, text)
  local session, block = attach(addr)
  lib.call("block.event", { session_id = session, block_id = block, event = { type = "paste", payload = { text = text } } }, addr.host)
end

function pane.enter(addr)
  local session, block = attach(addr)
  for _, action in ipairs({ "press", "release" }) do
    lib.call("block.event", { session_id = session, block_id = block, event = { type = "key", payload = {
      key = "enter", mods = "", consumed_mods = "", text = "\r", unshifted_codepoint = 13, composing = false, action = action,
    } } }, addr.host)
  end
end

-- Copy FILES into the inbox of a receiver on another host, for message ID.
function pane.attach(addr, files, id)
  local session, block = attach(addr)
  lib.send_files(addr.host, session, block, files, id)
end

return pane
