"""Fault injection for the dedicated simulator owned by the recovery test run.

No name-based kill: a request must identify a live Snowlit test host, whose
launchd_sim parent has exactly one WebContent child in two fresh snapshots.
The test separately requires the native termination callback and recovery.
"""
import os
import re
import signal


def target_for(snapshot, host_pid):
    processes = {row['pid']: row for row in snapshot['processes']}
    host = processes.get(host_pid)
    if not host or host['executable'] != 'Snowlit' or host['measurement'] != 'measured':
        raise ValueError('The requested test host is not live')
    parent = processes.get(host['parentPID'])
    if not parent or parent['executable'] != 'launchd_sim':
        raise ValueError('The test host is not owned by a simulator')
    targets = [row for row in processes.values() if row['parentPID'] == parent['pid']
               and row['executable'] in {'WebContent', 'com.apple.WebKit.WebContent'}
               and row['measurement'] == 'measured']
    if len(targets) != 1:
        raise ValueError('A single test-simulator WebContent process is required')
    return host, parent, targets[0]


class TerminationControl:
    def __init__(self, log, *, kill=None):
        self.log = log
        self.kill = kill or (lambda pid: os.kill(pid, signal.SIGKILL))
        self.seen = set()
        self.results = []
        self.errors = 0

    def poll(self, snapshot, refresh):
        log = self.log.read_text(encoding='utf-8', errors='replace')
        for token, host_text in re.findall(r'TerminationRequest token=([0-9a-f-]{36}) hostPID=(\d+)', log):
            if token in self.seen:
                continue
            self.seen.add(token)
            record = {'token': token, 'hostPID': int(host_text)}
            try:
                before = target_for(snapshot, int(host_text))
                current = target_for(refresh(), int(host_text))
                identity = lambda rows: [(row['pid'], row['parentPID'], row['startedUTC'], row['executable']) for row in rows]
                if identity(before) != identity(current):
                    raise ValueError('Process identity changed before the test signal')
                host, parent, target = current
                self.kill(target['pid'])
                record.update(result='signalled', targetPID=target['pid'], targetStartedUTC=target['startedUTC'],
                              simulatorParentPID=parent['pid'])
            except (ValueError, OSError, KeyError, TypeError):
                self.errors += 1
                record.update(result='rejected')
            self.results.append(record)
