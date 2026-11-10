"""Observe host process candidates; never infer WebView ownership or terminate them."""

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
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
    return dict(processes=records, exitedDuringDiscovery=unsigned(snapshot["exitedDuringDiscovery"]),
                timebaseNumerator=numerator, timebaseDenominator=denominator)


class ProcessSamples:
    def __init__(self, path, sampler):
        self.path = Path(path)
        self.sampler = Path(sampler)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.output = self.path.open("w", encoding="utf-8")
        self.errors = 0
        self.samples = 0
        self.write({
            "kind": "metadata", "format": 2, "hostCPUCount": os.cpu_count(),
            "scope": "Same-user host candidates and their same-user ancestors; no per-WebView attribution",
            "sampler": "macOS libproc; ancestors identity-only; no task ports or process signals",
            "rssUnit": "1024 bytes", "cpuSeconds": "Accumulated user + system ticks converted by mach_timebase_info",
        })

    def write(self, record):
        record["observedUTC"] = datetime.now(timezone.utc).isoformat()
        record["monotonicSeconds"] = time.monotonic()
        self.output.write(json.dumps(record, ensure_ascii=True) + "\n")
        self.output.flush()

    def sample(self, stage):
        started = time.monotonic()
        try:
            result = subprocess.run(
                [str(self.sampler)], capture_output=True, text=True, encoding="utf-8",
                timeout=2, check=True,
            )
            snapshot = parse_native_snapshot(result.stdout)
            self.write(dict(kind="sample", stage=stage, durationSeconds=time.monotonic() - started, **snapshot))
            self.samples += 1
        except (OSError, subprocess.SubprocessError, UnicodeError, ValueError, KeyError, TypeError) as error:
            self.errors += 1
            diagnostic = {}
            if isinstance(error, subprocess.CalledProcessError):
                try:
                    native = json.loads(error.stderr)
                    if native.get("phase") in {"arguments", "timebase", "list-size", "allocate", "list",
                                               "list-truncated", "identity", "metrics"}:
                        diagnostic["queryPhase"] = native["phase"]
                        for field in ["pid", "errorCode"]:
                            if type(native.get(field)) is int:
                                diagnostic[field] = native[field]
                except (ValueError, TypeError, AttributeError):
                    pass  # Preserve the failure without publishing arbitrary subprocess output.
            self.write(dict(kind="samplingError", stage=stage, errorType=type(error).__name__,
                            durationSeconds=time.monotonic() - started, **diagnostic))

    def close(self):
        self.output.close()
