# Rex alarms and spawn watchdog spike

## Recommendation

Use Rex-hosted Lua workers, not cron, launchd, Skulk, or a new installed service. Each alarm or child watch runs as a detached Rex terminal block. It survives the short command that created it, without adding a visible tab. Its lifetime is bounded by the Rex server, its session, and the worker process.

This is a plan, not an implementation. Existing uncommitted Lua migration changes were inspected and left untouched.

## Sources and local evidence

- [Rex Lua API](https://www.superlogical.com/rex/docs/reference/lua.md): `rex.after`, `rex.every`, timer cancellation, and `rex.exec.start`.
- [Lua events](https://www.superlogical.com/rex/docs/automate/lua-events.md): handlers, session scope, errors, and script lifetime.
- [Event reference](https://www.superlogical.com/rex/docs/reference/events.md): `terminal.child_exited`, `block_closed`, and process-change events.
- Installed CLI `rex api describe session.new_block`: detached blocks run without a window and answer API calls.
- Installed CLI `rex api describe session.list_blocks`: includes detached blocks, unlike the window-based enumeration in our `lib.blocks`.
- Installed CLI `rex api describe com.superlogical.terminal.process`: `last_exit` records terminal-command exit. Missing foreground information alone does not prove exit.
- Installed CLI `rex block types --json`: terminal command, shell, and exit policies.
- [Skulk source README](https://github.com/kitlangton/skulk): useful comparison for wake-up UX and delivery guarantees.
- Local files: `skills/rex-teams/scripts/{spawn,send,team,lib}.lua`, `skills/rex-teams/SKILL.md`, `CONTRIBUTING.md`.

Tested Rex build: `0.0.1793645657-gd018d2`, commit `d018d2de8cc31281265906a4648ec9cae8d2f4c5`, API revision 10. CLI was found inside `/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex`, not on this shell's PATH.

## What the live probes established

Tests used temporary isolated sessions. No messages were sent to existing agent panes. Every test session was removed afterward.

1. `rex.after(0.05, fn)` fired in the installed build. A timer-only script also exited automatically after its last timer fired.
2. `rex.every(0.15, fn)` fired three times; cancellation stopped it and `active()` returned false.
3. A detached block ran a Lua timer after its creating CLI command had exited. It wrote a marker file and remained inspectable with `session.list_blocks` and the process API.
4. `terminal.child_exited` arrived for commands that exited immediately and commands run through the default shell. `process.last_exit` provided a snapshot after the event.
5. Closing a running test block produced `block_closed`, with no child-exit notification observed in that probe. Do not generalize this one ordering to every platform.
6. Unexpected finding: with `shell="none"`, commands that explicitly exited 7 and `/usr/bin/false` were reported as exit code 0. A captured test confirmed the shell command actually ran. The default-shell path correctly reported exit codes 3 and 7. A nonexistent executable under `shell="none"` also produced 0. This needs an upstream repro; the watchdog must not equate zero with successful reporting.

Probe files remain in `/tmp/rex-teams-research-{probe,exits,background}.lua`. They are research artifacts, not shipped helpers.

## Skulk inspiration, without its installation

Borrow named wake-ups, explicit cancellation, and messages that explain why the agent woke. Do not copy its daemon, SQLite persistence, service installation, or OpenCode dependency. Skulk's duplicate-resistant delivery relies on stable OpenCode message IDs. Rex terminal typing has no equivalent acknowledgement or idempotency key, so we cannot claim that guarantee.

## Alarm interface proposal

One new public helper, following the existing `rex do` and key=value conventions:

```sh
# Target defaults to the calling agent's session and block.
rex do <skill>/scripts/alarm.lua after=20m message="Check the deployment"
rex do <skill>/scripts/alarm.lua every=1h message="Review pending work"

# Optionally target another agent explicitly.
rex do <skill>/scripts/alarm.lua after=5m session=<session ID> block=<block ID> message="Check the review"

rex do <skill>/scripts/alarm.lua action=list
rex do <skill>/scripts/alarm.lua action=cancel id=<alarm block ID>
```

`after` and `every` are mutually exclusive. Accept positive durations with s/m/h/d suffixes; reject ambiguous dates and cron expressions. Optional labels can come later. Print the worker's block ID as the alarm ID, schedule, target, and ready-made cancellation command.

### Implementation

1. Validate inputs and target before starting a worker.
2. Create one detached Rex block whose command runs an internal branch of `alarm.lua` through `rex do`. Pass arguments as separate argv entries, not shell-generated text.
3. Worker registers `rex.after` or `rex.every`, then announces readiness. The creator must detect startup failure rather than treating block creation as proof the timer is armed.
4. Callback uses the existing `lib.type_line`. System messages use an alarm header, not a reply address pointing at the worker.
5. List uses `session.list_blocks` and a reserved alarm label prefix, with process inspection to distinguish active and failed workers. Cancel validates the block as an alarm worker before closing it.
6. Successful one-shots remove their worker block; failures stay inspectable. Closing the target cancels its alarms. Session destruction naturally ends the workers.

Reusing Rex blocks avoids a PID registry, OS-specific backgrounding, IPC listener, and new service. A worker is a background process, even though it is not a separately installed daemon. Update CONTRIBUTING's wording to allow scoped Rex-hosted helpers rather than pretending there is no background execution.

### Explicit limitations

- Timers require the server, session, and worker to stay alive. Closing the desktop client is different from stopping the server.
- No restart recovery, calendar scheduling, or waking a sleeping computer. Suspend/resume timing needs a separate test.
- No OSC 7501 requirement and no status gating.
- No inbox and no draft protection. Delivery has exactly the limitations of existing terminal messaging.
- Do not retry a partially successful terminal write automatically. It may duplicate text or submit twice. Record the failure for inspection.
- `rex.every` coalesces ticks while its Lua worker is busy, not while the target agent is busy. Recurring prompts can accumulate in a harness that queues them. Do not claim one pending prompt per agent.
- The script path and Rex executable must be available on the host running the worker. Initial scope should match the existing helpers' same-host assumptions. Check host identity and fail clearly on unsupported remote setups.

## Conservative initial-report watchdog

Add an internal `watch.lua` launched by `spawn.lua`, with no extra step for the parent.

```text
spawn child, retain terminal after exit
    -> start watcher and confirm it armed
    -> register events + inspect current process state
    -> observe confirmed exit
    -> reconcile child block and initial result
    -> suppress or send one factual notice
```

Current spawn already retains the terminal with `exit.on_completion=false`. This makes it possible to detect immediate exits by snapshot even if the event happened before the watcher connected. Register handlers before taking that snapshot; deduplicate snapshot and event paths.

### Notification rules

- Only classify confirmed `terminal.child_exited` or non-null `last_exit` as an exit. Do not infer failure from idle status, a missing foreground PID, silence, or a timeout.
- Recheck that the child still exists after a short deferred reconciliation. If it was closed, treat that as intentional removal and stop quietly. A grace period is not a proof against every concurrent user action; final state checks are still required.
- If a valid initial result exists (`STATUS: completed`, `failed`, or `blocked`), suppress the missing-report notice.
- Otherwise send: "Subagent X exited; no valid initial report was found at PATH. Inspect its terminal." Include the exit code as reported by Rex, not as proof of success or a crash diagnosis.
- Mark the in-memory watch handled before attempting delivery. Do not retry ambiguous terminal sends.
- If the parent is gone, stop. API errors and disconnection are watcher errors, not evidence that the child crashed.
- Intentional cancellation closes the child block. A Ctrl-C inside a retained pane cannot reliably be distinguished from an unexpected interruption without another explicit signal; any notice must stay factual.

This prevents common false alarms, but it is not a complete or foolproof reporting protocol.

### Deliberate narrow scope

The watchdog protects the first report of the initial spawned task. Each spawn has a unique result path, so results from other tasks do not count. It does not claim coverage for later follow-ups that overwrite the same file.

There is a known gap: a child can write a valid result and die before notifying the parent. Suppressing alerts for an existing result avoids duplicate completion notices but leaves this gap. Closing it requires changing who owns completion notification or adding delivery bookkeeping. Neither can provide exactly-once agent delivery through terminal typing alone. Do not grow that into the first watchdog change.

Result publication should use temporary-file-plus-rename on the same filesystem so the watcher does not mistake a partial write for a finished report. Existing instructions currently tell agents to write the final path directly.

## Implementation sequence and release gates

### 1. Alarms

Add `alarm.lua` with one-shot, interval, list, and cancel. Keep internal worker dispatch in the same script. Use lib.type_line rather than adding a second sender. Document the runtime lifetime and recurring queue caveat. Add deterministic Lua tests and live Rex lifecycle tests.

Acceptance tests: creator exits before firing; one-shot fires once; repeat cancels; invalid duration; target disappears; worker fails to start; script or Rex missing on target host; no accidental cancellation of ordinary blocks; no writes to unrelated panes; cleanup after success and failure. Verify failed callback stops recurring delivery instead of Rex's default behavior of logging and continuing.

### 2. Watchdog

Add internal watch.lua and arm it from spawn.lua. Keep event and snapshot paths in one state transition. Spawn must not announce a watched child until the watcher has acknowledged registration and reconciliation. If that fails, report the child IDs and unmonitored state explicitly; do not create another child by retrying spawn blindly.

Acceptance tests: immediate exit; startup failure; zero-code exit without result; nonzero exit; killed process; normal result then exit; completed result followed by tab closure; blocked report; manual closure; duplicate event/snapshot; parent closure; disconnection; malformed or partial result; and an unrelated child exiting. Run the race cases repeatedly.

Do not use the current spawn comment that assumes the agent takes seconds to start as a synchronization guarantee. Prepare readable task instructions before starting the child, or introduce an explicit readiness step when implementation touches that startup sequence.

### 3. Compatibility checks

Run the repo-required real Claude/Codex/Pi fan-out and resume checks. Run on Windows and Linux before claiming tested cross-platform behavior. Local source inspection and macOS API probes alone do not establish that.

## Not tested or implemented

No production helper changed. No agent was spawned for the spike. No end-to-end alarm delivery, full watchdog, remote-host behavior, restart recovery, OS sleep/resume, Windows, or Linux tests were performed. The caller-to-worker readiness handshake and failure cleanup still need implementation tests.
