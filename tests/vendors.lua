-- Run from the repo root with `luajit tests/vendors.lua` or `lua5.1 tests/vendors.lua`.
-- Each CLI's composer parser against screens recorded from the real CLI
-- (tests/fixtures/screens/<state>@<app>.vt, from Rex's format="vt").
local vt = dofile("skills/rex-teams/scripts/vt.lua")
local vendors = dofile("skills/rex-teams/scripts/vendors.lua")
local apps = { "claude-code", "codex", "opencode", "pi" }

local function screen(name)
  local f = assert(io.open("tests/fixtures/screens/" .. name .. ".vt"))
  local s = f:read("*a")
  f:close()
  return vt.screen(s, 24)
end

local n, failed = 0, 0
local function trial(name, f)
  n = n + 1
  local ok, err = pcall(f)
  if not ok then failed = failed + 1 end
  print((ok and "ok " or "not ok ") .. n .. " - " .. name .. (ok and "" or ": " .. tostring(err)))
end
local function composer(state, app)
  return vendors.find(app).composer(screen(state .. "@" .. app))
end

local placeholder = {
  ["claude-code"] = 'Try "how does <filepath> work?"',
  codex = "Ask Codex to do anything",
  opencode = 'Ask anything… "Fix a TODO in the codebase"',
  pi = "", -- Pi shows no placeholder
}
local header = "[from Sender · msg 1795671000-abcd, who can't see this screen. Don't rename the Rex session or your tab."
  .. " Reply by running: rex do '/x/send.lua' block='block:me' message='<reply>'] Test only: do not reply or run anything."
local token = {
  ["claude-code"] = "[Pasted text #2]",
  codex = "[Pasted Content 2064 chars]",
  opencode = "[Pasted ~1 lines]",
  pi = "[paste #1 2064 chars]",
}

for _, app in ipairs(apps) do
  trial(app .. ": an empty composer has no text, and its placeholder is dim", function()
    local c = assert(composer("empty", app), "no composer")
    assert(c.text == "" and c.dim == placeholder[app], "text [" .. c.text .. "] dim [" .. c.dim .. "]")
  end)
  trial(app .. ": a person's draft is undimmed text", function()
    local c = assert(composer("draft", app), "no composer")
    assert(c.text == "hello there draft", c.text)
  end)
  trial(app .. ": our paste left unsent reads back as text or as one paste token", function()
    local c = assert(composer("ours-text", app), "no composer")
    if app == "opencode" then
      -- OpenCode shows even a short paste as a token.
      assert(c.text == token.opencode and vendors.token(vendors.find(app), c.text), c.text)
    else
      assert(c.text == header, c.text)
      assert(not vendors.token(vendors.find(app), c.text))
    end
    c = assert(composer("ours-token", app), "no composer")
    assert(c.text == token[app] and vendors.token(vendors.find(app), c.text), c.text)
  end)
  trial(app .. ": after delivery the composer is empty and its rows are below the transcript", function()
    local c = assert(composer("delivered", app), "no composer")
    assert(c.text == "", c.text)
    local rows = screen("delivered@" .. app)
    local above = {}
    for r = 1, c.top - 1 do above[#above + 1] = vt.text(rows[r]) end
    assert(table.concat(above, "\n"):find("msg 1795671000-dlvr", 1, true), "the delivered id isn't above the composer")
  end)
end
trial("claude-code: a dim suggestion after a reply isn't a draft", function()
  local c = assert(composer("placeholder", "claude-code"))
  assert(c.text == "" and c.dim ~= "", c.dim)
end)
trial("codex: an approval dialog reads as text that isn't ours, never as empty", function()
  local c = composer("dialog", "codex")
  assert(c and c.text ~= "" and not vendors.token(vendors.find("codex"), c.text), c and c.text)
end)
-- The guards below are checked on recorded screens with one row changed, so
-- each screen differs from a real one only where the guard matters.
local function blank() return { { ch = " " } } end
local function rule() local row = {} for i = 1, 80 do row[i] = { ch = "─" } end return row end
local function line(indent, text, bold)
  local row = {}
  for _ = 1, indent do row[#row + 1] = { ch = " " } end
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do row[#row + 1] = { ch = ch, bold = bold } end
  return row
end
trial("claude-code: a ❯ prompt echoed in the transcript isn't the composer", function()
  -- The composer is gone (as under a dialog) and a rule follows an echoed
  -- prompt: without a rule above it, that ❯ isn't a composer.
  local rows = screen("delivered@claude-code")
  assert(vt.text(rows[7]):find("^❯ %[from") and vt.text(rows[9]) == "", "the fixture changed")
  for r = 20, 22 do rows[r] = blank() end
  rows[9] = rule()
  local c = vendors.find("claude-code").composer(rows)
  assert(c == nil, c and c.text)
end)
trial("claude-code: a ❯ row with no closing rule below isn't a composer", function()
  local rows = screen("empty@claude-code")
  assert(vt.rule(rows[20]) and vt.rule(rows[22]), "the fixture changed")
  rows[22] = blank()
  local c = vendors.find("claude-code").composer(rows)
  assert(c == nil, c and c.text)
end)
trial("codex: a › that isn't bold isn't the composer", function()
  local rows = screen("empty@codex")
  rows[24] = line(0, "› a plain arrow in the footer", false)
  local c = assert(vendors.find("codex").composer(rows), "no composer")
  assert(c.text == "" and c.dim == placeholder.codex and c.top == 21, c.text)
end)
trial("codex: a bold › past column 2 isn't the composer", function()
  local rows = screen("empty@codex")
  rows[24] = line(4, "› an indented bold arrow", true)
  local c = assert(vendors.find("codex").composer(rows), "no composer")
  assert(c.text == "" and c.dim == placeholder.codex and c.top == 21, c.text)
end)
trial("CLIs are found by app, or by process name when the app is missing", function()
  for _, app in ipairs(apps) do assert(vendors.find(app), app) end
  assert(vendors.find(nil, "claude") == vendors.find("claude-code"))
  assert(vendors.find(nil, "codex") == vendors.find("codex"))
  assert(vendors.find(nil, "opencode") == vendors.find("opencode"))
  assert(vendors.find("aider") == nil and vendors.find(nil, "bash") == nil and vendors.find(nil, nil) == nil)
  assert(vendors.find("find") == nil and vendors.find("token") == nil, "the module's own functions aren't CLIs")
end)
trial("a token must be the whole composer", function()
  local codex = vendors.find("codex")
  assert(not vendors.token(codex, "see [Pasted Content 20 chars]"))
  assert(not vendors.token(codex, "[Pasted Content 20 chars] [Pasted Content 30 chars]"))
end)

if failed > 0 then print(failed .. " of " .. n .. " vendor trials failed.") os.exit(1) end
print("Passed " .. n .. " vendor trials.")
