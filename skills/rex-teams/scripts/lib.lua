-- Shared by send.lua, spawn.lua, and team.lua. Rex runs them with `rex do`,
-- so they need nothing but rex.
local lib = {}

lib.windows = package.config:sub(1, 1) == "\\"
lib.sep = lib.windows and "\\" or "/"
lib.dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")

-- Agent sandboxes usually let programs write to /tmp.
lib.root = (lib.windows and os.getenv("TEMP") or "/tmp") .. lib.sep .. "rex-teams"

function lib.path(...)
  return table.concat({ lib.root, ... }, lib.sep)
end

-- Lua can't make folders, so ask the OS.
function lib.mkdir(path)
  local argv = lib.windows and { "cmd", "/c", "if", "not", "exist", path, "mkdir", path } or { "mkdir", "-p", path }
  assert(assert(rex.exec(argv)).ok, "can't make " .. path)
end

function lib.call(method, args)
  return assert(rex.call(method, args))
end

-- The agent running this script.
function lib.me()
  return assert(os.getenv("REX_SESSION"), "run this inside a Rex terminal"), os.getenv("REX_BLOCK")
end

-- Every block in a session, with its tab and pane labels. A script must
-- attach to a session before it can act on it.
function lib.blocks(session)
  lib.call("session.attach", { session_id = session })
  local out = {}
  for _, window in ipairs(lib.call("session.view", { session_id = session }).windows) do
    local blocks = {}
    for _, layer in ipairs(window.layers) do
      for _, block in ipairs(layer.blocks) do blocks[#blocks + 1] = block end
    end
    for _, block in ipairs(blocks) do
      out[#out + 1] = { id = block.block_id, tab = window.label or "", pane = block.label or "", split = #blocks > 1 }
    end
  end
  return out
end

-- An agent goes by its pane's label in a split tab, and by its tab's label
-- otherwise. Rex labels an unnamed pane "shell".
function lib.name(block)
  if block.split and block.pane ~= "shell" then return block.pane end
  return block.tab
end

-- Paste one line into a terminal, then press Enter. A paste event lets the
-- program tell the text from the Enter that submits it.
function lib.type_line(session, block, text)
  lib.call("block.event", { session_id = session, block_id = block, event = { type = "paste", payload = { text = text } } })
  for _, action in ipairs({ "press", "release" }) do
    lib.call("block.event", { session_id = session, block_id = block, event = { type = "key", payload = {
      key = "enter", mods = "", consumed_mods = "", text = "\r", unshifted_codepoint = 13, composing = false, action = action,
    } } })
  end
end

-- How to run one of these scripts, for a message.
function lib.command(script, pairs)
  return 'rex do "' .. lib.dir .. script .. '" ' .. pairs
end

return lib
