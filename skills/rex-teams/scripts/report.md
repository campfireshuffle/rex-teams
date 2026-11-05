## How to report back

You are a subagent. Another agent started you in a Rex terminal and is waiting for your report. {nesting}

When you finish, or when you are stuck on a question only the parent or user can answer:

1. Write {result}. Its first line must be exactly one of:
   STATUS: completed
   STATUS: failed
   STATUS: blocked
   Then write a short report: what you did, files you changed, how you verified it, and any question you need answered.
2. Notify the parent by running this command (put your status in place of STATUS):
   {notify}
   If it fails with a sandbox or permission error, ask for permission to run it outside the sandbox.
3. Stop and wait. The parent or the user may send follow-ups into this terminal. Handle each one, then repeat steps 1 and 2. Overwrite result.md each time.

Don't notify the parent with progress updates. Notify it only when you finish or are blocked.
