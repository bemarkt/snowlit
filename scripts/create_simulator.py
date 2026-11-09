#!/usr/bin/env python3
"""Create a dedicated simulator and record its exact runtime/device metadata."""

import json
from pathlib import Path
import subprocess
import sys
import uuid

device_name, runtime_id, record_path = sys.argv[1:]
inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j"], text=True))
device = next((d for d in inventory["devicetypes"] if d["name"] == device_name), None)
runtime = next((r for r in inventory["runtimes"]
                if r["identifier"] == runtime_id and r["isAvailable"]), None)
if device is None or runtime is None:
    raise SystemExit(f"Required simulator is unavailable: {device_name}, {runtime_id}")
udid = subprocess.check_output([
    "xcrun", "simctl", "create", f"Snowlit-CI-{uuid.uuid4().hex[:8]}",
    device["identifier"], runtime["identifier"],
], text=True).strip()
Path(record_path).write_text(
    json.dumps({"udid": udid, "device": device, "runtime": runtime}, indent=2) + "\n",
    encoding="utf-8",
)
print(udid)
