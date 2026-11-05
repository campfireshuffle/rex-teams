-- Start a subagent in a background Rex tab and tell it how to report back.
--
--   rex do <skill>/scripts/spawn.lua name=NAME cwd=DIR task=FILE command="AGENT [ARGS...]" [depth=N]
--
-- command starts any agent CLI; its words are split on spaces. A {prompt}
-- word is replaced with the agent's first prompt; without one, the prompt
-- goes last, which suits claude, codex, and pi. For example:
-- command="gemini -i {prompt}". depth is how many levels of subagents it may
-- start below itself (default 0).
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
local a = rex.args
assert(a.name and a.cwd and a.task and a.command, 'usage: spawn.lua name=NAME cwd=DIR task=FILE command="AGENT [ARGS...]" [depth=N]')
local depth = a.depth or 0

local file = assert(io.open(a.task))
local task = file:read("*a")
file:close()

local session, me = lib.me()
lib.blocks(session)

-- A subagent's depth is kept in a file named after its terminal, since
-- that's all spawn.lua knows about whoever runs it. Agents the user starts
-- have none, so they have no limit.
local function depth_file(block) return lib.path("depth", (block:gsub("^block:", ""))) end
local mine = io.open(depth_file(me))
if mine then
  local allowed = tonumber(mine:read("*l"))
  mine:close()
  assert(allowed > 0, "your parent didn't allow you to start subagents; do the task yourself or report blocked")
  depth = math.min(depth, allowed - 1)
end

-- Resolve cwd the way a program in this terminal would, so . and ~ work.
local dir = lib.call("block.method", { session_id = session, block_id = me, method = "list_dir", args = { path = tostring(a.cwd), limit = 1 } })
assert(dir.status == "ok", tostring(a.cwd) .. " isn't a folder")

-- Every parent shares the folder, so a random suffix keeps two subagents
-- with the same name apart.
math.randomseed(os.time() + os.clock() * 1e6)
local suffix = ""
for _ = 1, 4 do suffix = suffix .. string.char(math.random(97, 122)) end
local task_id = a.name .. "-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. suffix
local task_dir = lib.path("tasks", task_id)
local prompt, result = lib.path("tasks", task_id, "prompt.md"), lib.path("tasks", task_id, "result.md")
lib.mkdir(task_dir)
lib.mkdir(lib.path("depth"))

-- The kickoff carries the naming rule itself. Rex tells new agents to name
-- their session before doing anything else, which would come before the prompt.
local kickoff = "You are a subagent. Never rename the Rex session; it belongs to the agent that started you. "
  .. 'If asked to name your session, name your tab instead and keep the arrow: rex window rename "↳ <name>". '
  .. "Read " .. prompt .. " and follow it."
local argv, placed = {}, false
for word in tostring(a.command):gmatch("%S+") do
  if word == "{prompt}" then word, placed = kickoff, true end
  argv[#argv + 1] = word
end
if not placed then argv[#argv + 1] = kickoff end

-- Open the tab first: the report needs its ID. The agent takes seconds to
-- start, so the prompt exists by the time it reads it.
local created = lib.call("session.new_window", {
  session_id = session,
  window_label = "↳ " .. a.name,
  focus = false,
  layout = rex.layout.block{
    flavor = "com.superlogical.terminal.shell",
    options = { command = argv, cwd = dir.path, exit = { on_completion = false } },
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
local notify = lib.command("send.lua", "session=" .. session .. " block=" .. me
  .. ' message="' .. task_id .. " STATUS. Read " .. result
  .. ". If it's completed and checks out, close this subagent with: rex window close -s " .. session .. " " .. window
  .. '. Then wait for any other subagents you started."')
f = assert(io.open(prompt, "w"))
f:write(task, [[


---

## How to report back

You are a subagent. Another agent started you in a Rex terminal and is waiting for your report.
]], nesting, [[


When you finish, or when you are stuck on a question only the parent or user can answer:

1. Write ]], result, [[. Its first line must be exactly one of:
   STATUS: completed
   STATUS: failed
   STATUS: blocked
   Then write a short report: what you did, files you changed, how you verified it, and any question you need answered.
2. Notify the parent by running this command (put your status in place of STATUS):
   ]], notify, [[

   If it fails with a sandbox or permission error, ask for permission to run it outside the sandbox.
3. Stop and wait. The parent or the user may send follow-ups into this terminal. Handle each one, then repeat steps 1 and 2. Overwrite result.md each time.

Don't notify the parent with progress updates. Notify it only when you finish or are blocked.
]])
f:close()

print("task: " .. task_id)
print("folder: " .. task_dir)
print("tab: " .. window)
print("message it: " .. lib.command("send.lua", "session=" .. session .. " block=" .. block .. ' message="MESSAGE"'))
