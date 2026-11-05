# Rex Teams

![Claude starts three subagents in Rex, and they run side by side](media/hero.webp)

A skill that lets coding agents in [Rex](https://rex.superlogical.com) start subagents, message long-running teammates, and set one-time or recurring alarms.

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

Spawned subagents get a background exit watcher. It notifies the parent if the agent's process exits, including during follow-up work. Closing the child's tab cancels the watcher quietly.

### Teammates (Grok Bot style)

Open agents in labeled tabs or panes, then talk to one:

> Hi Chief, ask Marketer to create a launch video for my product. 

### Set alarms

> Check in on the Marketer agent in 20 minutes.

> Every 30 minutes, wake up and check Reddit.

Alarms support a one-time delay or a repeating interval, not cron expressions or calendar schedules. They run in background Rex tabs; nothing extra needs installing.

## Limits

- If you're typing in a pane when a message lands, the message mixes into your draft.
- The exit watcher detects process exit, not a hung agent or a finished turn. A CLI that exits normally after reporting also produces an exit notice; this is not a crash diagnosis.
- Alarms and exit watchers require their Rex session and worker processes to remain alive. They do not recover after a server restart.
- Codex needs two settings in `~/.codex/config.toml`, so it can reach Rex and reply from the right tab:

```toml
[sandbox_workspace_write]
network_access = true

[features]
daemon_auto_start = false
```
