# Rex Teams

![Claude starts three subagents in Rex, and they run side by side](media/hero.webp)

A skill that lets coding agents in [Rex](https://rex.superlogical.com) start subagents, message long-running teammates, and set up one-time or recurring timers to check work on a schedule.

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

### Teammates (Grok Bot style)

Open agents in labeled tabs or panes, then talk to one:

> Hi Chief, ask Marketer to create a launch video for my product. 

### Scheduled wake-ups

Ask your agent to wake itself later, or periodically. The skill's `wake.lua` script runs in a background Rex tab. Nothing extra needs installing.

Spawned subagents also get a small exit watchdog. If a child exits without a valid initial report, it wakes the parent with an exit notice.

## Limits

- If you're typing in a pane when a message lands, the message mixes into your draft.
- The watchdog covers the initial report, not hangs or follow-up tasks. A child that writes its result but dies before notifying the parent can still leave the parent waiting.
- Timers and watchdogs require their Rex session and worker processes to remain alive. They do not recover after a server restart.
- Codex needs two settings in `~/.codex/config.toml`, so it can reach Rex and reply from the right tab:

```toml
[sandbox_workspace_write]
network_access = true

[features]
daemon_auto_start = false
```
