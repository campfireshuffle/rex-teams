-- What each agent CLI's prompt box (its composer) looks like on screen. This
-- is the only file that names a CLI; tests/lint.lua checks that.
--
-- Each entry, keyed by the app name the CLI reports with OSC 7501:
--   composer(rows) -> { text, dim, top, bottom } | nil
--     rows is the visible screen from vt.screen. text is what a person (or
--     we) typed, dim is placeholder or suggestion text, top..bottom are the
--     composer's rows. nil means no composer is showing, as when a dialog
--     covers it, and the postman holds.
--   tokens: patterns for the stand-in a CLI shows for a long paste. A
--     composer holding exactly one of them, right after our paste, holds ours.
-- A CLI that doesn't report its app is found by its process name. A CLI not
-- listed here gets no messages: the postman holds them and says why.
local vt = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "vt.lua")
local vendors, cli = {}, {}

local sgrdim = function(c) return c.dim end

cli["claude-code"] = {
  -- A "❯ " row under a ─ rule; the box ends at the next rule. Wrapped rows
  -- indent 2. Placeholders are SGR dim.
  composer = function(rows)
    for r = #rows, 2, -1 do
      local f = vt.first(rows[r])
      if f and rows[r][f].ch == "❯" and vt.rule(rows[r - 1]) then
        local e = r
        while rows[e + 1] and not vt.rule(rows[e + 1]) do e = e + 1 end
        if not rows[e + 1] then return nil end
        return vt.collect(rows, r, e, f + 2, sgrdim)
      end
    end
  end,
  tokens = { "^%[Pasted text #%d+[^%]]*%]$" },
}

cli.codex = {
  -- The last bold "›" at column 1 or 2. Wrapped rows indent 2 or more, and
  -- the box ends at a blank row. Placeholders are SGR dim. An approval list
  -- ("› 1. Yes") looks the same, which is why the postman checks blocked
  -- first and never treats text that isn't ours as safe.
  composer = function(rows)
    for r = #rows, 1, -1 do
      local f = vt.first(rows[r])
      if f and f <= 2 and rows[r][f].ch == "›" and rows[r][f].bold then
        local e = r
        while rows[e + 1] and (vt.first(rows[e + 1]) or 0) >= 3 do e = e + 1 end
        return vt.collect(rows, r, e, f + 2, sgrdim)
      end
    end
  end,
  tokens = { "^%[Pasted Content %d+ chars%]$" },
}

cli.opencode = {
  -- A "┃"-framed box on a raised background, ending above the
  -- "Agent · model" row and a "╹" row. The placeholder isn't SGR dim: it is
  -- the theme's muted colour, the colour of the "·" on the model row.
  composer = function(rows)
    local bottom
    for r = #rows, 1, -1 do
      local f = vt.first(rows[r])
      if f and rows[r][f].ch == "╹" then bottom = r; break end
    end
    if not bottom then return nil end
    local model = bottom - 1
    while model > 1 and not vt.text(rows[model]):match("%S") do model = model - 1 end
    local muted
    for _, c in ipairs(rows[model]) do if c.ch == "·" then muted = c.fg end end
    local bar = vt.first(rows[model])
    if not (bar and rows[model][bar].ch == "┃" and rows[model][bar + 1]) then return nil end
    local boxbg = rows[model][bar + 1].bg
    local function inbox(row)
      local f = vt.first(row)
      return f == bar and row[f].ch == "┃" and row[f + 1] and row[f + 1].bg == boxbg
    end
    local top = model - 1
    if top < 1 or not inbox(rows[top]) then return nil end
    while top > 1 and inbox(rows[top - 1]) do top = top - 1 end
    return vt.collect(rows, top, model - 1, bar + 3, function(c) return c.dim or (muted ~= nil and c.fg == muted) end)
  end,
  tokens = { "^%[Pasted ~%d+ lines?%]$" },
}

cli.pi = {
  -- The rows between the last two full-width ─ rules. No glyph and no
  -- placeholder; the cursor is an inverse cell.
  composer = function(rows)
    local below
    for r = #rows, 1, -1 do
      if vt.rule(rows[r]) then
        if below then return vt.collect(rows, r + 1, below - 1, 1, sgrdim) end
        below = r
      end
    end
  end,
  tokens = { "^%[paste #%d+ [^%]]*%]$" },
}

-- Process names, for a CLI that doesn't report its app.
local by_process = { claude = "claude-code", codex = "codex", opencode = "opencode" }

-- The entry for a program, from its reported app or its process name, or nil.
function vendors.find(app, process)
  if app then return cli[app] end
  return cli[by_process[process or ""] or ""]
end

-- Whether TEXT, a composer's text, is exactly one of the CLI's paste tokens.
function vendors.token(entry, text)
  for _, pattern in ipairs(entry.tokens) do
    if text:match(pattern) then return true end
  end
  return false
end

return vendors
