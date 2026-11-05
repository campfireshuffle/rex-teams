# Rex Teams

![Claude starts three subagents in Rex, and they run side by side](media/hero.webp)

A skill that lets coding agents in [Rex](https://rex.superlogical.com) start subagents and message long-running teammates.

> [!TIP]
> I expect Rex to do this better itself one day. When it does, delete the skill.

Rex already gives agents everything this skill needs: tabs, `rex send`, and `rex capture`. `rex-teams` just adds the habits on top. It sets out how a subagent reports back, and it starts every message with the command for replying. A message is typed into the other agent's terminal, which starts its next turn, so nobody polls.

## Install

```sh
npx skills add campfireshuffle/rex-teams
```

It needs only Rex. The scripts are Lua that Rex runs itself, so they should work on Windows too, though only macOS is tested.

## Usage patterns 

### Subagents

Ask your agent:

> Have Codex review this diff and Pi check the docs, then merge their findings.

### Teammates (Grok Bot style)

Open agents in labeled tabs or panes, then talk to one:

> Hi Chief, ask Marketer to create a launch video for my product. 

## Limits

- If you're typing in a pane when a message lands, the message mixes into your draft.
- A subagent that crashes before reporting wakes nobody.
- Codex needs two settings in `~/.codex/config.toml`, so it can reach Rex and reply from the right tab:

```toml
[sandbox_workspace_write]
network_access = true

[features]
daemon_auto_start = false
```
