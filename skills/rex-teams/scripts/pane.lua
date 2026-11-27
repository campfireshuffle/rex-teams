-- The postman's one adapter over Rex's terminal calls: whether a receiver's
-- pane is there, and the paste and Enter that deliver to it. Nothing here
-- reads the screen.
--
-- An address is { host?, session, block }; host is a label from `rex hosts`,
-- or nil for this host.
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")
local lib = dofile(dir .. "lib.lua")
local pane = {}

-- Sessions this script has attached to, per host. A script must attach to a
-- session before it acts on it.
local attached = {}
local function attach(addr)
  local key = (addr.host or "") .. " " .. addr.session
  if attached[key] then return end
  lib.attach(addr.session, addr.host)
  attached[key] = true
end

-- Whether the pane still exists. Raises when Rex can't reach its host.
function pane.exists(addr)
  return lib.call("target.resolve", { queries = { addr.block }, kinds = { "block" } }, addr.host).results[1].status == "resolved"
end

-- Paste TEXT, one line, into the pane. A paste event lets the program tell
-- the text from the Enter that submits it.
function pane.put(addr, text)
  attach(addr)
  lib.call("block.event", { session_id = addr.session, block_id = addr.block, event = { type = "paste", payload = { text = text } } }, addr.host)
end

function pane.enter(addr)
  attach(addr)
  for _, action in ipairs({ "press", "release" }) do
    lib.call("block.event", { session_id = addr.session, block_id = addr.block, event = { type = "key", payload = {
      key = "enter", mods = "", consumed_mods = "", text = "\r", unshifted_codepoint = 13, composing = false, action = action,
    } } }, addr.host)
  end
end

-- Copy FILES into the receiver's inbox for message ID, if it's on another
-- host. On this host the message names the files where they are.
function pane.attach(addr, files, id)
  if not addr.host or #files == 0 then return end
  attach(addr)
  lib.send_files(addr.host, addr.session, addr.block, files, id)
end

return pane
