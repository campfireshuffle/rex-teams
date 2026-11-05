"""Opt-in macOS/Linux Rex integration tests; creates and removes its own session.

REX_BIN=/path/to/rex python3 tests/live.py
Only Python's standard library is used. No existing agent pane is touched.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills/rex-teams/scripts"
REX = os.environ.get("REX_BIN", "rex")


def cli(*args, env=None):
    result = subprocess.run([REX, "--autostart=false", *args], text=True,
                            capture_output=True, timeout=30, env=env)
    if result.returncode:
        raise AssertionError(f"rex {args}: {result.stdout}\n{result.stderr}")
    return result.stdout


def eventually(check, timeout=12):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if check():
            return
        time.sleep(0.1)
    raise AssertionError("condition did not become true")


def main():
    created = json.loads(cli("new", "rex-teams-live-tests", "--json"))
    session = created["session_id"]
    artifacts = []

    def api(method, args):
        return json.loads(cli("api", "call", method, json.dumps({"session_id": session, **args})))

    def block(command, label="fixture", keep=True):
        return api("session.new_block", {
            "flavor": "com.superlogical.terminal.shell", "label": label,
            "options": {"command": command, "exit": {"on_completion": not keep}},
        })["block_id"]

    def close(block_id):
        api("block.close", {"block_id": block_id})

    def alive(block_id):
        return any(b["block_id"] == block_id for b in api("session.list_blocks", {})["blocks"])

    def process(block_id):
        return api("block.method", {"block_id": block_id, "method": "process", "args": {}})

    try:
        with tempfile.TemporaryDirectory(prefix="rex-teams-live-") as tmp:
            tmp = Path(tmp)
            messages = tmp / "messages"
            receiver = tmp / "receiver.py"
            receiver.write_text("import sys\nfrom pathlib import Path\nprint('receiver ready', flush=True)\n"
                                "for line in sys.stdin:\n"
                                "    with open(sys.argv[1], 'a') as f: f.write(line)\n")
            parent = block([sys.executable, str(receiver), str(messages)], "parent")
            env = {**os.environ, "REX_SESSION": session, "REX_BLOCK": parent}

            def received():
                return messages.read_text().splitlines() if messages.exists() else []

            def watch(child, result, tag):
                ready = tmp / (tag + ".ready")
                worker = block([REX, "do", "-s", session, "--fail-fast", str(SCRIPTS / "watch.lua"),
                                "session=" + session, "child=" + child, "parent=" + parent,
                                "result=" + str(result), "ready=" + str(ready), "task=" + tag], "watch: " + tag, False)
                eventually(ready.exists)
                return worker

            def alarm(text, seconds=0.3, recurring=False):
                # Matches the documented background-tab command, not a shell job.
                result = json.loads(cli("run", "-s", session, "--label", "alarm", "--focus=false", "--json", "--",
                                        REX, "do", "-s", session, "--fail-fast", str(SCRIPTS / "alarm.lua"),
                                        "session=" + session, "block=" + parent,
                                        "seconds=" + str(seconds), "recurring=" + str(recurring).lower(), "message=" + text))
                return result["block_ids"][0]

            for override in ({"seconds": "0"}, {"seconds": "-1"}, {"recurring": "yes"}, {"message": "two\nlines"}):
                args = {"session": session, "block": parent, "seconds": "1", "message": "invalid", **override}
                rejected = subprocess.run([REX, "--autostart=false", "do", "-s", session, "--fail-fast",
                                           str(SCRIPTS / "alarm.lua"), *[k + "=" + v for k, v in args.items()]],
                                          text=True, capture_output=True, timeout=10)
                assert rejected.returncode != 0 and "Alarm armed" not in rejected.stdout
            assert not received()
            print("ok invalid alarm arguments fail before arming")

            alarm_id = alarm("once")
            eventually(lambda: received() == ["[alarm] Don't rename the Rex session or your tab. once"])
            eventually(lambda: not alive(alarm_id))
            print("ok one-shot script delivers once after creator returns and cleans up")

            alarm_id = alarm("repeat", 0.8, recurring=True)
            eventually(lambda: sum("repeat" in m for m in received()) >= 2)
            close(alarm_id)
            time.sleep(1)
            before = len(received())
            time.sleep(1)
            assert len(received()) == before
            print("ok recurring script and explicit cancellation")

            alarm_id = alarm("cancelled", 30)
            close(alarm_id)
            time.sleep(0.5)
            assert not any("cancelled" in m for m in received())
            print("ok cancel before firing")

            # An already-exited child tests the attach/snapshot race repeatedly.
            for index in range(5):
                child = block(["/bin/sh", "-c", "exit 0"])
                eventually(lambda: process(child)["last_exit"] is not None)
                before = len(received())
                worker = watch(child, tmp / "missing", "immediate-" + str(index))
                eventually(lambda: len(received()) == before + 1)
                eventually(lambda: not alive(worker))
                close(child)
            print("ok five immediate zero-code exits each notify exactly once")

            child = block(["/bin/sh", "-c", "sleep 2; exit 7"])
            before = len(received())
            worker = watch(child, tmp / "missing", "later-exit")
            eventually(lambda: len(received()) == before + 1)
            eventually(lambda: not alive(worker))
            close(child)
            print("ok event-path nonzero exit")

            child = block([sys.executable, "-c", "import os,signal,time; time.sleep(2); os.kill(os.getpid(), signal.SIGKILL)"])
            before = len(received())
            worker = watch(child, tmp / "missing", "killed")
            eventually(lambda: len(received()) == before + 1)
            eventually(lambda: not alive(worker))
            close(child)
            print("ok killed child wakes parent")

            for status in ("completed", "failed", "blocked"):
                report = tmp / (status + ".md")
                report.write_text("STATUS: " + status + "\nTest report\n")
                child = block([sys.executable, "-c", "import sys; input(); sys.exit(7)"])
                before = len(received())
                worker = watch(child, report, status)
                assert len(received()) == before and alive(worker)
                cli("send", "-s", session, "-b", child, "follow-up")
                cli("send-key", "-s", session, "-b", child, "enter")
                eventually(lambda: len(received()) == before + 1)
                eventually(lambda: not alive(worker))
                assert "may be absent or stale" in received()[-1]
                close(child)
            print("ok follow-up exits notify despite completed, failed, or blocked reports")

            child = block(["/bin/sleep", "60"])
            worker = watch(child, tmp / "missing", "manual-close")
            before = len(received())
            close(child)
            eventually(lambda: not alive(worker))
            assert len(received()) == before
            print("ok manual close cancels without a notice")

            worker = watch(child, tmp / "missing", "already-closed")
            eventually(lambda: not alive(worker))
            assert len(received()) == before
            print("ok closure before watchdog startup also cancels quietly")

            # Exercise the real spawn wiring, including startup acknowledgement.
            task = tmp / "task.md"
            task.write_text("Test fixture; exit immediately.\n")
            before = len(received())
            output = cli("do", "-s", session, str(SCRIPTS / "spawn.lua"), "name=startup-failure",
                         "cwd=" + str(tmp), "task=" + str(task), "command=/no/such/rex-test-agent", env=env)
            task_dir = Path(re.search(r"^folder: (.+)$", output, re.M).group(1))
            artifacts.extend([task_dir / "prompt.md", task_dir / "result.md", task_dir / "watch.ready", task_dir])
            child_id = re.search(r"block=(block:[^ ]+)", output).group(1)
            artifacts.append(Path("/tmp/rex-teams/depth") / child_id.removeprefix("block:"))
            eventually(lambda: len(received()) == before + 1)
            worker = re.search(r"^watcher: (.+)$", output, re.M).group(1)
            eventually(lambda: not alive(worker))
            print("ok real spawn catches executable startup failure and acknowledges watch")

            # Target disappearance stops both kinds of worker.
            child = block(["/bin/sleep", "60"])
            worker = watch(child, tmp / "missing", "parent-gone")
            alarm_id = alarm("never", 60, recurring=True)
            close(parent)
            eventually(lambda: not alive(worker) and not alive(alarm_id))
            print("ok parent closure cleans up watchdog and recurring alarm")
            alarm_id = alarm("gone", 60)
            eventually(lambda: not alive(alarm_id))
            worker = watch(child, tmp / "missing", "parent-already-gone")
            eventually(lambda: not alive(worker))
            print("ok startup after parent closure leaves no workers")
    finally:
        cli("kill", session)
        for path in artifacts:
            if path.is_dir():
                path.rmdir()
            else:
                path.unlink(missing_ok=True)
    print("All live checks passed; isolated session removed")


if __name__ == "__main__":
    main()
