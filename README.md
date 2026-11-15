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

## Usage patterns 

### Subagents

Ask your agent:

> Have Codex review this diff and Pi check the docs, then merge their findings.

Parallel coding agents use separate Git worktrees. Their tabs show `↳ task (w)`; launch output and the team listing show the branch and checkout path without crowding the tab. Parents handle integration and cleanup. Closing a tab leaves the worktree intact.

### Teammates (Grok Bot style)

Open agents in labeled tabs or panes, then talk to one:

> Hi Chief, ask Marketer to create a launch video for my product. 

### Set alarms

> Check in on the Marketer agent in 20 minutes.

> Every 10 minutes, check CI on my PR and stop once it's green.

## Limitations

- If you're typing in a pane when a message lands, the message mixes into your draft.
- A subagent that crashes before reporting wakes nobody.
- Alarms stop if the Rex server restarts.
- Tested with Rex 0.1.0 (beta), Claude Code 2.1, Codex CLI 0.166, Pi 1.5 and OpenCode 2.2.
