"""Observe host process candidates; never infer WebView ownership or terminate them."""

from datetime import datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import select
import subprocess
import time


def parse_processes(output, *, metrics=True):
    """Parse the legacy ps evidence format, retained for historical comparisons."""
    processes = {}
    for line in output.splitlines():
        if not line.strip():
            continue
        expected = 10 if metrics else 8
        fields = line.split(None, expected - 1)
        if len(fields) != expected:
            raise ValueError("Incomplete ps row")
        pid, parent = map(int, fields[:2])
        if pid in processes or pid < 0 or parent < 0:
            raise ValueError("Invalid or duplicate process identity")
        date_start = 4 if metrics else 2
        started = datetime.strptime(" ".join(fields[date_start:date_start + 5]), "%a %b %d %H:%M:%S %Y")
        # comm contains the executable path, never argv or the environment.
        name = fields[-1].rsplit("/", 1)[-1]
        processes[pid] = {
            "pid": pid, "parentPID": parent,
            "startedUTC": started.replace(tzinfo=timezone.utc).isoformat(),
            "executable": name,
        }
        if metrics:
            rss = int(fields[2])
            if rss < 0:
                raise ValueError("Invalid resident size")
            processes[pid].update(rssKiB=rss, cpuTime=fields[3])
    candidates = {
        pid for pid, process in processes.items()
        if process["executable"].startswith("com.apple.WebKit.")
        or process["executable"] in {"WebContent", "xctest", "Snowlit"}
        or process["executable"].endswith("-Runner")
    }
    selected = set(candidates)
    for candidate in candidates:
        parent = processes[candidate]["parentPID"]
        visited = {candidate}
        while parent in processes and parent not in visited:
            visited.add(parent)
            selected.add(parent)
            parent = processes[parent]["parentPID"]
    return [dict(processes[pid], candidate=pid in candidates) for pid in sorted(selected)]


def parse_native_snapshot(output):
    snapshot = json.loads(output)

    def unsigned(value):
        if type(value) is not int or value < 0:
            raise ValueError("Invalid nonnegative integer")
        return value

    numerator = unsigned(snapshot["timebaseNumerator"])
    denominator = unsigned(snapshot["timebaseDenominator"])
    if not numerator or not denominator:
        raise ValueError("Invalid CPU timebase")
    query_duration = snapshot["querySeconds"]
    observed_epoch = snapshot["sampleEpochSeconds"]
    for number in [query_duration, observed_epoch]:
        if type(number) not in (int, float) or not math.isfinite(number) or number < 0:
            raise ValueError("Invalid native observation clock")
    identities = set()
    records = []
    for raw in snapshot["processes"]:
        pid = unsigned(raw["pid"])
        if pid in identities or not pid:
            raise ValueError("Invalid or duplicate process identity")
        identities.add(pid)
        microseconds = unsigned(raw["startMicroseconds"])
        if microseconds >= 1_000_000:
            raise ValueError("Invalid process start time")
        started = datetime.fromtimestamp(unsigned(raw["startSeconds"]), timezone.utc)
        started += timedelta(microseconds=microseconds)
        name = raw["executable"]
        if not isinstance(name, str) or not name or "/" in name or any(ord(c) < 32 for c in name):
            raise ValueError("Invalid executable basename")
        candidate = raw["candidate"]
        if type(candidate) is not bool:
            raise ValueError("Invalid candidate flag")
        measurement = raw["measurement"]
        allowed = {"measured", "exited-during-sample", "identity-changed-during-sample"}
        if measurement not in (allowed if candidate else {"identity-only"}):
            raise ValueError("Incomplete candidate measurement")
        record = dict(pid=pid, parentPID=unsigned(raw["parentPID"]), startedUTC=started.isoformat(),
                      executable=name, candidate=candidate, measurement=measurement)
        if measurement == "measured":
            cpu_ticks = unsigned(raw["userTicks"]) + unsigned(raw["systemTicks"])
            record.update(rssKiB=unsigned(raw["rssBytes"]) / 1024,
                          cpuSeconds=cpu_ticks * numerator / denominator / 1_000_000_000)
        records.append(record)
    return dict(processes=records, samplerPID=unsigned(snapshot["samplerPID"]),
                observedUTC=datetime.fromtimestamp(observed_epoch, timezone.utc).isoformat(),
                durationSeconds=query_duration,
                exitedDuringDiscovery=unsigned(snapshot["exitedDuringDiscovery"]),
                timebaseNumerator=numerator, timebaseDenominator=denominator)


class ProcessSamples:
    def __init__(self, path, sampler):
        self.path = Path(path)
        self.sampler = Path(sampler)
        self.process = None
        self.query_timeout = 2
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.output = self.path.open("w", encoding="utf-8")
        self.errors = 0
        self.samples = 0
        self.write({
            "kind": "metadata", "format": 3, "hostCPUCount": os.cpu_count(),
            "scope": "Same-user host candidates and their same-user ancestors; no per-WebView attribution",
            "sampler": "macOS libproc; ancestors identity-only; no task ports or process signals",
            "rssUnit": "1024 bytes", "cpuSeconds": "Accumulated user + system ticks converted by mach_timebase_info",
            "queryTimeoutSeconds": self.query_timeout,
            "clock": "Native CLOCK_REALTIME and CLOCK_MONOTONIC; supervisor round-trip recorded separately",
        })

    def write(self, record):
        record.setdefault("observedUTC", datetime.now(timezone.utc).isoformat())
        record["monotonicSeconds"] = time.monotonic()
        self.output.write(json.dumps(record, ensure_ascii=True) + "\n")
        self.output.flush()

    def sample(self, stage):
        started = time.monotonic()
        try:
            snapshot = parse_native_snapshot(self.read_snapshot())
            self.write(dict(kind="sample", stage=stage, supervisorElapsedSeconds=time.monotonic() - started, **snapshot))
            self.samples += 1
            return snapshot
        except (OSError, subprocess.SubprocessError, UnicodeError, ValueError, KeyError, TypeError) as error:
            self.stop_helper(force=True)
            self.errors += 1
            diagnostic = {}
            if isinstance(error, subprocess.CalledProcessError):
                try:
                    native = json.loads(error.stderr)
                    if native.get("phase") in {"arguments", "timebase", "clock", "input", "output", "list-size", "allocate", "list",
                                               "list-truncated", "identity", "metrics"}:
                        diagnostic["queryPhase"] = native["phase"]
                        for field in ["pid", "errorCode"]:
                            if type(native.get(field)) is int:
                                diagnostic[field] = native[field]
                except (ValueError, TypeError, AttributeError):
                    pass  # Preserve the failure without publishing arbitrary subprocess output.
            self.write(dict(kind="samplingError", stage=stage, errorType=type(error).__name__,
                            durationSeconds=time.monotonic() - started, **diagnostic))

    def read_snapshot(self):
        deadline = time.monotonic() + self.query_timeout
        if self.process is None:
            self.process = subprocess.Popen([str(self.sampler), "--server"], stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                            bufsize=0, start_new_session=True)
        process = self.process
        process.stdin.write(b"\n")
        received = bytearray()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                raise subprocess.TimeoutExpired([str(self.sampler)], self.query_timeout)
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                code = process.wait(timeout=max(0.001, deadline - time.monotonic()))
                raise subprocess.CalledProcessError(code or 1, [str(self.sampler)],
                                                    stderr=process.stderr.read().decode("utf-8"))
            received.extend(chunk)
            if len(received) > 4 * 1024 * 1024:
                raise ValueError("Native observation exceeds bounded response size")
            if b"\n" in received:
                if not received.endswith(b"\n") or received.count(b"\n") != 1:
                    raise ValueError("Unexpected native observation framing")
                return received.decode("utf-8")

    def stop_helper(self, *, force=False):
        process, self.process = self.process, None
        if process is None:
            return True
        clean = True
        if force and process.poll() is None:
            process.kill()  # Only this sampler child, never observed candidates.
        process.stdin.close()
        try:
            code = process.wait(timeout=self.query_timeout)
            clean = code == 0
        except subprocess.TimeoutExpired:
            clean = False
            process.kill()
            process.wait(timeout=self.query_timeout)
        finally:
            process.stdout.close()
            process.stderr.close()
        return clean

    def close(self):
        if not self.stop_helper():
            self.errors += 1
            self.write(dict(kind="samplingError", stage="helper-shutdown", errorType="UncleanSamplerExit"))
        self.output.close()
