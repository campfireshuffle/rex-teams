-- lib.me() finds the caller's session from REX_BLOCK, which every Rex
-- terminal has. There is no fallback: a pane Rex can't find is an error.
-- lib.name() names an agent the way its tab and panes are labelled.
--   lua5.1 tests/me.lua
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") or "./"
local env, calls = {}, 0
local real_getenv = os.getenv
os.getenv = function(k) if env[k] ~= nil then return env[k] or nil end return real_getenv(k) end
rex = { call = function(method, args)
  calls = calls + 1
  if method == "session.attach" then return {} end
  if method == "session.view" then
    return { windows = {
      { label = "Solo", layers = { { blocks = { { block_id = "block:solo", label = "Pane" } } } } },
      { label = "Split", layers = { { blocks = { { block_id = "block:left", label = "Left" } } },
        { blocks = { { block_id = "block:right", label = "shell" } } } } },
    } }
  end
  assert(method == "target.resolve" and args.kinds[1] == "block")
  if args.queries[1] == "block:mine" then
    return { results = { { status = "resolved", target = { kind = "block", session_id = "session:now", block_id = "block:mine" } } } }
  end
  return { results = { { status = "not_found", reason = "", query = args.queries[1] } } }
end }
local lib = dofile(dir .. "../skills/rex-teams/scripts/lib.lua")

local n = 0
local function trial(name, f) n = n + 1; calls = 0; f(); print("ok " .. n .. " - " .. name) end
local function fails(text) local ok, err = pcall(lib.me); assert(not ok and tostring(err):find(text, 1, true), tostring(err)) end

trial("REX_BLOCK finds the pane's current session", function()
  env = { REX_BLOCK = "block:mine", REX_SESSION = false }
  local s, b = lib.me()
  assert(s == "session:now" and b == "block:mine", tostring(s) .. " " .. tostring(b))
end)
trial("a stale REX_SESSION is ignored", function()
  env = { REX_BLOCK = "block:mine", REX_SESSION = "session:old" }
  assert(lib.me() == "session:now")
end)
trial("a pane Rex can't find is an error, even with REX_SESSION set", function()
  env = { REX_BLOCK = "block:gone", REX_SESSION = "session:old" }
  fails("block block:gone: not found")
end)
trial("outside Rex: a clear error and no lookup", function()
  env = { REX_BLOCK = false, REX_SESSION = "session:old" }
  fails("run this inside a Rex terminal")
  assert(calls == 0)
end)
trial("lib.name: a labelled pane in a split tab, else the tab, else the block ID", function()
  local want = { ["block:solo"] = "Solo", ["block:left"] = "Left", ["block:right"] = "Split", ["block:gone"] = "block:gone" }
  for block, name in pairs(want) do
    assert(lib.name("session:now", block) == name, block .. " is " .. tostring(lib.name("session:now", block)))
  end
end)
print("Passed " .. n .. " session lookup trials.")
