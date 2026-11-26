-- lib.me() finds the caller's session from REX_BLOCK, which every Rex
-- terminal has. There is no fallback: a pane Rex can't find is an error.
--   lua5.1 tests/me.lua
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") or "./"
local env, calls = {}, 0
local real_getenv = os.getenv
os.getenv = function(k) if env[k] ~= nil then return env[k] or nil end return real_getenv(k) end
rex = { call = function(method, args)
  calls = calls + 1
  assert(method == "target.resolve" and args.kinds[1] == "block")
  if args.queries[1] == "block:mine" then
    return { results = { { status = "resolved", target = { kind = "block", session_id = "session:now", block_id = "block:mine" } } } }
  end
  return { results = { { status = "not_found", query = args.queries[1] } } }
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
  fails("Rex can't find your pane block:gone (not_found)")
end)
trial("outside Rex: a clear error and no lookup", function()
  env = { REX_BLOCK = false, REX_SESSION = "session:old" }
  fails("run this inside a Rex terminal")
  assert(calls == 0)
end)
print("Passed " .. n .. " session lookup trials.")
