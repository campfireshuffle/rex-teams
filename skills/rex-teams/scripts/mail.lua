-- Messages between agents. Replies, reports, notices and alarms are all
-- messages; an alarm has `at` or `every`.
--
--   mail.post{ to, host?, text, files?, at?, every? } -> id, name
--
-- post checks everything first and raises if anything is wrong. It resolves
-- TO (a block ID, short ID or label on HOST, a label from `rex hosts`) once,
-- makes sure this host's postman is running, then writes the message to
-- /tmp/rex-teams/outbox/<id>.json and returns at once. When post raises,
-- nothing is queued, so sending again doesn't double the message. NAME is
-- the receiver's name. The postman delivers it; see postman.lua. Delete the file to drop the
-- message or cancel the alarm.
--
-- AT is a unix time; EVERY repeats every EVERY seconds from now. The
-- callers (send.lua, alarm.lua) pass HOST as a string, and at most one of
-- AT or EVERY, positive. FILES are
-- paths as the sender's terminal reads them, and must exist. On this host
-- the message names them; on another host they're copied at delivery into
-- the receiver's /tmp/rex-teams/inbox/<block>/<id>/, which the message names.
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")
local lib = dofile(dir .. "lib.lua")
local mail = {}

function mail.dir() return lib.path("outbox") end
function mail.file(id) return lib.path("outbox", id .. ".json") end

local function exists(path)
  local f = io.open(path)
  if f then f:close() end
  return f ~= nil
end

-- Write MSG atomically: a reader sees the old file or the new one. With
-- ONLY_IF_THERE, a file someone deleted stays deleted; returns false then.
function mail.write(msg, only_if_there)
  local path = mail.file(msg.id)
  if only_if_there and not exists(path) then return false end
  lib.write(path .. ".tmp", rex.json.encode(msg))
  assert(os.rename(path .. ".tmp", path))
  return true
end

function mail.remove(id)
  os.remove(mail.file(id))
end

-- The names in the outbox that match PATTERN, read through the caller's own
-- terminal, since Lua can't list a folder. A capture in PATTERN is returned.
local here
local function names(pattern)
  if not here then here = { lib.me() } end
  local r = lib.call("block.method", { session_id = here[1], block_id = here[2], method = "list_dir",
    args = { path = mail.dir(), files = true, limit = 10000 } })
  local out = {}
  for _, entry in ipairs(r.entries or {}) do
    local name = entry.name:match(pattern)
    if name then out[#out + 1] = name end
  end
  return out
end

-- Whether A was posted before B. POSTED is whole seconds, so SEQ orders
-- the messages to one receiver posted in the same second.
function mail.before(a, b)
  if a.posted ~= b.posted then return a.posted < b.posted end
  if a.seq ~= b.seq then return a.seq < b.seq end
  return a.id < b.id
end

-- The queue, oldest first. FILTER may name { block, host } to list only
-- the messages to one receiver. Every file is written whole by mail.write,
-- so one that isn't JSON was edited by hand: say which, and stop.
function mail.list(filter)
  local out = {}
  for _, id in ipairs(names("^(%d+%-%a%a%a%a)%.json$")) do
    local f = io.open(mail.file(id))
    if f then
      local text = f:read("*a")
      f:close()
      local ok, msg = pcall(rex.json.decode, text)
      if not ok or type(msg) ~= "table" then
        error(mail.file(id) .. " isn't a message" .. (ok and "" or " (" .. tostring(msg) .. ")") .. "; delete it", 0)
      end
      if not filter or (msg.to.block == filter.block and msg.to.host == filter.host) then out[#out + 1] = msg end
    end
  end
  table.sort(out, mail.before)
  return out
end

-- The SEQ for a message to TO posted at NOW: after every queued message
-- to TO posted in the same second.
local function seq(to, now)
  local n = 0
  for _, msg in ipairs(mail.list({ block = to.block, host = to.host })) do
    if msg.posted == now then n = math.max(n, msg.seq + 1) end
  end
  return n
end

-- Wake the postman, then queue MSG. The postman reads the outbox every few
-- seconds, so it finds MSG; a postman that won't start leaves nothing queued.
local function queue(msg)
  dofile(dir .. "postman.lua").ensure()
  lib.mkdir(mail.dir())
  mail.write(msg)
end

-- A note from the postman to FROM, the sender of a message it's handling.
-- A notice never causes a notice of its own.
function mail.notice(from, text)
  local id, now = lib.id(), os.time()
  mail.write({ id = id, posted = now, seq = seq(from, now), notice = true, to = from, from = from,
    head = "[rex-teams postman", tail = "] ", text = text })
end

function mail.post(o)
  local need = lib.need
  local text = o.text
  need(type(text) == "string" and text:find("%S"), "the message is empty; say something")
  -- A newline would submit half the message.
  need(not text:find("[\r\n]"), "the message must be one line; put longer text in a file and attach it with file=")
  local to = o.to
  -- Rex resolves an empty query to some terminal.
  need(type(to) == "string" and to:match("%S"), "say who the message is for")
  local host = o.host
  local files = type(o.files) == "table" and o.files or { o.files }
  for _, file in ipairs(files) do
    need(type(file) == "string" and file ~= "", "file must be a path or a list of paths")
  end

  local session, block = lib.target(host, to)
  local from_session, from_block = lib.me()
  lib.attach(from_session)
  local paths = lib.locate(from_session, from_block, files)
  local id = lib.id()
  local name = block
  for _, b in ipairs(lib.blocks(session, host)) do
    if b.id == block then name = lib.name(b) end
  end

  if #paths > 0 and host then
    need(not lib.windows, "file= to another host doesn't work from Windows yet")
    local landed, folder = lib.inbox(block, id, paths)
    text = text .. " [files: " .. table.concat(landed, ", ") .. "; you can remove " .. folder .. " once you've read them]"
  elseif #paths > 0 then
    text = text .. " [files: " .. table.concat(paths, ", ") .. "]"
  end
  local head, tail
  if (o.at or o.every) and not host and block == from_block then
    head, tail = "[alarm you set", "] "
  else
    head, tail = lib.header(from_session, from_block, host ~= nil)
  end
  local now = os.time()
  queue({
    id = id, posted = now, seq = seq({ block = block, host = host }, now),
    to = { host = host, session = session, block = block, name = name },
    from = { session = from_session, block = from_block },
    head = head, tail = tail, text = text,
    files = host and #paths > 0 and paths or nil,
    at = o.at, every = o.every, start = o.every and now,
  })
  return id, name
end

return mail
