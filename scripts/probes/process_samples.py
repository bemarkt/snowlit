"""Observe host process candidates; never infer WebView ownership or terminate them."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import time


def parse_processes(output):
    processes = {}
    for line in output.splitlines():
        if not line.strip():
            continue
        fields = line.split(None, 9)
        if len(fields) != 10:
            raise ValueError("Incomplete ps row")
        pid, parent, rss = map(int, fields[:3])
        if pid in processes or pid < 0 or parent < 0 or rss < 0:
            raise ValueError("Invalid or duplicate process identity")
        started = datetime.strptime(" ".join(fields[4:9]), "%a %b %d %H:%M:%S %Y")
        # comm contains the executable path, never argv or the environment.
        name = fields[9].rsplit("/", 1)[-1]
        processes[pid] = {
            "pid": pid, "parentPID": parent, "rssKiB": rss,
            "cpuTime": fields[3], "startedUTC": started.replace(tzinfo=timezone.utc).isoformat(),
            "executable": name,
        }
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
                ["/bin/ps", "-Aww", "-o", "pid=,ppid=,rss=,time=,lstart=,comm="],
                env=environment, capture_output=True, text=True, encoding="utf-8",
                timeout=2, check=True,
            )
            self.write({"kind": "sample", "stage": stage, "processes": parse_processes(result.stdout)})
            self.samples += 1
        except (OSError, subprocess.SubprocessError, UnicodeError, ValueError) as error:
            self.errors += 1
            # Error type only: no arbitrary process output, command arguments or environment.
            self.write({"kind": "samplingError", "stage": stage, "errorType": type(error).__name__})

    def close(self):
        self.output.close()
