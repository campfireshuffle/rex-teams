-- Shared by the scripts. Rex runs them with `rex do`,
-- so they need nothing but rex.
local lib = {}

-- Refuse with WHY, a plain sentence, unless OK. Rex prints an assert's
-- file and line; error(why, 0) prints just why.
function lib.need(ok, why)
  if not ok then error(why, 0) end
  return ok
end

lib.windows = package.config:sub(1, 1) == "\\"
lib.sep = lib.windows and "\\" or "/"
lib.dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")

-- Agent sandboxes usually let programs write to /tmp.
lib.root = (lib.windows and assert(os.getenv("TEMP"), "TEMP isn't set, so rex-teams has no folder for its files")
  or "/tmp") .. lib.sep .. "rex-teams"

function lib.path(...)
  return table.concat({ lib.root, ... }, lib.sep)
end

-- Lua can't make folders, so ask the OS.
function lib.mkdir(path)
  local argv = lib.windows and { "cmd", "/c", "if", "not", "exist", path, "mkdir", path } or { "mkdir", "-p", path }
  assert(assert(rex.exec(argv)).ok, "can't make " .. path)
end

function lib.read(path)
  local f = assert(io.open(path))
  local text = f:read("*a")
  f:close()
  return text
end

function lib.write(path, text)
  local f = assert(io.open(path, "w"))
  assert(f:write(text))
  assert(f:close())
end

-- Rex on HOST, a label from `rex hosts`, or on this host when HOST is nil.
-- rex.server fails on a label it doesn't know, so nothing lands on this host instead.
function lib.call(method, args, host)
  return assert((host and assert(rex.server(host)) or rex).call(method, args))
end

-- The session and full ID of BLOCK on HOST. BLOCK is anything Rex accepts:
-- a full ID, a short ID or a label.
function lib.target(host, block)
  local r = lib.call("target.resolve", { queries = { block }, kinds = { "block" } }, host).results[1]
  if r.status == "resolved" then return r.target.session_id, r.target.block_id end
  local choices = {}
  for _, c in ipairs(r.candidates or {}) do choices[#choices + 1] = c.block_id .. " (" .. c.label .. ", " .. c.where .. ")" end
  error("block " .. block .. (#choices > 0 and " could be " .. table.concat(choices, ", ")
    or ": " .. ((r.reason or "") ~= "" and r.reason or "not found")), 0)
end

-- Git runs on the machine running this script, like the task files.
function lib.worktree(cwd)
  local opts = { timeout = 2, env = { GIT_DIR = false, GIT_WORK_TREE = false, GIT_COMMON_DIR = false } }
  local r = rex.exec({ "git", "-C", cwd, "rev-parse", "--absolute-git-dir", "--path-format=absolute", "--git-common-dir", "--show-toplevel" }, opts)
  if not r or not r.ok then return end
  local gitdir, common, root = r.stdout:gsub("\r\n", "\n"):match("^([^\n]+)\n([^\n]+)\n([^\n]+)\n$")
  if not root or gitdir == common then return end
  local branch = rex.exec({ "git", "-C", cwd, "symbolic-ref", "--quiet", "--short", "HEAD" }, opts)
  return {
    path = root,
    branch = branch and branch.ok and branch.stdout:gsub("[\r\n]+$", "")
      or (branch and branch.code == 1 and "detached HEAD" or "unknown"),
  }
end

-- The agent running this script.
-- Rex sets REX_BLOCK in every terminal. A pane keeps its ID when its tab
-- moves to another session, so look its session up instead of trusting an
-- environment variable.
function lib.me()
  return lib.target(nil, lib.need(os.getenv("REX_BLOCK"), "run this inside a Rex terminal"))
end

-- A script must attach to a session before it can act on it.
function lib.attach(session, host)
  lib.call("session.attach", { session_id = session }, host)
end

-- Every block in a session, with its name. An agent goes by its pane's
-- label in a split tab, and by its tab's label otherwise. Rex labels an
-- unnamed pane "shell".
function lib.blocks(session, host)
  lib.attach(session, host)
  local out = {}
  for _, window in ipairs(lib.call("session.view", { session_id = session }, host).windows) do
    local blocks = {}
    for _, layer in ipairs(window.layers) do
      for _, block in ipairs(layer.blocks) do blocks[#blocks + 1] = block end
    end
    for _, block in ipairs(blocks) do
      local pane = #blocks > 1 and block.label ~= "shell" and block.label
      out[#out + 1] = { id = block.block_id, name = pane or window.label or "" }
    end
  end
  return out
end

-- The name of BLOCK in SESSION on HOST, or its ID if it isn't there.
function lib.name(session, block, host)
  for _, b in ipairs(lib.blocks(session, host)) do
    if b.id == block then return b.name end
  end
  return block
end

-- The absolute paths of PATHS, read the way a program in BLOCK's terminal
-- would, so relative paths and ~ work. Each must exist. BLOCK is on this
-- host, so Lua can open the absolute path.
function lib.locate(session, block, paths)
  local found = {}
  for _, path in ipairs(paths) do
    local dir = lib.call("block.method", { session_id = session, block_id = block, method = "list_dir", args = { path = path, limit = 1 } })
    -- not_dir is a file, or a path through one, such as a.md/x, which
    -- won't open.
    if dir.status == "not_dir" then
      local file = io.open(dir.path)
      if not file then error("file " .. path .. ": missing", 0) end
      file:close()
    elseif dir.status ~= "ok" then
      error("file " .. path .. ": " .. dir.status, 0)
    end
    -- The message is one line.
    lib.need(not dir.path:find("[\r\n]"), "file " .. path .. ": a name with a line break can't go in a message")
    found[#found + 1] = dir.path
  end
  return found
end

local cp_exit = { [3] = "that host's Rex has no rex cp", [4] = "can't reach that host" }

local function rex_cp(host, session, from, to)
  local r, err = rex.exec({ "rex", "-S", host, "cp", "-s", session, "-r", from, to }, { timeout = 600 })
  if not r then error("rex cp to " .. host .. ": " .. tostring(err), 0) end
  if not r.ok then
    error("rex cp to " .. host .. " failed (exit " .. tostring(r.code) .. (cp_exit[r.code] and ", " .. cp_exit[r.code] or "")
      .. "): " .. (r.stderr or ""):gsub("%s+$", ""), 0)
  end
end

-- Where FILES, absolute paths here, land in BLOCK's inbox on another host
-- for message ID: their paths there, and the folder holding them. Raises if
-- two share a name or one is the root folder.
function lib.inbox(block, id, files)
  local folder = "/tmp/rex-teams/inbox/" .. block:gsub("^block:", "") .. "/" .. id
  local landed, names = {}, {}
  for _, file in ipairs(files) do
    local name = file:match("([^/]+)/*$")
    if not name then error("file " .. file .. ": can't send the root folder", 0) end
    if names[name] then error("two files are named " .. name .. "; send them separately", 0) end
    names[name] = true
    landed[#landed + 1] = folder .. "/" .. name
  end
  return landed, folder
end

-- Copy FILES into BLOCK's inbox on HOST for message ID, with one rex cp,
-- where lib.inbox says. The receiver's /tmp/rex-teams may be a symlink, and
-- rex cp merges into a symlinked folder only when it's named as the
-- destination, so the stage holds inbox/<block>/<id>/ and goes to
-- /tmp/rex-teams/ itself.
function lib.send_files(host, session, block, files, id)
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
    elseif root ~= "ok" then
      error("/tmp/rex-teams on " .. host .. ": " .. root, 0)
    end
    rex_cp(host, session, stage .. "/inbox", ":/tmp/rex-teams/")
  end)
  local removed = rex.exec({ "rm", "-rf", stage })
  if not ok then error(err, 0) end
  assert(removed and removed.ok, "can't remove " .. stage)
end

-- Single quotes keep every character literal in POSIX shells.
function lib.quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- The command that sends a message to a terminal, for pasting into prompts.
-- HOST is the reader's `rex hosts` label for the terminal's host.
-- SCRIPT is send.lua's path as written in the command.
function lib.send_command(block, message, host, script)
  return "rex do " .. (script or lib.quote(lib.dir .. "send.lua")) .. (host and " host=" .. lib.quote(host) or "")
    .. " block=" .. lib.quote(block) .. " message=" .. lib.quote(message)
end

-- The header of a message, for another host when CROSS is true, in two
-- parts. The postman puts " · msg <id>" between them, so the receiver and
-- the postman can tell messages apart. The sender can't know send.lua's path
-- or its own label on the receiver's host, so the receiver fills them in.
function lib.header(from_session, from_block, cross)
  local from = lib.name(from_session, from_block)
  if not cross then
    return "[from " .. from, ", who can't see this screen."
      .. " Reply by running: " .. lib.send_command(from_block, "<reply>") .. "] "
  end
  local r = rex.exec({ "hostname" })
  local name = r and r.ok and r.stdout:match("^%s*(.-)%s*$") or ""
  assert(name ~= "", "can't read this machine's hostname")
  local id = assert(lib.call("server.status", {}).host_id, "Rex didn't report this host's host_id")
  return "[from " .. from .. " on " .. name .. " (Rex host " .. id .. ")", ", who can't see this screen."
    .. " To reply, run this with your rex-teams skill's path and your rex hosts label for that host filled in: "
    .. lib.send_command(from_block, "<reply>", "<label>", "<rex-teams skill>/scripts/send.lua") .. "] "
end

-- A name for a message: the time and four random letters. Two posts in
-- one second can draw the same letters, so draw again while the outbox
-- holds that name, or the second would replace the first.
local seeded
function lib.id()
  if not seeded then math.randomseed(os.time() + os.clock() * 1e6) seeded = true end
  while true do
    local id = tostring(os.time()) .. "-"
    for _ = 1, 4 do id = id .. string.char(math.random(97, 122)) end
    local f = io.open(lib.path("outbox", id .. ".json"))
    if not f then return id end
    f:close()
  end
end

return lib
