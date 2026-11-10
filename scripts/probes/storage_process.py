"""Interrupt only the explicitly launched probe App, then verify two fresh reopens."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid

from process_samples import parse_native_snapshot


BUNDLE = "io.github.bemarkt.snowlit"
POINTS = {
    "file": ("temporaryWritten", "filePromoted", "beforeCommit", "afterCommit"),
    "dataset": ("candidateValidated", "oldClosed", "pointerCommitted", "adopted"),
}
CONTENTS = {"original": "original committed chapter 🧪", "replacement": "replacement committed chapter 📖"}
DIGESTS = {key: hashlib.sha256(value.encode()).hexdigest() for key, value in CONTENTS.items()}


def validate_marker(marker, *, token, mode, point, pid):
    expected = dict(token=token, mode=mode, point=point, pid=pid)
    if any(marker.get(key) != value for key, value in expected.items()):
        raise ValueError("Checkpoint identity does not match this launch")
    stage = "checkpoint" if mode.endswith("-write") else "completed"
    if marker.get("stage") != stage:
        raise ValueError(f"Operation did not reach {stage}: {marker.get('stage')}")
    details = marker.get("details")
    if not isinstance(details, dict) or (stage == "checkpoint" and details.get("reached") != point):
        raise ValueError("Operation did not reach the exact commit point")
    return details


def verify_reopened(kind, point, first, second):
    expected = "replacement" if point in {"afterCommit", "pointerCommitted", "adopted"} else "original"
    for details in (first, second):
        if details.get("expected") != expected or details.get("contentSHA256") != DIGESTS[expected]:
            raise ValueError("Reopened content differs from commit semantics")
    if kind == "file":
        if (first.get("removedOrphans"), second.get("removedOrphans")) != ("1", "0"):
            raise ValueError("Orphan recovery is not idempotent across process restarts")
        if any(item.get("secondRecoveryRemoved") != "0" for item in (first, second)):
            raise ValueError("Repeated recovery changed the store")
    else:
        if first != second or first.get("originalContentSHA256") != DIGESTS["original"]:
            raise ValueError("Dataset changed across fresh reopens or original data was lost")
        original, active = uuid.UUID(first["originalDataset"]), uuid.UUID(first["activeDataset"])
        if (active != original) != (expected == "replacement"):
            raise ValueError("Active dataset identity differs from the committed pointer")


class Probe:
    def __init__(self, simulator, sampler, evidence):
        self.simulator = simulator
        self.sampler = sampler
        self.evidence = evidence
        self.operations = []
        self.results = []
        self.container = Path(self.command("get_app_container", simulator, BUNDLE, "data").strip())

    def command(self, *arguments):
        return subprocess.run(["xcrun", "simctl", *arguments], check=True, capture_output=True,
                              text=True, timeout=30).stdout

    def identity(self, pid):
        snapshot = subprocess.run([self.sampler], capture_output=True, text=True, check=True, timeout=3)
        rows = parse_native_snapshot(snapshot.stdout)["processes"]
        matches = [row for row in rows if row["pid"] == pid]
        if not matches:
            return None
        row = matches[0]
        if row["executable"] != "Snowlit" or not row["candidate"]:
            raise ValueError("Launched PID is not a measurable Snowlit process")
        if row["measurement"] in {"exited-during-sample", "identity-changed-during-sample"}:
            return None
        if row["measurement"] != "measured":
            raise ValueError("Incomplete App process identity")
        return dict(pid=pid, startedUTC=row["startedUTC"], executable=row["executable"])

    def interrupt(self, identity):
        pid = identity["pid"]
        if self.identity(pid) != identity:
            raise ValueError("Owned App identity changed before interruption")
        # Exact launched PID plus its native start time was checked immediately above.
        # No process-name, process-group, WebContent or other-user signals are sent.
        os.kill(pid, signal.SIGKILL)
        return dict(method="checkpoint-interruption", signal="SIGKILL", **self.wait_for_exit(identity))

    def finish(self, identity):
        if self.identity(identity["pid"]) != identity:
            raise ValueError("Completed App identity changed before termination")
        # Completed seed/read operations are not fault injections. Ask the
        # simulator lifecycle manager to terminate them before a fresh launch,
        # instead of introducing three unrelated crashes per checkpoint trial.
        self.command("terminate", self.simulator, BUNDLE)
        return dict(method="simctl-terminate", **self.wait_for_exit(identity))

    def wait_for_exit(self, identity):
        started = time.monotonic()
        while self.identity(identity["pid"]) == identity:
            if time.monotonic() - started > 10:
                raise TimeoutError("Terminated App identity is still observable")
            time.sleep(0.05)
        return dict(observedGone=True, elapsedSeconds=time.monotonic() - started)

    def operation(self, trial, kind, action, point):
        mode = kind + "-" + action
        token = str(uuid.uuid4()).upper()
        record = dict(trial=trial, token=token, mode=mode, point=point,
                      startedUTC=datetime.now(timezone.utc).isoformat())
        self.operations.append(record)
        identity = None
        started = time.monotonic()
        marker = self.container / "Library/Caches/SnowlitStorageProcessProbes" / trial / (token + ".json")
        try:
            print(f"Storage operation {mode}/{point} token={token}: launching", flush=True)
            output = self.command("launch", self.simulator, BUNDLE, "-snowlit-probe-storage",
                                  mode, trial, point, token)
            match = re.fullmatch(re.escape(BUNDLE) + r": ([1-9][0-9]*)\s*", output)
            if not match:
                raise ValueError("Unexpected simulator launch identity")
            pid = int(match[1])
            identity = self.identity(pid)
            if identity is None:
                raise ValueError("Launched App exited before observation")
            record["process"] = identity
            record["launchSeconds"] = time.monotonic() - started
            print(f"Storage operation {mode}/{point} token={token}: pid={pid}, waiting for marker", flush=True)
            deadline = time.monotonic() + 20
            while not marker.exists():
                if time.monotonic() >= deadline:
                    raise TimeoutError("App did not publish the requested checkpoint")
                if self.identity(pid) != identity:
                    raise ValueError("App exited before publishing its checkpoint")
                time.sleep(0.05)
            record["marker"] = json.loads(marker.read_text())
            details = validate_marker(record["marker"], token=token, mode=mode, point=point, pid=pid)
            record["termination"] = self.interrupt(identity) if action == "write" else self.finish(identity)
            identity = None
            record["outcome"] = "passed"
            print(f"Storage operation {mode}/{point} token={token}: completed", flush=True)
            return details
        except Exception as error:
            record["outcome"] = "failed"
            record["error"] = f"{type(error).__name__}: {error}"
            # A launch command can time out after the App starts. Preserve any
            # marker for diagnosis, but never accept it as a verified launch.
            if "marker" not in record and marker.is_file():
                record["unverifiedMarker"] = marker.read_text()
            print(f"Storage operation {mode}/{point} token={token}: failed ({type(error).__name__})", flush=True)
            raise
        finally:
            try:
                if identity is not None and self.identity(identity["pid"]) == identity:
                    record["cleanupTermination"] = self.interrupt(identity)
            finally:
                record["elapsedSeconds"] = time.monotonic() - started
                self.save()

    def save(self):
        report = dict(format=1, simulator=self.simulator, platform="iPhone simulator",
                      scope="App process interruption only; no device power-loss or fsync conclusion",
                      operations=self.operations, results=self.results,
                      passed=len(self.results) == 24 and all(op.get("outcome") == "passed" for op in self.operations))
        (self.evidence / "storage-process.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(self):
        for kind, points in POINTS.items():
            for point in points:
                for repetition in range(1, 4):
                    trial = str(uuid.uuid4()).upper()
                    self.operation(trial, kind, "seed", point)
                    self.operation(trial, kind, "write", point)
                    first = self.operation(trial, kind, "check", point)
                    second = self.operation(trial, kind, "recheck", point)
                    verify_reopened(kind, point, first, second)
                    self.results.append(dict(kind=kind, point=point, repetition=repetition, trial=trial,
                                             firstReopen=first, secondReopen=second, outcome="passed"))
                    self.save()
                    print(f"Storage interruption {kind}/{point}/{repetition}: passed", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("simulator")
    parser.add_argument("sampler")
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    probe = Probe(args.simulator, args.sampler, args.evidence)
    try:
        probe.run()
    finally:
        probe.save()
