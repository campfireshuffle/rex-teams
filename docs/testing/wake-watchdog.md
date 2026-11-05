# Wake-up and watchdog checks

Tested against Rex `0.0.1793645657-gd018d2` (API revision 10) on macOS.
The final runs used the current paste-based sender from main.

## Repeatable tests

```sh
lua5.1 tests/watch.lua
REX_BIN=/path/to/rex python3 tests/live.py
```

When Lua is not installed separately, `rex do tests/watch.lua` also runs the
19 state tests. CI runs them under Lua 5.1. The live test uses Python's standard
library and only its own temporary Rex session.

The state tests cover duplicate events, immediate exits, closures before and
after subscription, missing parents, all three report statuses, CRLF and empty
reports, late report publication, API failure, and ambiguous send failure.

The live checks passed:

- The exact Lua recipe extracted from the documentation fires once after its
  creating CLI returns, then its timer tab closes.
- Recurring delivery, cancellation before firing, and cancellation after ticks.
- Five immediate zero-code exits each produce one watchdog notice.
- Nonzero exit, SIGKILL, and executable startup failure produce notices.
- Completed, failed, and blocked reports suppress notices.
- Manual child closure is quiet, including closure before watcher startup.
- Parent closure cleans up the watchdog and timer, including startup after the
  parent is already gone.
- Real spawn creates its watchdog and receives its startup acknowledgement.

An early live run found that the timer recipe could miss target closure during
startup. It now subscribes and checks current membership before arming.

## Real harness checks

Ran a fan-out with Pi 1.5.0, Codex CLI 0.166.0, and Claude Code 2.1.311. Each
wrote a marker and result, then delivered its report to a recording parent pane.
All three passed with the final sender and watchdog. No watchdog notices were
emitted during normal reporting.

The documented timer then woke the idle Pi agent. Pi wrote a second marker and
reported back. Closed its tab, resumed its saved session in a new tab, and
verified another marker and report. No spurious watchdog notice appeared.

The initial Claude run required trusting the temporary test directory and
approving a marker-writing command. A test invocation also needed `--` before
its initial prompt because `--allowedTools` consumes multiple arguments. The
final run used `--allowedTools=Read,Write,Bash(rex:*) -- {prompt}` and file-write
tools for its markers. These are test setup details, not new skill behavior.

All temporary Rex sessions were removed. No package, service, cron job, or
scheduler was installed.

## Scope and remaining limits

No Windows or Linux live harness tests, server-restart recovery, remote-host
setup, or machine suspend/resume tests were run. The watchdog covers the initial
report only. A valid result whose notification never arrived remains a gap.
Terminal delivery is not acknowledged and is not retried after ambiguous failure.
