-- Run from the repo root with `lua5.1 tests/send_command.lua`.
-- Runs generated send commands through /bin/sh with a fake `rex` that prints its argv.
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function read(path)
  local f = assert(io.open(path))
  local value = f:read("*a")
  f:close()
  return value
end
local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end
local function sh(line)
  assert(os.execute(line) == 0, line)
end
local tmp = os.tmpname()
os.remove(tmp)
local root = tmp .. " it's \"$HOME\" `x` $(y) ↳ café"
sh("mkdir -p " .. quote(root .. "/bin") .. " " .. quote(root .. "/scripts"))
write(root .. "/bin/rex", '#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done\n')
sh("chmod +x " .. quote(root .. "/bin/rex"))

local lib = dofile("skills/rex-teams/scripts/lib.lua")
lib.dir = root .. "/scripts/"
local canary = root .. "/canary"

-- The words the shell hands to rex when it runs `command`.
local function argv(command)
  local script, out = root .. "/cmd.sh", root .. "/out"
  write(script, command .. "\n")
  sh("PATH=" .. quote(root .. "/bin") .. ':"$PATH" /bin/sh ' .. quote(script) .. " >" .. quote(out))
  local words = {}
  for word in read(out):gmatch("([^\n]*)\n") do words[#words + 1] = word end
  return words
end
local function arrives(command, message)
  local words = argv(command)
  assert(#words == 4, "expected 4 words, got " .. #words .. ": " .. command)
  assert(words[1] == "do" and words[2] == lib.dir .. "send.lua", "script path changed: " .. tostring(words[2]))
  assert(words[3] == "block=block:b1")
  assert(words[4] == "message=" .. message, "message changed: " .. tostring(words[4]))
  assert(not io.open(canary), "the shell ran text from the command")
end

local count = 0
local function check(name, fn)
  fn()
  count = count + 1
  print("ok " .. count .. " - " .. name)
end
local tricky = {
  "plain words",
  "it's a \"quote\" and 'another'",
  "$HOME ${HOME} $1 $$ $(touch " .. canary .. ")",
  "`touch " .. canary .. "` ; touch " .. canary .. " && echo | cat",
  "↳ café 🚀 naïve \\n \\ back\\slash",
  "* ? [a] ~ # !! %s %",
  "",
}
check("messages and script paths arrive literally through /bin/sh", function()
  for _, message in ipairs(tricky) do
    arrives(lib.send_command("block:b1", message), message)
  end
end)
check("agents can fill in a placeholder by editing the command text", function()
  for _, placeholder in ipairs({ "<reply>", "<message>", "MESSAGE" }) do
    local template = lib.send_command("block:b1", placeholder)
    local filled = template:gsub(placeholder:gsub("%p", "%%%0"), "Done, it'\\''s in /tmp/x $HOME")
    arrives(filled, "Done, it's in /tmp/x $HOME")
  end
end)
check("the reply command in a message header runs as written", function()
  lib.blocks = function() return { { id = "block:b1", tab = "it's `me` $HOME", pane = "", split = false } } end
  local header = lib.header("session:test", "block:b1")
  local reply = assert(header:match("Reply by running: (.*)%] $"))
  arrives(reply, "<reply>")
end)
sh("rm -rf " .. quote(root))
print("Passed " .. count .. " send command trials through /bin/sh.")
