# Rex Teams

![Claude starts three subagents in Rex, and they run side by side](media/hero.webp)

Run subagents inside Superlogical's [Rex terminal](https://rex.superlogical.com), across agent harnesses. Rex Teams lets a parent agent spawn Claude Code, Codex, Pi, OpenCode, or other agent CLIs in background tabs, receive their reports, and close completed tabs.

The skill also lets agents message long-running teammates and set one-time or recurring alarms.

This is an unofficial community skill. It isn't made by or affiliated with Superlogical, so please report bugs here, not to Rex.

> [!TIP]
> I expect Rex to do this better itself one day. When it does, delete the skill.

Rex already gives agents everything this skill needs: tabs and terminal input. `rex-teams` adds the habits on top. It sets out how a subagent reports back, and it starts every message with the command for replying. A message is typed into the other agent's terminal, so nobody polls.

Messages are queued, and one postman per Rex host delivers them. [ARCHITECTURE.md](ARCHITECTURE.md) explains how.

## Install

```sh
npx skills add -g campfireshuffle/rex-teams
```

Requirements:
- Rex 0.1.0-preview.25 or later
- `sha256sum` (macOS 15+ or coreutils) on macOS and Linux.

So that the postman comes back after Rex restarts, add this line to Rex's `init.lua`, with your skill folder's path, and run `rex config reload`:

```lua
rex.set("resume.trust.rex-teams", { command = { "rex", "do", rex.match.under("<skill>/scripts") }, flags = { ["--args"] = { "keep", values = 1 } } })
```

Without it, queued messages and alarms are kept, and go out once the next message starts the postman.

## Usage patterns

### Subagents

> /rex-teams Have Codex review this diff and Pi check the docs, then merge their findings.

### Teammates (Grok Bot style)

Open agents in labeled tabs or panes, then talk to one:

> /rex-teams Hi Chief, ask Marketer to create a launch video for my product.

> /rex-teams Ask the Builder agent on my-server to run the test suite.

> /rex-teams Send report.md to the reviewer on my-server and ask for comments.

### Set alarms

> /rex-teams Check in on the Marketer agent in 20 minutes.

> /rex-teams Every 10 minutes, check CI on my PR and stop once it's green.

## Limitations

- Messages are typed in as they arrive, into whatever the receiver shows: a half-written prompt or a dialog included. A lost Enter ([#40](https://github.com/campfireshuffle/rex-teams/issues/40)) and drafts ([#41](https://github.com/campfireshuffle/rex-teams/issues/41)) are open.
- A busy agent gets a message mid-turn. Its CLI decides what to do with it.
- The postman runs in a session labelled `rex-teams`. It comes back after a Rex restart only with the trust rule above. On Windows it doesn't come back.
- A subagent that crashes before reporting wakes nobody.
- Messages are one-way. A reply across hosts works only if the receiver's `rex hosts` can reach the sender's host.
- `spawn.lua` starts subagents only on your own host. You can message agents on other hosts and send them files, but not start them there yet ([#37](https://github.com/campfireshuffle/rex-teams/issues/37)).
- A Windows sender can't send files to another host yet.
- Short IDs that look like numbers need `--args` ([#38](https://github.com/campfireshuffle/rex-teams/issues/38)).
- Tested with Rex 0.1.0-preview.25, Claude Code 2.1.326, Codex CLI 0.172.0, Pi 1.6.0 and OpenCode 2.4.1.
