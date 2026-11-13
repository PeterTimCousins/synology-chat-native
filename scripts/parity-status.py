#!/usr/bin/env python3
"""Read-only acceptance gate for the full desktop parity goal, not the historical core scope."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = {f"F{i:03}" for i in range(1, 84)}


def check(document, root=ROOT):
    rows = document.get("rows", [])
    failures = []
    ids = [r.get("id") for r in rows if isinstance(r, dict)]
    if len(ids) != len(rows) or len(ids) != len(set(ids)) or not REQUIRED.issubset(ids):
        failures.append("Inventory must retain F001 through F083 exactly once; newly discovered features may be added.")
    accepted = []
    pending = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        feature = row.get("id", "unknown")
        receipt = row.get("parity_acceptance", {})
        valid = receipt.get("status") == "accepted" and bool(receipt.get("review"))
        proof = receipt.get("evidence", [])
        inputs = receipt.get("runtime_inputs", {})
        valid = valid and isinstance(proof, list) and bool(proof) and isinstance(inputs, dict) and bool(inputs)
        if valid:
            for item in proof:
                if not isinstance(item, dict) or not matches(root, item.get("path"), item.get("sha256")):
                    valid = False
            for path, digest in inputs.items():
                if not matches(root, path, digest):
                    valid = False
        if valid:
            accepted.append(feature)
        else:
            pending.append({"id": feature, "feature": row.get("feature"), "implementation": row.get("native_status"),
                            "reason": "Full parity acceptance absent, incomplete or stale; core-tested/partial is not acceptance."})
    if pending:
        failures.append(f"{len(pending)} feature parity outcomes remain unaccepted or stale.")
    return {"verdict": "NO-GO" if failures else "GO", "scope": "Full desktop parity plus modern native design",
            "accepted": len(accepted), "total": len(rows), "failures": failures, "pending": pending}


def matches(root, path, digest):
    if not isinstance(path, str) or not isinstance(digest, str):
        return False
    file = (root / path).resolve()
    if not file.is_relative_to(root.resolve()) or not file.is_file():
        return False
    return hashlib.sha256(file.read_bytes()).hexdigest() == digest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        result = check(json.loads((ROOT / "reference/synology-chat/feature-parity.json").read_text()))
    except (OSError, ValueError, TypeError, AttributeError):
        result = {"verdict": "NO-GO", "failures": ["Parity inventory unavailable or invalid."]}
    print(json.dumps(result, indent=2) if args.json else f"{result['verdict']}: {result.get('accepted', 0)}/{result.get('total', 83)} full-parity outcomes accepted")
    raise SystemExit(0 if result["verdict"] == "GO" else 1)
