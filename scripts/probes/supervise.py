#!/usr/bin/env python3
"""Bound an Apple integration command and preserve its actual exit/timeout status."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.timeout <= 0:
        parser.error("A command and a positive timeout are required")
    if os.name != "posix":
        parser.error("Apple probe supervision requires POSIX process groups")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    timed_out = False
    interrupted = False
    process = None

    def interrupt(_signal, _frame):
        raise KeyboardInterrupt

    def stop_group():
        # Only the new process group owned by this invocation, never a name-based kill.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        # The leader can exit while descendants remain; end the owned group too.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=10)

    signal.signal(signal.SIGTERM, interrupt)
    with args.log.open("wb") as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            exit_code = process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            stop_group()
            exit_code = 124
        except KeyboardInterrupt:
            interrupted = True
            stop_group()
            exit_code = 130
    result = {
        "command": command, "exitCode": exit_code, "processExitCode": process.returncode,
        "timedOut": timed_out, "interrupted": interrupted,
        "elapsedSeconds": time.monotonic() - started,
    }
    args.log.with_suffix(".status.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
