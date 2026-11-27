-- Run from the repo root with `luajit tests/lint.lua` or `lua5.1 tests/lint.lua`.
-- No script names an agent CLI or reads a pane's screen: the postman treats
-- every receiver alike (decision 005).
local names = { "claude", "codex", "opencode", "anthropic", "openai", "gemini", "aider", "cursor-agent" }
local dir = "skills/rex-teams/scripts/"
local found = {}
local p = io.popen("ls " .. dir)
for name in p:lines() do
  local f = assert(io.open(dir .. name))
  local text = f:read("*a"):lower()
  f:close()
  for _, cli in ipairs(names) do
    if text:find(cli, 1, true) then found[#found + 1] = name .. " names " .. cli end
  end
  -- Pi's name is a common syllable, so look for it as a word.
  if text:find("%f[%w]pi%f[%W]") then found[#found + 1] = name .. " names pi" end
  -- Reading a screen goes through a block's format or capture method.
  for _, call in ipairs({ 'method = "format"', 'method = "capture"', '"capture"' }) do
    if text:find(call, 1, true) then found[#found + 1] = name .. " reads a screen (" .. call .. ")" end
  end
end
p:close()
if #found > 0 then
  print("not ok 1 - no script names a CLI or reads a screen: " .. table.concat(found, "; "))
  os.exit(1)
end
print("ok 1 - no script names a CLI or reads a screen")
print("Passed 1 lint trial.")
