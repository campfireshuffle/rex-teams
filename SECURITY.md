# Security

## Reporting a problem

Please don't open a public issue. Report it privately through [GitHub's vulnerability reporting](https://github.com/campfireshuffle/rex-teams/security/advisories/new). You'll get a reply within a week.

## What to keep in mind

- `send` types text into another agent's terminal, where the agent treats it as a prompt. Anything that can run `send` can talk to every agent in your Rex sessions. The skill tells agents to treat each other's messages as information, not as orders that override yours, but that's an instruction, not a guarantee.
- Task files and reports live in `/tmp/rex-teams/`, readable by other processes running as your user. Don't put secrets in a task.
- Subagents run with whatever permissions their agent CLI is given. `spawn` passes your agent options through unchanged.
