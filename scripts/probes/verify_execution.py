"""Reject missing, empty or incomplete probe evidence even if a wrapper exits zero."""

import argparse
import json
from pathlib import Path
import re


def verify(evidence, mode):
    status = json.loads((evidence / "webkit-tests.status.json").read_text())
    if status["exitCode"] != 0 or status["processExitCode"] != 0 or status["timedOut"] or status["interrupted"]:
        raise ValueError("The test command did not complete successfully")
    bundle = evidence / "RuntimeTests.xcresult"
    if not bundle.is_dir() or not (bundle / "Info.plist").is_file():
        raise ValueError("The actual xcresult bundle is missing")
    suites = {
        "integration": ["WebKitRuntimeProbeTests", "ReaderProbeTests"],
        "recovery": ["WebKitRecoveryTests"],
    }[mode]
    log = (evidence / "webkit-tests.log").read_text(encoding="utf-8")
    counts = [int(count) for count in re.findall(r"Test run with (\d+) tests? in \d+ suites? passed", log)]
    if not counts or sum(counts) == 0:
        raise ValueError("No nonempty successful Swift Testing run was recorded")
    for suite in suites:
        if f"Suite {suite} passed" not in log:
            raise ValueError(f"Required suite did not pass: {suite}")
    if mode == "recovery":
        if status.get("processSamplingErrors") != 0 or not status.get("processSamples"):
            raise ValueError("Process observation did not complete")
        if not (evidence / "process-samples.jsonl").is_file():
            raise ValueError("Process observations are missing")
    return {"mode": mode, "suites": suites, "reportedTests": sum(counts), "result": "passed"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    parser.add_argument("mode", choices=["integration", "recovery"])
    args = parser.parse_args()
    result = verify(args.evidence, args.mode)
    (args.evidence / "execution-verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
