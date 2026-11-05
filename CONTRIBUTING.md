# Contributing

Thanks for helping. rex-teams is meant to stay small: a few Lua scripts that Rex runs with `rex do`, and one skill file. No installed daemon, no hooks. A scoped watchdog may run in a detached Rex block while its child is alive. The goal is that Rex can replace it one day and nobody misses anything.

## Before you start

- **Open an issue first** for anything bigger than a fix, so we can agree it belongs here. Most "add a feature" ideas are better as wording in `SKILL.md` than as code.
- A script earns its place only where agents would otherwise get something wrong, like the header on every message. Anything a capable agent can do with a plain `rex` command belongs in the skill instead.

## Making a change

1. Keep the scripts to Lua 5.1 and Rex's `rex` API, so they run wherever Rex does. Check they parse with `luac5.1 -p skills/rex-teams/scripts/*.lua`.
2. Run `lua5.1 tests/watch.lua` for watchdog state tests. With Rex running, run `REX_BIN=/path/to/rex python3 tests/live.py` for isolated timer/watchdog integration tests. The live tests use Python's standard library, create their own Rex session, and remove it afterward.
3. Test the change in Rex with real agents. At least run one fan-out (one subagent each of Claude, Codex, and Pi) and one resume, and say in the pull request what you ran.
4. Update `README.md` when behavior changes. Release notes are written from the merged pull requests, so a clear title is enough.

## Pull requests

- Title it as a [Conventional Commit](https://www.conventionalcommits.org), such as `fix: keep the reply header on one line`. Pull requests are squash-merged, and the title becomes the commit message.
- Keep each pull request to one change.
- CI must pass before merging.

## Conduct

Be kind, and assume good intent. The maintainer may close issues or lock threads that aren't.
