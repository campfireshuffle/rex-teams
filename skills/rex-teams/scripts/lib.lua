-- Shared by send.lua, spawn.lua, and team.lua. Rex runs all of them with
-- `rex do`, so they need nothing but rex, on any platform Rex runs on.
local lib = {}

lib.terminal = "com.superlogical.terminal"
lib.windows = package.config:sub(1, 1) == "\\"

-- The folder holding these scripts, so messages can name them by full path.
lib.dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") or "./"

-- Task files go in /tmp, which Codex's default sandbox can write. Lua can't
-- make folders, so every file sits directly in it.
lib.tmp = lib.windows and (os.getenv("TEMP") or "C:\\Windows\\Temp") or "/tmp"

function lib.path(name)
  return lib.tmp .. (lib.windows and "\\" or "/") .. name
end

function lib.fail(message)
  io.stderr:write(message, "\n")
  rex.stop(2)
end

-- The agent running this script: its session and terminal.
function lib.me()
  local session, block = os.getenv("REX_SESSION"), os.getenv("REX_BLOCK")
  if not session or not block then lib.fail("run this from an agent inside a Rex terminal") end
  return session, block
end

function lib.call(method, args)
  local result, err = rex.call(method, args)
  if err then error(method .. ": " .. tostring(err), 0) end
  return result
end

-- A script must attach to a session before it can act on it.
local attached = {}
function lib.view(session)
  if not attached[session] then
    lib.call("session.attach", { session_id = session })
    attached[session] = true
  end
  return lib.call("session.view", { session_id = session })
end

-- Each block in a session with its tab, its pane label, and whether its tab
-- is split into panes.
function lib.blocks(session)
  local out = {}
  for _, window in ipairs(lib.view(session).windows or {}) do
    local blocks = {}
    for _, layer in ipairs(window.layers or {}) do
      for _, block in ipairs(layer.blocks or {}) do blocks[#blocks + 1] = block end
    end
    for _, block in ipairs(blocks) do
      out[#out + 1] = {
        id = block.block_id,
        tab = window.label or "",
        pane = block.label or "",
        window = window.window_id,
        split = #blocks > 1,
      }
    end
  end
  return out
end

-- An agent goes by its pane's label when its tab is split, and by its tab's
-- label otherwise. Rex's default labels ("shell", "Window 1a2b3c4d") name
-- nobody, so an unlabeled pane goes by its tab.
function lib.name(block)
  local label = block.tab
  if block.split and block.pane ~= "" and block.pane ~= "shell" then label = block.pane end
  if label == "" or label:match("^Window %x+$") then return nil end
  return label
end

-- Type one line into a terminal, then press Enter.
function lib.type_line(session, block, text)
  lib.view(session)
  lib.call("block.method", { session_id = session, block_id = block, method = "write", args = { data = text } })
  -- Codex can miss an Enter that arrives right after a long burst of text.
  rex.sleep(0.5)
  for _, action in ipairs({ "press", "release" }) do
    lib.call("block.event", { session_id = session, block_id = block, event = { type = "key", payload = {
      key = "enter", mods = "", consumed_mods = "", text = "\r",
      unshifted_codepoint = 13, composing = false, action = action,
    } } })
  end
end

-- How to run a script from a message. Double quotes work in sh and PowerShell.
function lib.command(script, pairs)
  return 'rex do "' .. lib.dir .. script .. '" ' .. pairs
end

return lib
