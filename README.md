# rex-teams

A skill that lets Claude Code, Codex, and Pi work together as a team inside [Rex](https://rex.superlogical.com).

- **Subagents.** An agent starts another agent in a background tab, keeps talking to it while it works, and gets woken up when it reports back. Then it closes the tab, or reopens it later with its memory intact.
- **Teams.** You open a few long-running agents in Rex and label their tabs or panes, say `chief`, `pm`, and `engineer`. They can find each other and send each other messages.

It's a stopgap. I expect Rex to ship something like this itself, and when it does you can delete this skill without leaving anything behind: no daemon, no hooks, no config.

```text
you ── spawn ──▶ a new tab "↳ review"                    (subagent)
you ── send ───▶ any agent's tab                         (a question, an answer, a new ask)
agent ── send ──▶ you                                    (a report, or a reply)
you ── close / resume                                    (plain rex commands the skill spells out)
```

Every message is one line typed into the other agent's terminal, which starts its next turn. Claude queues a message that arrives mid-turn, Codex accepts it, and Pi steers with it. Nobody polls. Each message starts with a header saying who sent it and the exact command for replying, so even an agent that hasn't loaded the skill can answer.

## Install

```sh
npx skills add campfireshuffle/rex-teams -g -a claude-code -a codex -a pi
```

This puts the skill in `~/.agents/skills/rex-teams` (read by Codex and Pi) and links it into `~/.claude/skills` (read by Claude Code). Leave out `-a ...` to choose agents interactively.

It needs `rex` and `jq` on your `PATH`.

### Codex setup

These two problems affect any Codex agent that runs `rex` commands, with or without this skill. They hit harder here, though, because subagents run unattended and replies depend on each agent knowing its own tab. Add both to `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`):

```toml
[sandbox_workspace_write]
network_access = true

[features]
daemon_auto_start = false
```

- `network_access` lets sandboxed commands reach the Rex socket. Without it, Codex asks you to approve every message it sends.
- `daemon_auto_start = false` makes each Codex tab run its own commands. Otherwise Codex tabs share one background daemon, whose commands see the first tab's `REX_BLOCK`, and replies go to the wrong tab. If a daemon is already running, stop it once with `pkill -f 'codex app-server'`.

## Using it

### Subagents

Ask your agent for one in plain words:

> Have Codex review this diff and Pi check the docs, then merge their findings.

The agent writes a task file, runs `spawn`, and ends its turn. The subagents open as `↳` tabs next to your agent's tab, and you can click into them to watch or type. Each one writes `result.md` and sends a one-line report. When the last one is in, your agent gives you one answer and closes their tabs.

### Teams

Set up the team yourself. One way is a Rex session with one labeled tab per role:

```sh
rex session new launch --window chief -c ~/work/launch -- claude
rex window new pm       -s launch -c ~/work/launch -- codex
rex window new engineer -s launch -c ~/work/app    -- pi
rex window new marketer -s launch -c ~/work/launch -- claude
```

Or put the team side by side in one tab, one labeled pane each:

```sh
rex session new crew --window team -c ~/work/app -- claude
rex block rename -s crew chief
rex split -s crew --label eng --split right -c ~/work/app -- codex
rex split -s crew --label qa  --split right -c ~/work/app -- pi
```

The labels are up to you. So is the shape of the team: a chief who hands out work, peers who talk freely, or several sessions. Give each agent its brief the way you normally would, in a first message or in its project's `AGENTS.md` or `CLAUDE.md`, and tell it who its teammates are. Then talk to one of them. An agent finds a teammate's block ID by its label with `rex session inspect`, messages it with `send <session> <block ID> "..."`, and replies go back to whoever asked.

Agents sometimes rename sessions and tabs, so the skill uses labels only to find an agent and IDs to reach it.

Teammates never get closed.

## Patterns

Two scripts do all the work: `spawn` starts a subagent that reports back once, and `send` messages any agent. Every pattern is a way of combining them. Roles are tab labels and briefs, so you set a pattern up by asking for it, and a new pattern needs no new code.

| Pattern | How to ask for it |
| --- | --- |
| Worker | "Have Codex review this diff." |
| Fan-out | "Check these five repos in parallel and give me one summary." |
| Second opinion | "Ask Claude whether this plan holds up." |
| Leads with their own workers | "Split the migration among three leads, and let each lead split its work." |
| Teammates | "Ask pm what's left before launch." |
| Chief of staff | Open a tab labeled `chief` and brief it: "You coordinate. Hand work to pm, engineer, and marketer, start subagents for one-off tasks, and bring me only decisions." Then talk only to `chief`. |
| Pipeline | "When the draft is done, send it to editor, and have editor send the final to me." |

Nesting is off by default. A subagent can start its own only when you ask for it, as in the leads example.

## Scripts

Two scripts in `skills/rex-teams/scripts/`, each starting with a comment saying what it does. Everything else (closing tabs, resuming, checking on agents) is plain `rex` commands that the skill describes.

| Script | What it does |
| --- | --- |
| `spawn --name N --cwd DIR --task-file F [--depth N] -- AGENT [ARGS]` | Starts a subagent in a background tab and adds the rules for reporting back. `AGENT` is `claude`, `codex`, `pi`, or another agent CLI that takes a prompt as its last argument |
| `send SESSION BLOCK MESSAGE` | Types one line into another agent's terminal and presses Enter. `BLOCK` is a block ID, found with `rex session inspect` |

Subagent tasks live in `/tmp/rex-teams/tasks/<task-id>/`:

- `prompt.md` is what the subagent was asked to do.
- `result.md` is its latest report.

Agents keep their own conversations, so a closed subagent can be reopened with its memory. The skill shows each agent how: find the conversation log that mentions the task, then run `claude --resume`, `codex resume`, or `pi --session`. `/tmp` is cleared on restart, but the logs aren't.

## Known limits

- If Rex's "Let agents name sessions" setting is on, Rex tells every new agent to name its session, subagents included. Subagents are told not to, and Claude and Pi listen. Codex sometimes renames the session anyway, because it ranks Rex's hook above its prompt. Turn the setting off if that bothers you.
- Messages are typed into terminals. If you're typing in a pane when a message lands, it mixes into your draft. On a team, mostly type into one agent and let it talk to the rest.
- A subagent that crashes before reporting never wakes anyone. You'll see it in its tab.
- Agents show their folder-trust prompt the first time they open in a new folder.
- It's built for a handful of agents you can watch, not for dozens at once.

## Removing it

```sh
npx skills remove rex-teams -g
rm -rf /tmp/rex-teams
```

Then remove `network_access` from your Codex config if nothing else needs it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately, as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
