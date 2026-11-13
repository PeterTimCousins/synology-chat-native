#!/usr/bin/env python3
"""Run one owned DEBUG probe, retaining only fixed status labels from its output.

Do not use this wrapper to retry an uncertain receipt. Session credentials are
loaded only by the child in memory; no raw runtime/network output is persisted.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("summary", type=Path)
    args = parser.parse_args()
    if not args.binary.is_file() or args.receipt.exists() or args.summary.exists():
        raise SystemExit("A current binary and unused receipt/summary paths are required.")
    # Claim the safe process summary before launching anything. O_EXCL also
    # refuses dangling links rather than replacing a previous run's record.
    fd = os.open(args.summary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    report = {
        "state": "running",
        "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "raw_runtime_output_retained": False,
    }
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        output.write(json.dumps(report, indent=2) + "\n")
        output.flush()
        process = subprocess.Popen(
            [str(args.binary.resolve()), "--native-own-edit-live-probe", str(args.receipt.resolve()),
             "--disable-native-read-state"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        statuses = []
        suppressed = 0
        try:
            assert process.stdout is not None
            for line in process.stdout:
                # Map exact application-owned lines to labels; never forward a
                # raw line, including third-party framework diagnostics.
                if line.startswith(b"Verified current-model edit and zero-attempt conflict refusal"):
                    statuses.append("verified")
                elif line.startswith(b"Own-Peter edit verification stopped."):
                    statuses.append("stopped_no_retry")
                elif line.startswith(b"Edit probe requires disabled read receipts"):
                    statuses.append("invalid_or_existing_receipt")
                else:
                    suppressed += 1
            code = process.wait()
        except BaseException:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise
        report.update(state="terminal", exit_code=code, probe_statuses=statuses,
                      suppressed_runtime_lines=suppressed,
                      receipt_created=args.receipt.is_file(),
                      finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
        output.seek(0)
        output.truncate()
        output.write(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"exit_code": code, "probe_statuses": statuses,
                      "receipt_created": args.receipt.is_file(), "raw_runtime_output_retained": False}))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
