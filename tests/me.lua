-- lib.me() finds the caller's session from REX_BLOCK, as Rex 0.1.0-preview.25
-- and later expect, and falls back to REX_SESSION on older Rex.
--   lua5.1 tests/me.lua
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") or "./"
local env, calls = {}, 0
local real_getenv = os.getenv
os.getenv = function(k) if env[k] ~= nil then return env[k] or nil end return real_getenv(k) end
rex = { call = function(method, args)
  calls = calls + 1
  assert(method == "target.resolve" and args.queries[1] and args.kinds[1] == "block")
  if args.queries[1] == "block:mine" then
    return { results = { { status = "resolved", target = { kind = "block", session_id = "session:now", block_id = "block:mine" } } } }
  end
  return { results = { { status = "not_found", query = args.queries[1] } } }
end }
local lib = dofile(dir .. "../skills/rex-teams/scripts/lib.lua")

local n = 0
local function trial(name, f) n = n + 1; calls = 0; f(); print("ok " .. n .. " - " .. name) end

trial("REX_BLOCK alone resolves the pane's current session", function()
  env = { REX_BLOCK = "block:mine", REX_SESSION = false }
  local s, b = lib.me()
  assert(s == "session:now" and b == "block:mine", tostring(s) .. " " .. tostring(b))
end)
trial("the looked-up session wins over a stale REX_SESSION", function()
  env = { REX_BLOCK = "block:mine", REX_SESSION = "session:old" }
  assert(lib.me() == "session:now")
end)
trial("older Rex: REX_SESSION is used when the pane can't be looked up", function()
  env = { REX_BLOCK = "block:gone", REX_SESSION = "session:old" }
  local s, b = lib.me()
  assert(s == "session:old" and b == "block:gone")
end)
trial("outside Rex: a clear error and no lookup", function()
  env = { REX_BLOCK = false, REX_SESSION = false }
  local ok, err = pcall(lib.me)
  assert(not ok and tostring(err):find("run this inside a Rex terminal", 1, true), tostring(err))
  assert(calls == 0)
end)
print("Passed " .. n .. " session lookup trials.")
