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

from process_samples import ProcessSamples


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--process-samples", type=Path)
    parser.add_argument("--process-sampler", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.timeout <= 0:
        parser.error("A command and a positive timeout are required")
    if os.name != "posix":
        parser.error("Apple probe supervision requires POSIX process groups")
    if args.process_samples and sys.platform != "darwin":
        parser.error("Process sampling requires macOS libproc")
    if args.process_samples and (not args.process_sampler or not args.process_sampler.is_file()):
        parser.error("Process sampling requires the compiled host sampler")
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
    samples = ProcessSamples(args.process_samples, args.process_sampler) if args.process_samples else None
    if samples:
        samples.sample("before-command")
    with args.log.open("wb") as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            deadline = time.monotonic() + args.timeout
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, args.timeout)
                try:
                    exit_code = process.wait(timeout=min(0.25, remaining) if samples else remaining)
                    break
                except subprocess.TimeoutExpired:
                    if not samples:
                        raise
                    samples.sample("command-running")
        except subprocess.TimeoutExpired:
            timed_out = True
            stop_group()
            exit_code = 124
        except KeyboardInterrupt:
            interrupted = True
            stop_group()
            exit_code = 130
    command_exit_code = exit_code
    if samples:
        samples.sample("after-command")
        samples.close()
        if samples.errors and exit_code == 0:
            exit_code = 1
    result = {
        "command": command, "exitCode": exit_code, "processExitCode": process.returncode,
        "commandExitCode": command_exit_code,
        "timedOut": timed_out, "interrupted": interrupted,
        "elapsedSeconds": time.monotonic() - started,
        "processSamples": samples.samples if samples else None,
        "processSamplingErrors": samples.errors if samples else None,
    }
    args.log.with_suffix(".status.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
