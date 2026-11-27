# Architecture

rex-teams is a few Lua scripts that Rex runs with `rex do`. Agents message each other by typing into each other's terminals. A message is queued as a file, and one postman per Rex host types it in: it pastes the message and presses Enter, busy receiver or not. Nothing reads the screen, so a half-written prompt or a dialog gets the message too (#41, #40).

Three ideas cover it:

- **Message**: one line to an address. Replies, subagent reports, the postman's notices and alarms are all messages. An alarm has `at` or `every`.
- **Address**: a terminal (a Rex block) on a host. It's resolved once, when the message is posted.
- **Postman**: the one worker per host that delivers the queue.

## Components

```
send.lua  alarm.lua  team.lua  spawn.lua        entry points: parse arguments, print results
    \        |          |
     mail.lua (post, list)                       validate, resolve the address, start the postman if it isn't running, queue
         |
     outbox/<id>.json                            one file per message
         |
     postman.lua (deliver, ensure, run)          delivery (deliver) and the worker
         |
     pane.lua (exists, type, attach)             the one adapter over Rex's terminal calls
```

| File | Job |
|---|---|
| `send.lua` | `mail.post` for a message; prints `queued message <id> for <name>`. |
| `alarm.lua` | `mail.post` with `at` or `every`; `list=true` lists your alarms. |
| `team.lua` | Lists agents with ready `send.lua` commands, and the branch and worktree of each agent in a linked worktree. |
| `spawn.lua` | Starts a subagent. Its report is a `send.lua` command, so it's an ordinary message. |
| `mail.lua` | `mail.post{to, host?, text, files?, at?, every?} -> id, name` and `mail.list() -> messages`. Post checks the text, the receiver and the files, and raises before queueing, in a plain sentence; `send.lua` and `alarm.lua` check their own arguments. List raises, naming the file, on one that isn't JSON. |
| `postman.lua` | `deliver(msg, now) -> next wake`, which takes one message as far as it can go (Rex calls, outbox writes, notices) and returns when to try it again, or nil once it's over; `ensure()`, which starts the postman or raises; and the worker loop. |
| `pane.lua` | `exists(addr)`, `type(addr, text)` (paste, then Enter), `attach(addr, files, id)` (file copies across hosts). |
| `lib.lua` | Addresses, headers, quoting, `need` for plain refusals. |

No script names an agent CLI; `tests/lint.lua` checks.

## Request flows

**Send**
```
agent ─ rex do send.lua ─► mail.post ─ check, lib.target, postman.ensure ─► (start the postman if it isn't running)
                                     └─ then ─► outbox/<id>.json (tmp + rename); nothing if anything raised
agent ◄─ "queued message <id> for <name>"
```

**Deliver**
```
postman ─ outbox check (every 2 s) or a timer
        ─ each receiver's due messages, in posted order (posted, then seq)
        ─ pane.exists ─► gone            ─► one notice to the sender; the file is kept, marked dead
                      └► raises          ─► hold (Rex can't reach it): the rest of that receiver's queue waits, in order
                      └► there           ─► attach files (another host) ─► save d.pasted_at ─► pane.type
pane.type went through ─► delete the file (a recurring alarm waits for its next tick)
pane.type raised       ─► one notice to the sender, with the error; the file is deleted (a recurring alarm: see below), never pasted again
a restart finds d.pasted_at ─► the same notice ("the postman stopped between its paste and its Enter"), deleted (a recurring alarm: see below)
```

After a failed paste, a recurring alarm keeps its file and drops only that tick; its next tick goes out as usual.

One postman serves every receiver on this host in one loop. A check of a host that's down takes about 10 s, and a held receiver is checked again every 2 s. So while another host is unreachable, every delivery from this host can be delayed about 10 s per check of it.

An alarm waiting for its next tick, or a one-shot not yet due, doesn't hold up the messages behind it.

**Notice**
```
receiver gone, or files can't be copied ─► one notice, and the file is kept
paste or Enter failed, or may not have finished ─► one notice, and the message (or a recurring alarm's tick) is dropped
notices, and messages you sent yourself, never cause notices
```

**Alarm**
```
alarm.lua ─► mail.post{at=…} or {every=…} ─► outbox     (in= is any positive number; every= is at least 10)
postman: timer to the due time ─► deliver as above
recurring: tick k at start + k·every, never drifting
a due tick goes out however late; ticks that pile up (a restart, a sleep, an unreachable pane) collapse into the latest one
```

**Spawn and report**
```
parent ─ spawn.lua ─► new tab running the CLI with "Read <task>/prompt.md and follow it."
child  ─ (report.md's notify line) rex do send.lua block=<parent> … ─► a message like any other
```

**Cross-host**
```
send.lua host=ws ─► mail.post resolves the address on ws, writes the outbox here
postman here ─ rex.server("ws") ─► exists, type on ws; rex cp the files into ws's inbox first
```

## Where state lives

| Path | What |
|---|---|
| `/tmp/rex-teams/outbox/<id>.json` | A queued message and its delivery state. Written whole (tmp + rename). The postman saves its delivery state in it before each copy or paste, and deletes it once delivered or dropped. Delete it to drop a message or cancel an alarm. A message whose receiver is gone, or whose files couldn't be copied, stays, marked `dead`. A file that isn't JSON stops delivery, and the postman says once, in its block, to delete it. |
| `/tmp/rex-teams/stage/<id>/` | Files on their way to another host, removed after the copy. |
| `/tmp/rex-teams/inbox/<block>/<id>/` | Files that arrived from another host. The receiver removes them. |
| `/tmp/rex-teams/tasks/<task>/` | A subagent's prompt, report and close command. |
| `/tmp/rex-teams/depth/<block>` | How many levels of subagents a subagent may start. |
| The `rex-teams` session | Holds the postman's detached block, labelled `rex-teams postman`. Rex is the record of who the postman is: the oldest live block with that label (one running `rex`) in any session labelled `rex-teams`. `ensure` starts one if there's none, and a newer one quits at start. Right after a Rex restart, two can rarely overlap. |

On Windows the root is `%TEMP%\rex-teams`.

## Rex APIs each part relies on

If Rex grows a better API, this table says what to swap.

| Part | Rex API | Could become |
|---|---|---|
| `pane.exists` | `target.resolve` | the same |
| `pane.type` | `block.event` paste, then key Enter | a native queue (a CLI's or Rex's), or a Rex "unsent input" signal; then #40 and #41 close |
| `pane.attach` | `rex cp` | the same |
| postman timers | `rex.after` | the same |
| postman restart | OSC 7577 report, and the trust rule over the scripts folder that README.md quotes | the same |
| postman singleton | `session.list`, `session.list_blocks`, `block.method process` for liveness | a Rex singleton or named service |
| postman home | `session.list`, `session.create`, `session.new_block` (detached) | a Rex background service |
| cross-host | `rex.server(label)` | the same |
| listing the outbox | `block.method list_dir` | the same |
| addresses | `target.resolve`, `session.view` | the same |
