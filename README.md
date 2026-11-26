# Rex Teams

![Claude starts three subagents in Rex, and they run side by side](media/hero.webp)

Run subagents inside Superlogical's [Rex terminal](https://rex.superlogical.com), across agent harnesses. Rex Teams lets a parent agent spawn Claude Code, Codex, Pi, OpenCode, or other agent CLIs in background tabs, receive their reports, and close completed tabs.

The skill also lets agents message long-running teammates and set one-time or recurring alarms.

This is an unofficial community skill. It isn't made by or affiliated with Superlogical, so please report bugs here, not to Rex.

> [!TIP]
> I expect Rex to do this better itself one day. When it does, delete the skill.

Rex already gives agents everything this skill needs: tabs, `rex send`, and `rex capture`. `rex-teams` just adds the habits on top. It sets out how a subagent reports back, and it starts every message with the command for replying. A message is typed into the other agent's terminal, which starts its next turn, so nobody polls.

## Install

```sh
npx skills add campfireshuffle/rex-teams
```

Requires Rex 0.1.0-preview.25 or later on every host you use, and `sha256sum` (macOS 15+ or coreutils) on macOS and Linux.

## Usage patterns

Start a request with the skill's name. That's `/rex-teams` in Claude Code, `$rex-teams` in Codex and `/skill:rex-teams` in Pi; for OpenCode, check your CLI.

### Subagents

> /rex-teams Have Codex review this diff and Pi check the docs, then merge their findings.

Parallel coding agents use separate Git worktrees. Their tabs show `↳ task (w)`; launch output and the team listing show the branch and checkout path without crowding the tab. Parents handle integration and cleanup. Closing a tab leaves the worktree intact.

### Teammates (Grok Bot style)

Open agents in labeled tabs or panes, then talk to one:

> /rex-teams Hi Chief, ask Marketer to create a launch video for my product.

### Other hosts

> /rex-teams Ask the Builder agent on my-server to run the test suite.

> /rex-teams Send report.md to the reviewer on my-server and ask for comments.

### Set alarms

> /rex-teams Check in on the Marketer agent in 20 minutes.

> /rex-teams Every 10 minutes, check CI on my PR and stop once it's green.

### Keep alarms across Rex restarts

Rex resumes an alarm after it restarts only if you trust rex-teams' alarm script. Add this to Rex's `init.lua`, with the absolute path of the installed skill, then run `rex config reload`:

```lua
rex.set("resume.trust.rex-teams-alarm", {
  command = { "rex", "do", "<absolute path to the skill>/scripts/alarm.lua" },
  flags = { ["--args"] = { "keep", values = 1 } },
})
```

An alarm's details are its `--args`, so the rule trusts that one script with any arguments. Until you add the rule, setting an alarm prints it with the real path. A one-shot alarm that was due while Rex was down fires once when Rex is back, marked `[late by Ns, Rex restarted]`. A recurring alarm skips the ticks it missed.

## Limitations

- If you're typing in a pane when a message lands, the message mixes into your draft.
- A pasted message is occasionally left unsubmitted ([#40](https://github.com/campfireshuffle/rex-teams/issues/40)).
- A subagent that crashes before reporting wakes nobody.
- On Windows, alarms don't come back after a Rex restart.
- Messages are one-way. A reply across hosts works only if the receiver's `rex hosts` can reach the sender's host.
- `spawn.lua` starts subagents only on your own host. You can message agents on other hosts and send them files, but not start them there yet ([#37](https://github.com/campfireshuffle/rex-teams/issues/37)).
- A Windows sender can't send files to another host yet.
- Short IDs that look like numbers need `--args` ([#38](https://github.com/campfireshuffle/rex-teams/issues/38)).
- Tested with Rex 0.1.0-preview.25, Claude Code 2.1.326, Codex CLI 0.172.0, Pi 1.6.0 and OpenCode 2.4.1.
