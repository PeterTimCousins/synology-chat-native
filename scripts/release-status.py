#!/usr/bin/env python3
"""Read-only, fail-closed check of the native replacement's recorded assessment.

This checks freshness and recorded acceptance. It never infers acceptance from
test counts, changes scores, or substitutes for reviewing the linked evidence.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ASSESSMENT = "reference/synology-chat/release-audit.json"
EXCLUDED = {ASSESSMENT, "reference/synology-chat/release-audit.md"}
REQUIRED = {f"R{i}" for i in range(1, 12)}
CHECKS = {"security", "simplicity", "coherence", "compatibility", "retained_rollout", "final_audit"}


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT).decode().strip()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def baseline():
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT
    ).decode().split("\0")
    inputs = {name: sha(ROOT / name) if (ROOT / name).is_file() else None
              for name in sorted(set(names) - EXCLUDED - {""})}
    digest = hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"head": git("rev-parse", "HEAD"), "head_tree": git("rev-parse", "HEAD^{tree}"),
            "branch": git("branch", "--show-current"),
            "index_sha256": hashlib.sha256(subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=ROOT)).hexdigest(),
            "working_input_sha256": digest, "inputs": inputs}


def check(document, current, root=ROOT):
    failures = []
    for field in ("head", "head_tree", "branch", "index_sha256", "working_input_sha256", "inputs"):
        if document.get(field) != current.get(field):
            failures.append(f"Assessment drift: {field}")
    rows = document.get("outcomes", [])
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        return {"verdict": "NO-GO", "failures": failures + ["Invalid outcome matrix"]}
    ids = [row.get("id") for row in rows]
    if len(ids) != len(REQUIRED) or set(ids) != REQUIRED:
        failures.append("Outcome matrix must contain R1 through R11 exactly once")
    accepted = 0
    numerator = denominator = 0
    progress = []
    for row in rows:
        row_id = row.get("id", "unknown")
        scores = row.get("scores", [])
        valid_scores = isinstance(scores, list) and len(scores) == 10 and all(
            value is None or (type(value) in (int, float) and value in (0, 0.5, 1)) for value in scores)
        if not valid_scores or all(value is None for value in scores):
            failures.append(f"{row_id}: invalid evidence dimensions")
            continue
        exclusions = row.get("not_applicable", {})
        expected_exclusions = {str(index) for index, value in enumerate(scores) if value is None}
        if not isinstance(exclusions, dict) or set(exclusions) != expected_exclusions or any(
                not isinstance(reason, str) or not reason.strip() for reason in exclusions.values()):
            failures.append(f"{row_id}: inapplicable dimensions lack explicit reasons")
        applicable = [value for value in scores if value is not None]
        numerator += sum(applicable); denominator += len(applicable)
        progress.append({"id": row_id, "numerator": sum(applicable), "denominator": len(applicable)})
        if row.get("canonical_status") == "accepted":
            accepted += 1
        else:
            failures.append(f"{row_id}: canonical acceptance not recorded")
        if any(value != 1 for value in applicable):
            failures.append(f"{row_id}: evidence dimensions remain open")
        if row.get("blockers") != [] or row.get("reachable") != "yes":
            failures.append(f"{row_id}: blockers or reachability remain open")
        evidence = row.get("evidence")
        if not isinstance(evidence, list) or not evidence:
            failures.append(f"{row_id}: no pinned evidence")
        else:
            for item in evidence:
                if not isinstance(item, dict):
                    failures.append(f"{row_id}: invalid evidence reference"); continue
                path = root / item.get("path", "")
                if not path.is_file() or sha(path) != item.get("sha256"):
                    failures.append(f"{row_id}: evidence missing or changed: {item.get('path')}")
    cumulative = document.get("cumulative_checks", {})
    if not isinstance(cumulative, dict) or set(cumulative) != CHECKS or any(
            value != "closed" for value in cumulative.values()):
        failures.append("Cumulative checks remain open or unspecified")
    return {"verdict": "NO-GO" if failures else "GO", "accepted": accepted, "total": len(REQUIRED),
            "engineering_numerator": numerator, "engineering_denominator": denominator,
            "outcomes": progress, "failures": failures}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", action="store_true", help="Print current baseline only; does not approve or write an assessment")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        current = baseline()
        if args.snapshot:
            print(json.dumps(current, indent=2)); return 0
        result = check(json.loads((ROOT / ASSESSMENT).read_text()), current)
    except (OSError, ValueError, subprocess.CalledProcessError, TypeError) as error:
        result = {"verdict": "NO-GO", "failures": [f"Assessment unavailable: {type(error).__name__}"]}
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(result["verdict"] + " for native replacement release")
        if "accepted" in result:
            print(f"Canonical acceptance: {result['accepted']}/{result['total']}")
            print(f"Engineering/evidence: {result['engineering_numerator']}/{result['engineering_denominator']}")
        for failure in result["failures"]:
            print("- " + failure)
    return 0 if result["verdict"] == "GO" else 1


if __name__ == "__main__":
    sys.exit(main())
