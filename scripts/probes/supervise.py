#!/usr/bin/env python3
"""Bound an Apple integration command and preserve its actual exit/timeout status."""

import argparse
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from process_samples import ProcessSamples
from termination_control import TerminationControl


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--label")
    parser.add_argument("--heartbeat-interval", type=float, default=30)
    parser.add_argument("--process-samples", type=Path)
    parser.add_argument("--process-sampler", type=Path)
    parser.add_argument("--allow-test-termination", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("A command and a finite positive timeout are required")
    if not math.isfinite(args.heartbeat_interval) or args.heartbeat_interval <= 0:
        parser.error("A finite positive heartbeat interval is required")
    if os.name != "posix":
        parser.error("Apple probe supervision requires POSIX process groups")
    if args.process_samples and sys.platform != "darwin":
        parser.error("Process sampling requires macOS libproc")
    if args.process_samples and (not args.process_sampler or not args.process_sampler.is_file()):
        parser.error("Process sampling requires the compiled host sampler")
    if args.allow_test_termination and not args.process_samples:
        parser.error("Test termination requires simulator process observations")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    label = args.label or args.log.stem
    last_output = started
    next_heartbeat = started + args.heartbeat_interval
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
    termination = TerminationControl(args.log) if args.allow_test_termination else None
    if samples:
        samples.sample("before-command")
    with args.log.open("wb") as output, args.log.open("rb") as live_log:
        def publish_log(*, final=False):
            nonlocal last_output
            # Read the persisted log independently. No pipe reader thread can
            # outlive the command, and logging never changes its exit status.
            # Bound each live pass so a noisy command cannot starve sampling.
            for _ in range(1024 if final else 16):
                chunk = live_log.read(65536)
                if not chunk:
                    break
                last_output = time.monotonic()
                sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()

        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            deadline = time.monotonic() + args.timeout
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, args.timeout)
                try:
                    exit_code = process.wait(timeout=min(0.25, remaining))
                    break
                except subprocess.TimeoutExpired:
                    if samples:
                        snapshot = samples.sample("command-running")
                        if termination and snapshot:
                            termination.poll(snapshot, lambda: samples.sample("before-test-termination"))
                    publish_log()
                    now = time.monotonic()
                    if now >= next_heartbeat:
                        print(f"[{label}] Still running: {now - started:.0f}s elapsed; "
                              f"{max(0, deadline - now):.0f}s until command deadline; "
                              f"last child output {now - last_output:.0f}s ago.", flush=True)
                        next_heartbeat = now + args.heartbeat_interval
        except subprocess.TimeoutExpired:
            timed_out = True
            print(f"[{label}] Command deadline exceeded; stopping the owned process group.", flush=True)
            stop_group()
            exit_code = 124
        except KeyboardInterrupt:
            interrupted = True
            stop_group()
            exit_code = 130
        finally:
            publish_log(final=True)
    command_exit_code = exit_code
    if samples:
        samples.sample("after-command")
        samples.close()
        if samples.errors and exit_code == 0:
            exit_code = 1
    if termination and termination.errors and exit_code == 0:
        exit_code = 1
    result = {
        "label": label, "timeoutSeconds": args.timeout,
        "command": command, "exitCode": exit_code, "processExitCode": process.returncode,
        "commandExitCode": command_exit_code,
        "timedOut": timed_out, "interrupted": interrupted,
        "elapsedSeconds": time.monotonic() - started,
        "processSamples": samples.samples if samples else None,
        "processSamplingErrors": samples.errors if samples else None,
        "testTerminations": termination.results if termination else [],
    }
    args.log.with_suffix(".status.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
