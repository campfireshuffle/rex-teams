-- The mutation check: run before a merge, from the repo root, with
--   luajit tests/checks/mutate.lua [name]
-- For each mutant in tests/checks/mutants.txt it breaks the code in a
-- scratch copy (.scratch/mutate/), runs the mutant's test file, and prints
-- caught or SURVIVED. It exits non-zero if any mutant survives or no longer
-- applies. The real checkout is never edited.
local only = arg[1]
io.stdout:setvbuf("line")
local copy = ".scratch/mutate"

local function sh(cmd) return os.execute(cmd) == 0 end
local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end
local function write(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function unescape(s) return (s:gsub("\\n", "\n")) end

-- The mutants in file order; lines with the same name are one mutant
-- with several edits.
local mutants, by_name = {}, {}
for line in io.lines("tests/checks/mutants.txt") do
  if line:find("%S") and not line:find("^#") then
    local f = {}
    for field in (line .. "|"):gmatch("([^|]*)|") do f[#f + 1] = trim(field) end
    assert(#f == 6, "mutants.txt: want 6 fields: " .. line)
    local name = f[1]
    if not by_name[name] then
      by_name[name] = { name = name, test = f[5], edits = {} }
      mutants[#mutants + 1] = by_name[name]
    end
    table.insert(by_name[name].edits, { file = f[2], old = unescape(f[3]), new = unescape(f[4]) })
  end
end

-- A copy of the working tree, so uncommitted changes are tested too.
assert(sh("rm -rf " .. copy .. " && mkdir -p " .. copy
  .. " && tar --exclude ./.git --exclude ./.scratch -cf - . | tar -xf - -C " .. copy))

local bad = 0
for _, m in ipairs(mutants) do
  if not only or only == m.name then
    local originals, applies = {}, true
    for _, e in ipairs(m.edits) do
      local path = copy .. "/" .. e.file
      local s = originals[path] or read(path)
      originals[path] = originals[path] or s
      local at = s:find(e.old, 1, true)
      if not at or s:find(e.old, at + 1, true) then applies = false break end
      write(path, s:sub(1, at - 1) .. e.new .. s:sub(at + #e.old))
    end
    if not applies then
      print("NOAPPLY  " .. m.name .. ": its text isn't in the code exactly once; update or drop it")
      bad = bad + 1
    else
      local log = "../mutate-" .. m.name .. ".log"
      local passed = sh("cd " .. copy .. " && perl -e 'alarm 300; exec @ARGV' luajit " .. m.test .. " >" .. log .. " 2>&1")
      if passed then
        print("SURVIVED " .. m.name .. " (" .. m.test .. ")")
        bad = bad + 1
      else
        print("caught   " .. m.name .. " (" .. m.test .. ")")
      end
    end
    for path, s in pairs(originals) do write(path, s) end
  end
end
if bad > 0 then
  print(bad .. " mutant(s) not caught; logs in .scratch/")
  os.exit(1)
end
print("Every mutant was caught.")
