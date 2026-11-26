-- The postman's one adapter over Rex's terminal calls: what a receiver's
-- pane shows, and the paste and Enter that deliver to it. vendors.lua says
-- what each CLI's prompt box looks like.
--
-- An address is { host?, session, block }; host is a label from `rex hosts`,
-- or nil for this host.
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")
local lib = dofile(dir .. "lib.lua")
local vt = dofile(dir .. "vt.lua")
local vendors = dofile(dir .. "vendors.lua")
local pane = {}

-- Sessions this script has attached to, per host. A script must attach to a
-- session before it acts on it, and attaching also brings its events here.
local attached = {}
local function attach(addr)
  local key = (addr.host or "") .. " " .. addr.session
  if attached[key] then return end
  lib.attach(addr.session, addr.host)
  attached[key] = true
end

local function method(addr, name, args)
  return lib.call("block.method", { session_id = addr.session, block_id = addr.block, method = name, args = args or {} }, addr.host)
end

-- The screen as Rex's vt text. A long scrollback doesn't fit one reply, so
-- read only its tail; the screen is at the end.
local window = 65536
local function screen_vt(addr)
  local r = method(addr, "format", { format = "vt", max_bytes = window * 4 })
  if not r.id then return r.content end
  local parts, offset = {}, math.max(0, r.total - window)
  repeat
    local b = method(addr, "blob_read", { id = r.id, offset = offset, max_bytes = window })
    parts[#parts + 1] = b.data
    offset = offset + #b.data
  until b.eof or #b.data == 0
  -- The tail may start partway through a row.
  return (table.concat(parts):gsub("^[^\n]*\n", ""))
end

-- Whether TEXT holds NEEDLE, ended by a character that can't be part of
-- an id, so msg 1-abcd.1 doesn't match msg 1-abcd.12.
local function holds(text, needle)
  local at = 1
  while true do
    local i, j = text:find(needle, at, true)
    if not i then return false end
    if not text:sub(j + 1, j + 1):match("[%w%.%-]") then return true end
    at = j + 1
  end
end

-- What ROWS, the visible screen, show for message TAG, read with ENTRY from
-- vendors.lua: the composer, whether it holds ours, and whether "msg <tag>"
-- is on the screen above the composer. Pure, so tests feed it recorded
-- screens.
function pane.read(entry, rows, tag)
  local c = entry.composer(rows)
  if not c then return nil, false end
  -- A wrapped composer row can split the id, so compare without blanks.
  local ours = holds((c.text:gsub("%s", "")), "msg" .. tag) and "id"
    or vendors.token(entry, c.text) and "token" or nil
  -- A long line can wrap between "msg" and the id, so also look across each
  -- pair of rows, joined with their blanks collapsed.
  local seen, prev = false, ""
  for r = 1, c.top - 1 do
    local text = vt.text(rows[r]):gsub("%s+", " ")
    if holds(text, "msg " .. tag) or holds(prev .. text:gsub("^ ", ""), "msg " .. tag) then seen = true break end
    prev = text:gsub(" $", "") .. " "
  end
  return { text = c.text, ours = ours }, seen
end

-- look(addr, tag) -> { status, kind, app, known, composer, seen, gone }
--   status, kind: the program's OSC 7501 report (nil if it made none)
--   known: vendors.lua knows the program, so the composer can be read
--   composer: nil when none is showing, or { text, ours }, where text is
--     undimmed text and ours is "id" (it holds "msg <tag>"), "token" (just
--     one paste stand-in) or nil
--   seen: "msg <tag>" is on the screen above the composer
--   gone: the block no longer exists; nothing else is set
function pane.look(addr, tag)
  local found = lib.call("target.resolve", { queries = { addr.block }, kinds = { "block" } }, addr.host).results[1]
  if found.status ~= "resolved" then return { gone = true } end
  attach(addr)
  local root = {}
  for _, r in ipairs(method(addr, "program_status").records or {}) do
    if not r.id then root = r end
  end
  local app, process = root.app, nil
  if not app then
    local p = method(addr, "process")
    process = p.foreground and p.foreground.name
  end
  local entry = vendors.find(app, process)
  local look = { status = root.state, kind = root.kind, app = app or process, known = entry ~= nil, seen = false }
  if not entry then return look end
  local rows = vt.screen(screen_vt(addr), method(addr, "size").rows)
  look.composer, look.seen = pane.read(entry, rows, tag)
  return look
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
