-- Start a subagent in a background Rex tab and tell it how to report back.
--
--   rex do <skill>/scripts/spawn.lua name=NAME cwd=DIR task=FILE command="AGENT [ARGS...]" [depth=N]
--
-- command starts any agent CLI. A {prompt} argument is replaced with the
-- agent's first prompt; without one, the prompt goes last, which suits
-- claude, codex, and pi. For example: command="gemini -i {prompt}". Quote an
-- argument that has spaces with '...'. depth is how many levels of subagents
-- it may start below itself (default 0).
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
local args = rex.args

local usage = 'usage: rex do spawn.lua name=NAME cwd=DIR task=FILE command="AGENT [ARGS...]" [depth=N]'
local name, cwd, task, command = args.name, args.cwd, args.task, args.command
local depth = args.depth or 0
if not name or not cwd or not task or not command then lib.fail(usage) end
name, cwd, task, command = tostring(name), tostring(cwd), tostring(task), tostring(command)
-- The name becomes part of a file name, so keep it plain.
if name:find("[^a-z0-9-]") then lib.fail("spawn: use lowercase letters, digits, and dashes in name") end
if type(depth) ~= "number" or depth < 0 or depth % 1 ~= 0 then lib.fail("spawn: depth must be a whole number") end

local file = io.open(task)
if not file then lib.fail("spawn: can't read the task file " .. task) end
local task_text = file:read("*a")
file:close()

local session, my_block = lib.me()

-- Each subagent's depth is kept in a file named after its terminal. Agents
-- the user starts have none, so they have no limit. A subagent can't give
-- its own subagents more depth than it has.
local function depth_file(block) return lib.path("rex-teams-" .. block:gsub("^block:", "") .. ".depth") end
local mine = io.open(depth_file(my_block))
if mine then
  local allowed = tonumber(mine:read("*l")) or 0
  mine:close()
  if allowed <= 0 then
    io.stderr:write("spawn: your parent didn't allow you to start subagents; do the task yourself or report blocked\n")
    rex.stop(1)
  end
  if depth >= allowed then depth = allowed - 1 end
end

-- Resolve cwd the way a program in your terminal would, so a relative path
-- or ~ works, and check that it's a folder.
lib.view(session)
local dir = lib.call("block.method", { session_id = session, block_id = my_block, method = "list_dir", args = { path = cwd, limit = 1 } })
if dir.status ~= "ok" then lib.fail("spawn: " .. cwd .. " isn't a folder you can read") end
cwd = dir.path

-- Split command into words. Quotes group words and are removed.
local argv, word, quote, started = {}, "", nil, false
for c in command:gmatch(".") do
  if quote then
    if c == quote then quote = nil else word = word .. c end
  elseif c == "'" or c == '"' then
    quote, started = c, true
  elseif c:match("%s") then
    if started or word ~= "" then argv[#argv + 1] = word end
    word, started = "", false
  else
    word = word .. c
  end
end
if started or word ~= "" then argv[#argv + 1] = word end
if #argv == 0 then lib.fail(usage) end

-- Every parent shares the temp folder, so a random suffix keeps two
-- subagents with the same name apart.
math.randomseed(os.time() + tonumber(tostring({}):match("0x(%x+)") or "0", 16) % 100000)
local task_id, prompt_path
repeat
  local suffix = ""
  for _ = 1, 4 do suffix = suffix .. string.char(math.random(97, 122)) end
  task_id = name .. "-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. suffix
  prompt_path = lib.path("rex-teams-" .. task_id .. "-prompt.md")
  local taken = io.open(prompt_path)
  if taken then taken:close() end
until not taken
local result_path = lib.path("rex-teams-" .. task_id .. "-result.md")

-- The kickoff carries the naming rule itself. Rex tells new agents to name
-- their session before doing anything else, which would come before the prompt.
local kickoff = "You are a subagent. Never rename the Rex session; it belongs to the agent that started you. "
  .. 'If asked to name your session, name your tab instead and keep the arrow: rex window rename "↳ <name>". '
  .. "Read " .. prompt_path .. " and follow it."
local placed = false
for i, a in ipairs(argv) do
  if a == "{prompt}" then argv[i], placed = kickoff, true end
end
if not placed then argv[#argv + 1] = kickoff end

-- Open the tab first: the report needs its ID. The agent takes seconds to
-- start, so the prompt file exists by the time it reads it.
local created = lib.call("session.new_window", {
  session_id = session,
  window_label = "↳ " .. name,
  focus = false,
  layout = rex.layout.block{
    flavor = lib.terminal .. ".shell",
    options = { command = argv, cwd = cwd, exit = { on_completion = false } },
  },
})
local window, block = created.window_id, created.block_ids[1]

local f = assert(io.open(depth_file(block), "w"))
f:write(depth, "\n")
f:close()

local nesting = depth > 0
  and ("You may start subagents of your own with the rex-teams skill, up to " .. depth .. " level(s) below you. Report only after they have reported to you.")
  or "Do this task yourself. You can't start subagents."

-- The notice spells out the parent's next steps, because a parent that
-- compacted while the subagent worked may have lost the skill's instructions.
local notify = lib.command("send.lua", "session=" .. session .. " block=" .. my_block
  .. ' message="' .. task_id .. " STATUS. Read " .. result_path
  .. ". If it's completed and checks out, close this subagent with: rex window close -s " .. session .. " " .. window
  .. '. Then wait for any other subagents you started."')
f = assert(io.open(prompt_path, "w"))
f:write(task_text, [[


---

## How to report back

You are a subagent. Another agent started you in a Rex terminal and is waiting for your report.
]], nesting, [[


When you finish, or when you are stuck on a question only the parent or user can answer:

1. Write ]], result_path, [[. Its first line must be exactly one of:
   STATUS: completed
   STATUS: failed
   STATUS: blocked
   Then write a short report: what you did, files you changed, how you verified it, and any question you need answered.
2. Notify the parent by running this command (put your status in place of STATUS):
   ]], notify, [[

   If it fails with a sandbox or permission error, ask for permission to run it outside the sandbox.
3. Stop and wait. The parent or the user may send follow-ups into this terminal. Handle each one, then repeat steps 1 and 2. Overwrite the result file each time.

Don't notify the parent with progress updates. Notify it only when you finish or are blocked.
]])
f:close()

print("task: " .. task_id)
print("prompt: " .. prompt_path)
print("result: " .. result_path)
print("tab: " .. window)
print("message it: " .. lib.command("send.lua", "session=" .. session .. " block=" .. block .. ' message="MESSAGE"'))
