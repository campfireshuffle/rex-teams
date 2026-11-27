# Contributing

Thanks for helping. rex-teams is meant to stay small: a few Lua scripts that Rex runs with `rex do`, and one skill file. No hooks, and nothing to install: the one long-running piece, the postman, is itself a `rex do` script. [ARCHITECTURE.md](ARCHITECTURE.md) shows how the parts fit. The goal is that Rex can replace it one day and nobody misses anything.

## Before you start

- **Open an issue first** for anything bigger than a fix, so we can agree it belongs here. Most "add a feature" ideas are better as wording in `SKILL.md` than as code.
- A script earns its place only where agents would otherwise get something wrong, like the header on every message. Anything a capable agent can do with a plain `rex` command belongs in the skill instead.

## Making a change

1. Keep the scripts to Lua 5.1 and Rex's `rex` API, so they run wherever Rex does. Check they parse with `luac5.1 -p skills/rex-teams/scripts/*.lua`.
2. Test the change in Rex with real agents. At least run one fan-out (one subagent each of Claude, Codex, and Pi), one resume, and one alarm, and say in the pull request what you ran. A change to delivery also needs the live battery, `rex do tests/live/battery.lua`, which checks each CLI with real panes.
3. **Build for the steady state.** Assume the current Rex on every host, set up the normal way, and write one code path for that. When something is missing or fails, stop with an error that says what's wrong. Don't add a second path for older Rex, for a feature someone turned off, or for when the first path fails, and don't substitute a default or retry silently. A fallback hides the failure, is rarely tested, and is how a message reaches the wrong pane. Write the docs the same way: describe how things work in the steady state, and list a limitation only if it surprises people in normal use. The minimum Rex is stated once, in `README.md`; raise it when a change needs more.
4. Put tests in `tests/` as Lua 5.1 files that exit non-zero on failure. CI runs every `tests/*.lua`, so a new test needs no CI change.
5. Update `README.md` when behavior changes. Release notes are written from the merged pull requests, so a clear title is enough.

## Pull requests

- Title it as a [Conventional Commit](https://www.conventionalcommits.org), such as `fix: keep the reply header on one line`. Pull requests are squash-merged, and the title becomes the commit message.
- Keep each pull request to one change.
- CI must pass before merging.

## Conduct

Be kind, and assume good intent. The maintainer may close issues or lock threads that aren't.
