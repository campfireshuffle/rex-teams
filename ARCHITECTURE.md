# Architecture

rex-teams is a few Lua scripts that Rex runs with `rex do`. Agents message each other by typing into each other's terminals. A message is queued as a file, and one postman per Rex host types it in when the receiver's prompt box is free.

Three ideas cover it:

- **Message**: one line to an address. Replies, subagent reports, the postman's notices and alarms are all messages. An alarm has `at` or `every`.
- **Address**: a terminal (a Rex block) on a host. It's resolved once, when the message is posted.
- **Postman**: the one worker per host that delivers the queue.

## Components

```
send.lua  alarm.lua  team.lua  spawn.lua        entry points: parse arguments, print results
    \        |          |
     mail.lua (post, list)                       validate, resolve the address, queue, wake the postman
         |
     outbox/<id>.json                            one file per message
         |
     postman.lua (step, ensure, run)             the policy (step) and the worker
         |
     pane.lua (look, put, enter, attach)         the one adapter over Rex's terminal calls
         |
     vendors.lua  +  vt.lua                      what each CLI's prompt box looks like; the screen reader
```

| File | Job |
|---|---|
| `send.lua` | `mail.post` for a message; prints `queued message <id> for <name>`. |
| `alarm.lua` | `mail.post` with `at` or `every`; `list=true` lists your alarms. |
| `team.lua` | Lists agents with ready `send.lua` commands, and how many messages wait for each. |
| `spawn.lua` | Starts a subagent. Its report is a `send.lua` command, so it's an ordinary message. |
| `mail.lua` | `mail.post{to, host?, text, files?, at?, every?} -> id, name, hint` and `mail.list`. Raises before queueing on bad input. |
| `postman.lua` | `step(msg, look, now) -> action`, the pure delivery policy; `ensure()`, which starts the postman; and the worker loop. |
| `pane.lua` | `look(addr, tag)`, `put(addr, text)`, `enter(addr)`, `attach(addr, files, id)`. |
| `vendors.lua` | The only file that names a CLI: each one's composer parser, placeholder rule and paste-token patterns. |
| `vt.lua` | Turns Rex's `format=vt` output into styled cells. |
| `lib.lua` | Addresses, headers, quoting, file copies across hosts. |

## Request flows

**Send**
```
agent ─ rex do send.lua ─► mail.post ─ check, lib.target ─► outbox/<id>.json (tmp + rename)
                                     └─ postman.ensure ─► (start the postman if it isn't running)
agent ◄─ "queued message <id> for <name>"
```

**Deliver**
```
postman ─ outbox check (every 2 s) or a timer or a status event
        ─ pane.look ─► { status, composer, seen }
        ─ step ─► hold     (blocked, working, no composer, text in it, or an unknown CLI)
               └► put      ─ pane.put (paste "[from X · msg <id>, …] text") ─ pane.enter
```

**Confirm**
```
status event "working" after the paste ───────────────► done: delete the file
or: composer no longer holds ours, and "msg <id>" is on the screen above it ─► done
```

**Retry**
```
ours still in the composer ─► Enter again (2 s apart, at most 3) ─► then "couldn't confirm"
composer empty, id not seen, not working, 10 s / 30 s / 60 s after the paste
    ─► paste again, labelled "· resent" ─► after the third, notice "couldn't confirm"; keep the file
```

**Notice**
```
held 10 minutes ─► one notice to the sender, as a message from "rex-teams postman"
receiver gone, or files can't be copied ─► one notice, and the file is kept
notices, and alarms you set yourself, never cause notices
```

**Alarm**
```
alarm.lua ─► mail.post{at=…} or {every=…} ─► outbox
postman: timer to the due time ─► deliver as above
one-shot due while the postman was down ─► "[late by Ns, Rex restarted]"
recurring: tick k at start + k·every; a tick 1 s late, or one that comes while the last is held, is skipped
```

**Spawn and report**
```
parent ─ spawn.lua ─► new tab running the CLI with "Read <task>/prompt.md and follow it."
child  ─ (report.md's notify line) rex do send.lua block=<parent> … ─► a message like any other
```

**Cross-host**
```
send.lua host=ws ─► mail.post resolves the address on ws, writes the outbox here
postman here ─ rex.server("ws") ─► look, put, enter on ws; rex cp the files into ws's inbox first
(no status events from ws, so the postman checks it every 2 s)
```

## Where state lives

| Path | What |
|---|---|
| `/tmp/rex-teams/outbox/<id>.json` | A queued message and its delivery state. The postman rewrites it after each step and deletes it once delivered. Delete it to drop a message or cancel an alarm. A message the postman gave up on stays, marked `dead`. |
| `/tmp/rex-teams/postman.json` | The running postman: its block, session and pid. |
| `/tmp/rex-teams/postman.lock` | A `mkdir` lock while a postman claims `postman.json`. |
| `/tmp/rex-teams/stage/<id>/` | Files on their way to another host, removed after the copy. |
| `/tmp/rex-teams/inbox/<block>/<id>/` | Files that arrived from another host. The receiver removes them. |
| `/tmp/rex-teams/tasks/<task>/` | A subagent's prompt, report and close command. |
| `/tmp/rex-teams/depth/<block>` | How many levels of subagents a subagent may start. |
| The `rex-teams` session | Holds the postman's detached block, labelled `rex-teams postman`. |

On Windows the root is `%TEMP%\rex-teams`.

## Rex APIs each part relies on

If Rex grows a better API, this table says what to swap.

| Part | Rex API | Could become |
|---|---|---|
| `pane.look` | `block.method program_status` (OSC 7501 state and kind) | the same |
| `pane.look` | `block.method format` (vt), `size`, `blob_read`, parsed by `vendors.lua` | a Rex "unsent input" or composer API; then the parsers go |
| `pane.look` | `target.resolve` for a pane that's gone | the same |
| `pane.put`, `pane.enter` | `block.event` paste, then key Enter | a native queue (a CLI's or Rex's); then confirmation is an ack |
| `pane.attach` | `rex cp` (via `lib.send_files`) | the same |
| postman events | `rex.on("terminal.program_status_changed")`, `rex.on("block_closed")`, `session.attach` | the same |
| postman timers | `rex.after` | the same |
| postman restart | OSC 7577 report, trust rule over the scripts folder, `program_resume_records` | the same |
| postman singleton | `postman.json`, `mkdir` lock, `block.method process` for liveness | a Rex singleton or named service |
| postman home | `session.list`, `session.create`, `session.new_block` (detached) | a Rex background service |
| cross-host | `rex.server(label)` | the same |
| listing the outbox | `block.method list_dir` | the same |
| addresses | `target.resolve`, `session.view` | the same |
