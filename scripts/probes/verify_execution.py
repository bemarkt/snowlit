"""Reject missing, empty or incomplete probe evidence even if a wrapper exits zero."""

import argparse
from datetime import datetime
import json
from pathlib import Path
import re


def verify_recovery_observations(evidence, log, expected_count):
    records = [json.loads(line) for line in (evidence / "process-samples.jsonl").read_text().splitlines()]
    if not records or records[0].get("format") != 3:
        raise ValueError("Native process observation metadata is missing")
    if any(row.get("kind") == "samplingError" for row in records):
        raise ValueError("Process observation contains sampling errors")
    samples = [row for row in records if row.get("kind") == "sample"]
    if len(samples) != expected_count:
        raise ValueError("Process observation count does not match the command status")
    events = {}
    pattern = (r"RecoveryEvent epochSeconds=([\d.]+) stage=([a-z-]+) "
               r"fault=(spin|never) repetition=(\d+) hostPID=(\d+)")
    for epoch, stage, fault, repetition, pid in re.findall(pattern, log):
        key = (fault, int(repetition))
        events.setdefault(key, {})
        if stage in events[key]:
            raise ValueError("Duplicate recovery event")
        events[key][stage] = (float(epoch), int(pid))
    if set(events) != {(fault, repetition) for fault in ["spin", "never"] for repetition in range(1, 4)}:
        raise ValueError("Six complete recovery repetitions are required")
    results = []
    for (fault, repetition), stages in sorted(events.items()):
        required = ["baseline", "execution-requested", "fault-entered", "waiter-ended",
                    "closed", "replacement-ready", "observation-ended"]
        if set(stages) != set(required):
            raise ValueError("A required recovery event is missing")
        times = [stages[stage][0] for stage in required]
        pids = {stages[stage][1] for stage in required}
        if times != sorted(times) or len(pids) != 1:
            raise ValueError("Recovery ordering or host identity changed")
        host_pid = pids.pop()
        for label, first, last in [("baseline", "baseline", "execution-requested"),
                                   ("fault", "fault-entered", "closed"),
                                   ("post-close", "closed", "observation-ended"),
                                   ("replacement", "replacement-ready", "observation-ended")]:
            start, end = stages[first][0], stages[last][0]
            measured = []
            for sample in samples:
                stamp = datetime.fromisoformat(sample["observedUTC"]).timestamp()
                if not start <= stamp - sample["durationSeconds"] <= stamp <= end:
                    continue
                processes = [process for process in sample["processes"]
                             if process.get("measurement") == "measured"]
                host = any(process["pid"] == host_pid and process["executable"] == "Snowlit"
                           for process in processes)
                web_content = any(process["executable"] in {"WebContent", "com.apple.WebKit.WebContent"}
                                  for process in processes)
                # An observed absence after close is data, not missing sampling.
                # Baseline, entered fault and ready replacement still need WebContent.
                if host and (web_content or label == "post-close"):
                    measured.append(stamp)
            measured.sort()
            boundaries = [start, *measured, end]
            gap = max(right - left for left, right in zip(boundaries, boundaries[1:]))
            if len(measured) < 2 or gap > 1:
                raise ValueError(f"Incomplete App/WebContent sampling: {fault}/{repetition}/{label}")
            results.append(dict(fault=fault, repetition=repetition, window=label,
                                samples=len(measured), maximumGapSeconds=gap))
    return {"scope": "Sampling coverage only; no per-WebView attribution or resource acceptance", "windows": results}


def verify(evidence, mode):
    status = json.loads((evidence / "webkit-tests.status.json").read_text())
    if status["exitCode"] != 0 or status["processExitCode"] != 0 or status["timedOut"] or status["interrupted"]:
        raise ValueError("The test command did not complete successfully")
    bundle = evidence / "RuntimeTests.xcresult"
    if not bundle.is_dir() or not (bundle / "Info.plist").is_file():
        raise ValueError("The actual xcresult bundle is missing")
    log = (evidence / "webkit-tests.log").read_text(encoding="utf-8")
    if mode == "reader-ui":
        tests = re.findall(r"Test Case '-\[SnowlitUITests\.ReaderInteractionUITests (\w+)\]' passed", log)
        expected = {"testSystemCurlCommitsCompletedGesturesAndKeepsPageAfterCancellation", "testBackgroundClosesPendingRuntimeAndForegroundStartsFreshWork"}
        if len(tests) != len(expected) or set(tests) != expected or "Test Suite 'ReaderInteractionUITests' passed" not in log:
            raise ValueError("The actual Reader interaction UI test did not pass")
        return {"mode": mode, "suites": ["ReaderInteractionUITests"], "reportedTests": len(tests), "result": "passed"}
    suites = {
        "integration": ["WebKitRuntimeProbeTests", "ReaderProbeTests", "SourceContractProbeTests", "SourceCandidateValidatorTests", "ReadingViewportTests"],
        "recovery": ["WebKitRecoveryTests"],
    }[mode]
    counts = [int(count) for count in re.findall(r"Test run with (\d+) tests? in \d+ suites? passed", log)]
    if not counts or sum(counts) == 0:
        raise ValueError("No nonempty successful Swift Testing run was recorded")
    for suite in suites:
        if f"Suite {suite} passed" not in log:
            raise ValueError(f"Required suite did not pass: {suite}")
    result = {"mode": mode, "suites": suites, "reportedTests": sum(counts), "result": "passed"}
    if mode == "integration":
        ui = {
            "LibraryFlowUITests": "testAdoptSearchAllCatalogPagesAddAndReopenFromTheShelf",
            "ReaderFlowUITests": "testChapterNavigationSettingsAndCachedResumeAfterRelaunch",
        }
        for suite, method in ui.items():
            if (f"Test Case '-[SnowlitUITests.{suite} {method}]' passed" not in log
                    or f"Test Suite '{suite}' passed" not in log):
                raise ValueError(f"Required product UI did not pass: {suite}")
        result["productUISuites"] = list(ui)
    if mode == "recovery":
        if status.get("processSamplingErrors") != 0 or not status.get("processSamples"):
            raise ValueError("Process observation did not complete")
        if not (evidence / "process-samples.jsonl").is_file():
            raise ValueError("Process observations are missing")
        result["samplingCoverage"] = verify_recovery_observations(evidence, log, status["processSamples"])
        terminations = status.get('testTerminations', [])
        completed = re.findall(r'TerminationCompleted token=([0-9a-f-]{36}) hostPID=(\d+)', log)
        if len(terminations) != 3 or any(row.get('result') != 'signalled' for row in terminations):
            raise ValueError('Three controlled native process terminations are required')
        expected = {(row['token'], str(row['hostPID'])) for row in terminations}
        requested = re.findall(r'TerminationRequest token=([0-9a-f-]{36}) hostPID=(\d+)', log)
        if len(expected) != 3 or len(completed) != 3 or set(completed) != expected or set(requested) != expected:
            raise ValueError('Native termination callbacks and successful replacements are incomplete')
        result['nativeTerminations'] = terminations
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    parser.add_argument("mode", choices=["integration", "recovery", "reader-ui"])
    args = parser.parse_args()
    result = verify(args.evidence, args.mode)
    (args.evidence / "execution-verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
