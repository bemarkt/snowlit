"""Observe host process candidates; never infer WebView ownership or terminate them."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import time


def parse_processes(output, *, metrics=True):
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


class ProcessSamples:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.output = self.path.open("w", encoding="utf-8")
        self.errors = 0
        self.samples = 0
        self.write({
            "kind": "metadata", "format": 1, "hostCPUCount": os.cpu_count(),
            "scope": "Host candidates and their ancestors; no per-WebView attribution",
            "rssUnit": "1024 bytes", "cpuTime": "Accumulated user + system CPU time from ps",
        })

    def write(self, record):
        record["observedUTC"] = datetime.now(timezone.utc).isoformat()
        record["monotonicSeconds"] = time.monotonic()
        self.output.write(json.dumps(record, ensure_ascii=True) + "\n")
        self.output.flush()

    def sample(self, stage):
        environment = dict(os.environ, LC_ALL="C", TZ="UTC")
        try:
            result = subprocess.run(
                ["/bin/ps", "-Aww", "-o", "pid=,ppid=,lstart=,comm="],
                env=environment, capture_output=True, text=True, encoding="utf-8",
                timeout=2, check=True,
            )
            identities = parse_processes(result.stdout, metrics=False)
            measured = []
            if identities:
                # Resource lookup for every host process can stall a busy CI runner.
                # Read task metrics only for the observed candidates and their ancestors.
                pids = ",".join(str(process["pid"]) for process in identities)
                result = subprocess.run(
                    ["/bin/ps", "-ww", "-p", pids, "-o", "pid=,ppid=,rss=,time=,lstart=,comm="],
                    env=environment, capture_output=True, text=True, encoding="utf-8", timeout=2,
                )
                # All selected processes may have exited between the two snapshots.
                empty = result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip()
                if not empty:
                    result.check_returncode()
                    selected = {(process["pid"], process["startedUTC"]) for process in identities}
                    measured = [process for process in parse_processes(result.stdout)
                                if (process["pid"], process["startedUTC"]) in selected]
            self.write({"kind": "sample", "stage": stage, "processes": measured})
            self.samples += 1
        except (OSError, subprocess.SubprocessError, UnicodeError, ValueError) as error:
            self.errors += 1
            # Error type only: no arbitrary process output, command arguments or environment.
            self.write({"kind": "samplingError", "stage": stage, "errorType": type(error).__name__})

    def close(self):
        self.output.close()
